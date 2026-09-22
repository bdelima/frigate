#!/usr/bin/env bash
#
# scripts/build.sh
#
# Builds a custom Frigate image with Kellen Renshaw's Panther Lake NPU
# driver bump (PR #24007: https://github.com/blakeblackshear/frigate/pull/24007)
# merged onto a chosen upstream release tag, with Bob's own NPU
# driver/QSV/iHD version patches applied on top.
#
# This is the CI-safe, non-interactive descendant of the original
# build-frigate-npu.sh (which supported an interactive tag picker and a
# --continue mode for resuming after a manually-resolved merge conflict).
# Those two things don't translate to a CI runner, which can't prompt for
# input or pause mid-run — so this version always requires an explicit
# tag argument, and on a merge conflict it commits the conflicted state
# (with markers, so nothing is silently guessed at) to the target branch,
# pushes it if --push-on-conflict is set, and exits with status 2 rather
# than trying to resolve anything itself.
#
# Usage:
#   scripts/build.sh <upstream-tag> [--push-on-conflict]
#
# Exit codes:
#   0 — built successfully, image tagged locally as frigate:<ver>-panther_lake
#   1 — a real error (bad tag, patch didn't apply, build failed, etc.)
#   2 — merge conflict; branch left with a WIP conflict commit for manual
#       resolution (pushed to origin if --push-on-conflict was passed)
#
# Local use (e.g. resolving a conflict, or a one-off build) works the same
# as before: run this from inside your clone of the fork, on whatever
# branch/state you're in — it's idempotent at every patch step, same as
# the original script.

set -euo pipefail

TAG="${1:-}"
[[ -n "$TAG" ]] || { echo "ERROR: usage: $0 <upstream-tag> [--push-on-conflict]" >&2; exit 1; }
PUSH_ON_CONFLICT=0
[[ "${2:-}" == "--push-on-conflict" ]] && PUSH_ON_CONFLICT=1

UPSTREAM_URL="https://github.com/blakeblackshear/frigate.git"
NPU_BRANCH="npu-update"

# ---------------------------------------------------------------------------
# NPU driver version to patch in on top of Kellen's PR base (v1.28.0).
# Kellen's npu-update branch always introduces the same fixed lines in
# docker/main/install_deps.sh referencing v1.28.0 — these are the exact
# strings this script patches. To bump again later when Intel ships a
# newer driver, just update these three variables (check
# https://github.com/intel/linux-npu-driver/releases for the latest
# tarball filename, and the release's own instructions for the paired
# libze1/Level Zero version and download URL).
# ---------------------------------------------------------------------------
NPU_DRIVER_TAG="v1.38.0"
NPU_DRIVER_ASSET="linux-npu-driver-v1.38.0.20260910-34487311128-ubuntu2404.tar.gz"
LEVEL_ZERO_DEB_URL="https://snapshot.ppa.launchpadcontent.net/kobuk-team/intel-graphics/ubuntu/20260830T100000Z/pool/main/l/level-zero-loader/libze1_1.32.0-1~24.04~ppa1_amd64.deb"

OLD_NPU_DRIVER_TAG="v1.28.0"
OLD_NPU_DRIVER_ASSET="linux-npu-driver-v1.28.0.20251218-20347000698-ubuntu2404.tar.gz"
OLD_LEVEL_ZERO_LINE="wget https://github.com/oneapi-src/level-zero/releases/download/v1.28.2/level-zero_1.28.2+u22.04_amd64.deb"

# QSV runtime pin — see the long comment in this project's README for why
# this exists. Kept as-is from the original script; worth revisiting once
# Frigate 0.18.1 ships its own filter-chain-ordering fix, since that (not
# this package pin) turned out to be the real root cause of the QSV
# regression this was originally built to work around.
QSV_MFXGEN_VERSION="24.2.4-914~22.04"
QSV_VPL_VERSION="1:2.13.0.0-1012~22.04"

OLD_JAMMY_INSTALL_LINE="    apt-get -qq install --no-install-recommends --no-install-suggests -y \\
        libmfx1"
OLD_TRIXIE_GEN_VPL_LINE="    apt-get -qq install -y -t trixie libmfx-gen1.2 libvpl2"
OLD_TRIXIE_LIBVA_LINE="    apt-get -qq install -y -t trixie libva2 libva-drm2 libzstd1"
NEW_TRIXIE_LIBVA_LINE="    apt-get -qq install -y -t trixie libva2 libva-drm2 libzstd1 libstdc++6"

NEW_MEDIA_DRIVER_VERSION="intel-media-26.2.4"
NEW_GMMLIB_VERSION="intel-gmmlib-22.10.0"
OLD_MEDIA_DRIVER_VERSION="intel-media-25.2.6"
OLD_GMMLIB_VERSION="intel-gmmlib-22.7.2"

log()  { echo -e "\n==> $*"; }
die()  { echo -e "\nERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 1: upstream remote + tags
# ---------------------------------------------------------------------------
if ! git remote get-url upstream >/dev/null 2>&1; then
  log "Adding upstream remote"
  git remote add upstream "$UPSTREAM_URL"
fi

log "Fetching tags from upstream"
git fetch upstream --tags --force

git rev-parse "$TAG" >/dev/null 2>&1 || die "Tag '$TAG' not found in upstream."

# ---------------------------------------------------------------------------
# Step 2: create/checkout the merge branch and merge the tag
# ---------------------------------------------------------------------------
BRANCH="npu-update-${TAG}"

if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  log "Branch $BRANCH already exists — checking it out"
  git checkout "$BRANCH"
else
  log "Creating branch $BRANCH from $NPU_BRANCH"
  git checkout -b "$BRANCH" "$NPU_BRANCH"
fi

log "Merging $TAG into $BRANCH"
if git merge --no-edit "$TAG"; then
  log "Merge completed cleanly"
else
  UNMERGED=$(git diff --name-only --diff-filter=U || true)
  echo
  echo "MERGE CONFLICT — manual resolution needed."
  echo "Conflicting file(s):"
  echo "$UNMERGED" | sed 's/^/  - /'

  # Commit the conflicted state as-is (with conflict markers) so it's a
  # real, inspectable commit rather than lost working-tree state — this
  # is what gets pushed for manual resolution, not a clean history.
  git add -A
  git commit -m "WIP: merge conflict merging ${TAG} into ${BRANCH} — needs manual resolution" --no-verify

  if [[ "$PUSH_ON_CONFLICT" -eq 1 ]]; then
    log "Pushing conflicted branch $BRANCH for manual resolution"
    git push origin "$BRANCH"
  fi

  echo
  echo "To resolve locally:"
  echo "  git fetch origin && git checkout $BRANCH"
  echo "  git reset --soft HEAD~1   # undo the WIP conflict commit, keep conflict markers in the working tree"
  echo "  # edit the conflicting file(s) listed above, keeping Kellen's NPU driver bump"
  echo "  # alongside whatever changed upstream"
  echo "  git add <resolved files>"
  echo "  git commit --no-edit"
  echo "  git push origin $BRANCH"
  echo "  # then re-run the 'Build and publish' workflow with tag=$TAG"
  exit 2
fi

# ---------------------------------------------------------------------------
# Step 3: patch in the latest NPU driver version, on top of Kellen's
# PR base (which always ships pinned to v1.28.0)
# ---------------------------------------------------------------------------
INSTALL_DEPS="docker/main/install_deps.sh"

if grep -q "$NPU_DRIVER_TAG" "$INSTALL_DEPS" 2>/dev/null; then
  log "install_deps.sh already patched to $NPU_DRIVER_TAG — skipping"
elif grep -q "$OLD_NPU_DRIVER_TAG" "$INSTALL_DEPS" 2>/dev/null; then
  log "Patching NPU driver: $OLD_NPU_DRIVER_TAG -> $NPU_DRIVER_TAG"
  sed -i "s|download/${OLD_NPU_DRIVER_TAG}/|download/${NPU_DRIVER_TAG}/|" "$INSTALL_DEPS"
  sed -i "s|${OLD_NPU_DRIVER_ASSET}|${NPU_DRIVER_ASSET}|g" "$INSTALL_DEPS"
  ESCAPED_OLD_LZ=$(printf '%s\n' "$OLD_LEVEL_ZERO_LINE" | sed 's/[&/\]/\\&/g')
  ESCAPED_NEW_LZ=$(printf '%s\n' "wget $LEVEL_ZERO_DEB_URL" | sed 's/[&/\]/\\&/g')
  sed -i "s|${ESCAPED_OLD_LZ}|${ESCAPED_NEW_LZ}|" "$INSTALL_DEPS"

  grep -q "$NPU_DRIVER_TAG" "$INSTALL_DEPS" || die "NPU driver patch did not apply — upstream may have changed $INSTALL_DEPS. Check 'grep -n -B2 -A20 linux-npu-driver $INSTALL_DEPS' and update the OLD_*/NPU_DRIVER_* variables at the top of this script."

  git add "$INSTALL_DEPS"
  git commit -m "Bump NPU driver to ${NPU_DRIVER_TAG} / Level Zero to match" --no-edit
  log "NPU driver patched and committed"
else
  echo "WARNING: Neither $OLD_NPU_DRIVER_TAG nor $NPU_DRIVER_TAG found in $INSTALL_DEPS — skipping NPU driver patch. Check manually."
fi

# ---------------------------------------------------------------------------
# Step 4: pin the QSV runtime (libmfxgen1/libvpl2)
# ---------------------------------------------------------------------------
if grep -qF "libmfxgen1=${QSV_MFXGEN_VERSION}" "$INSTALL_DEPS" 2>/dev/null; then
  log "install_deps.sh already pinned to QSV runtime ${QSV_MFXGEN_VERSION} — skipping"
elif grep -qF "$OLD_JAMMY_INSTALL_LINE" "$INSTALL_DEPS" 2>/dev/null && grep -qF "$OLD_TRIXIE_GEN_VPL_LINE" "$INSTALL_DEPS" 2>/dev/null; then
  log "Pinning QSV runtime: libmfxgen1=${QSV_MFXGEN_VERSION}, libvpl2=${QSV_VPL_VERSION}"

  NEW_JAMMY_INSTALL_LINE="    apt-get -qq install --no-install-recommends --no-install-suggests -y \\
        libmfx1 libmfxgen1=${QSV_MFXGEN_VERSION} libvpl2=${QSV_VPL_VERSION}"

  python3 - "$INSTALL_DEPS" <<PYEOF
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

old_jammy = r"""${OLD_JAMMY_INSTALL_LINE}"""
new_jammy = r"""${NEW_JAMMY_INSTALL_LINE}"""
old_trixie_line = r"""${OLD_TRIXIE_GEN_VPL_LINE}"""

assert content.count(old_jammy) == 1, f"expected 1 match for jammy install line, found {content.count(old_jammy)}"
assert content.count(old_trixie_line) == 1, f"expected 1 match for trixie gen/vpl line, found {content.count(old_trixie_line)}"

content = content.replace(old_jammy, new_jammy)
content = content.replace(old_trixie_line + "\n", "")

with open(path, "w") as f:
    f.write(content)
PYEOF

  grep -qF "libmfxgen1=${QSV_MFXGEN_VERSION}" "$INSTALL_DEPS" || die "QSV pin did not apply — check 'grep -n -B5 -A20 intel-graphics.key $INSTALL_DEPS'."

  git add "$INSTALL_DEPS"
  git commit -m "Pin QSV runtime (libmfxgen1/libvpl2) to pre-Battlemage-bump versions from Intel jammy repo" --no-edit
  log "QSV runtime pinned and committed"
else
  echo "WARNING: Expected QSV install lines not found in $INSTALL_DEPS — skipping. Check manually."
fi

# ---------------------------------------------------------------------------
# Step 5: preserve the libstdc++6 upgrade the removed trixie line used to
# provide as a transitive dependency
# ---------------------------------------------------------------------------
if grep -qF "$NEW_TRIXIE_LIBVA_LINE" "$INSTALL_DEPS" 2>/dev/null; then
  log "libstdc++6 already added to trixie libva line — skipping"
elif grep -qF "$OLD_TRIXIE_LIBVA_LINE" "$INSTALL_DEPS" 2>/dev/null; then
  log "Adding libstdc++6 to trixie libva install line"
  sed -i "s|${OLD_TRIXIE_LIBVA_LINE}|${NEW_TRIXIE_LIBVA_LINE}|" "$INSTALL_DEPS"
  grep -qF "$NEW_TRIXIE_LIBVA_LINE" "$INSTALL_DEPS" || die "libstdc++6 fix did not apply."
  git add "$INSTALL_DEPS"
  git commit -m "Add libstdc++6 to trixie libva install to fix libigdgmm12 dependency after QSV pin" --no-edit
  log "libstdc++6 fix applied and committed"
else
  echo "WARNING: Expected trixie libva install line not found in $INSTALL_DEPS — skipping."
fi

# ---------------------------------------------------------------------------
# Step 6: bump the iHD media driver (VAAPI) and gmmlib
# ---------------------------------------------------------------------------
MEDIA_DRIVER_SCRIPT="docker/main/build_intel_media_driver.sh"

if grep -qF "MEDIA_DRIVER_VERSION=\"${NEW_MEDIA_DRIVER_VERSION}\"" "$MEDIA_DRIVER_SCRIPT" 2>/dev/null; then
  log "build_intel_media_driver.sh already bumped — skipping"
elif grep -qF "MEDIA_DRIVER_VERSION=\"${OLD_MEDIA_DRIVER_VERSION}\"" "$MEDIA_DRIVER_SCRIPT" 2>/dev/null; then
  log "Bumping iHD media driver: ${OLD_MEDIA_DRIVER_VERSION} -> ${NEW_MEDIA_DRIVER_VERSION}"
  sed -i "s|MEDIA_DRIVER_VERSION=\"${OLD_MEDIA_DRIVER_VERSION}\"|MEDIA_DRIVER_VERSION=\"${NEW_MEDIA_DRIVER_VERSION}\"|" "$MEDIA_DRIVER_SCRIPT"
  sed -i "s|GMMLIB_VERSION=\"${OLD_GMMLIB_VERSION}\"|GMMLIB_VERSION=\"${NEW_GMMLIB_VERSION}\"|" "$MEDIA_DRIVER_SCRIPT"
  grep -qF "MEDIA_DRIVER_VERSION=\"${NEW_MEDIA_DRIVER_VERSION}\"" "$MEDIA_DRIVER_SCRIPT" || die "iHD/gmmlib bump did not apply."
  git add "$MEDIA_DRIVER_SCRIPT"
  git commit -m "Bump iHD media driver to ${NEW_MEDIA_DRIVER_VERSION}, gmmlib to ${NEW_GMMLIB_VERSION}" --no-edit
  log "iHD media driver / gmmlib bumped and committed"
else
  echo "WARNING: Neither driver version string found in $MEDIA_DRIVER_SCRIPT — skipping."
fi

# ---------------------------------------------------------------------------
# Step 7: push the successfully patched branch (before the build, so the
# patched source is recoverable even if the build itself fails)
# ---------------------------------------------------------------------------
log "Pushing patched branch $BRANCH"
git push origin "$BRANCH"

# ---------------------------------------------------------------------------
# Step 8: build
# ---------------------------------------------------------------------------
log "Building image with 'make local' (do not use 'docker build' directly — it skips generating frigate/version.py and the image will crash-loop on startup)"
make local

VERSION="${TAG#v}"
IMAGE_TAG="frigate:${VERSION}-panther_lake"
log "Tagging built image as $IMAGE_TAG"
docker tag frigate:latest "$IMAGE_TAG"

log "Verifying version.py inside the built image"
docker run --rm --entrypoint sh "$IMAGE_TAG" -c "cat /opt/frigate/frigate/version.py"

echo
echo "============================================================"
echo " Build complete: $IMAGE_TAG"
echo " NPU driver baked in: $NPU_DRIVER_TAG"
echo " QSV runtime pinned: libmfxgen1=${QSV_MFXGEN_VERSION}, libvpl2=${QSV_VPL_VERSION}"
echo " iHD media driver: ${NEW_MEDIA_DRIVER_VERSION} (gmmlib ${NEW_GMMLIB_VERSION})"
echo "============================================================"

# Export for the calling workflow to pick up as outputs
echo "IMAGE_TAG=${IMAGE_TAG}" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
echo "VERSION=${VERSION}" >> "${GITHUB_ENV:-/dev/null}" 2>/dev/null || true
