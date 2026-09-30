# UIA text extraction fallback: CDP returns Forbidden on chrome:// (WebUI) targets,
# but the rendered page is still readable through Windows UI Automation.
# Run with Windows PowerShell 5.1 (powershell.exe) - UIAutomationClient is in the GAC there.
param(
  [Parameter(Mandatory = $true)][string]$ProcIds,   # comma-separated pids of browser processes
  [Parameter(Mandatory = $true)][string]$OutFile,
  [int]$MaxNodes = 6000
)
$ErrorActionPreference = 'Stop'
function Log([string]$m) { Write-Host "detail: uia-dump: $m" }
try {
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
} catch {
  Log "failed to load UIAutomation assemblies: $($_.Exception.Message)"
  exit 1
}
$ids = @($ProcIds -split ',' | Where-Object { $_ } | ForEach-Object { [int]$_ })
if ($ids.Count -eq 0) { Log 'no process ids supplied'; exit 1 }
$sb = New-Object System.Text.StringBuilder
try {
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  $found = 0
  foreach ($id in $ids) {
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $id)
    $wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
    foreach ($w in @($wins)) {
      $found++
      [void]$sb.AppendLine('## window: ' + $w.Current.Name)
      $all = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
      $n = 0
      foreach ($el in @($all)) {
        if ($n -ge $MaxNodes) { break }
        $n++
        try {
          $name = $el.Current.Name
          if ($name) { [void]$sb.AppendLine($name) }
          if ($el.Current.ControlType.ProgrammaticName -eq 'ControlType.Edit') {
            try {
              $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
              if ($vp) {
                $v = $vp.Current.Value
                if ($v) { [void]$sb.AppendLine('= ' + $v) }
              }
            } catch { }
          }
        } catch { }
      }
      Log "window pid=$id name=[$($w.Current.Name)] nodes=$n"
    }
  }
  if ($found -eq 0) { Log 'no top-level windows for the given pids'; exit 1 }
} catch {
  Log "walk failed: $($_.Exception.Message)"
  exit 1
}
$text = $sb.ToString()
Set-Content -Path $OutFile -Value $text -Encoding utf8
Log "text bytes=$($text.Length)"
exit 0
