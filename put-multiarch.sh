#!/usr/bin/env bash
set -Eeuo pipefail

bashbrewLibrary="${BASHBREW_LIBRARY:-$HOME/docker/official-images/library}"
[ -n "$BASHBREW_ARCH_NAMESPACES" ]

dockerConfig="${DOCKER_CONFIG:-$HOME/.docker}"
[ -s "$dockerConfig/config.json" ]

args=(
	--mount "type=bind,src=$bashbrewLibrary,dst=/library,ro"
	--env BASHBREW_LIBRARY=/library
	--env BASHBREW_ARCH_NAMESPACES

	--mount "type=bind,src=$dockerConfig,dst=/.docker,ro"
	--env DOCKER_CONFIG='/.docker'

	--env DOCKERHUB_PUBLIC_PROXY

	#--env MOJO_CLIENT_DEBUG=1
	#--env MOJO_IOLOOP_DEBUG=1

	# localhost!
	--network host

	# no signal handlers 😅
	--init
)

if [ -t 0 ] && [ -t 1 ]; then
	args+=( -it )
fi

dir="$(dirname "$BASH_SOURCE")"
img="$(docker build -q -t oisupport/perl-bashbrew "$dir")"

#exec docker run --rm "${args[@]}" "$img" perl -MCarp::Always bin/put-multiarch.pl "$@"
exec docker run --rm "${args[@]}" "$img" bin/put-multiarch.pl "$@"
