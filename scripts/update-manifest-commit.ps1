# Sets SaddlebagExchange/manifest.toml commit to the git SHA D17 should build.
# Run from repo root.
#
# Usage:
#   .\scripts\update-manifest-commit.ps1              # smart default (see bash script)
#   .\scripts\update-manifest-commit.ps1 HEAD~1       # explicit ref

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repoRoot "SaddlebagExchange\manifest.toml"

if (-not (Test-Path $manifestPath)) {
    Write-Error "Not found: $manifestPath"
    exit 1
}
$contentHead = Get-Content $manifestPath -Raw
if ($contentHead -notmatch '(?m)^commit\s*=') {
    Write-Error "No commit = line in $manifestPath"
    exit 1
}

if ($args.Count -ge 1 -and $args[0]) {
    $commit = git -C $repoRoot rev-parse $args[0]
    Write-Output "Using explicit ref: $($args[0]) -> $commit"
} else {
    $subject = git -C $repoRoot log -1 --pretty=%s HEAD
    if ($subject -match '^Set manifest commit') {
        $commit = git -C $repoRoot rev-parse HEAD~1
        Write-Output "Latest commit is a manifest-pointer commit. Pinning D17 build to release tree: $commit"
    } else {
        $commit = git -C $repoRoot rev-parse HEAD
        Write-Output "Pinning D17 build to HEAD: $commit"
    }
}

$content = Get-Content $manifestPath -Raw
$content = $content -replace '(?m)^commit\s*=.*$', "commit = `"$commit`""
Set-Content $manifestPath -Value $content.TrimEnd() -NoNewline

Write-Output "Set SaddlebagExchange/manifest.toml commit to $commit"
Write-Output "Next: git add SaddlebagExchange/manifest.toml; git commit -m 'Set manifest commit …'; .\scripts\validate-manifest.ps1"
