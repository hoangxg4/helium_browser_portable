# probe/claims/page-dump.ps1 — bounded page capture for the claims probes.
#
# Channel 1: headless (or headed) --dump-dom with a virtual-time budget.
# Channel 2: probe/cdp-dump.ps1 fallback (spike P0/P2: --dump-dom returns 0
#            bytes on this build, the file:// CDP path works).
#
# Exit codes: 0 = content written and -RequirePattern matched (when given)
#             1 = no content from either channel
#             2 = content written but -RequirePattern did not match

param(
    [Parameter(Mandatory)][string]$App,        # package root (Yandex\) or install dir
    [Parameter(Mandatory)][string]$Url,        # page to capture (file:///... or about:blank)
    [Parameter(Mandatory)][string]$OutFile,
    [string]$Profile = '',                     # default <root>\Data
    [string]$Label = 'dump',
    [int]$Port = 9499,
    [int]$DumpMs = 30000,
    [int]$ReadyMs = 30000,
    [int]$AwaitMs = 60000,
    [string]$AwaitExpr = '',
    [string]$RequirePattern = '',
    [switch]$Headed,
    [int]$RunSec = 0                           # >0: launch, stay up, graceful close, no dump
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

function Write-DumpDetail([string]$m) { Write-Host "detail: page-dump[$Label]: $m" }

$layout = Get-ClaimsAppLayout -App $App
if ([string]::IsNullOrWhiteSpace($Profile)) { $Profile = $layout.Profile }
New-Item -ItemType Directory -Force -Path $Profile | Out-Null
$null = Disable-ClaimsVersionDll -AppDir $layout.AppDir
Stop-ClaimsBrowser

if (-not $AwaitExpr) {
    # every probe page starts as <title>probe</title> and reports via title/pre
    $AwaitExpr = '(function(){var t=document.title;if(t&&t!=="probe"){return t;}var p=document.getElementById("o");if(p&&p.innerText&&p.innerText!=="pending"){return p.innerText;}return "";})()'
}

$Uri = if ($Url -match '^[a-z]+:') { $Url } else { 'file:///' + ($Url -replace '\\', '/') }
$flags = @('--disable-gpu', '--no-first-run', '--no-default-browser-check', '--disable-crash-reporter',
           '--enable-logging=stderr', '--v=1', "--user-data-dir=$Profile")
if ($Headed) { $flags += '--force-renderer-accessibility' } else { $flags += '--headless=new' }

if ($RunSec -gt 0) {
    # T5 first-run: launch so the NTP opens naturally, then close gracefully.
    $argList = $flags + $Uri
    Write-DumpDetail "headless-run is off; headed stay=$RunSec s url=$Uri"
    $p = Start-Process -FilePath $layout.Exe -ArgumentList $argList -PassThru -WorkingDirectory $layout.AppDir `
        -RedirectStandardOutput "$OutFile.out" -RedirectStandardError "$OutFile.err"
    if (-not $p.WaitForExit($RunSec * 1000)) {
        Write-DumpDetail "still running after $RunSec s; closing gracefully"
        Close-ClaimsBrowserGracefully
    }
    else {
        Write-DumpDetail "exited early code=$($p.ExitCode)"
    }
    Set-Content -Encoding utf8 -Path $OutFile -Value ''
    Write-DumpDetail "headed run complete (profile=$Profile)"
    exit 0
}

$base = $flags
$content = ''
$channel = 'none'
$exitInfo = 'n/a'

# ---- channel 1: --dump-dom ------------------------------------------------
try {
    $argList = $base + @('--virtual-time-budget=12000', '--dump-dom', $Uri)
    $out = "$OutFile.ch1.out"
    $err = "$OutFile.ch1.err"
    $p = $null
    try {
        $p = Start-Process -FilePath $layout.Exe -ArgumentList $argList -PassThru -NoNewWindow `
            -WorkingDirectory $layout.AppDir -RedirectStandardOutput $out -RedirectStandardError $err
        if (-not $p.WaitForExit($DumpMs)) {
            try { $p.Kill($true) } catch { }
            $null = $p.WaitForExit(5000)
            $exitInfo = "killed@${DumpMs}ms"
        }
        else { $exitInfo = "exit=$($p.ExitCode)" }
    }
    catch {
        $exitInfo = "start-failed: $($_.Exception.Message)"
    }
    Stop-ClaimsBrowser
    if (Test-Path -LiteralPath $out) {
        $raw = Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue
        if ($null -ne $raw) { $content = [string]$raw }
    }
    if (-not [string]::IsNullOrWhiteSpace($content)) { $channel = 'dump-dom' }
    Write-DumpDetail "channel1 dump-dom $exitInfo bytes=$($content.Length)"
}
catch {
    Write-DumpDetail "channel1 threw: $($_.Exception.Message)"
}

$needFallback = [string]::IsNullOrWhiteSpace($content) -or
    (-not [string]::IsNullOrWhiteSpace($RequirePattern) -and ($content -notmatch $RequirePattern))

# ---- channel 2: CDP -------------------------------------------------------
if ($needFallback) {
    try {
        $cdpScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'cdp-dump.ps1'
        $cdpOut = "$OutFile.cdp.html"
        & $cdpScript -App $layout.AppDir -Url $Uri -OutFile $cdpOut -Base $base -Profile $Profile `
            -Port $Port -ReadyMs $ReadyMs -AwaitExpr $AwaitExpr -AwaitMs $AwaitMs
        $cdpExit = $LASTEXITCODE
        if (Test-Path -LiteralPath $cdpOut) {
            $raw = Get-Content -LiteralPath $cdpOut -Raw -ErrorAction SilentlyContinue
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $content = [string]$raw
                $channel = 'cdp'
            }
        }
        Write-DumpDetail "channel2 cdp exit=$cdpExit bytes=$($content.Length)"
    }
    catch {
        Write-DumpDetail "channel2 threw: $($_.Exception.Message)"
    }
}

Stop-ClaimsBrowser
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
Set-Content -Encoding utf8 -Path $OutFile -Value $content
Write-DumpDetail "final channel=$channel bytes=$($content.Length)"

if ([string]::IsNullOrWhiteSpace($content)) { exit 1 }
if (-not [string]::IsNullOrWhiteSpace($RequirePattern) -and ($content -notmatch $RequirePattern)) { exit 2 }
exit 0
