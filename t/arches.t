use Mojo::Base -strict;

use Test::More;

require_ok('Bashbrew');

my %archPlatformTestCases = (
	# https://github.com/docker-library/bashbrew/blob/faf7efe8f489f717c5439688af1e34d4641f74cf/architecture/oci-platform.go#L3-L27
	amd64 =>    { os => 'linux', architecture => 'amd64' },
	arm32v5 =>  { os => 'linux', architecture => 'arm', variant => 'v5' },
	arm32v6 =>  { os => 'linux', architecture => 'arm', variant => 'v6' },
	arm32v7 =>  { os => 'linux', architecture => 'arm', variant => 'v7' },
	arm64v8 =>  { os => 'linux', architecture => 'arm64', variant => 'v8' },
	i386 =>     { os => 'linux', architecture => '386' },
	mips64le => { os => 'linux', architecture => 'mips64le' },
	ppc64le =>  { os => 'linux', architecture => 'ppc64le' },
	riscv64 =>  { os => 'linux', architecture => 'riscv64' },
	s390x =>    { os => 'linux', architecture => 's390x' },

	'windows-amd64' => { os => 'windows', architecture => 'amd64' },
);
for my $arch (sort keys %archPlatformTestCases) {
	my %platform = Bashbrew::arch_to_platform($arch);
	is_deeply(\%platform, $archPlatformTestCases{$arch}, "right OCI platform for arch '$arch'");
}

done_testing();
