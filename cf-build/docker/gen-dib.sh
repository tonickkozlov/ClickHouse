#!/bin/bash

set -eu -o pipefail

CURDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$CURDIR"

echo $CURDIR

# Separate assignment and export to avoid masking return value.
VERSION_STRING=$(git describe --tags --long --abbrev=12 | sed 's/^v//')
export VERSION_STRING

docker_images_path="./../../.docker-images"

rm -rf "$docker_images_path"

if [[ "$1" == "apt" ]]; then
  cat > "$docker_images_path" << EOF
image_stubs:
  clickhouse:
    context: cf-build/docker
images:
  - name: clickhouse
    dockerfile: cf-build/docker/Dockerfile
    versions: ${VERSION_STRING}
    build_arguments:
      version: ${VERSION_STRING}
  - name: clickhouse
    dockerfile: cf-build/docker/Dockerfile.dbg
    versions: ${VERSION_STRING}-with-dbg
    build_arguments:
      version: ${VERSION_STRING}
EOF
elif [[ "$1" == "local" ]]; then
  cat > "$docker_images_path" << EOF
image_stubs:
  clickhouse:
    context: artifacts # cfsetup build puts *.deb files there
images:
  - name: clickhouse
    dockerfile: cf-build/docker/Dockerfile.local
    versions: ${VERSION_STRING}
    build_arguments:
      version: ${VERSION_STRING}
EOF
else
  echo "Unknown target '$1'. Usage: $0 <apt|local>"
fi
