#!/usr/bin/env bash
set -Eeuo pipefail

# docker run -dit --name registry --restart always -p 5000:5000 registry

# docker run -dit --name registry --restart always -p 5000:5000 --env REGISTRY_VALIDATION_MANIFESTS_URLS_ALLOW='["^.*$"]' --env REGISTRY_VALIDATION_MANIFESTS_URLS_DENY='[]' registry

image="${1:-hello-world:latest}"
registry='docker.io'
target='localhost:5000'

arches="$(bashbrew cat --format '{{- range .Entries }}{{ json .Architectures -}}{{- end -}}' "$image")"
arches="$(jq <<<"$arches" -sr 'flatten | unique | map(@sh) | join(" ")')"
eval "arches=( $arches )"

if ! command -v crane &> /dev/null; then
	if ! docker image inspect --format '.' gcr.io/go-containerregistry/crane &> /dev/null; then
		docker pull gcr.io/go-containerregistry/crane
	fi
	crane() {
		local args=(
			--interactive --rm
			--user "$RANDOM:$RANDOM"
			--network host
			--security-opt no-new-privileges
		)
		if [ -t 0 ] && [ -t 1 ]; then
			args+=( --tty )
		fi
		docker run "${args[@]}" gcr.io/go-containerregistry/crane "$@"
	}
fi

BASHBREW_ARCH_NAMESPACES=
for arch in "${arches[@]}"; do
	if [ "$arch" = 'windows-amd64' ]; then
		src="$registry/winamd64/$image"
	else
		src="$registry/$arch/$image"
	fi
	trg="$target/$arch/$image"

	crane copy "$src" --insecure "$trg"

	# skopeo appears to be the only one of these "registry copy" tools willing to do format conversions between Docker and OCI 👀
	#skopeo copy --multi-arch all --format oci "docker://$src" --dest-tls-verify=false "docker://$trg"
	#skopeo copy --multi-arch all --format v2s2 "docker://$src" --dest-tls-verify=false "docker://$trg"

	[ -z "$BASHBREW_ARCH_NAMESPACES" ] || BASHBREW_ARCH_NAMESPACES+=', '
	BASHBREW_ARCH_NAMESPACES+="$arch = $target/$arch"
done
export BASHBREW_ARCH_NAMESPACES

export DOCKERHUB_PUBLIC_PROXY=https://bogus.example.com # unnecessary for pushing to localhost

./put-multiarch.sh --dry-run --insecure "$target/library/$image"

exec ./put-multiarch.sh --insecure "$target/library/$image"
