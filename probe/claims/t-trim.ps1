# probe/claims/t-trim.ps1 — T3: trim-group safety (per-group, no confounds).
#
# One baseline capability measurement (throwaway copy), then each group on its
# own fresh copy of the pristine baseline: delete the group, launch headless
# captures (file:// pages), compare against baseline, emit one T3 verdict line
# per group plus an overall line. Trees are deleted as we go (disk budget);
# group E is kept for T8.

param(
    [Parameter(Mandatory)][string]$Baseline,
    [string]$OutDir = $env:CLAIMS,
    [string]$Groups = 'ABCDE'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'claims-lib.ps1')
. (Join-Path $PSScriptRoot 'common.ps1')
$emit    = Join-Path $PSScriptRoot 'emit-verdict.ps1'
$pageDump = Join-Path $PSScriptRoot 'page-dump.ps1'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$pagesDir = Join-Path $repoRoot 'probe\claims'

function Emit([string]$details) {
    & $emit -Id 'T3' -Details $details -OutDir $OutDir
    exit 0
}
function EmitGroup([string]$details) {
    # per-group evidence line; does not stop the loop
    & $emit -Id 'T3' -Details $details -OutDir $OutDir
}
function Read-Capture([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $raw) { return '' }
    return [string]$raw
}
function Copy-BaselineTo([string]$Dest) {
    if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Dest) | Out-Null
    Copy-Item -LiteralPath $Baseline -Destination $Dest -Recurse -Force
    if (-not (Test-Path -LiteralPath (Join-Path $Dest 'Yandex\browser.exe'))) {
        throw "baseline copy failed (no browser.exe under $Dest)"
    }
}
function Get-GroupPaths([string]$Tree, $Spec) {
    # Resolves each declared group item inside the tree. Missing items are not
    # an error (consumer builds may not ship them) - they are reported.
    $layout = Get-ClaimsAppLayout -App $Tree
    $found  = @()
    $absent = @()
    foreach ($pat in $Spec.Delete) {
        if ($Spec.Id -eq 'E') {
            $loc = Get-ChildItem -LiteralPath $Tree -Recurse -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ieq 'Locales' } | Select-Object -First 1
            if ($null -ne $loc) { $found += $loc.FullName } else { $absent += 'Locales' }
            continue
        }
        if ($pat -match '[\*\?]') {
            $hits = @(Get-ChildItem -Path (Join-Path $layout.AppDir $pat) -Force -ErrorAction SilentlyContinue)
            if ($hits.Count -eq 0) { $hits = @(Get-ChildItem -Path (Join-Path $Tree $pat) -Force -ErrorAction SilentlyContinue) }
            if ($hits.Count -eq 0) { $absent += $pat } else { $found += @($hits | ForEach-Object { $_.FullName }) }
            continue
        }
        $direct = Join-Path $layout.AppDir $pat
        if (Test-Path -LiteralPath $direct) { $found += (Get-Item -LiteralPath $direct).FullName; continue }
        $atRoot = Join-Path $Tree $pat
        if (Test-Path -LiteralPath $atRoot) { $found += (Get-Item -LiteralPath $atRoot).FullName; continue }
        $hit = Get-ChildItem -LiteralPath $Tree -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ieq (Split-Path $pat -Leaf) } | Select-Object -First 3
        if ($null -eq $hit) { $absent += $pat } else { $found += @($hit | ForEach-Object { $_.FullName }) }
    }
    return [pscustomobject]@{ Found = $found; Absent = $absent; AppDir = $layout.AppDir }
}
function Measure-Capabilities([string]$Tree, [int]$PortBase, [string]$Tag) {
    # Two launches per tree: webgl.html proves capture+webgl, eme-probe.html
    # proves the DRM baseline.
    $caps = @{ Dump = 'NO_RESULT'; Webgl = 'NO_RESULT'; Eme = 'NO_RESULT'; EmeRaw = 'NO_RESULT' }
    $webglUrl = 'file:///' + ((Join-Path $pagesDir 'webgl.html') -replace '\\', '/')
    $emeUrl   = 'file:///' + ((Join-Path $repoRoot 'probe\eme-probe.html') -replace '\\', '/')
    $out1 = Join-Path $OutDir "t3-$Tag-webgl.html"
    & $pageDump -App $Tree -Url $webglUrl -OutFile $out1 -RequirePattern 'WEBGL_(OK|FAIL)' `
        -Port $PortBase -DumpMs 20000 -ReadyMs 25000 -AwaitMs 30000 -Label "$Tag-webgl"
    $t1 = Read-Capture $out1
    if ($t1 -match 'WEBGL_(OK|FAIL)') { $caps.Dump = 'OK' }
    if ($t1 -match 'WEBGL_OK') { $caps.Webgl = 'OK' } elseif ($t1 -match 'WEBGL_FAIL') { $caps.Webgl = 'WEBGL_FAIL' }
    $out2 = Join-Path $OutDir "t3-$Tag-eme.html"
    & $pageDump -App $Tree -Url $emeUrl -OutFile $out2 -RequirePattern 'CDM_(OK|FAIL|THROW)' `
        -Port ($PortBase + 1) -DumpMs 20000 -ReadyMs 25000 -AwaitMs 30000 -Label "$Tag-eme"
    $t2 = Read-Capture $out2
    $raw = Get-EmeResult $t2
    $caps.EmeRaw = $raw
    $caps.Eme = if ($raw -like 'CDM_OK*') { 'OK' }
                elseif ($raw -like 'CDM_FAIL*') { 'CDM_FAIL' }
                elseif ($raw -like 'CDM_THROW*') { 'CDM_THROW' }
                else { 'NO_RESULT' }
    Write-Host ("detail: T3[{0}]: dump={1} webgl={2} eme={3} emeRaw={4}" -f $Tag, $caps.Dump, $caps.Webgl, $caps.Eme, $caps.EmeRaw)
    return $caps
}
function Get-CapState([string]$Base, [string]$Cur) {
    if ($Cur -eq 'OK') { return 'OK' }          # works right now
    if ($Base -eq 'OK') { return 'BROKEN' }     # baseline proved it, now it does not
    if ($Cur -eq $Base) { return 'WARN' }       # same pre-existing limitation
    if ($Base -eq 'NO_RESULT') { return 'WARN' }# baseline could not be measured either
    return 'BROKEN'                             # baseline reported a real state, now degraded
}

try {
    if ($env:SRC_OK -ne '1') { Emit 'FAIL - source tree unavailable (install step did not complete)' }
    if (-not (Test-Path -LiteralPath (Join-Path $Baseline 'Yandex\browser.exe'))) {
        Emit ("FAIL - baseline tree missing at {0}" -f $Baseline)
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $OutDir 'trees') | Out-Null
    $baselineBytes = Get-ClaimsDirBytes -Path $Baseline
    Write-Host ("detail: T3: baselineBytes={0}" -f $baselineBytes)

    # --- baseline capabilities (throwaway copy) -----------------------------
    $gBase = Join-Path $OutDir 'trees\gBase'
    Copy-BaselineTo -Dest $gBase
    $baseCaps = Measure-Capabilities -Tree $gBase -PortBase 9530 -Tag 'base'
    Remove-Item -LiteralPath $gBase -Recurse -Force -ErrorAction SilentlyContinue

    $inconclusive = ($baseCaps.Dump -ne 'OK')
    if ($inconclusive) {
        Write-Host 'detail: T3: baseline page capture failed - group states are relative to an unmeasurable baseline'
    }
    if ($baseCaps.Eme -eq 'NO_RESULT') {
        Write-Host 'detail: T3: baseline EME capture failed - EME states degrade to WARN/BROKEN relative to that'
    }

    # --- per-group ----------------------------------------------------------
    $idx = 0
    $brokenGroups = @()
    $savedParts = @()
    $idxByGroup = @{ A = 1; B = 2; C = 3; D = 4; E = 5 }
    foreach ($ch in $Groups.ToCharArray()) {
        $g = "$ch"
        $idx++
        $spec = Get-TrimGroupSpec -GroupId $g
        $tree = Join-Path $OutDir ("trees\g{0}" -f $g)
        $portBase = 9540 + ($idxByGroup[$g] * 10)
        try {
            Copy-BaselineTo -Dest $tree
            $resolved = Get-GroupPaths -Tree $tree -Spec $spec
            $deleted = @()
            foreach ($p in $resolved.Found) {
                if ($spec.Id -eq 'E') {
                    foreach ($child in @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue)) {
                        if (@($spec.Keep | Where-Object { $_ -ieq $child.Name }).Count -gt 0) {
                            Write-Host ("detail: T3[E]: kept {0}" -f $child.Name)
                            continue
                        }
                        Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction SilentlyContinue
                        $deleted += $child.Name
                    }
                }
                elseif (Test-Path -LiteralPath $p -PathType Container) {
                    Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
                    $deleted += $p
                }
                else {
                    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
                    $deleted += $p
                }
            }
            Write-Host ("detail: T3[{0}]: deleted={1}; absent={2}" -f $g, ($deleted -join ', '), ($resolved.Absent -join ', '))

            $afterBytes = Get-ClaimsDirBytes -Path $tree
            $saved = $baselineBytes - $afterBytes

            $caps = Measure-Capabilities -Tree $tree -PortBase $portBase -Tag $g
            $dumpState   = Get-CapState -Base $baseCaps.Dump   -Cur $caps.Dump
            $webglState  = Get-CapState -Base $baseCaps.Webgl  -Cur $caps.Webgl
            $emeState    = Get-CapState -Base $baseCaps.Eme    -Cur $caps.Eme
            $gv = Get-GroupVerdict -Capabilities @{ Dump = $dumpState; Webgl = $webglState; Eme = $emeState }

            $savedParts += ('{0}={1}B' -f $g, $saved)
            if ($gv.State -ne 'SAFE') { $brokenGroups += $g }

            $detail = ('{0} - group {1}; broken=({2}); saved={3} bytes of {4}; dump {5}->{6}; webgl {7}->{8}; eme {9} (baseline {10}); deleted={11}; absent={12}' -f
                $gv.State, $g, ($gv.Broken -join ','), $saved, $baselineBytes,
                $baseCaps.Dump, $dumpState, $baseCaps.Webgl, $webglState,
                $caps.Eme, $baseCaps.Eme,
                $(if ($deleted.Count -gt 0) { ($deleted -join ',') } else { 'none' }),
                $(if ($resolved.Absent.Count -gt 0) { ($resolved.Absent -join ',') } else { 'none' }))
            EmitGroup $detail
        }
        catch {
            EmitGroup ('BROKEN - group {0}; error: {1}' -f $g, $_.Exception.Message)
            $brokenGroups += $g
        }
        finally {
            if ($g -ne 'E') {
                Remove-Item -LiteralPath $tree -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $savedSummary = ($savedParts -join ', ')
    $groupList = ($Groups.ToCharArray() -join ',')
    if ($brokenGroups.Count -gt 0) {
        Emit ('BROKEN - groups {0} broke a capability vs baseline; per-group lines above; saved: {1}; baselineBytes={2}' -f
            ($brokenGroups -join ','), $savedSummary, $baselineBytes)
    }
    if ($inconclusive) {
        Emit ('INCONCLUSIVE - baseline page capture failed (dump={0}); relative group results: {1} groups measured; saved: {2}' -f
            $baseCaps.Dump, $Groups.ToCharArray().Count, $savedSummary)
    }
    Emit ('SAFE - groups {0} all SAFE vs baseline; saved: {1}; baselineBytes={2}; baseline dump={3} webgl={4} eme={5}' -f
        $groupList, $savedSummary, $baselineBytes, $baseCaps.Dump, $baseCaps.Webgl, $baseCaps.Eme)
}
catch {
    Emit ('FAIL - ' + $_.Exception.Message)
}
