#!/usr/bin/env bash
# =============================================================================
#  Publish an Interchange artifact drop as a GitHub release.
# =============================================================================
#  Run this yourself — it uses YOUR authenticated `gh` session. Nothing here
#  stores or asks for a password.
#
#    gh auth login                 # once, interactive, in your own terminal
#    ./publish-release.sh v2026.08.191 /path/to/artifacts
#
#  It generates SHA256SUMS from the actual files, creates (or updates) the
#  release, and uploads every artifact as a release ASSET.
#
#  ⚠️  Release assets, NOT committed files. GitHub hard-limits committed files
#      at 100 MB and the LXC templates are ~247 MB. Never `git add` an artifact
#      — once a large blob is in history it is painful to remove.
# =============================================================================
set -euo pipefail

TAG="${1:-}"
SRC="${2:-}"
REPO="${REPO:-goobenet/interchange-deploy}"

[[ -n "$TAG" && -n "$SRC" ]] || { echo "usage: $0 <tag> <artifact-dir>   (e.g. $0 v2026.08.191 ./artifacts)"; exit 1; }
[[ -d "$SRC" ]] || { echo "no such directory: $SRC"; exit 1; }
command -v gh >/dev/null || { echo "gh CLI not found — install it, then: gh auth login"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not authenticated. Run: gh auth login"; exit 1; }

# Only ship the artifact types customers install.
mapfile -t FILES < <(find "$SRC" -maxdepth 1 -type f \( -name '*.deb' -o -name '*.tar.zst' -o -name '*-Setup.exe' \) | sort)
[[ ${#FILES[@]} -gt 0 ]] || { echo "no artifacts (*.deb, *.tar.zst, *-Setup.exe) found in $SRC"; exit 1; }

echo "Publishing ${#FILES[@]} artifact(s) to $REPO @ $TAG"
printf '  %s\n' "${FILES[@]##*/}"

# Integrity manifest, generated from the real bytes — never hand-written.
SUMS="$SRC/SHA256SUMS"
( cd "$SRC" && sha256sum "${FILES[@]##*/}" > SHA256SUMS )
echo; echo "SHA256SUMS:"; sed 's/^/  /' "$SUMS"

# The deploy script pins these hashes per version, so the script and the
# artifacts must be released together. If a hash below differs from the
# PRODUCTS manifest in interchange-vm.sh, fix the script BEFORE publishing —
# a mismatch makes the deployer refuse to install, which is the correct
# behaviour but a confusing customer experience.
echo
read -r -p "Do these match the PRODUCTS manifest in interchange-vm.sh? [y/N]: " ok
[[ "${ok:-N}" =~ ^[Yy]$ ]] || { echo "aborted — reconcile the hashes first"; exit 1; }

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "release $TAG exists — uploading (clobbering same-named assets)"
  gh release upload "$TAG" "${FILES[@]}" "$SUMS" --repo "$REPO" --clobber
else
  gh release create "$TAG" "${FILES[@]}" "$SUMS" --repo "$REPO" \
    --title "Interchange $TAG" \
    --notes "Interchange product artifacts.

Every binary in this release is a licensable production build. Verify any
download against \`SHA256SUMS\`.

Deploy with the one-liner in the README."
fi

echo
echo "done: https://github.com/$REPO/releases/tag/$TAG"
echo "asset URLs look like:"
echo "  https://github.com/$REPO/releases/download/$TAG/${FILES[0]##*/}"
