# Attribution

This build combines several projects. None of the actual NVR functionality, NPU driver support, or media driver code originates in this repo — this repo's own contribution is limited to the version-bump patches and CI automation in `scripts/build.sh` and `.github/workflows/`.

## Frigate

- **Project:** [Frigate](https://github.com/blakeblackshear/frigate) — open-source NVR with realtime AI object detection.
- **License:** MIT, © Frigate, Inc.
- **Trademark:** the "Frigate" name, branding, and logo are trademarks of Frigate, Inc. and are **not** covered by the MIT License (Frigate's own repo carries a separate trademark policy). This build's Docker Hub tag (`bdelima/frigate-panther-lake`) uses "frigate" descriptively, to say what it's a build of — it is not an official Frigate, Inc. release and carries no official branding or endorsement.

## Kellen Renshaw's `npu-update` branch

- **Fork:** [KellenRenshaw/frigate](https://github.com/KellenRenshaw/frigate), branch `npu-update`.
- **Upstream PR:** [blakeblackshear/frigate#24007](https://github.com/blakeblackshear/frigate/pull/24007) (open, not merged as of this writing).
- **License:** MIT, inherited unchanged from Frigate.
- Adds Panther Lake NPU driver support that isn't in upstream Frigate yet. This repo's fork builds directly on top of this branch.
- This repo forked his branch once and now builds independently of his repo staying online (see the README for why) — that's a technical resilience choice, not a reduction in credit. The NPU support this build relies on originates entirely from his work.

## Intel NPU driver

- **Project:** [intel/linux-npu-driver](https://github.com/intel/linux-npu-driver)
- **License:** MIT, © Intel Corporation.
- Downloaded as a prebuilt release tarball during the image build (see `scripts/build.sh` for the pinned version).

## Intel media driver (iHD) and gmmlib

- **Projects:** [intel/media-driver](https://github.com/intel/media-driver), [intel/gmmlib](https://github.com/intel/gmmlib)
- Compiled from source during the image build (see `docker/main/build_intel_media_driver.sh` in the Frigate tree, and the version pins in `scripts/build.sh`).

## QSV runtime packages

`libmfxgen1` and `libvpl2`, pinned to specific versions sourced from Intel's own Ubuntu jammy apt repository — see `scripts/build.sh` for exact versions and the reasoning.

---

If you hold rights to any of the above and have concerns about this build, please open an issue on this repo.
