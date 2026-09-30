# probe/claims/claims-lib.ps1 — pure decision logic for the claims probes
# (feature yandex-issue1-claims-test, issue #1).
#
# Everything here is deterministic and offline: no network, no browser, no
# registry, no filesystem writes. IO lives in probe/claims/*.ps1; verdict
# wording lives here so tests/claims.tests.ps1 can pin it before CI runs it.
#
# Dot-source: . probe/claims/claims-lib.ps1

Set-StrictMode -Version Latest

# Names claimed by issue #1 section 5 (4 EXIST in the ADMX, 5 fabricated).
$script:IssueClaimedNames = @(
    'MetricsReportingEnabled',
    'YandexAliceEnabled',
    'FeedbackAllowed',
    'SpellCheckServiceEnabled',
    'AutofillCreditCardEnabled',
    'AutofillAddressEnabled',
    'PromotionalTabsEnabled',
    'DefaultSearchProviderEnabled',
    'BrowserAddPersonEnabled'
)

# Our 11 shipped names (build-yandex.ps1 / update.bat debloater.reg).
$script:ShippedPolicyNames = @(
    'StatisticsReporting',
    'CrashesReporting',
    'BackgroundModeEnabled',
    'YandexAutoLaunchMode',
    'YandexAliceMsgDisable',
    'NeuroNtpTools',
    'NtpNotificationsDisable',
    'YandexButtonDisable',
    'SearchSuggestEnabled',
    'UpdateAllowed',
    'BackgroundUpdateAllowed'
)

# Cache dirs the portable tree must recreate on a clean relaunch (T7).
$script:PruneCriticalDirs = @('GPUCache', 'Default\Cache')

function New-OrdinalIgnoreCaseMap {
    return [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
}

# ---------------------------------------------------------------- verdicts --

function Format-VerdictLine {
    <# One line, grep-safe: "<id> verdict: <details>" (ASCII ' - '). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^T\d+$')][string]$Id,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Details
    )
    $oneLine = ($Details -replace '[\r\n]+', ' ') -replace '\s{2,}', ' '
    return ('{0} verdict: {1}' -f $Id, $oneLine.Trim())
}

# -------------------------------------------------------------------- ADMX --

function Get-AdmxAudit {
    <# Parse an ADMX document and audit the issue-claimed vs shipped names.
       Every <policy> element is counted; class= is broken down. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$AdmxText,
        [string[]]$IssueNames = $script:IssueClaimedNames,
        [string[]]$ShippedNames = $script:ShippedPolicyNames
    )

    $audit = [pscustomobject]@{
        Total                = 0
        AllClassBoth         = $false
        ClassCounts          = New-OrdinalIgnoreCaseMap
        Issue                = New-OrdinalIgnoreCaseMap
        Shipped              = New-OrdinalIgnoreCaseMap
        IssueMissing         = @()
        ShippedMissing       = @()
        IssueFabricatedCount = 0
    }

    $policyTags = [regex]::Matches($AdmxText, '<policy\b[^>]*>', 'IgnoreCase')
    $seenClasses = 0
    $bothCount   = 0
    foreach ($tag in $policyTags) {
        $audit.Total++
        $classMatch = [regex]::Match($tag.Value, '\bclass\s*=\s*"([^"]*)"', 'IgnoreCase')
        $className  = if ($classMatch.Success) { $classMatch.Groups[1].Value } else { '(none)' }
        if (-not $audit.ClassCounts.ContainsKey($className)) { $audit.ClassCounts[$className] = 0 }
        $audit.ClassCounts[$className] = [int]$audit.ClassCounts[$className] + 1
        $seenClasses++
        if ($className -ieq 'Both') { $bothCount++ }
    }
    $audit.AllClassBoth = ($audit.Total -gt 0 -and $seenClasses -eq $bothCount)

    foreach ($name in $IssueNames) {
        $state = if ($AdmxText -match ('<policy\b[^>]*\bname\s*=\s*"{0}"' -f [regex]::Escape($name))) { 'EXISTS' } else { 'MISSING' }
        $audit.Issue[$name] = $state
        if ($state -eq 'MISSING') { $audit.IssueMissing += $name }
    }
    $audit.IssueFabricatedCount = @($audit.IssueMissing).Count

    foreach ($name in $ShippedNames) {
        $state = if ($AdmxText -match ('<policy\b[^>]*\bname\s*=\s*"{0}"' -f [regex]::Escape($name))) { 'EXISTS' } else { 'MISSING' }
        $audit.Shipped[$name] = $state
        if ($state -eq 'MISSING') { $audit.ShippedMissing += $name }
    }

    return $audit
}

# ---------------------------------------------------------------- T7 trim --

function Get-TrimGroupSpec {
    <# Trim group definition: what to delete, what must survive (T6). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GroupId)

    switch -Regex ($GroupId.Trim().ToUpperInvariant()) {
        '^A$' {
            return [pscustomobject]@{
                Id     = 'A'
                Delete = @('clidmgr.exe', 'browser_proxy.exe', 'clids_*.xml')
                Keep   = @()
            }
        }
        '^B$' {
            return [pscustomobject]@{ Id = 'B'; Delete = @('widgets');      Keep = @() }
        }
        '^C$' {
            return [pscustomobject]@{ Id = 'C'; Delete = @('voiceactivation'); Keep = @() }
        }
        '^D$' {
            return [pscustomobject]@{ Id = 'D'; Delete = @('web_app_config'); Keep = @() }
        }
        '^E$' {
            return [pscustomobject]@{
                Id     = 'E'
                Delete = @('Locales\*')
                Keep   = @('en-US.pak')
            }
        }
        default {
            throw ("unknown trim group '{0}' (expected A-E)" -f $GroupId)
        }
    }
}

# --------------------------------------------------- EME / WebGL parsers --

function Get-EmeResult {
    <# Extract the CDM probe outcome from a page dump. The DRM baseline is
       CDM_FAIL (Widevine needs a signed CDM); anything else is new. #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return 'NO_RESULT' }

    $title = [regex]::Match($Text, '<title>\s*(CDM_(?:OK|FAIL)[^<]*?)\s*</title>', 'IgnoreCase')
    if ($title.Success) { return $title.Groups[1].Value }

    $body = [regex]::Match($Text, '>\s*(CDM_FAIL[^<]*?)\s*<', 'IgnoreCase')
    if ($body.Success) { return $body.Groups[1].Value }

    return 'NO_RESULT'
}

function Get-WebglResult {
    <# Extract the WebGL probe outcome from a page dump. #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return 'NO_RESULT' }

    $title = [regex]::Match($Text, '<title>\s*(WEBGL_(?:OK|FAIL)[^<]*?)\s*</title>', 'IgnoreCase')
    if ($title.Success) { return $title.Groups[1].Value }

    return 'NO_RESULT'
}

# -------------------------------------------------------- T6 group verdict --

function Get-GroupVerdict {
    <# A trim group is SAFE only when every probed capability still reports.
       Any BROKEN (or a NEW EME crash) fails the group; a capability that
       never reported cannot be silently SAFE. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Capabilities)

    $expected = @('Dump', 'Webgl', 'Eme')
    $broken   = @()
    foreach ($cap in $expected) {
        if (-not $Capabilities.ContainsKey($cap)) {
            $broken += $cap
            continue
        }
        $state = [string]$Capabilities[$cap]
        if ($state -ieq 'BROKEN' -or $state -ieq 'CRASH') { $broken += $cap }
    }

    $stateWord = if ($broken.Count -eq 0) { 'SAFE' } else { 'BROKEN' }
    return [pscustomobject]@{
        State   = $stateWord
        Broken  = $broken
        Details = ('rule: group is SAFE only when Dump+Webgl+Eme all report; broken=({0})' -f ($broken -join ','))
    }
}

# ----------------------------------------------------------- T7 prune rule --

function Get-PruneVerdict {
    <# Relaunch after deleting the cache dirs must recreate the launch-critical
       set. Event-driven dirs (Crashpad, BrowserMetrics-*) never fail the probe
       by themselves; they are reported only. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$RelaunchOk,
        [string[]]$Recreated = @(),
        [string[]]$Missing   = @(),
        [string[]]$EventDriven = @('Crashpad', 'BrowserMetrics-*')
    )

    $criticalMissing = @($Missing | Where-Object { $_ -in $script:PruneCriticalDirs })
    $eventOnly       = @($Missing | Where-Object { $_ -in $EventDriven })
    $recreated       = @($Recreated)

    $rule = 'rule: relaunch ok + >=1 dir recreated + no missing GPUCache/Default\Cache (event-driven dirs reported only)'
    $parts = @(
        $rule
        ('relaunch={0}' -f $(if ($RelaunchOk) { 'ok' } else { 'FAILED' }))
        ('recreated={0}' -f $(if ($recreated.Count -gt 0) { $recreated -join ',' } else { 'none' }))
        ('missing={0}' -f $(if (@($Missing).Count -gt 0) { $Missing -join ',' } else { 'none' }))
        ('event-driven={0}' -f $(if ($eventOnly.Count -gt 0) { $eventOnly -join ',' } else { 'none' }))
        ('critical-missing={0}' -f $(if ($criticalMissing.Count -gt 0) { $criticalMissing -join ',' } else { 'none' }))
    )

    $failed     = (-not $RelaunchOk) -or ($recreated.Count -eq 0) -or ($criticalMissing.Count -gt 0)
    $stateWord  = if ($failed) { 'FAIL' } else { 'PASS' }

    return [pscustomobject]@{
        State   = $stateWord
        Details = ($parts -join '; ')
    }
}

# --------------------------------------------------- T5 preference helpers --

function Get-PreferenceKeyHits {
    <# Which of the audited key names appear at all in a Preferences blob. #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string[]]$Keys
    )

    $hits = New-OrdinalIgnoreCaseMap
    $blob = if ([string]::IsNullOrEmpty($Text)) { '' } else { $Text }
    foreach ($key in $Keys) {
        $pattern = '"{0}"\s*:' -f [regex]::Escape($key)
        $hits[$key] = if ($blob -match $pattern) { 'EXIST' } else { 'ABSENT' }
    }
    return $hits
}

function Get-PreferenceDiff {
    <# Pre-launch vs post-first-run Preferences diff for the audited keys. #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Before,
        [AllowNull()][AllowEmptyString()][string]$After,
        [Parameter(Mandatory)][string[]]$Keys
    )

    $beforeHits = Get-PreferenceKeyHits -Text $Before -Keys $Keys
    $afterHits  = Get-PreferenceKeyHits -Text $After  -Keys $Keys

    $status = New-OrdinalIgnoreCaseMap
    $materialized = 0
    $preseeded    = 0
    foreach ($key in $Keys) {
        $b = [string]$beforeHits[$key]
        $a = [string]$afterHits[$key]
        $state = if ($b -eq 'EXIST' -and $a -eq 'EXIST') { $preseeded++; 'PRESEEDED' }
                 elseif ($b -eq 'ABSENT' -and $a -eq 'EXIST') { $materialized++; 'MATERIALIZED' }
                 elseif ($b -eq 'EXIST' -and $a -eq 'ABSENT') { 'LOST' }
                 else { 'ABSENT' }
        $status[$key] = $state
    }

    return [pscustomobject]@{
        Status             = $status
        MaterializedCount  = $materialized
        PreseededCount     = $preseeded
        Keys               = $Keys
    }
}

function Get-FirstRunVerdict {
    <# Single-line T5 details: per-name status plus the summary. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Diff)

    $pairs = @()
    foreach ($key in $Diff.Keys) { $pairs += ('{0}={1}' -f $key, [string]$Diff.Status[$key]) }
    $summary = ('first-run: {0} EXIST ({1} materialized, {2} preseeded, {3} lost, {4} absent)' -f
        (@($pairs).Count),
        $Diff.MaterializedCount,
        $Diff.PreseededCount,
        (@($Diff.Keys | Where-Object { $Diff.Status[$_] -eq 'LOST' }).Count),
        (@($Diff.Keys | Where-Object { $Diff.Status[$_] -eq 'ABSENT' }).Count))
    return (@($pairs) -join ', ') + '; ' + $summary
}

# --------------------------------------------------------- T4 corporate URLs --

function Get-CorporateProbeTargets {
    <# The URLs T4 probes: three corporate CDN candidates plus the public
       corporate landing page. #>
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        Cdn = @(
            'https://download.cdn.yandex.net/browser/corporate/YandexBrowser.admx'
            'https://download.cdn.yandex.net/browser/corporate/YandexBrowser.msi'
            'https://download.cdn.yandex.net/browser/corporate/YandexBrowser.exe'
        )
        Landing = 'https://yandex.com/support/browser/business/en/'
    }
}

function Get-CorporateVerdict {
    <# T4 verdict from probed results. A resolving URL is reported verbatim;
       all-404 yields NO-PUBLIC-ENDPOINT-FOUND and never claims a 404 proves
       login-gating (prior research says the endpoint is login-gated; 404 alone
       is only consistent with that). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()]$Results,
        [AllowEmptyCollection()][string[]]$InstallerHrefs = @()
    )

    $tried  = @($Results).Count
    $hrefs  = @($InstallerHrefs | Where-Object { $_ -match '^https?://' })

    foreach ($entry in @($Results)) {
        $status = [string]$entry.Status
        if ($status -match '^[23]\d\d$') {
            return ('PUBLIC-ENDPOINT {0} (HTTP {1})' -f [string]$entry.Url, $status)
        }
    }
    foreach ($href in $hrefs) {
        if ($href -match '^https?://') { return ('PUBLIC-ENDPOINT {0} (link discovered, HTTP pending)' -f $href) }
    }

    $hrefNote = if ($hrefs.Count -gt 0) { ('; {0} installer link(s) found but none fetched' -f $hrefs.Count) } else { '' }
    return ('NO-PUBLIC-ENDPOINT-FOUND - tried {0} URLs (corporate CDN candidates, public landing, discovered links); ' -f $tried) +
           ('consistent with prior research (login-gated); a 404 alone is not proof of login-gating{0}' -f $hrefNote)
}

# ------------------------------------------------------------- selection --

function Get-VerdictIdsForSelection {
    <# Map the workflow_dispatch `test` input to probe ids.
       all/unknown -> T1..T9; t9 -> T9 (launcher stage, task 2); tN -> that probe. #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Selection = 'all')

    $all = @('T1', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'T8', 'T9')
    $sel = if ([string]::IsNullOrWhiteSpace($Selection)) { 'all' } else { $Selection.Trim() }

    # Unary comma keeps the array intact through the pipeline: single-element
    # selections must still report .Count -eq 1 instead of collapsing to a
    # scalar string.
    if ($sel -ieq 'all') { return ,$all }

    $single = [regex]::Match($sel, '^t([1-9])$', 'IgnoreCase')
    if ($single.Success) { return ,@(('T' + $single.Groups[1].Value)) }

    return ,$all
}

# ------------------------------------------------------- T6 atomic replace --

function Invoke-AtomicReplace {
    <# Atomic same-directory swap: the caller writes $SourcePath (a .tmp), then
       the destination is replaced in place. Never passes $null as the backup
       argument - PowerShell binds $null to an empty [string] for .NET method
       parameters, and File.Replace then throws "The path is empty" (the CI T6
       probe died on exactly that on its first write). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) { throw "atomic replace source missing: $SourcePath" }
    [IO.File]::Replace($SourcePath, $DestinationPath, [NullString]::Value)
    return $true
}

# -------------------------------------------------------- T8 locale verdict --

function Get-LocaleVerdict {
    <# T8 verdict: judge the RENDER after the locale trim, not the language
       tag. navigator.language comes from profile/OS negotiation (CI run showed
       lang=ru on an en-US-only Locales tree with a fully rendered page) - the
       pak catalog holds UI strings and does not drive the negotiation, so the
       verdict reports the observed tag instead of demanding en*. #>
    [CmdletBinding()]
    param(
        [bool]$DomOk,
        [bool]$OnlyEn,
        [AllowNull()][AllowEmptyString()][string]$Lang = '',
        [int]$DomBytes = 0
    )

    $problems = @()
    if (-not $DomOk) { $problems += 'body render marker RENDERED_TEXT_OK missing' }
    if ([string]::IsNullOrWhiteSpace($Lang)) {
        $problems += 'navigator.language unreadable (no LOCALE_ title in DOM)'
    }
    elseif ($DomBytes -le 0) {
        $problems += 'empty page dump (domBytes=0)'
    }
    if (-not $OnlyEn) { $problems += 'Locales tree is not en-US.pak-only (trim precondition broken)' }
    if ($problems.Count -gt 0) { return ('FAIL - ' + ($problems -join '; ')) }

    return ('PASS - rendered with lang={0} (negotiation is profile/OS-level; en-US-only pak trim keeps the render); domBytes={1}' -f $Lang, $DomBytes)
}

# ---------------------------------------------------- T6 prefs leftovers --

function Get-PrefsLeftovers {
    <# Corruption leftovers from an atomic Preferences write: only files whose
       name is derived from "Preferences" itself (Preferences.tmp/.bak/-journal).
       The browser's own SQLite sidecars (History-journal, Web Data-journal,
       ...) live in the same Default\ folder and are NORMAL after any launch -
       flagging them turned CI run 1's T6 into a false FAIL. #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Names = @())

    $leftovers = @()
    foreach ($n in $Names) {
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        if ($n -ieq 'Preferences') { continue }
        if ($n -like 'Preferences*' -and $n -match '(\.(tmp|bak|journal)$|-journal$)') { $leftovers += $n }
    }
    return ,$leftovers
}
