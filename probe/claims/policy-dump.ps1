# probe/claims/policy-dump.ps1 — headed chrome://policy/ capture for T1.
#
# Proven path (spike H2-H5): CDP is Forbidden on WebUI targets, but the rendered
# policy page is readable through Windows UI Automation when the browser runs
# with --force-renderer-accessibility. This script launches the browser with the
# policy page as the startup URL (so the commit happens before we attach), runs
# probe/uia-dump.ps1 under powershell.exe 5.1 (UIAutomationClient is in the GAC
# there), writes the text, then closes the browser.
#
# Exit codes: 0 = text captured at/above -MinBytes, 1 = otherwise.

param(
    [Parameter(Mandatory)][string]$App,          # package root
    [Parameter(Mandatory)][string]$OutFile,      # UIA text output
    [string]$Profile = '',
    [string]$StartupUrl = 'chrome://policy/',
    [int]$Port = 9501,
    [int]$LaunchSec = 25,
    [int]$DumpSec = 30,
    [int]$MinBytes = 600
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Write-PolicyDetail([string]$m) { Write-Host "detail: policy-dump: $m" }

$layout = Get-ClaimsAppLayout -App $App
if ([string]::IsNullOrWhiteSpace($Profile)) { $Profile = $layout.Profile }
New-Item -ItemType Directory -Force -Path $Profile | Out-Null
$null = Disable-ClaimsVersionDll -AppDir $layout.AppDir
Stop-ClaimsBrowser
$uiaScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'uia-dump.ps1'
if (-not (Test-Path -LiteralPath $uiaScript)) { throw "uia-dump.ps1 missing at $uiaScript" }

$base = @('--no-first-run', '--no-default-browser-check', '--disable-crash-reporter', '--disable-gpu',
          '--enable-logging=stderr', '--v=1', '--force-renderer-accessibility',
          "--user-data-dir=$Profile", "--remote-debugging-port=$Port", '--remote-allow-origins=*', $StartupUrl)

$text = ''
$note = ''
$proc = $null
try {
    Write-PolicyDetail "launching headed url=$StartupUrl port=$Port"
    $proc = Start-Process -FilePath $layout.Exe -ArgumentList $base -PassThru -WorkingDirectory $layout.AppDir `
        -RedirectStandardOutput "$OutFile.launch.out" -RedirectStandardError "$OutFile.launch.err"

    $alive = $false
    $devTools = ''
    $deadline = [DateTime]::UtcNow.AddSeconds($LaunchSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 2
        $alive = -not $proc.HasExited
        if (-not $alive) { $note = "browser exited early code=$($proc.ExitCode)"; break }
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/json/version" -UseBasicParsing -TimeoutSec 3
            $devTools = [string]($r.Content | ConvertFrom-Json).Browser
            if ($devTools) { break }
        }
        catch { }
    }
    Write-PolicyDetail "alive=$alive devtools=$devTools after $LaunchSec s"
    if (-not $alive) { throw $note }
    if (-not $devTools) { throw 'devtools endpoint not reachable' }

    # wait for a real window title so the UIA walk sees the policy page
    $titleOk = $false
    $titleDeadline = [DateTime]::UtcNow.AddSeconds($LaunchSec)
    while ([DateTime]::UtcNow -lt $titleDeadline) {
        $titles = @(Get-Process -Name browser -ErrorAction SilentlyContinue |
            ForEach-Object { $_.MainWindowTitle } | Where-Object { $_ })
        if (@($titles | Where-Object { $_ -match 'polic' }).Count -gt 0) { $titleOk = $true; break }
        Start-Sleep -Seconds 2
    }
    Write-PolicyDetail "policy window title seen=$titleOk titles=[$(@($titles) -join ', ')]"

    $pids = @(Get-Process -Name browser -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    if ($pids.Count -eq 0) { throw 'no browser process to dump' }
    $psExe = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if (-not $psExe) { throw 'powershell.exe not available for the UIA dump' }

    $uiaP = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -Wait -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $uiaScript,
        '-ProcIds', ($pids -join ','), '-OutFile', $OutFile)
    Write-PolicyDetail "uia-dump exit=$($uiaP.ExitCode)"
    if (Test-Path -LiteralPath $OutFile) {
        $raw = Get-Content -LiteralPath $OutFile -Raw -ErrorAction SilentlyContinue
        if ($null -ne $raw) { $text = [string]$raw }
    }
    Write-PolicyDetail "uia text bytes=$($text.Length) (min=$MinBytes)"
}
catch {
    $note = $_.Exception.Message
    Write-PolicyDetail "failed: $note"
}
finally {
    Stop-ClaimsBrowser
    Start-Sleep -Seconds 2
}

if ($text.Length -ge $MinBytes) { exit 0 }
if ($note) { Write-PolicyDetail "no usable text ($note)" }
exit 1
