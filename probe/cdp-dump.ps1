# Extracts page HTML over the Chrome DevTools Protocol.
# Used as a fallback when --dump-dom never terminates (Yandex 26.8 / Chromium 150 on CI).
param(
  [Parameter(Mandatory = $true)][string]$App,
  [Parameter(Mandatory = $true)][string]$Url,
  [Parameter(Mandatory = $true)][string]$OutFile,
  [string[]]$Base = @(),
  [string]$Profile = '',
  [int]$Port = 9444,
  [int]$ReadyMs = 30000,
  [string]$AwaitExpr = '',
  [int]$AwaitMs = 0,
  [int]$PollMs = 1000,
  [switch]$NoLaunch,
  [switch]$DriveNav
)
$ErrorActionPreference = 'Stop'
function Log([string]$m) { Write-Host "detail: cdp-dump: $m" }
function J($o) {
  $s = $null
  try { $s = $o | ConvertTo-Json -Compress -Depth 6 } catch { $s = "<json error: $($_.Exception.Message)>" }
  if ($null -eq $s) { $s = '<null>' }
  if ($s.Length -gt 700) { return $s.Substring(0, 700) }
  return $s
}

$proc = $null
$ws = $null
$ok = $false
try {
  $exe = Join-Path $App 'browser.exe'
  if (-not (Test-Path $exe)) { Log "browser.exe missing in $App"; exit 2 }
  if (-not $Profile) { $Profile = Join-Path ([IO.Path]::GetTempPath()) ('cdp-' + [Guid]::NewGuid().ToString('N')) }

  if (-not $NoLaunch) {
    $launchUrl = $Url
    if ($DriveNav) { $launchUrl = 'about:blank' }
    $argList = $Base + @("--user-data-dir=$Profile", "--remote-debugging-port=$Port", '--remote-allow-origins=*', $launchUrl)
    Log "launch browser.exe port=$Port url=$launchUrl"
    $proc = Start-Process -FilePath $exe -ArgumentList $argList -PassThru -NoNewWindow -WorkingDirectory $App `
      -RedirectStandardOutput "$OutFile.out" -RedirectStandardError "$OutFile.err"
  }

  function Find-Target {
    $dl = [DateTime]::UtcNow.AddMilliseconds($ReadyMs)
    $last = ''
    while ([DateTime]::UtcNow -lt $dl) {
      Start-Sleep -Milliseconds $PollMs
      try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/json/list" -UseBasicParsing -TimeoutSec 3
        $list = @($r.Content | ConvertFrom-Json)
        $pages = @($list | Where-Object { $_.type -eq 'page' })
        if ($pages.Count -gt 0) {
          $prefix = $Url.TrimEnd('/')
          $withUrl = @($pages | Where-Object { $_.url })
          $exact = @($withUrl | Where-Object { $_.url -eq $Url -or $_.url -like ($prefix + '*') })
          if ($exact.Count -gt 0) { Log "matched target url=$($exact[0].url)"; return $exact[0] }
          if (($withUrl.Count -eq 1) -and ([DateTime]::UtcNow -gt $dl.AddMilliseconds(-4000))) {
            Log "late single-page fallback url=$($withUrl[0].url)"
            return $withUrl[0]
          }
          $last = "page urls=[$(($pages | ForEach-Object { $_.url }) -join ', ')]"
        } else { $last = 'no page targets' }
      } catch { $last = $_.Exception.Message }
    }
    Log "no url-matched target within ${ReadyMs}ms (last=$last)"
    return $null
  }
  function Get-AnyPage([int]$timeoutMs) {
    $dl = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
    $last = ''
    while ([DateTime]::UtcNow -lt $dl) {
      Start-Sleep -Milliseconds $PollMs
      try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/json/list" -UseBasicParsing -TimeoutSec 3
        $list = @($r.Content | ConvertFrom-Json)
        $pages = @($list | Where-Object { $_.type -eq 'page' })
        if ($pages.Count -gt 0) {
          $live = @($pages | Where-Object { $_.url })
          if ($live.Count -gt 0) { return $live[0] }
          return $pages[0]
        }
        $last = 'no page targets'
      } catch { $last = $_.Exception.Message }
    }
    Log "no page target within ${timeoutMs}ms (last=$last)"
    return $null
  }
  $navDriven = $false
  if ($DriveNav) {
    $target = Get-AnyPage 8000
    if ($null -eq $target) { exit 3 }
    $navDriven = $true
    Log 'DriveNav: attaching to first page target; navigation will be driven over CDP'
  } else {
    $target = Find-Target
    if ($null -eq $target) { exit 3 }
  }
  Log "target url=$($target.url)"

  function Send-Json([string]$json) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $seg = [ArraySegment[byte]]::new($bytes)
    $sendTask = $ws.SendAsync($seg, [Net.WebSockets.WebSocketMessageType]::Text, $true, $ct)
    if (-not $sendTask.Wait(15000)) { throw 'ws send timeout (15s)' }
  }
  function Receive-Json {
    $ms = New-Object IO.MemoryStream
    $buf = New-Object byte[] 262144
    do {
      $seg = [ArraySegment[byte]]::new($buf)
      $recvTask = $ws.ReceiveAsync($seg, $ct)
      if (-not $recvTask.Wait(15000)) { throw 'ws receive timeout (15s)' }
      $res = $recvTask.Result
      if ($res.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw 'ws closed by peer' }
      $ms.Write($buf, 0, $res.Count)
    } while (-not $res.EndOfMessage)
    [Text.Encoding]::UTF8.GetString($ms.ToArray())
  }
  function Invoke-Cdp([string]$method, $params) {
    $script:cdpSeq++
    $id = $script:cdpSeq
    $obj = @{ id = $id; method = $method }
    if ($null -ne $params) { $obj['params'] = $params }
    Send-Json ($obj | ConvertTo-Json -Compress -Depth 8)
    $limit = [DateTime]::UtcNow.AddSeconds(45)
    while ([DateTime]::UtcNow -lt $limit) {
      $msg = Receive-Json | ConvertFrom-Json
      if (($null -ne $msg.PSObject.Properties['id']) -and $msg.id -eq $id) { return $msg }
    }
    throw "no CDP response for $method"
  }
  $script:cdpSeq = 0

  # Connects (and re-connects) a CDP session. A cross-process navigation swap can
  # leave the previous websocket pointing at the dead renderer, so callers pass a
  # freshly re-listed target to open a NEW session that reaches the live renderer.
  function Connect-Session($t, [string]$tag) {
    for ($attempt = 1; $attempt -le 2; $attempt++) {
      if ($null -ne $script:ws) { try { $script:ws.Dispose() } catch { Log "ws dispose: $($_.Exception.Message)" }; $script:ws = $null }
      $script:ws = New-Object System.Net.WebSockets.ClientWebSocket
      $script:ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(5)
      $script:ct = [Threading.CancellationToken]::None
      $connTask = $script:ws.ConnectAsync([Uri]$t.webSocketDebuggerUrl, $script:ct)
      if (-not $connTask.Wait(15000)) { throw "$tag ws connect timeout (15s)" }
      Log "$tag ws connected (attempt $attempt)"
      try {
        $en = Invoke-Cdp 'Runtime.enable' @{}
        if ($en.PSObject.Properties['error']) { Log "$tag Runtime.enable RPC error: $(J $en.error)" }
        else { Log "$tag Runtime.enable ok" }
        return $true
      }
      catch { Log "$tag Runtime.enable attempt ${attempt}: $($_.Exception.Message)"; if ($attempt -lt 2) { Start-Sleep -Seconds 3 } }
    }
    return $false
  }
  if (-not (Connect-Session $target 'attach')) { throw 'Runtime.enable failed after 2 attempts' }
  # diagnostic: does evaluate work AT ALL on this target before we navigate?
  try {
    $pr = Invoke-Cdp 'Runtime.evaluate' @{ expression = '1+1'; returnByValue = $true }
    if ($pr.PSObject.Properties['error']) { Log "eval probe RPC error: $(J $pr.error)" }
    else { Log "eval probe: $(J $pr.result)" }
  } catch { Log "eval probe exception: $($_.Exception.Message)" }

  $locDiagLogged = $false
  $reDiagLogged = $false
  if ($navDriven) {
    $null = Invoke-Cdp 'Page.enable' @{}
    $nav = Invoke-Cdp 'Page.navigate' @{ url = $Url }
    $navErr = ''
    if ($nav.PSObject.Properties['error']) { $navErr = "rpc: $($nav.error.message)" }
    elseif ($null -ne $nav.result -and $nav.result.PSObject.Properties['errorText']) { $navErr = [string]$nav.result.errorText }
    if ($navErr) { Log "Page.navigate $Url errorText=$navErr" }
    else { Log "Page.navigate issued for $Url (no errorText)" }
    $loc = ''
    $prefix = $Url.TrimEnd('/')
    $locLimit = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $locLimit) {
      Start-Sleep -Milliseconds $PollMs
      try {
        $r = Invoke-Cdp 'Runtime.evaluate' @{ expression = 'location.href'; returnByValue = $true }
        if ($null -ne $r.result -and $null -ne $r.result.result -and $null -ne $r.result.result.PSObject.Properties['value']) {
          $loc = [string]$r.result.result.value
        }
        elseif (-not $locDiagLogged) { $locDiagLogged = $true; Log "loc poll no-value response: $(J $r)" }
        if (($loc -eq $Url) -or $loc.StartsWith($prefix)) { break }
      } catch { Log "loc poll: $($_.Exception.Message)" }
    }
    Log "navigated location.href=[$loc]"
    if (($loc -ne $Url) -and (-not $loc.StartsWith($prefix))) {
      # The swap to the WebUI renderer can kill this session: /json/list may already
      # show the committed url even though this session can no longer evaluate.
      # Re-list the target, open a FRESH session and re-verify there.
      Log "session lost the commit (location.href=$loc); re-listing targets for a fresh attach"
      $fresh = $null
      $fdl = [DateTime]::UtcNow.AddSeconds(10)
      while (($null -eq $fresh) -and ([DateTime]::UtcNow -lt $fdl)) {
        try {
          $lr = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/json/list" -UseBasicParsing -TimeoutSec 3
          foreach ($p in @($lr.Content | ConvertFrom-Json | Where-Object { $_.type -eq 'page' -and $_.url })) {
            if ($p.url -like ($prefix + '*')) { $fresh = $p; break }
          }
        } catch { Log "re-list: $($_.Exception.Message)" }
        if ($null -eq $fresh) { Start-Sleep -Milliseconds $PollMs }
      }
      if ($null -eq $fresh) {
        Log "navigation to $Url did not commit (location.href=$loc; no re-listed target); continuing to extraction"
      } else {
        Log "fresh attach: re-listed target url=$($fresh.url)"
        if (-not (Connect-Session $fresh 'reattach')) { throw 'fresh attach: Runtime.enable failed after 2 attempts' }
        $loc = ''
        $rlim = [DateTime]::UtcNow.AddSeconds(10)
        while ([DateTime]::UtcNow -lt $rlim) {
          Start-Sleep -Milliseconds $PollMs
          try {
            $r = Invoke-Cdp 'Runtime.evaluate' @{ expression = 'location.href'; returnByValue = $true }
            if ($null -ne $r.result -and $null -ne $r.result.result -and $null -ne $r.result.result.PSObject.Properties['value']) {
              $loc = [string]$r.result.result.value
            }
            elseif (-not $reDiagLogged) { $reDiagLogged = $true; Log "reattach loc poll no-value response: $(J $r)" }
            if (($loc -eq $Url) -or $loc.StartsWith($prefix)) { break }
          } catch { Log "reattach loc poll: $($_.Exception.Message)" }
        }
        Log "reattach location.href=[$loc]"
        if (($loc -ne $Url) -and (-not $loc.StartsWith($prefix))) {
          Log "reattach: $Url still not committed (location.href=$loc); continuing to extraction"
        }
      }
    }
  }

  try { $null = Invoke-Cdp 'Runtime.enable' @{} } catch { Log "Runtime.enable: $($_.Exception.Message)" }

  if ($AwaitExpr) {
    $val = ''
    $limit = [DateTime]::UtcNow.AddMilliseconds($AwaitMs)
    while ([DateTime]::UtcNow -lt $limit) {
      Start-Sleep -Milliseconds $PollMs
      try {
        $r = Invoke-Cdp 'Runtime.evaluate' @{ expression = $AwaitExpr; returnByValue = $true }
        if ($null -ne $r.result -and $null -ne $r.result.result -and $null -ne $r.result.result.PSObject.Properties['value']) {
          $val = [string]$r.result.result.value
        }
      } catch { Log "await eval: $($_.Exception.Message)" }
      if ($val -and $val -ne 'pending') { break }
    }
    Log "await value=[$val]"
  }

  $html = ''
  $r = $null
  try {
    $r = Invoke-Cdp 'Runtime.evaluate' @{ expression = 'document.documentElement.outerHTML'; returnByValue = $true }
    if ($r.PSObject.Properties['error']) { Log "outerHTML RPC error: $(J $r.error)" }
    elseif ($null -ne $r.result -and $null -ne $r.result.result -and $null -ne $r.result.result.PSObject.Properties['value']) {
      $html = [string]$r.result.result.value
    }
    else { Log "outerHTML no-value response: $(J $r)" }
  } catch { Log "outerHTML evaluate: $($_.Exception.Message)" }
  if (-not $html) {
    Log 'outerHTML evaluate empty; falling back to DOM.getOuterHTML'
    try {
      $en = Invoke-Cdp 'DOM.enable' @{}
      if ($en.PSObject.Properties['error']) { Log "DOM.enable RPC error: $(J $en.error)" }
      $doc = Invoke-Cdp 'DOM.getDocument' @{ depth = -1 }
      if ($doc.PSObject.Properties['error']) { Log "DOM.getDocument RPC error: $(J $doc.error)" }
      elseif ($null -ne $doc.result -and $null -ne $doc.result.root) {
        $outer = Invoke-Cdp 'DOM.getOuterHTML' @{ nodeId = $doc.result.root.nodeId }
        if ($outer.PSObject.Properties['error']) { Log "DOM.getOuterHTML RPC error: $(J $outer.error)" }
        elseif ($null -ne $outer.result -and $outer.result.PSObject.Properties['outerHTML']) { $html = [string]$outer.result.outerHTML }
      }
      else { Log "DOM.getDocument no-root response: $(J $doc)" }
    } catch { Log "DOM.getOuterHTML: $($_.Exception.Message)" }
  }
  if (-not $html) {
    # captureSnapshot runs in the browser and needs no JS execution context -
    # works even where Runtime/DOM domains answer empty for WebUI targets
    Log 'no JS/DOM extraction; falling back to Page.captureSnapshot (mhtml)'
    try {
      $pe = Invoke-Cdp 'Page.enable' @{}
      if ($pe.PSObject.Properties['error']) { Log "Page.enable RPC error: $(J $pe.error)" }
      $snap = Invoke-Cdp 'Page.captureSnapshot' @{ format = 'mhtml' }
      if ($snap.PSObject.Properties['error']) { Log "captureSnapshot RPC error: $(J $snap.error)" }
      elseif ($null -ne $snap.result -and $snap.result.PSObject.Properties['data']) { $html = [string]$snap.result.data }
      else { Log "captureSnapshot no-data response: $(J $snap)" }
    } catch { Log "captureSnapshot: $($_.Exception.Message)" }
  }
  if (-not $html) {
    # accessibility tree is a different domain - may survive where Runtime/DOM/Page are Forbidden
    Log 'falling back to Accessibility.getFullAXTree'
    try {
      $ae = Invoke-Cdp 'Accessibility.enable' @{}
      if ($ae.PSObject.Properties['error']) { Log "Accessibility.enable RPC error: $(J $ae.error)" }
      $ax = Invoke-Cdp 'Accessibility.getFullAXTree' @{}
      if ($ax.PSObject.Properties['error']) { Log "Accessibility.getFullAXTree RPC error: $(J $ax.error)" }
      elseif ($null -ne $ax.result -and $ax.result.nodes) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($nd in @($ax.result.nodes)) {
          foreach ($f in 'name', 'value', 'description') {
            if ($nd.PSObject.Properties[$f] -and $nd.$f -and $nd.$f.PSObject.Properties['value'] -and $nd.$f.value) {
              [void]$parts.Add([string]$nd.$f.value)
            }
          }
          if ($nd.PSObject.Properties['properties'] -and $nd.properties) {
            foreach ($pr in @($nd.properties)) {
              if ($pr.value -and $pr.value.PSObject.Properties['value'] -and $pr.value.value) {
                [void]$parts.Add([string]$pr.value.value)
              }
            }
          }
        }
        $html = ($parts -join ' | ')
        Log "AX tree nodes=$(@($ax.result.nodes).Count) text bytes=$($html.Length)"
      }
      else { Log "Accessibility.getFullAXTree no-nodes response: $(J $ax)" }
    } catch { Log "Accessibility.getFullAXTree: $($_.Exception.Message)" }
  }
  if (-not $html) {
    # map which domains this target allows at all (evidence for the spike report)
    Log 'scanning CDP domain availability on this target'
    foreach ($m in @('Log.enable', 'Network.enable', 'Debugger.enable', 'Profiler.enable', 'CSS.enable',
                     'DOMStorage.enable', 'Application.enable', 'CacheStorage.enable', 'ServiceWorker.enable',
                     'IndexedDB.enable', 'Audits.enable', 'Emulation.enable', 'Overlay.enable', 'Storage.enable',
                     'Media.enable', 'DeviceAccess.enable', 'PWA.enable', 'Fetch.enable', 'Security.enable',
                     'Inspector.enable')) {
      try {
        $pr = Invoke-Cdp $m @{}
        if ($pr.PSObject.Properties['error']) { Log "domain-scan $m -> error: $($pr.error.message)" }
        else { Log "domain-scan $m -> OK" }
      } catch { Log "domain-scan $m -> exception: $($_.Exception.Message)" }
    }
    # printToPDF runs browser-side and has been observed ALLOWED even where
    # every other domain returns Forbidden - keep the artifact for the report
    try {
      $pdf = Invoke-Cdp 'Page.printToPDF' @{ printBackground = $true }
      if ($pdf.PSObject.Properties['error']) { Log "domain-scan Page.printToPDF -> error: $($pdf.error.message)" }
      else {
        $b64 = ''
        if ($null -ne $pdf.result -and $pdf.result.PSObject.Properties['data']) { $b64 = [string]$pdf.result.data }
        Log "domain-scan Page.printToPDF -> OK base64 bytes=$($b64.Length)"
        if ($b64.Length -gt 64) {
          $pdfPath = $OutFile + '.pdf'
          try {
            [IO.File]::WriteAllBytes($pdfPath, [Convert]::FromBase64String($b64))
            Log "saved printToPDF artifact: $pdfPath ($((Get-Item $pdfPath).Length) bytes)"
          } catch { Log "printToPDF save failed: $($_.Exception.Message)" }
        }
      }
    } catch { Log "domain-scan Page.printToPDF -> exception: $($_.Exception.Message)" }
  }
  if (-not $html) { throw 'no DOM: outerHTML, DOM.getOuterHTML, Page.captureSnapshot and Accessibility tree all produced nothing' }
  Set-Content -Path $OutFile -Value $html -Encoding utf8
  Log "dom bytes=$($html.Length)"
  $ok = $true
  exit 0
} catch {
  Log "error: $($_.Exception.Message)"
  exit 1
} finally {
  if ($null -ne $ws) {
    try { $ws.Dispose() } catch { Log "ws dispose: $($_.Exception.Message)" }
  }
  if ($null -ne $proc) {
    try { if (-not $proc.HasExited) { $proc.Kill($true) } } catch { Log "kill: $($_.Exception.Message)" }
  }
  if ($NoLaunch) {
    # the caller owns the browser process: leave it alive so further probes
    # (e.g. the next policy URL) can attach to the same headed instance
    Log 'NoLaunch: leaving the caller-launched browser running'
  } else {
    Stop-Process -Name browser, browser_proxy -Force -ErrorAction SilentlyContinue
  }
  if (-not $ok) { Log 'cdp extraction did not produce a DOM' }
}
