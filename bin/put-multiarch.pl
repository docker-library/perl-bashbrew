#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;

# this is a replacement for "bashbrew put-shared" (without "--single-arch") to combine many architecture-specific repositories into manifest lists in a separate repository
# for example, combining amd64/bash:latest, arm32v5/bash:latest, ..., s390x/bash:latest into a single library/bash:latest manifest list
# (in a more efficient way than manifest-tool can do generically such that we can reasonably do 3700+ no-op tag pushes individually in ~9 minutes)

use Digest::SHA;
use Dpkg::Version;
use Getopt::Long;
use Mojo::Promise;

use Bashbrew qw( arch_to_platform bashbrew );
use Bashbrew::RemoteImageRef;
use Bashbrew::RegistryUserAgent;

my $ua = Bashbrew::RegistryUserAgent->new;

my $dryRun = '';
my $insecureRegistry = '';
GetOptions(
	'dry-run!' => \$dryRun,
	'insecure!' => \$insecureRegistry,
) or die "error in command line arguments\n";

$ua->insecure($insecureRegistry);

# TODO make this "die" conditional based on whether we're actually targeting Docker Hub?
$ua->hubProxy($ENV{DOCKERHUB_PUBLIC_PROXY} || die 'missing DOCKERHUB_PUBLIC_PROXY env (https://github.com/tianon/dockerhub-public-proxy)');

# get list of manifest list items and necessary blobs for a particular architecture
sub get_arch_p ($targetRef, $arch, $archRef) {
	return $ua->get_manifest_p($archRef)->then(sub ($manifestData = undef) {
		return unless $manifestData;
		my ($mediaType, $digest, $size, $manifest) = (
			$manifestData->{mediaType},
			$manifestData->{digest},
			$manifestData->{size},
			$manifestData->{manifest},
		);

		my @manifests;
		if (Bashbrew::RegistryUserAgent::is_media_image_list($mediaType)) {
			push @manifests, @{ $manifest->{manifests} };
		}
		elsif (Bashbrew::RegistryUserAgent::is_media_image_manifest($mediaType)) {
			push @manifests, {
				mediaType => $mediaType,
				size => $size,
				digest => $digest,
			};
		}
		else {
			die "unknown mediaType '$mediaType' for '$archRef'";
		}

		# filter out objects we know we don't want (not a hashref, missing required fields)
		@manifests = grep {
			# https://specs.opencontainers.org/image-spec/descriptor/?v=v1.0.1
			'HASH' eq ref($_) && $_->{mediaType} && $_->{digest} && $_->{size}
		} @manifests;

		# filter objects down to just fields we care about
		@manifests = map {
			# https://specs.opencontainers.org/image-spec/descriptor/?v=v1.0.1
			{ %{ $_ }{qw{
				mediaType
				digest
				size
				annotations
				platform
			}} }
		} @manifests;

		my %platform = arch_to_platform($arch);

		# normalize the result a bit (delete empty annotations and make sure platform is an object and that every platform has at least "os" and "architecture")
		@manifests = map {
			$_->{platform} //= {};
			for my $key (qw( os architecture )) {
				$_->{platform}{$key} //= $platform{$key};
			}
			delete $_->{annotations} unless defined $_->{annotations};
			$_
		} @manifests;

		# now that we have a list of potential manifests, let's filter it based on %platform's "os" and "architecture" (avoids "riscv64" from being able to poison us with anything other than riscv64-tagged manifests)
		my @filteredManifests = grep {
			Bashbrew::RegistryUserAgent::is_media_image_manifest($_->{mediaType})
			&& $_->{platform}{os} eq $platform{os}
			&& $_->{platform}{architecture} eq $platform{architecture}
		} @manifests;
		# normalize "platform" objects (esp. for "variant")
		for my $item (@filteredManifests) {
			for my $key (keys %platform) {
				$item->{platform}{$key} = $platform{$key};
			}
		}

		# include any relevant "Docker-style" attachments (https://github.com/moby/buildkit/pull/2983, https://github.com/moby/buildkit/pull/3129, etc)
		my %digests = map { $_ => 1 } map { $_->{digest} } @filteredManifests;
		push @filteredManifests, grep {
			$_->{mediaType} eq Bashbrew::RegistryUserAgent::MEDIA_OCI_MANIFEST_V1
			&& $_->{platform}{os} eq 'unknown'
			&& $_->{platform}{architecture} eq 'unknown'
			&& $_->{annotations}
			&& $digests{$_->{annotations}{'vnd.docker.reference.digest'} // ''}
			&& $_->{annotations}{'vnd.docker.reference.type'}
		} @manifests;

		# if we're looking at Windows, we need to make an effort to fetch the "os.version" value from the config for the platform object
		return Mojo::Promise->map({ concurrency => 3 }, sub ($item) {
			unless (
				Bashbrew::RegistryUserAgent::is_media_image_manifest($item->{mediaType})
				&& $item->{platform}{os} eq 'windows'
				&& !$item->{platform}{'os.version'}
			) {
				return Mojo::Promise->resolve($item);
			}
			return $ua->get_manifest_p($archRef->clone->digest($item->{digest}))->then(sub ($manifestData = undef) {
				return $item unless $manifestData;
				my $manifest = $manifestData->{manifest};
				return $item unless $manifest->{config} and $manifest->{config}{digest};
				return $ua->get_blob_p($archRef->clone->digest($manifest->{config}{digest}))->then(sub ($config = undef) {
					if ($config && $config->{'os.version'}) {
						$item->{platform}{'os.version'} = $config->{'os.version'};
					}
					return $item;
				});
			});
		}, @filteredManifests)->then(sub (@manifests) {
			@manifests = map { @$_ } @manifests;
			return ($archRef, \@manifests);
		});
	});
}

sub needed_artifacts_p ($targetRef, $sourceRef) {
	return $ua->head_manifest_p($targetRef->clone->digest($sourceRef->digest))->then(sub ($exists) {
		return if $exists;

		return $ua->get_manifest_p($sourceRef)->then(sub ($manifestData = undef) {
			return unless $manifestData;

			my $manifest = $manifestData->{manifest};
			my $schemaVersion = $manifest->{schemaVersion};
			my @blobs;
			if ($schemaVersion == 1) {
				push @blobs, map { $_->{blobSum} } @{ $manifest->{fsLayers} };
			}
			elsif ($schemaVersion == 2) {
				die "this should never happen: $manifest->{mediaType}" unless $manifest->{mediaType} eq Bashbrew::RegistryUserAgent::MEDIA_OCI_MANIFEST_V1 || $manifest->{mediaType} eq Bashbrew::RegistryUserAgent::MEDIA_MANIFEST_V2; # sanity check
				push @blobs, $manifest->{config}{digest}, map { $_->{urls} ? () : $_->{digest} } @{ $manifest->{layers} };
			}
			else {
				die "this should never happen: $schemaVersion"; # sanity check
			}

			return Mojo::Promise->all(
				Mojo::Promise->resolve([ 'manifest', $sourceRef ]),
				(
					@blobs ? Mojo::Promise->map({ concurrency => 3 }, sub ($blob) {
						return $ua->head_blob_p($targetRef->clone->digest($blob))->then(sub ($exists) {
							return if $exists;
							return 'blob', $sourceRef->clone->digest($blob);
						});
					}, @blobs) : (),
				),
			)->then(sub { map { @$_ } @_ });
		});
	});
}

Mojo::Promise->map({ concurrency => 8 }, sub ($img) {
	die "image '$img' is missing explict namespace -- bailing to avoid accidental push to 'library'" unless $img =~ m!/!;

	my $ref = Bashbrew::RemoteImageRef->new($img);

	my @refs = (
		$ref->tag
		? ( $ref )
		: (
			map { $ref->clone->tag((split /:/)[1]) }
			List::Util::uniq sort
			split /\n/, bashbrew('list', $ref->repo_name)
		)
	);
	return Mojo::Promise->resolve unless @refs; # no tags, nothing to do! (opensuse, etc)

	return Mojo::Promise->map({ concurrency => 1 }, sub ($ref) {
		my @arches = (
			List::Util::uniq sort
			split /\n/, bashbrew('cat', '--format', '{{ range .Entries }}{{ range .Architectures }}{{ . }}={{ archNamespace . }}{{ "\n" }}{{ end }}{{ end }}', $ref->repo_name . ':' . $ref->tag)
		);
		return Mojo::Promise->resolve unless @arches; # no arches, nothing to do!

		return Mojo::Promise->map({ concurrency => 1 }, sub ($archData) {
			my ($arch, $archNamespace) = split /=/, $archData;
			die "missing arch namespace for '$arch'" unless $archNamespace;
			my $archRef = Bashbrew::RemoteImageRef->new($archNamespace . '/' . $ref->repo_name . ':' . $ref->tag);
			die "'$archRef' registry does not match '$ref' registry" unless $archRef->registry_host eq $ref->registry_host;
			return get_arch_p($ref, $arch, $archRef);
		}, @arches)->then(sub (@archResponses) {
			my @manifestListItems;
			my @neededArtifactPromises;
			for my $archResponse (@archResponses) {
				next unless @$archResponse;
				my ($archRef, $manifestListItems) = @$archResponse;
				push @manifestListItems, @$manifestListItems;
				push @neededArtifactPromises, map { my $digest = $_->{digest}; sub { needed_artifacts_p($ref, $archRef->clone->digest($digest)) } } @$manifestListItems;
			}

			# sort Windows image manifests to ensure proper order in the image index
			my $sorter = sub {
				# also sort platform->variant for linux/arm?
				for my $obj ($a, $b) {
					return 0 unless $obj->{platform};
					for my $field (qw{ os architecture os.version }) {
						return 0 unless $obj->{platform}{$field};
					}
				}
				return 0 unless $a->{platform}{os} eq $b->{platform}{os};
				return 0 unless $a->{platform}{architecture} eq $b->{platform}{architecture};
				# reverse version sort windows versions: 10.0.20348.2227, 10.0.17763.5329
				return - ( Dpkg::Version->new($a->{platform}{'os.version'}) <=> Dpkg::Version->new($b->{platform}{'os.version'}) );
			};
			@manifestListItems = sort $sorter @manifestListItems;

			my $manifestList = {
				schemaVersion => 2,
				mediaType => (
					(
						@manifestListItems
						&& (
							$manifestListItems[0]->{mediaType} eq Bashbrew::RegistryUserAgent::MEDIA_MANIFEST_V2
							|| $manifestListItems[0]->{mediaType} eq Bashbrew::RegistryUserAgent::MEDIA_MANIFEST_V1
						)
					)
					# if our first manifest uses a Docker media type, let's use a Docker manifest list for our outer wrapper
					? Bashbrew::RegistryUserAgent::MEDIA_MANIFEST_LIST
					# otherwise, let's default to the OCI index media type
					: Bashbrew::RegistryUserAgent::MEDIA_OCI_INDEX_V1
				),
				manifests => \@manifestListItems,
			};
			my $manifestListJson = Mojo::JSON::encode_json($manifestList);
			my $manifestListDigest = 'sha256:' . Digest::SHA::sha256_hex($manifestListJson);

			return $ua->head_manifest_p($ref->clone->digest($manifestListDigest))->then(sub ($exists) {
				# if we already have the manifest we're planning to push in the namespace where we plan to push it, we can skip all blob mounts! \m/
				return if $exists;
				# (we can also skip if we're in "dry run" mode since we only care about the final manifest matching in that case)
				return if $dryRun;

				return (
					@neededArtifactPromises
					? Mojo::Promise->map({ concurrency => 1 }, sub { $_->() }, @neededArtifactPromises)
					: Mojo::Promise->resolve
				)->then(sub (@neededArtifacts) {
					@neededArtifacts = map { @$_ } @neededArtifacts;
					# now "@neededArtifacts" is a list of tuples of the format [ sourceNamespace, sourceRepo, type, digest ], ready for cross-repo mounting / PUTing (where type is "blob" or "manifest")
					my @mountBlobPromises;
					my @putManifestPromises;
					for my $neededArtifact (@neededArtifacts) {
						next unless @$neededArtifact;
						my ($type, $artifactRef) = @$neededArtifact;
						if ($type eq 'blob') {
							# https://specs.opencontainers.org/distribution-spec/?v=v1.0.0#mounting-a-blob-from-another-repository
							push @mountBlobPromises, sub { $ua->authenticated_registry_req_p(
								POST => $ref,
								'repository:' . $ref->repo . ':push repository:' . $artifactRef->repo . ':pull',
								'blobs/uploads/?mount=' . $artifactRef->digest . '&from=' . $artifactRef->repo,
							) };
						}
						elsif ($type eq 'manifest') {
							push @putManifestPromises, sub { $ua->get_manifest_p($artifactRef)->then(sub ($manifestData = undef) {
								return unless $manifestData;
								return $ua->authenticated_registry_req_p(
									PUT => $ref,
									'repository:' . $ref->repo . ':push',
									'manifests/' . $artifactRef->digest,
									$manifestData->{mediaType}, $manifestData->{verbatim},
								)->then(sub ($tx) {
									if (my $err = $tx->error) {
										die "Failed to PUT $artifactRef to $ref: " . $err->{message};
									}
									return;
								});
							}) };
						}
						else {
							die "this should never happen: $type"; # sanity check
						}
					}

					# mount any necessary blobs
					return (
						@mountBlobPromises
						? Mojo::Promise->map({ concurrency => 1 }, sub { $_->() }, @mountBlobPromises)
						: Mojo::Promise->resolve
					)->then(sub {
						# ... *then* push any missing image manifests (because they'll fail to push if the blobs aren't pushed first)
						if (@putManifestPromises) {
							return Mojo::Promise->map({ concurrency => 1 }, sub { $_->() }, @putManifestPromises);
						}
						return;
					});
				});
			})->then(sub {
				# let's do one final check of the tag we're pushing to see if it's already the manifest we expect it to be (to avoid making literally every image constantly "Updated a few seconds ago" all the time)
				return $ua->head_manifest_p($ref)->then(sub ($digest = undef) {
					if ($digest && $digest eq $manifestListDigest) {
						say "Skipping $ref ($manifestListDigest)" unless $dryRun; # if we're in "dry run" mode, we need clean output
						return;
					}

					if ($dryRun) {
						say "Would push $ref ($manifestListDigest)";
						return;
					}

					# finally, all necessary blobs and manifests are pushed, we've verified that we do in fact need to push this manifest, so we should be golden to push it!
					return $ua->authenticated_registry_req_p(
						PUT => $ref,
						$ref->repo . ':push',
						'manifests/' . $ref->tag,
						$manifestList->{mediaType}, $manifestListJson
					)->then(sub ($tx) {
						if (my $err = $tx->error) {
							die 'Failed to push manifest list: ' . $err->{message};
						}
						my $digest = $tx->res->headers->header('Docker-Content-Digest');
						say "Pushed $ref ($digest)";
						if (!$digest) {
							say {*STDERR} "WARNING: missing 'Docker-Content-Digest: $manifestListDigest' header (for '$ref')";
						}
						elsif ($manifestListDigest ne $digest) {
							die "expected '$manifestListDigest', got '$digest' (for '$ref')";
						}
					});
				});
			});
		});
	}, @refs);
}, @ARGV)->catch(sub {
	say {*STDERR} "ERROR: $_" for @_;
	exit scalar @_;
})->wait;
