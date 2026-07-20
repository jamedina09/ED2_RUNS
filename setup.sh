#!/usr/bin/env bash
# One-time setup: pull the ed2 image and extract the two host-side assets
# (R-utils/, ED2IN template) baked into it, into this repo's root.
#
# Usage:
#   ./setup.sh
#
# Same IMAGE_TAG/IMAGE override as run_ed2.sh - re-run this after switching
# to a different ED2 version to refresh R-utils/ED2IN to match:
#   IMAGE_TAG=d971a620 ./setup.sh
#
# Replaces the old multi-step process of separately cloning and building
# ed2-personal-container's ~700MB build stage locally just to `podman cp`
# two small files out of it - both are baked into the runtime image itself
# now, so a single `podman cp` against the image you already pulled is all
# that's needed. See ed2-personal-container's CHANGELOG.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

IMAGE_TAG="${IMAGE_TAG:-latest}"
IMAGE="${IMAGE:-ghcr.io/jamedina09/ed2:${IMAGE_TAG}}"

if podman image exists "${IMAGE}"; then
    echo "*** ${IMAGE} already present locally, skipping pull"
else
    echo "*** Pulling ${IMAGE}"
    podman pull "${IMAGE}"
fi

echo "*** Extracting R-utils/ and ED2IN from ${IMAGE}"
CONTAINER="ed2-setup-extract-$$"
podman create --name "$CONTAINER" "${IMAGE}" >/dev/null
trap 'podman rm "$CONTAINER" >/dev/null 2>&1 || true' EXIT

rm -rf R-utils
podman cp "$CONTAINER:/opt/ed2_assets/R-utils" R-utils
mkdir -p ED/run
podman cp "$CONTAINER:/opt/ed2_assets/ED2IN" ED/run/ED2IN

echo "*** Done. R-utils/ and ED/run/ED2IN are ready (from ${IMAGE})."
echo "Next: place site raw data (see README.md), then follow the manual"
echo "or automated workflow (README.md §4/§5)."
