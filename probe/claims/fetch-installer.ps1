# probe/claims/fetch-installer.ps1 — download the winget installer ONCE for the
# whole claims run and SHA256-verify it against the winget manifest
# (build-yandex.ps1 is dot-sourced for its helper functions; its dot-source
# guard stops the build from starting).

param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$OutFile
)

$ErrorActionPreference = 'Stop'

# Capture before the dot-source: build-yandex.ps1 declares its own
# param($Version) and dot-sourcing runs in THIS scope, so its empty default
# would clobber ours (the SHA256 manifest URL then 404s on an empty version).
$wantVersion = $Version
$wantOut     = $OutFile

$builder = Join-Path $RepoRoot 'build-yandex.ps1'
if (-not (Test-Path -LiteralPath $builder)) { throw "build-yandex.ps1 missing at $builder" }
. $builder

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $wantOut) | Out-Null

if ((Test-Path -LiteralPath $wantOut) -and ((Get-Item -LiteralPath $wantOut).Length -gt 0MB)) {
    Write-Host "detail: fetch-installer: reusing cached installer $wantOut"
}
else {
    $candidate = Get-CdnCandidateUrl $wantVersion
    $installerUrl = $null
    if (Test-Url $candidate) {
        $installerUrl = $candidate
        Write-Host "detail: fetch-installer: CDN candidate live: $installerUrl"
    }
    else {
        $installerUrl = Resolve-ManifestUrl $wantVersion
        Write-Host "detail: fetch-installer: CDN candidate not live; winget manifest URL: $installerUrl"
    }
    Write-Host "detail: fetch-installer: downloading $installerUrl -> $wantOut"
    Invoke-WebRequest -Uri $installerUrl -OutFile $wantOut -TimeoutSec 900 -UseBasicParsing
}

$sha = Get-ManifestSha256 $wantVersion
$null = Assert-InstallerSha256 -Path $wantOut -ExpectedSha256 $sha
Write-Host "detail: fetch-installer: SHA256 verified against winget InstallerSha256 ($sha)"
Write-Host "detail: fetch-installer: installer=$wantOut"
exit 0
