#!/usr/bin/env bash
# Convenience wrapper to run the ed2:personal podman image against a run
# directory.
#
# Usage:
#   ./run_ed2.sh sites/BCI/run ED2IN-001_baseline
#
# RUNDIR      directory containing ED2IN + input data, mounted at /data
# ED2IN_NAME  namelist file name inside RUNDIR (default: ED2IN)
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 RUNDIR [ED2IN_NAME]" >&2
    exit 1
fi

RUNDIR="$(cd "$1" && pwd)"
ED2IN_NAME="${2:-ED2IN}"

if [[ ! -f "${RUNDIR}/${ED2IN_NAME}" ]]; then
    echo "Could not find ${ED2IN_NAME} in ${RUNDIR}" >&2
    exit 1
fi

podman run --rm --ulimit stack=-1:-1 \
    -v "${RUNDIR}:/data:Z" \
    ed2:personal -f "${ED2IN_NAME}"
