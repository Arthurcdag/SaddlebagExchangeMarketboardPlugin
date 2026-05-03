#!/usr/bin/env bash
# Validates SaddlebagExchange/manifest.toml for D17/custom-repo hygiene.
# Run from repo root: bash scripts/validate-manifest.sh
# CI sets GITHUB_ACTIONS; warnings use ::warning:: when set.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

MANIFEST="$REPO_ROOT/SaddlebagExchange/manifest.toml"
CSPROJ_REL="SaddlebagExchange/SaddlebagExchange.csproj"
CSPROJ="$REPO_ROOT/$CSPROJ_REL"
REPO_JSON="$REPO_ROOT/repo.json"

warn() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning::$*"
  else
    echo "Warning: $*" >&2
  fi
}

die() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error::$*"
  else
    echo "Error: $*" >&2
  fi
  exit 1
}

version_from_csproj_text() {
  local text="$1"
  local v
  if v=$(echo "$text" | tr -d '\r' | grep -oE '<Version>[0-9]+\.[0-9]+\.[0-9]+</Version>' | head -1); then
    echo "$v" | sed -E 's/<\/?Version>//g'
    return
  fi
  if v=$(echo "$text" | tr -d '\r' | grep -oE '<AssemblyVersion>[0-9]+\.[0-9]+\.[0-9]+</AssemblyVersion>' | head -1); then
    echo "$v" | sed -E 's/<\/?AssemblyVersion>//g'
    return
  fi
  echo ""
}

[[ -f "$MANIFEST" ]] || die "Missing $MANIFEST"
[[ -f "$CSPROJ" ]] || die "Missing $CSPROJ"
[[ -f "$REPO_JSON" ]] || die "Missing $REPO_JSON"

if ! grep -qE '^commit\s*=' "$MANIFEST"; then
  die "manifest.toml has no commit = line"
fi

PIN_LINE=$(grep -E '^commit\s*=' "$MANIFEST" | head -1)
PIN=$(echo "$PIN_LINE" | sed -E 's/^commit\s*=\s*["'\'']?([^"'\'']+)["'\'']?.*/\1/' | tr -d '[:space:]')
[[ -n "$PIN" ]] || die "Could not parse commit from manifest.toml"

if [[ ! "$PIN" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
  die "manifest commit does not look like a git SHA: $PIN"
fi

PIN_FULL=$(git rev-parse --verify "$PIN^{commit}" 2>/dev/null) || die "manifest commit is not a valid object in this repo: $PIN"
echo "manifest.toml pins build to: $PIN_FULL"

if ! git merge-base --is-ancestor "$PIN_FULL" HEAD 2>/dev/null; then
  die "Pinned commit is not an ancestor of HEAD (wrong branch, shallow clone, or typo). Pin: $PIN_FULL"
fi

PIN_CS=$(git show "$PIN_FULL:$CSPROJ_REL" 2>/dev/null) || die "Cannot read $CSPROJ_REL at pinned commit (wrong project_path or missing history)."
PIN_VER=$(version_from_csproj_text "$PIN_CS")
[[ -n "$PIN_VER" ]] || die "Could not read <Version> (or <AssemblyVersion>) from csproj at pinned commit."

HEAD_CS=$(cat "$CSPROJ")
HEAD_VER=$(version_from_csproj_text "$HEAD_CS")
[[ -n "$HEAD_VER" ]] || die "Could not read <Version> from working-tree csproj."

if [[ "$HEAD_VER" != "$PIN_VER" ]]; then
  die "Version mismatch: working tree csproj is $HEAD_VER but manifest.toml pins $PIN_FULL which builds $PIN_VER. D17 will show $PIN_VER to users. Bump the pin (run scripts/release.sh or scripts/update-manifest-commit.* after the commit that contains $HEAD_VER), or revert the stray csproj bump."
fi

RJ_VER=$(grep -oE '"AssemblyVersion"[[:space:]]*:[[:space:]]*"[^"]+"' "$REPO_JSON" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
if [[ "$RJ_VER" != "$HEAD_VER" ]]; then
  die "repo.json AssemblyVersion ($RJ_VER) does not match working-tree csproj ($HEAD_VER). Run release script or align manually."
fi

if grep -qiF 'Initial release' "$MANIFEST"; then
  die "manifest changelog still contains a placeholder (e.g. Initial release). Write a real D17 changelog (see README)."
fi

if grep -qE '^changelog\s*=\s*""\s*$' "$MANIFEST"; then
  die "manifest changelog is empty."
fi

SUBJ=$(git log -1 --pretty=%s HEAD)
if echo "$SUBJ" | grep -qE '^Set manifest commit'; then
  if [[ "$PIN_FULL" == "$(git rev-parse HEAD)" ]]; then
    die "HEAD is a manifest-only pointer commit, but manifest.toml pins HEAD. That is impossible for a self-consistent tree (git cannot embed its own hash). The pin must be the *release* commit (parent). Run: bash scripts/update-manifest-commit.sh"
  fi
  if [[ "$PIN_FULL" != "$(git rev-parse HEAD~1)" ]]; then
    warn "HEAD is \"Set manifest commit …\" but pin is not HEAD~1. Expected pin $(git rev-parse HEAD~1) if you used scripts/release.sh."
  fi
fi

echo "validate-manifest.sh: OK (pin $PIN_FULL builds version $PIN_VER, matches repo.json and working tree)."
