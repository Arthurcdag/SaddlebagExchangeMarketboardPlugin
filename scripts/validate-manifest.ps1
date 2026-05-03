# Validates SaddlebagExchange/manifest.toml for D17/custom-repo hygiene.
# Run from repo root: .\scripts\validate-manifest.ps1

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$manifestPath = Join-Path $repoRoot "SaddlebagExchange\manifest.toml"
$csprojRel = "SaddlebagExchange/SaddlebagExchange.csproj"
$csprojPath = Join-Path $repoRoot "SaddlebagExchange\SaddlebagExchange.csproj"
$repoJsonPath = Join-Path $repoRoot "repo.json"

function Get-VersionFromCsprojText([string]$text) {
    $m = [regex]::Match($text, '<Version>(\d+\.\d+\.\d+)</Version>')
    if ($m.Success) { return $m.Groups[1].Value }
    $m = [regex]::Match($text, '<AssemblyVersion>(\d+\.\d+\.\d+)</AssemblyVersion>')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Write-ValidateError([string]$msg) {
    if ($env:GITHUB_ACTIONS) { Write-Output "::error::$msg" } else { Write-Error $msg }
    exit 1
}

function Write-ValidateWarning([string]$msg) {
    if ($env:GITHUB_ACTIONS) { Write-Output "::warning::$msg" } else { Write-Warning $msg }
}

if (-not (Test-Path $manifestPath)) { Write-ValidateError "Missing $manifestPath" }
if (-not (Test-Path $csprojPath)) { Write-ValidateError "Missing $csprojPath" }
if (-not (Test-Path $repoJsonPath)) { Write-ValidateError "Missing $repoJsonPath" }

$manifestRaw = Get-Content $manifestPath -Raw
if ($manifestRaw -notmatch '(?m)^commit\s*=') { Write-ValidateError "manifest.toml has no commit = line" }

$m = [regex]::Match($manifestRaw, '(?m)^commit\s*=\s*["'']([0-9a-fA-F]+)["'']')
if (-not $m.Success) {
    $m = [regex]::Match($manifestRaw, '(?m)^commit\s*=\s*([0-9a-fA-F]+)\s*$')
}
if (-not $m.Success) { Write-ValidateError "Could not parse commit from manifest.toml" }
$pin = $m.Groups[1].Value

$pinFull = (git rev-parse "$pin^{commit}" 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or -not $pinFull) {
    Write-ValidateError "manifest commit is not a valid object in this repo: $pin"
}
Write-Output "manifest.toml pins build to: $pinFull"

git merge-base --is-ancestor $pinFull HEAD 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-ValidateError "Pinned commit is not an ancestor of HEAD. Pin: $pinFull"
}

$pinShow = git show "${pinFull}:$csprojRel" 2>$null
if ($LASTEXITCODE -ne 0 -or -not $pinShow) { Write-ValidateError "Cannot read $csprojRel at pinned commit." }
$pinCs = if ($pinShow -is [array]) { $pinShow -join "`n" } else { [string]$pinShow }
$pinVer = Get-VersionFromCsprojText $pinCs
if (-not $pinVer) { Write-ValidateError "Could not read Version from csproj at pinned commit." }

$headCs = Get-Content $csprojPath -Raw
$headVer = Get-VersionFromCsprojText $headCs
if (-not $headVer) { Write-ValidateError "Could not read Version from working-tree csproj." }

if ($headVer -ne $pinVer) {
    Write-ValidateError "Version mismatch: working tree csproj is $headVer but manifest pins $pinFull which builds $pinVer. Run .\scripts\release.ps1 pin after the commit that contains $headVer, or see README."
}

$repoJson = Get-Content $repoJsonPath -Raw
$rm = [regex]::Match($repoJson, '"AssemblyVersion"\s*:\s*"([^"]+)"')
if (-not $rm.Success) { Write-ValidateError "Could not parse AssemblyVersion from repo.json" }
$rjVer = $rm.Groups[1].Value
if ($rjVer -ne $headVer) {
    Write-ValidateError "repo.json AssemblyVersion ($rjVer) does not match csproj ($headVer)."
}

if ($manifestRaw -match 'Initial release') {
    Write-ValidateError "manifest changelog still contains a placeholder (Initial release). See README."
}
if ($manifestRaw -match '(?m)^changelog\s*=\s*""\s*$') {
    Write-ValidateError "manifest changelog is empty."
}

$subj = git log -1 --pretty=%s HEAD
if ($subj -match '^Set manifest commit') {
    $headSha = git rev-parse HEAD
    if ($pinFull -eq $headSha) {
        Write-ValidateError "HEAD is manifest-only but manifest pins HEAD (invalid). Run: .\scripts\release.ps1 pin"
    }
    $parentSha = git rev-parse HEAD~1
    if ($pinFull -ne $parentSha) {
        Write-ValidateWarning "HEAD is Set manifest commit but pin is not HEAD~1. Expected $parentSha if you used release.ps1."
    }
}

Write-Output "validate-manifest.ps1: OK (pin $pinFull builds $pinVer)."
