# probe/claims/t-corp.ps1 — T4: is a public corporate/MSI endpoint reachable?
# HEAD first (cheap), GET when HEAD fails (some CDNs reject HEAD); the landing
# page is fetched and grepped for direct installer hrefs. A 404 alone is NEVER
# stated as proof of login-gating - Get-CorporateVerdict owns that wording.

param(
    [string]$OutDir = $env:CLAIMS
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'claims-lib.ps1')
$emit = Join-Path $PSScriptRoot 'emit-verdict.ps1'

function Emit([string]$details) {
    & $emit -Id 'T4' -Details $details -OutDir $OutDir
    exit 0
}

function Get-HttpStatus([string]$Uri) {
    # Returns an integer status code as string, or ERR:<message>.
    try {
        $r = Invoke-WebRequest -Uri $Uri -Method Head -UseBasicParsing -TimeoutSec 25 -MaximumRedirection 5
        return [string][int]$r.StatusCode
    }
    catch {
        $resp = $_.Exception.Response
        $code = $null
        if ($null -ne $resp) {
            try { $code = [int]$resp.StatusCode } catch { $code = $null }
        }
        if ($null -ne $code -and $code -ne 405 -and $code -ne 501) {
            # recorded status is enough; still try GET for CDN hosts that lie on HEAD
            if ($code -ge 400) {
                try {
                    $g = Invoke-WebRequest -Uri $Uri -Method Get -UseBasicParsing -TimeoutSec 25 -MaximumRedirection 5
                    return [string][int]$g.StatusCode
                }
                catch {
                    $gr = $_.Exception.Response
                    if ($null -ne $gr) {
                        try { return [string][int]$gr.StatusCode } catch { }
                    }
                }
            }
            return [string]$code
        }
        # HEAD rejected (405/501) or no response object: fall back to GET
        try {
            $g = Invoke-WebRequest -Uri $Uri -Method Get -UseBasicParsing -TimeoutSec 25 -MaximumRedirection 5
            return [string][int]$g.StatusCode
        }
        catch {
            $gr = $_.Exception.Response
            if ($null -ne $gr) {
                try { return [string][int]$gr.StatusCode } catch { }
            }
            return ('ERR:' + $_.Exception.Message)
        }
    }
}

try {
    $targets = Get-CorporateProbeTargets
    $results = @()
    foreach ($u in $targets.Cdn) {
        $status = Get-HttpStatus -Uri $u
        Write-Host ("detail: T4: {0} -> {1}" -f $u, $status)
        $results += @{ Url = $u; Status = $status }
    }

    $hrefs = @()
    $landingStatus = 'ERR:not attempted'
    try {
        $landing = Invoke-WebRequest -Uri $targets.Landing -UseBasicParsing -TimeoutSec 40
        $landingStatus = [string][int]$landing.StatusCode
        $htmlPath = Join-Path $OutDir 't4-landing.html'
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
        Set-Content -Encoding utf8 -Path $htmlPath -Value ([string]$landing.Content)
        $base = [Uri]$targets.Landing
        foreach ($m in [regex]::Matches([string]$landing.Content, 'href\s*=\s*["'']([^"'']+)["'']', 'IgnoreCase')) {
            $href = $m.Groups[1].Value
            if ($href -match '\.(msi|exe|admx|zip)(\?|#|$)' -or $href -match '/corporate/') {
                try { $hrefs += ([Uri]::new($base, $href).AbsoluteUri) } catch { }
            }
        }
        $hrefs = @($hrefs | Select-Object -Unique)
        Write-Host ("detail: T4: landing {0} -> HTTP {1}, installer-like hrefs={2}" -f $targets.Landing, $landingStatus, $hrefs.Count)
        foreach ($h in $hrefs) { Write-Host "detail: T4: landing href: $h" }
    }
    catch {
        $gr = $_.Exception.Response
        if ($null -ne $gr) { try { $landingStatus = [string][int]$gr.StatusCode } catch { } }
        if ($landingStatus -eq 'ERR:not attempted') { $landingStatus = 'ERR:' + $_.Exception.Message }
        Write-Host ("detail: T4: landing fetch failed: {0}" -f $landingStatus)
    }
    $results += @{ Url = $targets.Landing; Status = $(if ($landingStatus -match '^\d+$') { $landingStatus } else { 'ERR' }) }

    foreach ($h in $hrefs) {
        $status = Get-HttpStatus -Uri $h
        Write-Host ("detail: T4: landing-discovered {0} -> {1}" -f $h, $status)
        if ($status -match '^[23]\d\d$') { $results += @{ Url = $h; Status = $status } }
    }

    $verdict = Get-CorporateVerdict -Results $results -InstallerHrefs $hrefs
    Emit $verdict
}
catch {
    Emit ('FAIL - ' + $_.Exception.Message)
}
