# Changelog

Maps each release of this repo to the `ghcr.io/jamedina09/ed2` image tag
it's meant to be used with. The image itself is built from
[ed2-personal-container](https://github.com/jamedina09/ed2-personal-container)
— see that repo's own `CHANGELOG.md` for the underlying ED2/toolchain
versions.

## v1.0.0 — 2026-07-19

- Works with image tag `d971a620` (and `latest`, at the time).
- `run_ed2.sh` now defaults to `ghcr.io/jamedina09/ed2:${IMAGE_TAG:-latest}`
  instead of a local-only `ed2:personal` tag that required a manual
  `podman tag` step after pulling — set `IMAGE_TAG=<version>` to pin, or
  `IMAGE=<full-ref>` to point at a purely local image while
  developing/testing a build.
- `run_ed2.sh` now passes `LOCAL_UID`/`LOCAL_GID` (defaulting to your own
  account via `id -u`/`id -g`) to `podman run` — the paired image version
  (`d971a620`+) remaps its internal user to match, so output is owned by
  you, not a container-internal default. **Fixes a real bug**: without this,
  the first real end-to-end smoke test of the paired image against this
  repo's BCI pipeline failed with a permission-denied error writing into the
  run directory — this release is what makes that combination actually work,
  not just theoretically compatible. See `ed2-personal-container`'s
  `CHANGELOG.md` for the full story.
- Removed hardcoded `/Users/medinaja/...` absolute paths from `README.md`
  (5 occurrences) in favor of relative/generic references, and updated §2.2
  to lead with `podman pull` instead of building the image locally by
  default, matching the image repo's own publishing workflow.
- Added Troubleshooting entries for the two UID/GID-related failure modes
  above.
- Initial versioned release — this repo existed and worked before this
  entry, but had no `CHANGELOG.md` and no version-to-image-tag mapping.

**Verification performed:** this is the release that was actually used for
`ed2-personal-container`'s own smoke test — the full BCI pipeline (data
validation → met/init build → `ED2IN` build → `ed2` run → output), run for
real against the paired image's `d971a620` build, not a synthetic check.
Completed in 167.4s for the default 3-month window, output correctly owned
by the host user.
