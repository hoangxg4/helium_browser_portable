# probe/claims/extract-tree.ps1 — build one portable tree with build-yandex.ps1.
# The builder runs in a CHILD process (its dot-source guard makes it callable,
# but its main body uses exit codes we need intact).

param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$OutDir,
    [Parameter(Mandatory)][string]$Version,
    [string]$Installer = '',
    [string]$ChromePlusUrl = ''
)

$ErrorActionPreference = 'Stop'

$builder = Join-Path $RepoRoot 'build-yandex.ps1'
if (-not (Test-Path -LiteralPath $builder)) { throw "build-yandex.ps1 missing at $builder" }

$argList = @('-NoProfile', '-File', $builder, '-Version', $Version, '-OutDir', $OutDir)
if ($Installer) { $argList += @('-Installer', $Installer) } else { $argList += '-Download' }
if ($ChromePlusUrl) { $argList += @('-ChromePlusUrl', $ChromePlusUrl) }

Write-Host ("detail: extract-tree: running build-yandex.ps1 {0}" -f (($argList | Select-Object -Skip 4) -join ' '))
$pwshExe = (Get-Command pwsh -ErrorAction Stop).Source
& $pwshExe @argList
$code = $LASTEXITCODE
if ($code -ne 0) { throw "build-yandex.ps1 exited $code for OutDir=$OutDir" }

$exe = Join-Path (Join-Path $OutDir 'Yandex') 'browser.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "extract finished but $exe is missing" }
Write-Host "detail: extract-tree: ok exe=$exe"
exit 0
