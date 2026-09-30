# probe/claims/t9-launcher.ps1 — T9: Go launcher MVP claims (issue #1 #4/#7/#8).
#
# Runs the built launcher against a real extracted package on the runner and
# asserts the testable mechanics, in this order:
#   1. single-instance: Global\YandexPortable_SingleInstance acquired, a second
#      invocation forwards its argv URL and both exit 0 (start-twice)
#   2. ephemeral HKCU policy: the 11 shipped keys are present during the hold
#      window and gone after exit when T1=HONORED; when T1!=HONORED nothing is
#      written and the printed mode line names the exact reason
#   3. launch plan: version.dll preferred, explicit --user-data-dir fallback
#      flags when it is set aside
#   4. cache prune: stale state.json -> volatile dirs deleted + state.json
#      stamped; the immediate rerun takes the fast-skip path
#   5. bilingual EN/RU output and --settings
# Emits exactly one "T9 verdict:" line through emit-verdict.ps1.

param(
    [Parameter(Mandatory)][string]$Baseline,
    [string]$OutDir = $env:CLAIMS,
    [string]$Exe = $env:T9_EXE
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'claims-lib.ps1')
. (Join-Path $PSScriptRoot 'common.ps1')
$emit     = Join-Path $PSScriptRoot 'emit-verdict.ps1'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

$script:policyKey = 'HKCU:\Software\Policies\YandexBrowser'
$script:exe       = ''
$script:tree      = ''
$script:dllAside  = $null
$script:heldHandle = $null

function Emit([string]$details) {
    & $emit -Id 'T9' -Details $details -OutDir $OutDir
    exit 0
}

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Show-Output {
    param([string]$Label, [string]$Text)
    if ($null -eq $Text) { return }
    foreach ($l in ($Text -split "`r?`n")) {
        if ($l.Trim() -ne '') { Write-Host ("detail: T9: [{0}] {1}" -f $Label, $l.TrimEnd()) }
    }
}

function Read-OutputFile {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return '' }
    $t = [string](Get-Content -LiteralPath $File -Raw -ErrorAction SilentlyContinue)
    if ($null -eq $t) { return '' }
    return $t
}

function Format-LauncherArgs {
    param([string[]]$LauncherArgs)
    # Quote anything with a space so paths with spaces survive the single
    # -ArgumentList string that Start-Process hands to CreateProcess.
    return (($LauncherArgs | ForEach-Object {
        if ($_ -match '[\s"]') { '"{0}"' -f ($_ -replace '"', '\"') } else { $_ }
    }) -join ' ')
}

function Invoke-Launcher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$LauncherArgs,
        [Parameter(Mandatory)][string]$Label,
        [int]$TimeoutSec = 60
    )
    $outFile = Join-Path $OutDir ("t9-{0}.out.txt" -f $Label)
    $errFile = Join-Path $OutDir ("t9-{0}.err.txt" -f $Label)
    if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue }

    $p = Start-Process -FilePath $script:exe -ArgumentList (Format-LauncherArgs $LauncherArgs) `
        -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        throw ("launcher '{0}' did not exit within {1}s" -f $Label, $TimeoutSec)
    }
    $text = Read-OutputFile -File $outFile
    $errt = Read-OutputFile -File $errFile
    Write-Host ("detail: T9: [{0}] exit={1} bytes={2}" -f $Label, $p.ExitCode, $text.Length)
    Show-Output -Label $Label -Text $text
    if ($errt.Trim() -ne '') { Write-Host ("detail: T9: [{0}] stderr: {1}" -f $Label, $errt.Trim()) }
    return [pscustomobject]@{ Code = $p.ExitCode; Text = $text; Err = $errt }
}

function Start-Launcher {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$LauncherArgs, [Parameter(Mandatory)][string]$Label)
    $outFile = Join-Path $OutDir ("t9-{0}.out.txt" -f $Label)
    if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue }
    $p = Start-Process -FilePath $script:exe -ArgumentList (Format-LauncherArgs $LauncherArgs) `
        -NoNewWindow -PassThru -RedirectStandardOutput $outFile `
        -RedirectStandardError (Join-Path $OutDir ("t9-{0}.err.txt" -f $Label))
    return [pscustomobject]@{ Process = $p; OutFile = $outFile }
}

function Wait-OutputContains {
    param([string]$File, [string]$Pattern, [int]$TimeoutSec = 20)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        $t = Read-OutputFile -File $File
        if ($t -match $Pattern) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Wait-LauncherExit {
    param([Parameter(Mandatory)]$Handle, [int]$TimeoutSec = 40)
    if (-not $Handle.Process.WaitForExit($TimeoutSec * 1000)) {
        try { $Handle.Process.Kill() } catch { }
        throw ("held launcher did not exit within {0}s" -f $TimeoutSec)
    }
    $text = Read-OutputFile -File $Handle.OutFile
    Write-Host ("detail: T9: [held] exit={0} bytes={1}" -f $Handle.Process.ExitCode, $text.Length)
    Show-Output -Label 'held' -Text $text
    return [pscustomobject]@{ Code = $Handle.Process.ExitCode; Text = $text }
}

function Get-PolicySnapshot {
    $snap = @{}
    if (Test-Path -LiteralPath $script:policyKey) {
        $k = Get-Item -LiteralPath $script:policyKey
        foreach ($n in $k.GetValueNames()) { $snap[$n] = $k.GetValue($n) }
    }
    return $snap
}

function Get-ShippedPolicyEntries {
    <# Section-scoped parse of debloater.reg, mirroring the launcher's parser:
       only values under the HKLM YandexBrowser policy section count. #>
    param([Parameter(Mandatory)][string]$RegPath)
    $entries = [ordered]@{}
    $inSection = $false
    foreach ($raw in (Get-Content -LiteralPath $RegPath)) {
        $line = $raw.Trim()
        if ($line -match '^\[(.+)\]$') {
            $inSection = ($Matches[1].Trim() -ieq 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\YandexBrowser')
            continue
        }
        if (-not $inSection -or $line -eq '' -or $line.StartsWith(';')) { continue }
        if ($line -match '^"([^"]+)"\s*=\s*dword:([0-9a-fA-F]+)$') {
            $entries[$Matches[1]] = [Convert]::ToInt32($Matches[2], 16)
        }
    }
    return ,$entries
}

# ---------------------------------------------------------------- attempt --

try {
    if ($env:SRC_OK -ne '1') { Emit 'FAIL - source tree unavailable (install step did not complete)' }
    if ($env:T9_GO_OK -eq '0') { Emit 'FAIL - go vet/test/build failed (see the T9 Go checks step log)' }

    $findings = Join-Path $repoRoot 'docs\issue1-claims-findings.md'
    if (-not (Test-Path -LiteralPath $findings)) { Emit 'FAIL - findings doc missing (Task 1 incomplete)' }

    # Step 0 mechanism: the T1 verdict in the findings doc picks the mode.
    $fText = [string](Get-Content -LiteralPath $findings -Raw)
    $m = [regex]::Match($fText, '(?m)^T1 verdict:[ \t]*(\S+)')
    if (-not $m.Success) { Emit 'FAIL - no T1 verdict line in findings doc (Task 1 incomplete)' }
    $t1Verdict = $m.Groups[1].Value
    $modeActive = ($t1Verdict -ieq 'HONORED')
    $modeLabel = if ($modeActive) { 'hkcu' } else { ('skip({0})' -f $t1Verdict) }
    Write-Host ("detail: T9: T1 verdict={0} -> launcher mode={1}" -f $t1Verdict, $modeLabel)

    # A browser left behind by an earlier probe would take the prune's
    # "browser running" skip path and hide the claim under test.
    Stop-ClaimsBrowser

    $tree = Join-Path $OutDir 'trees\t9'
    if (Test-Path -LiteralPath $tree) { Remove-Item -LiteralPath $tree -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $tree) | Out-Null
    Copy-Item -LiteralPath $Baseline -Destination $tree -Recurse -Force
    $script:tree = $tree

    $layout = Get-ClaimsAppLayout -App $tree
    $regFile = Join-Path $layout.AppDir 'debloater.reg'
    Assert (Test-Path -LiteralPath $regFile) ("shipped debloater.reg missing at {0}" -f $regFile)

    $entries = Get-ShippedPolicyEntries -RegPath $regFile
    $names = @($entries.Keys)
    Write-Host ("detail: T9: debloater.reg policy entries={0} [{1}]" -f $names.Count, ($names -join ', '))
    Assert ($names.Count -eq 11) ("expected exactly 11 policy values, got {0}" -f $names.Count)
    foreach ($forbidden in @('SafeBrowsingProtectionLevel', 'ComponentUpdatesEnabled')) {
        Assert (-not ($names -contains $forbidden)) ("3-don't-touch key {0} must never reach the launcher" -f $forbidden)
    }

    if ([string]::IsNullOrWhiteSpace($Exe)) {
        $goCmd = Get-Command go -ErrorAction SilentlyContinue
        if ($null -eq $goCmd) { Emit 'FAIL - go toolchain not found and T9_EXE not set' }
        $binDir = Join-Path $OutDir 'bin'
        New-Item -ItemType Directory -Force -Path $binDir | Out-Null
        $Exe = Join-Path $binDir 'yandex-launcher.exe'
        Push-Location (Join-Path $repoRoot 'launcher')
        try {
            & go build -o $Exe .
            if ($LASTEXITCODE -ne 0) { Emit 'FAIL - go build failed' }
        }
        finally { Pop-Location }
    }
    Assert (Test-Path -LiteralPath $Exe) ("launcher exe missing at {0}" -f $Exe)
    $script:exe = $Exe
    Write-Host ("detail: T9: launcher exe={0}" -f $Exe)

    # The builder downloads Chrome++ at extract time; if it was unavailable the
    # package ships without version.dll and the fallback is the only plan there
    # is. Either way the reported plan must match what is on disk.
    $dllPresent = Test-Path -LiteralPath (Join-Path $layout.AppDir 'version.dll')
    Write-Host ("detail: T9: version.dll present in package={0}" -f $dllPresent)

    $common = @('--app-dir', $tree, '--findings', $findings, '--debloater', $regFile)
    $before = Get-PolicySnapshot

    # --- phase 1: selftest with version.dll present + stale prune fixtures --
    $statePath = Join-Path $tree 'state.json'
    '{}' | Out-File -FilePath $statePath -Encoding utf8
    $stale = (Get-Date).ToUniversalTime().AddDays(-9)
    (Get-Item -LiteralPath $statePath).LastWriteTimeUtc = $stale
    $gpu = Join-Path $tree 'Data\GPUCache'
    New-Item -ItemType Directory -Force -Path $gpu | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $gpu 'seed.bin') | Out-Null

    $r1 = Invoke-Launcher -Label 'selftest-dll' -LauncherArgs (@('--selftest', '--dry-run', '--lang', 'en') + $common)
    Assert ($r1.Code -eq 0) ("selftest must exit 0, got {0}" -f $r1.Code)
    Assert ($r1.Text -match 'mutex: acquired Global\\YandexPortable_SingleInstance') 'mutex acquisition not reported (Global namespace)'
    Assert ($r1.Text -match 'selftest: ok - all checks passed') 'selftest summary missing'
    Assert ($r1.Text -notmatch 'T9 verdict: FAIL') ("selftest reported a failure: {0}" -f $r1.Text)
    if ($modeActive) {
        Assert ($r1.Text -match 'mode: hkcu - T1 verdict: HONORED') 'HKCU mode not reported as active'
        Assert ($r1.Text -match 'policy: applied 11 values') 'the 11 policy values were not applied'
        Assert ($r1.Text -match 'readback ok - 11 values present during run') 'policy readback not confirmed'
        Assert ($r1.Text -match 'cleanup - deleted=11') 'policy cleanup did not report all created values removed'
    }
    else {
        Assert ($r1.Text -match ('mode: skip - T1 verdict: {0}' -f $t1Verdict)) 'skip mode must log the exact T1 reason'
        Assert ($r1.Text -notmatch 'policy: applied') 'policy must not be applied when T1 is not HONORED'
    }
    if ($dllPresent) {
        Assert ($r1.Text -match 'launch: version.dll next to browser.exe') 'version.dll launch plan not reported'
        $dllNote = 'version.dll preferred, explicit fallback flags when it is set aside'
    }
    else {
        Assert ($r1.Text -match 'version\.dll missing - fallback flags: --user-data-dir') 'fallback flags not reported for a package without version.dll'
        $dllNote = 'explicit fallback flags (package ships no version.dll)'
    }
    Assert ($r1.Text -match 'prune: executed') 'stale state.json did not trigger the prune'
    Assert (-not (Test-Path -LiteralPath $gpu)) 'prune left Data\GPUCache behind'
    Assert (Test-Path -LiteralPath $statePath) 'prune did not stamp state.json'

    # --- phase 2: the immediate rerun must take the fast-skip path ----------
    $r2 = Invoke-Launcher -Label 'selftest-fresh' -LauncherArgs (@('--selftest', '--dry-run', '--lang', 'en') + $common)
    Assert ($r2.Code -eq 0) ("fresh-run selftest must exit 0, got {0}" -f $r2.Code)
    Assert ($r2.Text -match 'prune: .* - fast skip') 'a fresh state.json did not take the fast-skip path'

    # --- phase 3: version.dll set aside -> explicit fallback flags ----------
    if ($dllPresent) {
        $script:dllAside = Disable-ClaimsVersionDll -AppDir $layout.AppDir
        Assert ($null -ne $script:dllAside) 'version.dll vanished between the presence check and the move'
        $r3 = Invoke-Launcher -Label 'selftest-fallback' -LauncherArgs (@('--selftest', '--dry-run', '--lang', 'en') + $common)
        Assert ($r3.Code -eq 0) ("fallback selftest must exit 0, got {0}" -f $r3.Code)
        Assert ($r3.Text -match 'version\.dll missing - fallback flags: --user-data-dir') 'fallback flags not reported'
        Assert ($r3.Text -match [regex]::Escape((Join-Path $tree 'Data'))) 'fallback must target the portable Data dir'
        Move-Item -LiteralPath $script:dllAside -Destination (Join-Path $layout.AppDir 'version.dll') -Force
        $script:dllAside = $null
    }
    else {
        Write-Host 'detail: T9: phase 3 skipped - package ships no version.dll, phase 1 already proved the fallback plan'
    }

    # --- phase 4: held selftest = HKCU during run + start-twice forwarding --
    $held = Start-Launcher -Label 'held' -LauncherArgs (@('--selftest', '--dry-run', '--lang', 'en', '--hold-ms', '9000') + $common)
    $script:heldHandle = $held
    $holdReady = Wait-OutputContains -File $held.OutFile -Pattern 'selftest: hold' -TimeoutSec 25
    Assert $holdReady 'held selftest never reached its hold window'

    if ($modeActive) {
        $deadline = [DateTime]::UtcNow.AddSeconds(6)
        $present = $false
        while ([DateTime]::UtcNow -lt $deadline) {
            $snap = Get-PolicySnapshot
            $present = $true
            foreach ($n in $names) {
                if (-not $snap.ContainsKey($n) -or [int]$snap[$n] -ne [int]$entries[$n]) { $present = $false; break }
            }
            if ($present) { break }
            Start-Sleep -Milliseconds 250
        }
        Assert $present 'HKCU policy values were not present during the run (HONORED mode)'
        Write-Host 'detail: T9: all 11 HKCU values verified present during the hold window'
    }

    # Flags must precede the positional URL: Go's flag package stops parsing
    # at the first non-flag argument.
    $second = Invoke-Launcher -Label 'second' -LauncherArgs ($common + @('https://example.test/from-second')) -TimeoutSec 30
    Assert ($second.Code -eq 0) ("second instance must exit 0, got {0}" -f $second.Code)
    Assert ($second.Text -match 'mutex: held by another instance') 'second instance did not detect the busy mutex'
    Assert ($second.Text -match 'forward: url delivered') 'argv URL was not forwarded to the primary'

    $heldRun = Wait-LauncherExit -Handle $held -TimeoutSec 40
    $script:heldHandle = $null
    Assert ($heldRun.Code -eq 0) ("held selftest must exit 0, got {0}" -f $heldRun.Code)
    Assert ($heldRun.Text -match 'hold received url https://example.test/from-second') 'primary never received the forwarded URL'
    Assert ($heldRun.Text -notmatch 'T9 verdict: FAIL') ("held selftest reported a failure: {0}" -f $heldRun.Text)

    $after = Get-PolicySnapshot
    if ($modeActive) {
        foreach ($n in $names) {
            if ($before.ContainsKey($n)) {
                Assert ($after.ContainsKey($n) -and [int]$after[$n] -eq [int]$before[$n]) ("pre-existing user value {0} was not restored" -f $n)
            }
            else {
                Assert (-not $after.ContainsKey($n)) ("HKCU value {0} survived the exit" -f $n)
            }
        }
        $leftover = @()
        if (Test-Path -LiteralPath $script:policyKey) {
            $leftover = @((Get-Item -LiteralPath $script:policyKey).GetValueNames())
        }
        foreach ($k in $leftover) {
            Assert $before.ContainsKey($k) ("HKCU value {0} appeared during the run and survived the exit" -f $k)
        }
        Write-Host 'detail: T9: HKCU policy removed/restored exactly as created'
    }
    else {
        foreach ($n in $names) {
            Assert ($before.ContainsKey($n) -eq $after.ContainsKey($n)) ("HKCU value {0} appeared although T1={1}" -f $n, $t1Verdict)
            if ($before.ContainsKey($n)) {
                Assert ([int]$before[$n] -eq [int]$after[$n]) ("HKCU value {0} changed although the mode was skip" -f $n)
            }
        }
        Write-Host 'detail: T9: HKCU left untouched in skip mode'
    }

    # --- phase 5: bilingual settings (no mutex, no registry) ----------------
    $rEn = Invoke-Launcher -Label 'settings-en' -LauncherArgs @('--settings', '--lang', 'en', '--app-dir', $tree, '--findings', $findings)
    Assert ($rEn.Code -eq 0) ("--settings (en) must exit 0, got {0}" -f $rEn.Code)
    Assert ($rEn.Text -match 'language: en') 'EN settings did not report the language'
    Assert ($rEn.Text -match 'hkcu-mode') 'EN settings did not report the hkcu-mode field'
    $rRu = Invoke-Launcher -Label 'settings-ru' -LauncherArgs @('--settings', '--lang', 'ru', '--app-dir', $tree, '--findings', $findings)
    Assert ($rRu.Code -eq 0) ("--settings (ru) must exit 0, got {0}" -f $rRu.Code)
    Assert ($rRu.Text -match 'язык: ru') 'RU settings did not report the language'
    Assert ($rRu.Text -match 'настройки:') 'RU settings title missing'

    $policyNote = if ($modeActive) {
        'policy 11 keys present during run and removed after'
    }
    else {
        ('policy skipped (T1 {0}), HKCU untouched' -f $t1Verdict)
    }
    Emit ('PASS - mode={0}; {1}; {2}; mutex+start-twice forward, prune stale+fresh, EN/RU settings, selftest exit 0' -f $modeLabel, $policyNote, $dllNote)
}
catch {
    Emit ('FAIL - ' + $_.Exception.Message)
}
finally {
    if ($null -ne $script:heldHandle -and -not $script:heldHandle.Process.HasExited) {
        try { $script:heldHandle.Process.Kill() } catch { }
    }
    if ($null -ne $script:dllAside -and (Test-Path -LiteralPath $script:dllAside)) {
        Move-Item -LiteralPath $script:dllAside -Destination (Join-Path (Split-Path -Parent $script:dllAside) 'version.dll') -Force -ErrorAction SilentlyContinue
    }
    Stop-ClaimsBrowser
    if (-not [string]::IsNullOrWhiteSpace($script:tree) -and (Test-Path -LiteralPath $script:tree)) {
        Remove-Item -LiteralPath $script:tree -Recurse -Force -ErrorAction SilentlyContinue
    }
}
