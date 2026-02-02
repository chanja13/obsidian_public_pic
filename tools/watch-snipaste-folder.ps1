param(
  [string]$Folder = "D:\chanja13\d_drive\repo\obsidian_public_pic\pic",
  [string]$RepoRoot = "D:\chanja13\d_drive\repo\obsidian_public_pic"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$handlerScript = Join-Path $RepoRoot "tools\auto-push-screenshot.ps1"
if (-not (Test-Path -LiteralPath $handlerScript)) {
  throw "Missing: $handlerScript"
}

if (-not (Test-Path -LiteralPath $Folder)) {
  throw "Folder not found: $Folder"
}

$logPath = Join-Path $RepoRoot "tools\watch-snipaste.log"

function Write-Log([string]$Message) {
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Add-Content -LiteralPath $logPath -Value "[$ts] $Message"
}

$processed = @{} # path -> ticks (dedupe)

$script:jobs = @() # background jobs to drain for console output
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $Folder
$watcher.Filter = "*.*"
$watcher.IncludeSubdirectories = $false
$watcher.NotifyFilter = [System.IO.NotifyFilters]"FileName, LastWrite, CreationTime, Size"
$watcher.InternalBufferSize = 65536
$watcher.EnableRaisingEvents = $true

$action = {
  $path = $Event.SourceEventArgs.FullPath
  $eventName = $Event.SourceEventArgs.ChangeType

  Write-Log "Event=$eventName Path=$path"

  $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
  if ($ext -notin @(".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp")) {
    return
  }

  $now = [DateTime]::UtcNow.Ticks
  if ($processed.ContainsKey($path) -and ($now - $processed[$path]) -lt [TimeSpan]::FromSeconds(3).Ticks) {
    return
  }
  $processed[$path] = $now

  $job = Start-Job -ScriptBlock {
    param($p, $scriptPath, $repoRoot, $log)

    Start-Sleep -Milliseconds 500

    try {
      $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ImagePath $p -RepoRoot $repoRoot 2>&1
      if ($out) { $out | Add-Content -LiteralPath $log }
      $out
    } catch {
      $msg = "HandlerError: " + $_.Exception.Message
      $msg | Add-Content -LiteralPath $log
      $msg
    }
  } -ArgumentList $path, $handlerScript, $RepoRoot, $logPath

  $script:jobs += $job
}

Register-ObjectEvent -InputObject $watcher -EventName Created -Action $action | Out-Null
Register-ObjectEvent -InputObject $watcher -EventName Changed -Action $action | Out-Null
Register-ObjectEvent -InputObject $watcher -EventName Renamed -Action $action | Out-Null
Register-ObjectEvent -InputObject $watcher -EventName Error -Action {
  try {
    $ex = $Event.SourceEventArgs.GetException()
    Write-Log "WatcherError: $($ex.GetType().FullName): $($ex.Message)"
  } catch {
    Write-Log "WatcherError: (unknown)"
  }
} | Out-Null

Write-Log "Started watcher Folder=$Folder Handler=$handlerScript"

Write-Output "Watching: $Folder"
Write-Output "Log: $logPath"

while ($true) {
  Wait-Event -Timeout 2 | Out-Null

  # Drain completed jobs so the pushed image URL prints to the console.
  $done = @($script:jobs | Where-Object { $_.State -in @('Completed', 'Failed', 'Stopped') })
  foreach ($j in $done) {
    try {
      $out = Receive-Job -Job $j -ErrorAction SilentlyContinue
      if ($out) { $out | ForEach-Object { Write-Output $_ } }
    } catch {
    } finally {
      Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
    }
  }

  if ($done.Count -gt 0) {
    $doneIds = $done | ForEach-Object { $_.Id }
    $script:jobs = @($script:jobs | Where-Object { $doneIds -notcontains $_.Id })
  }

}
