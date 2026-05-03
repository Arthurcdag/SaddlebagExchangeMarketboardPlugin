#!/usr/bin/env bash
# Sets SaddlebagExchange/manifest.toml commit to the git SHA D17 should build.
# Run from repo root.
#
# Usage:
#   bash scripts/update-manifest-commit.sh              # smart default (see below)
#   bash scripts/update-manifest-commit.sh <ref>       # explicit ref (branch, HEAD~1, full SHA)
#
# Smart default: if the latest commit message starts with "Set manifest commit"
# (the follow-up commit from scripts/release.sh), this pins HEAD~1 — the release
# tree — instead of HEAD. Otherwise uses HEAD. This avoids the impossible case
# where manifest would point at the manifest-only commit.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO_ROOT/SaddlebagExchange/manifest.toml"

if [[ ! -f "$MANIFEST" ]]; then
  echo "Error: $MANIFEST not found." >&2
  exit 1
fi
if ! grep -qE '^commit\s*=' "$MANIFEST"; then
  echo "Error: no commit = line in $MANIFEST" >&2
  exit 1
fi

if [[ -n "${1:-}" ]]; then
  COMMIT="$(git -C "$REPO_ROOT" rev-parse "$1")"
  echo "Using explicit ref: $1 -> $COMMIT"
else
  SUBJECT="$(git -C "$REPO_ROOT" log -1 --pretty=%s HEAD)"
  if echo "$SUBJECT" | grep -qE '^Set manifest commit'; then
    COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD~1)"
    echo "Latest commit is a manifest-pointer commit. Pinning D17 build to release tree: $COMMIT"
  else
    COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
    echo "Pinning D17 build to HEAD: $COMMIT"
  fi
fi

if [[ "$(uname -s)" =~ ^(MINGW|MSYS|CYGWIN) ]]; then
  sed -i "s/^commit = .*/commit = \"$COMMIT\"/" "$MANIFEST"
else
  sed -i.bak "s/^commit = .*/commit = \"$COMMIT\"/" "$MANIFEST" && rm -f "${MANIFEST}.bak"
fi

if ! grep -qF "$COMMIT" "$MANIFEST"; then
  echo "Error: manifest was not updated with commit $COMMIT" >&2
  exit 1
fi

echo "Set SaddlebagExchange/manifest.toml commit to $COMMIT"
echo "Next: git add SaddlebagExchange/manifest.toml && git commit -m \"Set manifest commit …\" && bash scripts/validate-manifest.sh"
