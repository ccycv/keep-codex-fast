#requires -Version 5.1
param(
  [switch]$Apply,
  [switch]$IncludeWsl,
  [switch]$ForceWhileRunning,
  [switch]$IncludeSecretsBackup,
  [switch]$InstallScheduledTask,
  [string[]]$WslDistro = @(),
  [string]$CodexHome = (Join-Path $env:USERPROFILE ".codex"),
  [int]$SessionDaysToKeep = 10,
  [int]$WorktreeDaysToKeep = 14,
  [int]$LogRotateMB = 100,
  [string]$ScheduleTime = "09:00"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Format-Bytes {
  param([double]$Bytes)
  if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
  if ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
  if ($Bytes -ge 1KB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
  return ("{0:N0} B" -f $Bytes)
}

function Get-FileSizeSafe {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return 0 }
  return (Get-Item -LiteralPath $Path -Force).Length
}

function Get-DirSizeSafe {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return 0 }
  $measure = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
    Measure-Object -Property Length -Sum
  $sum = $measure | Select-Object -ExpandProperty Sum
  if ($null -eq $sum) { return 0 }
  return [double]$sum
}

function Get-TopFiles {
  param([string]$Path, [int]$Limit = 10)
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  return @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
    Sort-Object Length -Descending |
    Select-Object -First $Limit |
    ForEach-Object {
      [pscustomobject]@{
        path = $_.FullName
        sizeBytes = $_.Length
        size = Format-Bytes $_.Length
        lastWrite = $_.LastWriteTime.ToString('s')
      }
    })
}

function Get-RunningCodexProcesses {
  return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -match "codex" -or
    ($_.Path -and $_.Path -match "Codex|\.codex")
  } | Select-Object Id, ProcessName, Path)
}

function Get-UniqueDestination {
  param([string]$Directory, [string]$Name)
  $target = Join-Path $Directory $Name
  if (-not (Test-Path -LiteralPath $target)) { return $target }
  $base = [IO.Path]::GetFileNameWithoutExtension($Name)
  $ext = [IO.Path]::GetExtension($Name)
  $i = 1
  while ($true) {
    $candidate = Join-Path $Directory ("{0}-{1}{2}" -f $base, $i, $ext)
    if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    $i++
  }
}

function New-HandoffDoc {
  param([IO.FileInfo]$SessionFile, [string]$HandoffDir)
  Ensure-Dir $HandoffDir
  $target = Join-Path $HandoffDir (($SessionFile.BaseName) + ".md")
  $tail = @()
  try { $tail = @(Get-Content -LiteralPath $SessionFile.FullName -Tail 30 -ErrorAction Stop) } catch { $tail = @() }
  $content = @(
    "# Codex Session Handoff"
    ""
    "Archived session: ``$($SessionFile.FullName)``"
    "Size: $(Format-Bytes $SessionFile.Length)"
    "Last modified: $($SessionFile.LastWriteTime.ToString('s'))"
    ""
    "## Reactivation Prompt"
    ""
    "Continue from archived Codex session ``$($SessionFile.Name)``. Inspect the archived JSONL if exact context is needed, then make a concise current-state summary before changing files."
    ""
    "## Last Session Lines"
    ""
    '```jsonl'
  )
  $content += $tail
  $content += '```'
  Set-Content -LiteralPath $target -Value $content -Encoding UTF8
  return $target
}

function Backup-CodexHome {
  param([string]$CodexRoot, [string]$Stamp, [bool]$IncludeSecrets)
  $backupRoot = Join-Path $CodexRoot "maintenance\backups\$Stamp"
  Ensure-Dir $backupRoot

  $items = @(
    "config.toml",
    ".codex-global-state.json",
    "session_index.jsonl",
    "state_5.sqlite",
    "state_5.sqlite-shm",
    "state_5.sqlite-wal",
    "logs_2.sqlite",
    "logs_2.sqlite-shm",
    "logs_2.sqlite-wal",
    "memories",
    "skills",
    "plugins",
    "automations",
    "sqlite"
  )
  if ($IncludeSecrets) {
    $items += @("auth.json", ".credentials.json", ".tokens.json")
  }

  $copied = @()
  foreach ($item in $items) {
    $source = Join-Path $CodexRoot $item
    if (Test-Path -LiteralPath $source) {
      $dest = Join-Path $backupRoot $item
      Ensure-Dir ([IO.Path]::GetDirectoryName($dest))
      Copy-Item -LiteralPath $source -Destination $dest -Recurse -Force
      $copied += $item
    }
  }

  return [pscustomobject]@{
    path = $backupRoot
    copied = $copied
    secretsIncluded = $IncludeSecrets
  }
}

function Archive-OldSessions {
  param([string]$CodexRoot, [string]$Stamp, [int]$Days, [bool]$DoApply)
  $sessionRoot = Join-Path $CodexRoot "sessions"
  $archiveRoot = Join-Path $CodexRoot "archived_sessions"
  $handoffRoot = Join-Path $CodexRoot "maintenance\handoffs\$Stamp"
  if (-not (Test-Path -LiteralPath $sessionRoot)) { return @() }
  $cutoff = (Get-Date).AddDays(-$Days)
  $files = @(Get-ChildItem -LiteralPath $sessionRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cutoff -and $_.Extension -eq ".jsonl" } |
    Sort-Object LastWriteTime)

  $result = @()
  foreach ($file in $files) {
    $dest = Get-UniqueDestination -Directory $archiveRoot -Name $file.Name
    $handoff = $null
    if ($DoApply) {
      Ensure-Dir $archiveRoot
      $handoff = New-HandoffDoc -SessionFile $file -HandoffDir $handoffRoot
      Move-Item -LiteralPath $file.FullName -Destination $dest
    }
    $result += [pscustomobject]@{
      source = $file.FullName
      destination = $dest
      handoff = $handoff
      sizeBytes = $file.Length
      size = Format-Bytes $file.Length
      lastWrite = $file.LastWriteTime.ToString('s')
      applied = $DoApply
    }
  }
  return $result
}

function Move-StaleWorktrees {
  param([string]$CodexRoot, [string]$Stamp, [int]$Days, [bool]$DoApply)
  $root = Join-Path $CodexRoot "worktrees"
  $archiveRoot = Join-Path $CodexRoot "archived_worktrees\$Stamp"
  if (-not (Test-Path -LiteralPath $root)) { return @() }
  $cutoff = (Get-Date).AddDays(-$Days)
  $dirs = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cutoff } |
    Sort-Object LastWriteTime)

  $result = @()
  foreach ($dir in $dirs) {
    $dest = Get-UniqueDestination -Directory $archiveRoot -Name $dir.Name
    if ($DoApply) {
      Ensure-Dir $archiveRoot
      Move-Item -LiteralPath $dir.FullName -Destination $dest
    }
    $result += [pscustomobject]@{
      source = $dir.FullName
      destination = $dest
      lastWrite = $dir.LastWriteTime.ToString('s')
      applied = $DoApply
    }
  }
  return $result
}

function Rotate-LargeLogs {
  param([string]$CodexRoot, [string]$Stamp, [int]$MinMB, [bool]$DoApply)
  $archiveRoot = Join-Path $CodexRoot "archived_logs\$Stamp"
  if (-not (Test-Path -LiteralPath $CodexRoot)) { return @() }
  $minBytes = $MinMB * 1MB
  $logs = @(Get-ChildItem -LiteralPath $CodexRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -eq ".log" -and $_.Length -ge $minBytes } |
    Sort-Object Length -Descending)

  $result = @()
  foreach ($log in $logs) {
    $relative = $log.FullName.Substring($CodexRoot.Length).TrimStart("\")
    $dest = Join-Path $archiveRoot $relative
    if ($DoApply) {
      Ensure-Dir ([IO.Path]::GetDirectoryName($dest))
      Move-Item -LiteralPath $log.FullName -Destination $dest
    }
    $result += [pscustomobject]@{
      source = $log.FullName
      destination = $dest
      sizeBytes = $log.Length
      size = Format-Bytes $log.Length
      applied = $DoApply
    }
  }
  return $result
}

function Normalize-ExtendedPaths {
  param([string]$CodexRoot, [bool]$DoApply)
  $targets = @("config.toml", ".codex-global-state.json", "session_index.jsonl")
  $result = @()
  foreach ($name in $targets) {
    $path = Join-Path $CodexRoot $name
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $text = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $text) { continue }
    $count = ([regex]::Matches($text, [regex]::Escape('\\?\'))).Count
    if ($count -gt 0 -and $DoApply) {
      Set-Content -LiteralPath $path -Value ($text.Replace('\\?\', '')) -Encoding UTF8
    }
    $result += [pscustomobject]@{
      path = $path
      extendedPathMatches = $count
      applied = ($DoApply -and $count -gt 0)
    }
  }
  return $result
}

function Find-DeadConfigPaths {
  param([string]$CodexRoot)
  $targets = @("config.toml", ".codex-global-state.json", "session_index.jsonl")
  $dead = @()
  foreach ($name in $targets) {
    $path = Join-Path $CodexRoot $name
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $text = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $text) { continue }
    $pathMatches = @()
    foreach ($pattern in @('[A-Za-z]:\\[^"\r\n]+', '\\\\\?\\[A-Za-z]:\\[^"\r\n]+', '/mnt/[a-z]/[^"\r\n ]+', '/home/[^"\r\n ]+')) {
      $pathMatches += [regex]::Matches($text, $pattern)
    }
    foreach ($match in $pathMatches) {
      $candidate = $match.Value.Trim().TrimEnd([char[]]@(",", "]", "}", ")"))
      if ($candidate.Length -gt 240) { continue }
      $testPath = $candidate.Replace('\\?\', '')
      if ($testPath -match "^/mnt/([a-z])/(.+)$") {
        $drive = $Matches[1].ToUpper()
        $rest = $Matches[2].Replace("/", "\")
        $testPath = "$drive`:\$rest"
      }
      if ($testPath -match "^[A-Za-z]:\\" -and -not (Test-Path -LiteralPath $testPath)) {
        $dead += [pscustomobject]@{ file = $path; path = $candidate }
      }
    }
  }
  return @($dead | Sort-Object file,path -Unique)
}

function Get-StorageSummary {
  param([string]$CodexRoot)
  $names = @("sessions", "archived_sessions", "worktrees", "archived_worktrees", "archived_logs", "cache", "plugins", "skills", "memories", "sqlite")
  $rows = @()
  foreach ($name in $names) {
    $path = Join-Path $CodexRoot $name
    $size = Get-DirSizeSafe $path
    $rows += [pscustomobject]@{
      name = $name
      path = $path
      sizeBytes = $size
      size = Format-Bytes $size
      exists = (Test-Path -LiteralPath $path)
    }
  }
  $dbs = @(Get-ChildItem -LiteralPath $CodexRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match "\.sqlite|\.db|\.sqlite-wal|\.db-wal" } |
    Sort-Object Length -Descending |
    Select-Object -First 10 |
    ForEach-Object {
      [pscustomobject]@{
        path = $_.FullName
        sizeBytes = $_.Length
        size = Format-Bytes $_.Length
        lastWrite = $_.LastWriteTime.ToString('s')
      }
    })
  return [pscustomobject]@{ directories = $rows; databases = $dbs }
}

function Write-MarkdownReport {
  param([string]$Path, [object]$Report)
  $lines = @(
    "# Keep Codex Fast Report"
    ""
    "Mode: $($Report.mode)"
    "Generated: $($Report.generatedAt)"
    "Codex home: ``$($Report.codexHome)``"
    ""
    "## Storage"
    ""
  )
  foreach ($row in $Report.storage.directories) {
    $lines += "- $($row.name): $($row.size)"
  }
  $lines += ""
  $lines += "## Top Active Sessions"
  $lines += ""
  foreach ($file in $Report.topActiveSessions) {
    $lines += "- $($file.size) ``$($file.path)``"
  }
  $lines += ""
  $lines += "## Planned Or Applied"
  $lines += ""
  $lines += "- Sessions archived/planned: $(@($Report.sessions).Count)"
  $lines += "- Worktrees moved/planned: $(@($Report.worktrees).Count)"
  $lines += "- Logs rotated/planned: $(@($Report.logs).Count)"
  $lines += "- Extended path files checked: $(@($Report.normalizedPaths).Count)"
  $lines += "- Dead config paths reported: $(@($Report.deadConfigPaths).Count)"
  if ($Report.backup) {
    $lines += "- Backup: ``$($Report.backup.path)``"
  }
  $lines += ""
  $lines += "## Background Processes"
  $lines += ""
  foreach ($proc in $Report.backgroundProcesses) {
    $lines += "- PID $($proc.Id) $($proc.ProcessName) ``$($proc.Path)``"
  }
  Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}

function Convert-WindowsPathToWslPath {
  param([string]$WindowsPath)

  if ([string]::IsNullOrWhiteSpace($WindowsPath)) { return $null }
  $normalized = $WindowsPath -replace "/", "\"
  if ($normalized -notmatch "^([A-Za-z]):\\(.+)$") { return $null }

  $drive = $Matches[1].ToLower()
  $rest = $Matches[2] -replace "\\", "/"
  return "/mnt/$drive/$rest"
}

function Invoke-WslMaintenance {
  param([string]$Distro, [bool]$DoApply, [int]$SessionDays, [int]$WorktreeDays, [int]$LogMB)
  $script = Join-Path $PSScriptRoot "keep-codex-fast-wsl.sh"
  if (-not (Test-Path -LiteralPath $script)) {
    return [pscustomobject]@{ distro = $Distro; ok = $false; error = "Missing WSL script: $script" }
  }
  $applyValue = if ($DoApply) { "1" } else { "0" }
  $scriptWsl = Convert-WindowsPathToWslPath -WindowsPath $script
  if ([string]::IsNullOrWhiteSpace($scriptWsl)) {
    return [pscustomobject]@{ distro = $Distro; ok = $false; error = "Could not convert Windows script path to a WSL path: $script" }
  }
  $output = & wsl.exe -d $Distro -- env "CODEX_FAST_APPLY=$applyValue" "CODEX_FAST_SESSION_DAYS=$SessionDays" "CODEX_FAST_WORKTREE_DAYS=$WorktreeDays" "CODEX_FAST_LOG_MB=$LogMB" bash $scriptWsl 2>&1
  $exitVar = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
  $code = if ($exitVar) { [int]$exitVar.Value } else { 0 }
  return [pscustomobject]@{
    distro = $Distro
    ok = ($code -eq 0)
    exitCode = $code
    output = @($output)
  }
}

function Install-CodexFastTask {
  param([string]$ScriptPath, [string]$AtTime, [bool]$WithWsl)
  $args = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Apply"
  if ($WithWsl) { $args += " -IncludeWsl" }
  $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $args
  $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At $AtTime
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries
  Register-ScheduledTask -TaskName "Keep Codex Fast" -Action $action -Trigger $trigger -Settings $settings -Description "Backup and archive old Codex sessions, worktrees, and logs." -Force | Out-Null
}

if (-not (Test-Path -LiteralPath $CodexHome)) {
  throw "Codex home not found: $CodexHome"
}

if ($InstallScheduledTask) {
  Install-CodexFastTask -ScriptPath $PSCommandPath -AtTime $ScheduleTime -WithWsl:$IncludeWsl
  Write-Host "Installed weekly scheduled task: Keep Codex Fast, Sunday $ScheduleTime"
  exit 0
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$maintenanceRoot = Join-Path $CodexHome "maintenance"
$reportRoot = Join-Path $maintenanceRoot "reports"
Ensure-Dir $reportRoot

$runningCodex = Get-RunningCodexProcesses
if ($Apply -and $runningCodex.Count -gt 0 -and -not $ForceWhileRunning) {
  Write-Host "Codex appears to be running. Inspecting only. Close Codex and rerun with -Apply."
  $Apply = $false
}

$backup = $null
if ($Apply) {
  $backup = Backup-CodexHome -CodexRoot $CodexHome -Stamp $stamp -IncludeSecrets:$IncludeSecretsBackup
}

$storage = Get-StorageSummary -CodexRoot $CodexHome
$sessions = Archive-OldSessions -CodexRoot $CodexHome -Stamp $stamp -Days $SessionDaysToKeep -DoApply:$Apply
$worktrees = Move-StaleWorktrees -CodexRoot $CodexHome -Stamp $stamp -Days $WorktreeDaysToKeep -DoApply:$Apply
$logs = Rotate-LargeLogs -CodexRoot $CodexHome -Stamp $stamp -MinMB $LogRotateMB -DoApply:$Apply
$normalized = Normalize-ExtendedPaths -CodexRoot $CodexHome -DoApply:$Apply
$deadPaths = Find-DeadConfigPaths -CodexRoot $CodexHome
$topSessions = Get-TopFiles -Path (Join-Path $CodexHome "sessions") -Limit 10
$topHomeFiles = Get-TopFiles -Path $CodexHome -Limit 20
$background = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
  $_.ProcessName -match "node|npm|pnpm|yarn|vite|tauri|cargo|rustc|code|codex"
} | Select-Object Id, ProcessName, Path)

$wslReports = @()
if ($IncludeWsl) {
  $distros = @($WslDistro | Where-Object { $_ })
  if ($distros.Count -eq 0) {
    $rawDistros = & wsl.exe -l -q 2>$null
    $distros = @($rawDistros | ForEach-Object { ($_ -replace "`0", "").Trim() } | Where-Object { $_ })
  }
  foreach ($distro in $distros) {
    $wslReports += Invoke-WslMaintenance -Distro $distro -DoApply:$Apply -SessionDays $SessionDaysToKeep -WorktreeDays $WorktreeDaysToKeep -LogMB $LogRotateMB
  }
}

$report = [pscustomobject]@{
  generatedAt = (Get-Date).ToString('s')
  mode = if ($Apply) { "apply" } else { "inspect" }
  codexHome = $CodexHome
  codexRunning = ($runningCodex.Count -gt 0)
  runningCodexProcesses = $runningCodex
  backup = $backup
  storage = $storage
  topActiveSessions = $topSessions
  topFiles = $topHomeFiles
  sessions = $sessions
  worktrees = $worktrees
  logs = $logs
  normalizedPaths = $normalized
  deadConfigPaths = $deadPaths
  backgroundProcesses = $background
  wsl = $wslReports
}

$jsonPath = Join-Path $reportRoot "$stamp.json"
$mdPath = Join-Path $reportRoot "$stamp.md"
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
Write-MarkdownReport -Path $mdPath -Report $report

Write-Host ""
Write-Host "Keep Codex Fast report"
Write-Host "Mode: $($report.mode)"
Write-Host "Codex home: $CodexHome"
Write-Host "Sessions archived/planned: $(@($sessions).Count)"
Write-Host "Worktrees moved/planned: $(@($worktrees).Count)"
Write-Host "Logs rotated/planned: $(@($logs).Count)"
Write-Host "Report: $mdPath"
Write-Host "JSON: $jsonPath"
if ($backup) { Write-Host "Backup: $($backup.path)" }
if ($IncludeWsl) { Write-Host "WSL distros checked: $(@($wslReports).Count)" }
if (-not $Apply) { Write-Host "No changes made. Rerun with -Apply after closing Codex." }
