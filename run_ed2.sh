#!/usr/bin/env bash
# Convenience wrapper to run the ed2 podman image against a run directory.
#
# Usage:
#   ./run_ed2.sh sites/BCI/run ED2IN-001_baseline
#
# RUNDIR      directory containing ED2IN + input data, mounted at /data
# ED2IN_NAME  namelist file name inside RUNDIR (default: ED2IN)
#
# Image defaults to ghcr.io/jamedina09/ed2:latest; override with IMAGE_TAG=
# <version> to pin a specific ED2 build (see ed2-personal-container's
# CHANGELOG.md for what's available), or IMAGE=<full-ref> to point at a
# purely local image instead (e.g. IMAGE=localhost/ed2:d971a620 while
# developing/testing a build before it's pushed). LOCAL_UID/LOCAL_GID
# default to your own account's - the image's entrypoint remaps its
# internal user to match, so output written into RUNDIR is owned by you,
# not some arbitrary container default. Override either only if you have a
# specific reason to.
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 RUNDIR [ED2IN_NAME]" >&2
    exit 1
fi

RUNDIR="$(cd "$1" && pwd)"
ED2IN_NAME="${2:-ED2IN}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
IMAGE="${IMAGE:-ghcr.io/jamedina09/ed2:${IMAGE_TAG}}"
LOCAL_UID="${LOCAL_UID:-$(id -u)}"
LOCAL_GID="${LOCAL_GID:-$(id -g)}"

if [[ ! -f "${RUNDIR}/${ED2IN_NAME}" ]]; then
    echo "Could not find ${ED2IN_NAME} in ${RUNDIR}" >&2
    exit 1
fi

podman run --rm --ulimit stack=-1:-1 \
    -e LOCAL_UID="${LOCAL_UID}" -e LOCAL_GID="${LOCAL_GID}" \
    -v "${RUNDIR}:/data:Z" \
    "${IMAGE}" -f "${ED2IN_NAME}"
