param(
    [string]$Installer,
    [switch]$Download,
    [string]$Version,
    [string]$OutDir
)

<#
    build-yandex.ps1 — Yandex Browser Portable builder (STUB, Task 2).

    Stages (design §3, idempotent):
      1. Resolve source  — -Installer <path> (user-supplied) or -Download (CI, public CDN).
                           The winget PackageVersion is the SOLE source of truth for the
                           release tag, zip name and version.txt; a version read back from
                           the binary is a log-only cross-check.
      2. Extract         — spike P1 branch A: 7z payload of Yandex.exe, then the nested
                           browser.7z. Hard-fail with a message naming BOTH branches
                           (outer exe resource archive / post-silent-install
                           Installer\browser.7z) when neither yields browser.exe.
      3. Layout          — Yandex_Portable\{Yandex\..., Data\, Cache\}; copy chrome++.ini
                           (data_dir/cache_dir at package root), version.dll (Chrome++
                           path) or launch.bat --user-data-dir fallback (spike P2),
                           target browser.exe — NOT chrome.exe.
      4. Debloat         — merge debloater.reg into HKLM\SOFTWARE\Policies\YandexBrowser +
                           preseed Local State / Default\Preferences with Yandex-specific
                           keys and an empty "First Run" sentinel (Yandex discards
                           hand-made profile files without it).
      5. Strip updater   — remove service_update.exe / yupdate-exec.exe; UpdateAllowed=0
                           and BackgroundUpdateAllowed=0 are already carried by
                           debloater.reg.

    Never: SafeBrowsingProtectionLevel, ComponentUpdatesEnabled,
    --disable-component-update (Widevine/DRM), security updates beyond the
    UpdateAllowed rationale.
#>

if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'dist' }

Write-Host "build-yandex.ps1: stub — stages not implemented yet (Tasks 3-5)"
Write-Host "  Installer=$Installer Download=$Download Version=$Version OutDir=$OutDir"

exit 0
