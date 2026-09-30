# tests/claims.tests.ps1 — behavior tests for probe/claims/claims-lib.ps1
# (issue #1 claims probes T1-T8, feature yandex-issue1-claims-test).
#
# Run:  pwsh -NoProfile -File tests/claims.tests.ps1
# Hermetic: no network, no browser, no registry — the lib is pure decision
# logic so the claims verdicts are testable off-Windows before CI runs them.

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$lib      = Join-Path $repoRoot 'probe/claims/claims-lib.ps1'

$script:passed  = 0
$script:failed  = 0
$script:failure = @()

function Ok([string]$m) {
    $script:passed++
    Write-Host "  ok   $m"
}
function Fail([string]$m) {
    $script:failed++
    $script:failure += $m
    Write-Host "  FAIL $m" -ForegroundColor Red
}
function Assert([bool]$cond, [string]$m) {
    if ($cond) { Ok $m } else { Fail $m }
}

if (-not (Test-Path -LiteralPath $lib)) {
    Write-Host "  FAIL missing lib: $lib" -ForegroundColor Red
    Write-Host ''
    Write-Host "RESULT: 0 passed, 1 failed"
    exit 1
}
. $lib

# ------------------------------------------------------------ verdict lines --

Write-Host 'Format-VerdictLine'
Assert ((Format-VerdictLine 'T1' 'PASS - ok') -eq 'T1 verdict: PASS - ok') `
    'formats the spike verdict line verbatim'
Assert ((Format-VerdictLine 'T8' "FAIL - line1`nline2") -eq 'T8 verdict: FAIL - line1 line2') `
    'newlines inside details collapse to one line (log grep stays single-line)'
Assert ((Format-VerdictLine 'T3' 'BROKEN - group B: webgl') -notmatch "[`r`n]") `
    'never returns a multi-line verdict'
$planStyle = Format-VerdictLine 'T2' '5 of 9 claimed names fabricated; 461 policies; all class=Both'
Assert ($planStyle -eq 'T2 verdict: 5 of 9 claimed names fabricated; 461 policies; all class=Both') `
    'custom (non PASS/FAIL) verdict keeps the plan wording'
Assert ((Format-VerdictLine 'T7' 'PASS - relaunch ok') -match '^T[1-8] verdict: ') `
    'verdict line matches the verify grep T[1-8] verdict:'
foreach ($id in @('T1', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'T8')) {
    Assert ((Format-VerdictLine $id 'PASS - x') -match ('^' + $id + ' verdict: ')) `
        "id $id emits its own verdict anchor"
}

# --------------------------------------------------------------- ADMX audit --

Write-Host 'Get-AdmxAudit'
$admxOrder = @'
<?xml version="1.0" encoding="utf-16"?>
<policyDefinitions revision="1.0" xmlns="http://schemas.microsoft.com/GroupPolicy/2006/07/PolicyDefinitions">
  <policies>
    <policy name="SpellCheckServiceEnabled" class="Both" displayName="x" />
    <policy class="Machine" name="WeirdOrder" displayName="y" />
    <policy name="StatisticsReporting" displayName="z" class="Both" />
  </policies>
</policyDefinitions>
'@
$a1 = Get-AdmxAudit -AdmxText $admxOrder -IssueNames @('SpellCheckServiceEnabled', 'MetricsReportingEnabled') -ShippedNames @('StatisticsReporting', 'UpdateAllowed')
Assert ($a1.Total -eq 3) 'counts every policy element'
Assert ($a1.ClassCounts['Both'] -eq 2 -and $a1.ClassCounts['Machine'] -eq 1) 'breaks class= down per policy'
Assert (-not $a1.AllClassBoth) 'AllClassBoth is false when any policy is not Both'
Assert (-not ($a1.ClassCounts.ContainsKey('policyDefinitions'))) 'policyDefinitions element is never counted as a policy'
Assert ($a1.Issue['SpellCheckServiceEnabled'] -eq 'EXISTS') 'existing claimed name reports EXISTS'
Assert ($a1.Issue['MetricsReportingEnabled'] -eq 'MISSING') 'fabricated claimed name reports MISSING'
Assert ($a1.IssueFabricatedCount -eq 1) 'fabricated count = missing issue names'
Assert ($a1.Shipped['StatisticsReporting'] -eq 'EXISTS') 'shipped name present reports EXISTS'
Assert ($a1.Shipped['UpdateAllowed'] -eq 'MISSING') 'shipped name absent reports MISSING'
Assert ($a1.IssueMissing[0] -eq 'MetricsReportingEnabled') 'missing issue names listed for the details block'

# The real Discovery shape: 4 of the 9 issue-claimed names exist, all 11 shipped
# names exist, every policy is class=Both -> verdict must read "5 of 9".
$have = @('SpellCheckServiceEnabled', 'AutofillCreditCardEnabled', 'AutofillAddressEnabled', 'DefaultSearchProviderEnabled')
$shipped = @('StatisticsReporting', 'CrashesReporting', 'BackgroundModeEnabled', 'YandexAutoLaunchMode',
             'YandexAliceMsgDisable', 'NeuroNtpTools', 'NtpNotificationsDisable', 'YandexButtonDisable',
             'SearchSuggestEnabled', 'UpdateAllowed', 'BackgroundUpdateAllowed')
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('<?xml version="1.0" encoding="utf-16"?>')
[void]$sb.AppendLine('<policyDefinitions><policies>')
foreach ($n in ($have + $shipped)) { [void]$sb.AppendLine("  <policy name=`"$n`" class=`"Both`" />") }
for ($i = 0; $i -lt 446; $i++) { [void]$sb.AppendLine("  <policy name=`"Filler$i`" class=`"Both`" />") }
[void]$sb.AppendLine('</policies></policyDefinitions>')
$a2 = Get-AdmxAudit -AdmxText $sb.ToString()
Assert ($a2.Total -eq 461) 'totals 461 policies for the discovery-shaped fixture'
Assert ($a2.AllClassBoth) 'AllClassBoth true when every policy is Both'
Assert ($a2.IssueFabricatedCount -eq 5) '5 of 9 issue-claimed names fabricated (Discovery)'
Assert ($a2.ShippedMissing.Count -eq 0) 'all 11 shipped names found in the ADMX'
Assert ((Format-VerdictLine 'T2' "$($a2.IssueFabricatedCount) of 9 claimed names fabricated; $($a2.Total) policies; all class=Both") -eq
        'T2 verdict: 5 of 9 claimed names fabricated; 461 policies; all class=Both') `
    'T2 verdict string matches the plan wording'
Assert ((Get-AdmxAudit -AdmxText $sb.ToString()).Issue.Count -eq 9) 'defaults audit exactly the 9 issue-claimed names'
Assert ((Get-AdmxAudit -AdmxText $sb.ToString()).Shipped.Count -eq 11) 'defaults audit exactly our 11 shipped names'

# -------------------------------------------------------------- trim groups --

Write-Host 'Get-TrimGroupSpec'
$gA = Get-TrimGroupSpec 'A'
Assert (($gA.Delete -join ',') -eq 'clidmgr.exe,browser_proxy.exe,clids_*.xml') 'group A deletes the affiliate trio'
Assert ($gA.Keep.Count -eq 0) 'group A keeps nothing'
Assert (((Get-TrimGroupSpec 'B').Delete -join ',') -eq 'widgets') 'group B deletes widgets'
Assert (((Get-TrimGroupSpec 'C').Delete -join ',') -eq 'voiceactivation') 'group C deletes voiceactivation'
Assert (((Get-TrimGroupSpec 'D').Delete -join ',') -eq 'web_app_config') 'group D deletes web_app_config'
$gE = Get-TrimGroupSpec 'E'
Assert (($gE.Delete -join ',') -eq 'Locales\*') 'group E clears the Locales directory'
Assert (($gE.Keep -join ',') -eq 'en-US.pak') 'group E keeps only en-US.pak'
$threw = $false
try { Get-TrimGroupSpec 'Z' | Out-Null } catch { $threw = $true }
Assert $threw 'unknown group id throws instead of silently deleting nothing'

# ------------------------------------------------------- EME / WebGL parsing --

Write-Host 'Get-EmeResult / Get-WebglResult'
Assert ((Get-EmeResult '<html><title>CDM_OK</title></html>') -eq 'CDM_OK') 'CDM_OK title parses'
Assert ((Get-EmeResult '<pre id="o">CDM_FAIL:NotSupportedError:Unsupported keySystem</pre>') -eq 'CDM_FAIL:NotSupportedError:Unsupported keySystem') `
    'CDM_FAIL pre text parses'
Assert ((Get-EmeResult '<pre id="o">pending</pre>') -eq 'NO_RESULT') 'pending pre is NO_RESULT'
Assert ((Get-EmeResult '') -eq 'NO_RESULT') 'empty dump is NO_RESULT'
Assert ((Get-EmeResult $null) -eq 'NO_RESULT') 'null dump is NO_RESULT'
Assert ((Get-WebglResult '<title>WEBGL_OK</title>') -eq 'WEBGL_OK') 'WEBGL_OK title parses'
Assert ((Get-WebglResult '<title>WEBGL_FAIL</title>') -eq 'WEBGL_FAIL') 'WEBGL_FAIL title parses'
Assert ((Get-WebglResult '<title>probe</title>') -eq 'NO_RESULT') 'unrelated title is NO_RESULT'
Assert ((Get-WebglResult '') -eq 'NO_RESULT') 'empty webgl dump is NO_RESULT'

# ------------------------------------------------------------ group verdicts --

Write-Host 'Get-GroupVerdict'
$safe = Get-GroupVerdict -Capabilities @{ Dump = 'OK'; Webgl = 'OK'; Eme = 'WARN' }
Assert ($safe.State -eq 'SAFE') 'EME at the CDM_FAIL baseline (WARN) keeps the group SAFE'
Assert ($safe.Broken.Count -eq 0) 'SAFE group lists no broken capability'
$broken = Get-GroupVerdict -Capabilities @{ Dump = 'OK'; Webgl = 'BROKEN'; Eme = 'OK' }
Assert ($broken.State -eq 'BROKEN') 'a broken WebGL capability breaks the group'
Assert (($broken.Broken -join ',') -eq 'Webgl') 'the broken capability is named'
$mixed = Get-GroupVerdict -Capabilities @{ Dump = 'BROKEN'; Webgl = 'OK'; Eme = 'BROKEN' }
Assert ($mixed.State -eq 'BROKEN' -and $mixed.Broken.Count -eq 2) 'every broken capability is reported'
$crash = Get-GroupVerdict -Capabilities @{ Dump = 'OK'; Webgl = 'OK'; Eme = 'CRASH' }
Assert ($crash.State -eq 'BROKEN') 'a NEW EME crash (not the CDM_FAIL baseline) breaks the group'
$miss = Get-GroupVerdict -Capabilities @{ Dump = 'OK' }
Assert ($miss.State -eq 'BROKEN') 'a capability that never reported cannot be silently SAFE'

# --------------------------------------------------------------- prune rules --

Write-Host 'Get-PruneVerdict'
$core = @('GPUCache', 'ShaderCache', 'GrShaderCache', 'DawnCache', 'Default\Cache', 'Default\Code Cache', 'Default\Service Worker\CacheStorage')
$eventDriven = @('Crashpad', 'BrowserMetrics-*')
$p1 = Get-PruneVerdict -RelaunchOk $true -Recreated @($core + $eventDriven) -Missing @() -EventDriven $eventDriven
Assert ($p1.State -eq 'PASS') 'all dirs recreated passes'
$p2 = Get-PruneVerdict -RelaunchOk $true -Recreated @('GPUCache', 'Crashpad') -Missing @('ShaderCache') -EventDriven $eventDriven
Assert ($p2.State -eq 'PASS' -and $p2.Details -match 'missing') `
    'event-driven dirs reported missing never fail the probe by themselves'
$p3 = Get-PruneVerdict -RelaunchOk $true -Recreated @('Crashpad') -Missing @('GPUCache', 'Default\Cache') -EventDriven $eventDriven
Assert ($p3.State -eq 'FAIL') 'a missing core cache dir fails the probe'
$p4 = Get-PruneVerdict -RelaunchOk $false -Recreated @() -Missing @() -EventDriven $eventDriven
Assert ($p4.State -eq 'FAIL') 'a broken relaunch fails the probe'
$p5 = Get-PruneVerdict -RelaunchOk $true -Recreated @() -Missing @('GPUCache') -EventDriven $eventDriven
Assert ($p5.State -eq 'FAIL') 'zero recreated dirs fails the probe even when relaunch works'
Assert ($p1.Details -match 'rule:') 'prune verdict states its rule in the details'

# ---------------------------------------------------------- preference hits --

Write-Host 'Get-PreferenceKeyHits / Get-PreferenceDiff'
$keys = @('neuro_question', 'video_button_enabled', 'show_ya_button', 'app_side_promo_service_enabled', 'alissenger', 'default_apps_installed')
$pre = '{"browser":{"show_ya_button":false,"app_side_promo_service_enabled":false},"alissenger":{"enabled":false},"web_app":{"default_apps_installed":{}}}'
$hits = Get-PreferenceKeyHits -Text $pre -Keys $keys
Assert ($hits['show_ya_button'] -eq 'EXIST') 'preseeded key reports EXIST'
Assert ($hits['neuro_question'] -eq 'ABSENT') 'missing key reports ABSENT'
Assert ($hits.Count -eq 6) 'all six issue-claimed names are audited'
$post = $pre + '{"neuro":{"question":{"video_button_enabled":true}},"neuro_question":true}'
$diff = Get-PreferenceDiff -Before $pre -After $post -Keys $keys
Assert ($diff.Status['neuro_question'] -eq 'MATERIALIZED') 'absent -> exist means the NTP materialized it'
Assert ($diff.Status['video_button_enabled'] -eq 'MATERIALIZED') 'nested video_button_enabled materialized'
Assert ($diff.Status['show_ya_button'] -eq 'PRESEEDED') 'present before launch means preseeded'
Assert ($diff.Status['alissenger'] -eq 'PRESEEDED') 'alissenger stays PRESEEDED'
Assert ($diff.MaterializedCount -eq 2) 'materialized count covers both new keys'
Assert ($diff.PreseededCount -eq 4) 'preseeded count covers the four shipped keys'
$loss = Get-PreferenceDiff -Before $pre -After '{}' -Keys $keys
Assert ($loss.Status['show_ya_button'] -eq 'LOST') 'present -> absent reports LOST'
Assert ($loss.Status['neuro_question'] -eq 'ABSENT') 'absent -> absent reports ABSENT'

# -------------------------------------------------------- corporate verdicts --

Write-Host 'Get-CorporateProbeTargets / Get-CorporateVerdict'
$t = Get-CorporateProbeTargets
Assert ($t.Cdn.Count -eq 3) 'three corporate CDN candidate patterns are probed'
Assert (@($t.Cdn | Where-Object { $_ -notlike 'https://download.cdn.yandex.net/*' }).Count -eq 0) 'every CDN candidate stays under download.cdn.yandex.net'
Assert (@($t.Cdn | Select-Object -Unique).Count -eq 3) 'CDN candidates are distinct'
Assert ($t.Landing -eq 'https://yandex.com/support/browser/business/en/') 'the public corporate landing page is probed'
$all404 = Get-CorporateVerdict -Results @(
    @{ Url = $t.Cdn[0]; Status = '404' },
    @{ Url = $t.Cdn[1]; Status = '404' },
    @{ Url = $t.Cdn[2]; Status = '404' },
    @{ Url = $t.Landing; Status = '404' }) -InstallerHrefs @()
Assert ($all404 -match '^NO-PUBLIC-ENDPOINT-FOUND') 'no resolvable URL yields NO-PUBLIC-ENDPOINT-FOUND'
Assert ($all404 -match 'tried 4 URLs') 'the verdict counts every URL it tried'
Assert ($all404 -match 'consistent with prior research \(login-gated\)') 'the verdict cites prior research'
Assert ($all404 -notmatch 'proves') 'the verdict never claims a 404 proves login-gating'
$found = Get-CorporateVerdict -Results @(
    @{ Url = $t.Cdn[0]; Status = '404' },
    @{ Url = 'https://download.cdn.yandex.net/browser/corporate/YandexBrowser.msi'; Status = '200' }) -InstallerHrefs @()
Assert ($found -match '^PUBLIC-ENDPOINT https://download\.cdn\.yandex\.net/browser/corporate/YandexBrowser\.msi') `
    'a resolving installer URL is reported verbatim'

# ------------------------------------------------------------- T5 first-run --

Write-Host 'Get-FirstRunVerdict'
$fr = Get-FirstRunVerdict -Diff $diff
Assert ($fr -match 'EXIST') 'first-run verdict states how many names exist'
Assert ($fr -match 'neuro_question=MATERIALIZED') 'first-run verdict carries per-name status'
Assert ($fr -notmatch "[`r`n]") 'first-run verdict stays on one line'

# ------------------------------------------------------------ selection map --

Write-Host 'Get-VerdictIdsForSelection'
Assert ((Get-VerdictIdsForSelection 'all').Count -eq 8) 'all selects the eight T1-T8 probes'
Assert ((Get-VerdictIdsForSelection 'all') -contains 'T1') 'T1 is part of the T1-T8 group'
Assert ((Get-VerdictIdsForSelection 't3').Count -eq 1 -and (Get-VerdictIdsForSelection 't3')[0] -eq 'T3') `
    'single-probe selection returns just that probe'
Assert ((Get-VerdictIdsForSelection 'T7')[0] -eq 'T7') 'selection ids are case-insensitive'
Assert ((Get-VerdictIdsForSelection 't9').Count -eq 0) 't9 selects nothing until task 2 adds its job'
Assert ((Get-VerdictIdsForSelection 'nonsense').Count -eq 8) 'an unknown selection degrades to all probes'
$ids = Get-VerdictIdsForSelection 'all'
Assert (($ids -join ',') -eq 'T1,T2,T3,T4,T5,T6,T7,T8') 'selection order is T1..T8 (T1 emitted last by the job)'

Write-Host ''
Write-Host 'fetch-installer version passthrough (dot-source param clobber regression)'
# build-yandex.ps1 has its own param($Version); dot-sourcing it shares this
# scope, so its empty default used to clobber -Version before the SHA256 fetch
# (manifest URL built with an empty version -> 404). Fake builder records what
# the helper receives; a warm cache skips the network download entirely.
$fiRoot = Join-Path ([IO.Path]::GetTempPath()) ('fetch-installer-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fiRoot -Force | Out-Null
$fiBuilderText = @'
param(
    [string]$Version,
    [string]$OutDir,
    [string]$Installer,
    [switch]$Download,
    [string]$ChromePlusUrl = ''
)
$script:RecordPath = Join-Path $PSScriptRoot 'calls.txt'
function Test-Url([string]$uri) { return $true }
function Resolve-ManifestUrl([string]$version) {
    Add-Content -LiteralPath $script:RecordPath -Value ("resolve:{0}" -f $version)
    return 'file:///unused'
}
function Get-ManifestSha256([string]$version) {
    Add-Content -LiteralPath $script:RecordPath -Value ("sha:{0}" -f $version)
    return ('0' * 64)
}
function Assert-InstallerSha256([string]$Path, [string]$ExpectedSha256) {
    Add-Content -LiteralPath $script:RecordPath -Value ("assert:{0}" -f $ExpectedSha256)
    return $ExpectedSha256
}
'@
Set-Content -LiteralPath (Join-Path $fiRoot 'build-yandex.ps1') -Value $fiBuilderText -Encoding utf8
$fiOut = Join-Path $fiRoot 'out.exe'
[IO.File]::WriteAllBytes($fiOut, [byte[]](1..64))
$fiScript = Join-Path $repoRoot 'probe/claims/fetch-installer.ps1'
$fiLog = Join-Path $fiRoot 'run.log'
$pwshExe = (Get-Command pwsh -ErrorAction Stop).Source
& $pwshExe -NoProfile -File $fiScript -RepoRoot $fiRoot -Version '9.9.9.9' -OutFile $fiOut *> $fiLog
$fiRc = $LASTEXITCODE
Assert ($fiRc -eq 0) "fetch-installer exits 0 against the fake builder (rc=$fiRc)"
$fiCalls = Join-Path $fiRoot 'calls.txt'
$fiRecord = if (Test-Path -LiteralPath $fiCalls) { [string](Get-Content -LiteralPath $fiCalls -Raw -ErrorAction SilentlyContinue) } else { '' }
Assert ($fiRecord -match 'sha:9\.9\.9\.9') "builder helper receives -Version intact after dot-source (got: $($fiRecord -replace "`n", '; '))"
$fiRunLog = if (Test-Path -LiteralPath $fiLog) { [string](Get-Content -LiteralPath $fiLog -Raw -ErrorAction SilentlyContinue) } else { '' }
Assert ($fiRunLog -match 'SHA256 verified') 'fetch-installer reports the SHA256 verification step'
Remove-Item -LiteralPath $fiRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "RESULT: $script:passed passed, $script:failed failed"
if ($script:failed -gt 0) {
    foreach ($f in $script:failure) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
exit 0
