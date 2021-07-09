package Bashbrew;
use Mojo::Base -base, -signatures;

use version; our $VERSION = qv(0.0.1); # TODO useful version number?

use Exporter 'import';
our @EXPORT_OK = qw(
	arch_to_platform
	bashbrew
);

# TODO create dedicated Bashbrew::Arch package?
sub arch_to_platform ($arch) {
	if ($arch =~ m{
		^
		(?: ([^-]+) - )? # optional "os" prefix ("windows-", etc)
		([^-]+?) # "architecture" bit ("arm64", "s390x", etc)
		(v[0-9]+)? # optional "variant" suffix ("v7", "v6", etc)
		$
	}x) {
		my ($os, $architecture, $variant) = ($1, $2, $3);
		$os //= 'linux';
		if ($architecture eq 'i386') {
			$architecture = '386';
		}
		elsif ($architecture eq 'arm32') {
			$architecture = 'arm';
		}
		elsif ($architecture eq 'risc' && $variant) { # "riscv64" is not "risc, v64" 😂
			$architecture .= $variant;
			$variant = '';
		}
		return (
			os => $os,
			architecture => $architecture,
			($variant ? (variant => $variant) : ()),
		);
	}
	die "unrecognized architecture format in: $arch";
}

# TODO make this promise-based and non-blocking? (and/or make a dedicated Package for it?)
# https://github.com/jberger/Mojolicious-Plugin-TailLog/blob/master/lib/Mojolicious/Plugin/TailLog.pm#L16-L22
# https://metacpan.org/pod/Capture::Tiny
# https://metacpan.org/pod/Mojo::IOLoop#subprocess
# https://metacpan.org/pod/IO::Async::Process
# (likely not worth it, given how quickly it typically completes)
sub bashbrew (@) {
	open my $fh, '-|', 'bashbrew', @_ or die "failed to run 'bashbrew': $!";
	local $/;
	my $output = <$fh>;
	close $fh or die "failed to close 'bashbrew'";
	chomp $output;
	return $output;
}

1;
