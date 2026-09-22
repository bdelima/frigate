# frigate (Panther Lake NPU fork)

This is Bob's fork, built on top of [Kellen Renshaw's `npu-update` branch](https://github.com/KellenRenshaw/frigate/tree/npu-update) ([upstream PR #24007](https://github.com/blakeblackshear/frigate/pull/24007), not yet merged into Frigate proper), which adds Panther Lake NPU driver support. This fork automatically tracks new upstream Frigate releases, merges each one onto the NPU branch, applies a few additional driver/runtime version patches on top, and publishes the result to Docker Hub as [`bdelima/frigate-panther-lake`](https://hub.docker.com/r/bdelima/frigate-panther-lake).

**This is an unofficial, personal build.** It is not affiliated with, endorsed by, or supported by Frigate, Inc. or Kellen Renshaw. See [`ATTRIBUTION.md`](ATTRIBUTION.md) for full credit and licensing details on everything this build bundles.

## What gets patched on top of Kellen's branch

Kellen's `npu-update` branch pins an older NPU driver version (`v1.28.0` as of this writing). Each automated build additionally:

1. **Bumps the NPU driver** to a newer version (currently `v1.38.0`) and the matching Level Zero loader package.
2. **Pins the QSV runtime** (`libmfxgen1`/`libvpl2`) to known-good pre-regression versions from Intel's own jammy apt repo, instead of the versions Debian trixie ships. *(Note: the real root cause of the Frigate 0.18 QSV regression this was originally built to work around turned out to be a filter-chain ordering bug in `frigate/ffmpeg_presets.py`, not this package version — see the linked Frigate discussion in the commit history. This pin may become unnecessary once that's fixed upstream in 0.18.1; worth revisiting then.)*
3. **Bumps the iHD media driver** (VAAPI) and `gmmlib` to current quarterly releases (compiled from source, not an apt pin).

Exact versions are in [`scripts/build.sh`](scripts/build.sh) — that's the single source of truth, not this README.

## How builds happen

`.github/workflows/auto-build-publish.yml` runs daily (and can be triggered manually with a specific tag via workflow_dispatch):

1. Finds the latest stable upstream Frigate release tag (or uses the tag you give it manually).
2. Checks Docker Hub — if that version's already published, stops (no-op).
3. Otherwise creates/updates a branch `npu-update-<tag>`, merges the upstream tag onto `npu-update`, and applies the patches above.
4. **On a merge conflict:** commits the conflicted state (with markers, untouched) to that branch, pushes it, and fails the workflow run cleanly. Nothing gets auto-resolved. To fix:
   ```bash
   git fetch origin && git checkout npu-update-<tag>
   git reset --soft HEAD~1   # undo the WIP conflict commit, keep the conflict markers in your working tree
   # edit the conflicting file(s), keeping Kellen's NPU changes alongside whatever changed upstream
   git add <resolved files>
   git commit --no-edit
   git push origin npu-update-<tag>
   ```
   Then re-run the workflow (workflow_dispatch, with `tag` set to that same upstream tag).
5. On a clean merge, builds with `make local` (Frigate's own build target — **never** `docker build` directly, it skips generating `frigate/version.py` and the image crash-loops on startup), tags it `frigate:<version>-panther_lake`, pushes to Docker Hub, and cuts a GitHub Release.

## Running it

```yaml
services:
  frigate:
    image: bdelima/frigate-panther-lake:latest   # or pin to a specific version, e.g. :0.18.1-panther_lake
    # ... your existing Frigate compose config (devices, volumes, ports, etc.) is unchanged
```

## Why this is a fork, not a live dependency on Kellen's repo

This repo is a one-time fork of `KellenRenshaw/frigate` (`npu-update` branch), not a live integration with it. The fork operation copies his NPU driver work into this repo's own git history permanently — after that, nothing here ever clones, fetches, or otherwise reaches out to his repo again. The daily build only talks to upstream Frigate (`blakeblackshear/frigate`) and to this repo itself.

That's intentional: it means this build keeps working indefinitely even if `KellenRenshaw/frigate` is ever deleted, renamed, or made private. The tradeoff is that if Kellen later improves his NPU work upstream, it won't show up here automatically — someone would need to notice and manually merge it in. Given this repo already patches NPU driver versions on top of his base independently, that's an acceptable tradeoff.

None of this changes the credit due: the NPU support this build relies on originates entirely from Kellen's work (see [`ATTRIBUTION.md`](ATTRIBUTION.md)), and that stays true regardless of what happens to his repo going forward.

## One-time repo setup (for whoever's bootstrapping this)

- Fork [`KellenRenshaw/frigate`](https://github.com/KellenRenshaw/frigate) (branch `npu-update`) to `bdelima/frigate`.
- Add `.github/workflows/auto-build-publish.yml` and `scripts/build.sh` from this delivery to the fork's default branch.
- Add `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` as repo secrets (Settings → Secrets and variables → Actions) — the workflow needs both to push.
- The workflow uses the built-in `GITHUB_TOKEN` to push branches/commits it creates back to this same repo — no extra PAT needed, but confirm under Settings → Actions → General → Workflow permissions that "Read and write permissions" is selected, or pushes from the workflow will fail with a permissions error.
