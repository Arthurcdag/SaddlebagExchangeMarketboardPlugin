# Full release: bump version, tag, set manifest.toml commit, validate.
# Manifest-only pin: .\scripts\release.ps1 pin [ref]
# Run from repo root.

param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$CommandOrVersion = "",
    [Parameter(Mandatory = $false, Position = 1)]
    [string]$PinRef = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $repoRoot ".git"))) {
    Write-Error "Not a git repo root: $repoRoot. Run from repo root."
    exit 1
}

$manifestPath = Join-Path $repoRoot "SaddlebagExchange\manifest.toml"

function Invoke-PinManifestOnly {
    param([string]$ExplicitRef)
    if (-not (Test-Path $manifestPath)) {
        Write-Error "Not found: $manifestPath"
        exit 1
    }
    $contentHead = Get-Content $manifestPath -Raw
    if ($contentHead -notmatch '(?m)^commit\s*=') {
        Write-Error "No commit = line in $manifestPath"
        exit 1
    }

    if ($ExplicitRef) {
        $commit = git -C $repoRoot rev-parse $ExplicitRef
        Write-Output "Using explicit ref: $ExplicitRef -> $commit"
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

    $validatePs1 = Join-Path $repoRoot "scripts\validate-manifest.ps1"
    if (Get-Command bash -ErrorAction SilentlyContinue) {
        Push-Location $repoRoot
        try {
            & bash "scripts/validate-manifest.sh"
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        } finally {
            Pop-Location
        }
    } else {
        & $validatePs1
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    Write-Output ""
    Write-Output "Pin-only done. Commit the manifest when ready:"
    Write-Output "  git add SaddlebagExchange/manifest.toml; git commit -m 'Set manifest commit …'; git push origin main"
}

if ($CommandOrVersion -in @("pin", "--pin-manifest")) {
    $explicit = $PinRef
    Invoke-PinManifestOnly -ExplicitRef $explicit
    exit 0
}

if (-not $CommandOrVersion) {
    Write-Error "Usage: release.ps1 <X.Y.Z> | release.ps1 pin [ref]"
    exit 1
}

$Version = $CommandOrVersion
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    Write-Error "Version must be X.Y.Z (e.g. 1.0.11), or use: release.ps1 pin [ref]. Got: $Version"
    exit 1
}

$csprojPath = Join-Path $repoRoot "SaddlebagExchange\SaddlebagExchange.csproj"
$repoJsonPath = Join-Path $repoRoot "repo.json"

foreach ($p in $csprojPath, $repoJsonPath, $manifestPath) {
    if (-not (Test-Path $p)) {
        Write-Error "Not found: $p"
        exit 1
    }
}

# 1) Bump version in csproj
$csproj = Get-Content $csprojPath -Raw
if ($csproj -match '<Version>[^<]+</Version>') {
    $csproj = $csproj -replace '(<Version>)[^<]+(</Version>)', "`${1}$Version`$2"
    $versionProperty = "Version"
} elseif ($csproj -match '<AssemblyVersion>[^<]+</AssemblyVersion>') {
    $csproj = $csproj -replace '(<AssemblyVersion>)[^<]+(</AssemblyVersion>)', "`${1}$Version`$2"
    $versionProperty = "AssemblyVersion"
} else {
    Write-Error "Could not find <Version> or <AssemblyVersion> in $csprojPath"
    exit 1
}
Set-Content $csprojPath -Value $csproj -NoNewline
Write-Output "Set SaddlebagExchange.csproj $versionProperty to $Version"

# 2) Bump version, API level, and LastUpdated in repo.json
$repoJson = Get-Content $repoJsonPath -Raw
$repoJson = $repoJson -replace '("AssemblyVersion":\s*")[^"]+(")', "`${1}$Version`$2"
if ($csproj -match 'Dalamud\.NET\.Sdk/(\d+)\.') {
    $apiLevel = $Matches[1]
} else {
    Write-Error "Could not derive DalamudApiLevel from Dalamud.NET.Sdk in $csprojPath"
    exit 1
}
$repoJson = $repoJson -replace '("DalamudApiLevel":\s*)\d+', "`${1}$apiLevel"
if ($repoJson -match '"DalamudApiLevel":\s*(\d+)') {
    if ($Matches[1] -ne $apiLevel) {
        Write-Error "Failed to set repo.json DalamudApiLevel to $apiLevel"
        exit 1
    }
} else {
    Write-Error "Could not find DalamudApiLevel in $repoJsonPath"
    exit 1
}
Write-Output "Set repo.json DalamudApiLevel to $apiLevel"
$unixNow = [long]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
$repoJson = $repoJson -replace '("LastUpdated":\s*)\d+', "`${1}$unixNow"
Set-Content $repoJsonPath -Value $repoJson -NoNewline
Write-Output "Set repo.json AssemblyVersion to $Version and LastUpdated to $unixNow"

# 3) Restore manifest.toml so it cannot be accidentally included
#    in the release commit with a stale commit SHA.
Push-Location $repoRoot
try {
    & git restore "$manifestPath"
    Write-Output "Restored manifest.toml to last committed state (will be updated in a separate commit)"

    # 4) Git: stage only version bump files, commit, push release
    & git add "$csprojPath" "$repoJsonPath"
    & git status
    & git commit -m "Release $Version"
    & git push origin main
} finally {
    Pop-Location
}

# 5) Tag and push tag
Push-Location $repoRoot
try {
    & git tag "v$Version"
    & git push origin "v$Version"
} finally {
    Pop-Location
}

# 6) Capture release commit SHA (this is the code state D17 builds)
$commit = (git -C $repoRoot rev-parse HEAD)
Write-Output "Release commit SHA: $commit"

# 7) Set manifest.toml commit to release commit SHA
$content = Get-Content $manifestPath -Raw
$content = $content -replace '(?m)^commit = .*$', "commit = `"$commit`""
Set-Content $manifestPath -Value $content.TrimEnd() -NoNewline
Write-Output "Set SaddlebagExchange/manifest.toml commit to $commit"

# 8) Commit and push manifest pointer update
Push-Location $repoRoot
try {
    & git add "$manifestPath"
    & git commit -m "Set manifest commit for $Version"
    & git push origin main
} finally {
    Pop-Location
}

$validatePs1 = Join-Path $repoRoot "scripts\validate-manifest.ps1"
if (Get-Command bash -ErrorAction SilentlyContinue) {
    Push-Location $repoRoot
    try {
        & bash "scripts/validate-manifest.sh"
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } finally {
        Pop-Location
    }
} else {
    & $validatePs1
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Output ""
Write-Output "Release $Version done!"
Write-Output "  Release commit (what D17 builds): $commit"
Write-Output "  Tag: v$Version"
Write-Output "  manifest.toml now points to the release commit."
