#!/bin/bash
# Lint every shell script in the repository with koalaman/shellcheck (same pinned image locally and in CI).
# Zero findings is the gate: any note, warning or error fails. Usage: bash tests/shellcheck.sh
set -euo pipefail

cd "$(dirname "$0")/.."

# Pinned by version and digest, like the base images in the Dockerfile. Bump both together.
image="koalaman/shellcheck:v0.11.0@sha256:bb596a0d169b85ddd81d8b6d3a2ff6d5baf5fca10b97f575ebc647c3dff62b3d"

# bash scripts: shebang is bash or with-contenv bash (the s6-rc 'up' files are execline, not shell)
bash_files=(
    rootfs/scripts/helper/*.sh
    rootfs/scripts/init-scripts/*.sh
    rootfs/scripts/service-scripts/*.sh
    rootfs/etc/s6-overlay/s6-rc.d/*/run
    rootfs/etc/s6-overlay/s6-rc.d/*/finish
    docs/examples/s6-rc/*/*/run
    tests/*.sh
)
# POSIX sh scripts run by the Dockerfile with /bin/sh (busybox ash)
sh_files=(
    build/build-scripts/*
)

run() { docker run --rm -v "${PWD}:/mnt:ro" "${image}" --color=always "$@"; }

echo "shellcheck -s bash on ${#bash_files[@]} files"
run -s bash "${bash_files[@]}"
echo "shellcheck -s sh on ${#sh_files[@]} files"
run -s sh "${sh_files[@]}"
echo "shellcheck: no findings"
