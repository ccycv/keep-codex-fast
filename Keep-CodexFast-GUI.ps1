#requires -Version 5.1

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$workerScript = Join-Path $scriptRoot "Keep-CodexFast.ps1"
$script:lastReportPath = $null
$script:currentOutputPath = $null
$script:lastOutputText = ""

function Open-PathIfExists {
  param([string]$Path)
  if (Test-Path -LiteralPath $Path) {
    Start-Process explorer.exe $Path | Out-Null
    return
  }

  [System.Windows.Forms.MessageBox]::Show(
    "Path not found:`r`n$Path",
    "Keep Codex Fast",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Warning
  ) | Out-Null
}

function Build-Arguments {
  param(
    [bool]$Apply,
    [bool]$IncludeWsl,
    [bool]$IncludeSecrets,
    [bool]$InstallTask,
    [string]$CodexHome,
    [string]$WslDistro,
    [int]$SessionDays,
    [int]$WorktreeDays,
    [int]$LogRotateMb,
    [string]$ScheduleTime
  )

  $args = @(
    "-NoProfile"
    "-ExecutionPolicy"; "Bypass"
    "-File"; $workerScript
    "-CodexHome"; $CodexHome
    "-SessionDaysToKeep"; $SessionDays
    "-WorktreeDaysToKeep"; $WorktreeDays
    "-LogRotateMB"; $LogRotateMb
  )

  if ($Apply) { $args += "-Apply" }
  if ($IncludeWsl) { $args += "-IncludeWsl" }
  if ($IncludeSecrets) { $args += "-IncludeSecretsBackup" }
  if ($InstallTask) {
    $args += "-InstallScheduledTask"
    $args += "-ScheduleTime"
    $args += $ScheduleTime
  }
  if (-not [string]::IsNullOrWhiteSpace($WslDistro)) {
    $args += "-WslDistro"
    $args += $WslDistro.Trim()
  }

  return ,$args
}

function Convert-ToProcessArguments {
  param([string[]]$Values)

  $encoded = foreach ($value in $Values) {
    if ($null -eq $value) { '""'; continue }
    if ($value -notmatch '[\s"]') { $value; continue }
    '"' + ($value.Replace('"', '\"')) + '"'
  }

  return ($encoded -join " ")
}

function Update-OutputFromFile {
  if (-not $script:currentOutputPath) { return }
  if (-not (Test-Path -LiteralPath $script:currentOutputPath)) { return }

  $text = Get-Content -LiteralPath $script:currentOutputPath -Raw -ErrorAction SilentlyContinue
  if ($null -eq $text) { return }
  if ($text -eq $script:lastOutputText) { return }

  $script:lastOutputText = $text
  $outputBox.Text = $text
  $outputBox.SelectionStart = $outputBox.TextLength
  $outputBox.ScrollToCaret()

  foreach ($line in ($text -split "`r?`n")) {
    if ($line -like "Report:*") {
      $script:lastReportPath = $line.Substring(7).Trim()
    }
  }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Keep Codex Fast"
$form.Size = New-Object System.Drawing.Size(820, 700)
$form.MinimumSize = New-Object System.Drawing.Size(820, 700)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = "Keep Codex Fast"
$title.Location = New-Object System.Drawing.Point(18, 16)
$title.Size = New-Object System.Drawing.Size(260, 28)
$title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 16)
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "Friendly Windows wrapper for Codex cleanup. Inspect first, then apply."
$subtitle.Location = New-Object System.Drawing.Point(20, 46)
$subtitle.Size = New-Object System.Drawing.Size(560, 22)
$form.Controls.Add($subtitle)

$codexHomeLabel = New-Object System.Windows.Forms.Label
$codexHomeLabel.Text = "Windows Codex home"
$codexHomeLabel.Location = New-Object System.Drawing.Point(20, 84)
$codexHomeLabel.Size = New-Object System.Drawing.Size(160, 20)
$form.Controls.Add($codexHomeLabel)

$codexHomeBox = New-Object System.Windows.Forms.TextBox
$codexHomeBox.Location = New-Object System.Drawing.Point(20, 106)
$codexHomeBox.Size = New-Object System.Drawing.Size(510, 28)
$codexHomeBox.Text = [System.IO.Path]::Combine($env:USERPROFILE, ".codex")
$form.Controls.Add($codexHomeBox)

$includeWslBox = New-Object System.Windows.Forms.CheckBox
$includeWslBox.Text = "Include WSL"
$includeWslBox.Location = New-Object System.Drawing.Point(550, 108)
$includeWslBox.Size = New-Object System.Drawing.Size(110, 24)
$form.Controls.Add($includeWslBox)

$wslDistroLabel = New-Object System.Windows.Forms.Label
$wslDistroLabel.Text = "WSL distro (optional)"
$wslDistroLabel.Location = New-Object System.Drawing.Point(20, 144)
$wslDistroLabel.Size = New-Object System.Drawing.Size(160, 20)
$form.Controls.Add($wslDistroLabel)

$wslDistroBox = New-Object System.Windows.Forms.TextBox
$wslDistroBox.Location = New-Object System.Drawing.Point(20, 166)
$wslDistroBox.Size = New-Object System.Drawing.Size(200, 28)
$wslDistroBox.Text = "Ubuntu"
$form.Controls.Add($wslDistroBox)

$sessionDaysLabel = New-Object System.Windows.Forms.Label
$sessionDaysLabel.Text = "Keep active sessions (days)"
$sessionDaysLabel.Location = New-Object System.Drawing.Point(20, 208)
$sessionDaysLabel.Size = New-Object System.Drawing.Size(180, 20)
$form.Controls.Add($sessionDaysLabel)

$sessionDays = New-Object System.Windows.Forms.NumericUpDown
$sessionDays.Location = New-Object System.Drawing.Point(20, 230)
$sessionDays.Size = New-Object System.Drawing.Size(100, 28)
$sessionDays.Minimum = 1
$sessionDays.Maximum = 90
$sessionDays.Value = 10
$form.Controls.Add($sessionDays)

$worktreeDaysLabel = New-Object System.Windows.Forms.Label
$worktreeDaysLabel.Text = "Move worktrees older than (days)"
$worktreeDaysLabel.Location = New-Object System.Drawing.Point(160, 208)
$worktreeDaysLabel.Size = New-Object System.Drawing.Size(220, 20)
$form.Controls.Add($worktreeDaysLabel)

$worktreeDays = New-Object System.Windows.Forms.NumericUpDown
$worktreeDays.Location = New-Object System.Drawing.Point(160, 230)
$worktreeDays.Size = New-Object System.Drawing.Size(100, 28)
$worktreeDays.Minimum = 1
$worktreeDays.Maximum = 180
$worktreeDays.Value = 14
$form.Controls.Add($worktreeDays)

$logMbLabel = New-Object System.Windows.Forms.Label
$logMbLabel.Text = "Rotate logs larger than (MB)"
$logMbLabel.Location = New-Object System.Drawing.Point(300, 208)
$logMbLabel.Size = New-Object System.Drawing.Size(180, 20)
$form.Controls.Add($logMbLabel)

$logMb = New-Object System.Windows.Forms.NumericUpDown
$logMb.Location = New-Object System.Drawing.Point(300, 230)
$logMb.Size = New-Object System.Drawing.Size(100, 28)
$logMb.Minimum = 10
$logMb.Maximum = 2048
$logMb.Value = 100
$form.Controls.Add($logMb)

$includeSecretsBox = New-Object System.Windows.Forms.CheckBox
$includeSecretsBox.Text = "Include auth/token files in backup"
$includeSecretsBox.Location = New-Object System.Drawing.Point(20, 274)
$includeSecretsBox.Size = New-Object System.Drawing.Size(260, 24)
$form.Controls.Add($includeSecretsBox)

$inspectButton = New-Object System.Windows.Forms.Button
$inspectButton.Text = "Inspect"
$inspectButton.Location = New-Object System.Drawing.Point(20, 316)
$inspectButton.Size = New-Object System.Drawing.Size(110, 34)
$form.Controls.Add($inspectButton)

$applyButton = New-Object System.Windows.Forms.Button
$applyButton.Text = "Apply Cleanup"
$applyButton.Location = New-Object System.Drawing.Point(140, 316)
$applyButton.Size = New-Object System.Drawing.Size(130, 34)
$form.Controls.Add($applyButton)

$openReportsButton = New-Object System.Windows.Forms.Button
$openReportsButton.Text = "Open Reports"
$openReportsButton.Location = New-Object System.Drawing.Point(280, 316)
$openReportsButton.Size = New-Object System.Drawing.Size(120, 34)
$form.Controls.Add($openReportsButton)

$openBackupsButton = New-Object System.Windows.Forms.Button
$openBackupsButton.Text = "Open Backups"
$openBackupsButton.Location = New-Object System.Drawing.Point(410, 316)
$openBackupsButton.Size = New-Object System.Drawing.Size(120, 34)
$form.Controls.Add($openBackupsButton)

$installTaskButton = New-Object System.Windows.Forms.Button
$installTaskButton.Text = "Install Weekly Task"
$installTaskButton.Location = New-Object System.Drawing.Point(540, 316)
$installTaskButton.Size = New-Object System.Drawing.Size(140, 34)
$form.Controls.Add($installTaskButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Ready"
$statusLabel.Location = New-Object System.Drawing.Point(20, 364)
$statusLabel.Size = New-Object System.Drawing.Size(760, 20)
$form.Controls.Add($statusLabel)

$outputBox = New-Object System.Windows.Forms.TextBox
$outputBox.Location = New-Object System.Drawing.Point(20, 390)
$outputBox.Size = New-Object System.Drawing.Size(760, 250)
$outputBox.Multiline = $true
$outputBox.ReadOnly = $true
$outputBox.ScrollBars = "Vertical"
$outputBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$form.Controls.Add($outputBox)

$footer = New-Object System.Windows.Forms.Label
$footer.Text = "Tip: giant active sessions are the usual reason Codex becomes slow."
$footer.Location = New-Object System.Drawing.Point(20, 648)
$footer.Size = New-Object System.Drawing.Size(760, 20)
$form.Controls.Add($footer)

$script:currentProcess = $null
$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 500

$pollTimer.Add_Tick({
  try {
    Update-OutputFromFile
    if ($script:currentProcess -and $script:currentProcess.HasExited) {
      $pollTimer.Stop()
      Set-UiBusy -Busy $false

      if ($script:currentProcess.ExitCode -eq 0) {
        switch ($script:currentMode) {
          "task" { $statusLabel.Text = "Weekly task installed." }
          "apply" { $statusLabel.Text = "Cleanup finished." }
          default { $statusLabel.Text = "Inspect finished." }
        }
      } else {
        $statusLabel.Text = "Finished with errors."
      }

      Update-OutputFromFile
      if ($script:lastReportPath -and (Test-Path -LiteralPath $script:lastReportPath)) {
        $outputBox.AppendText([Environment]::NewLine + "Latest report ready: $script:lastReportPath" + [Environment]::NewLine)
      }
      $script:currentProcess = $null
    }
  } catch {
    $pollTimer.Stop()
    Set-UiBusy -Busy $false
    $statusLabel.Text = "GUI update failed."
    $outputBox.AppendText([Environment]::NewLine + $_.Exception.Message + [Environment]::NewLine)
    $script:currentProcess = $null
  }
})

function Set-UiBusy {
  param([bool]$Busy)
  $inspectButton.Enabled = -not $Busy
  $applyButton.Enabled = -not $Busy
  $installTaskButton.Enabled = -not $Busy
  $openReportsButton.Enabled = -not $Busy
  $openBackupsButton.Enabled = -not $Busy
  $codexHomeBox.Enabled = -not $Busy
  $includeWslBox.Enabled = -not $Busy
  $wslDistroBox.Enabled = -not $Busy
  $sessionDays.Enabled = -not $Busy
  $worktreeDays.Enabled = -not $Busy
  $logMb.Enabled = -not $Busy
  $includeSecretsBox.Enabled = -not $Busy
  $form.UseWaitCursor = $Busy
}

function Start-Run {
  param([bool]$Apply, [bool]$InstallTask)

  if (-not (Test-Path -LiteralPath $workerScript)) {
    [System.Windows.Forms.MessageBox]::Show(
      "Worker script not found:`r`n$workerScript",
      "Keep Codex Fast",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    return
  }

  if ($Apply) {
    $choice = [System.Windows.Forms.MessageBox]::Show(
      "Cleanup will back up first, then move old sessions/worktrees and rotate large logs. Continue?",
      "Confirm cleanup",
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }
  }

  $outputBox.Clear()
  $script:lastReportPath = $null
  $script:lastOutputText = ""
  $script:currentOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) ("keep-codex-fast-" + [guid]::NewGuid().ToString("N") + ".log")
  Set-Content -LiteralPath $script:currentOutputPath -Value "" -Encoding UTF8
  $statusLabel.Text = if ($InstallTask) { "Installing weekly task..." } elseif ($Apply) { "Running cleanup..." } else { "Inspecting..." }
  Set-UiBusy -Busy $true

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "cmd.exe"
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = $scriptRoot

  $argList = Build-Arguments `
    -Apply:$Apply `
    -IncludeWsl:$includeWslBox.Checked `
    -IncludeSecrets:$includeSecretsBox.Checked `
    -InstallTask:$InstallTask `
    -CodexHome $codexHomeBox.Text `
    -WslDistro $wslDistroBox.Text `
    -SessionDays ([int]$sessionDays.Value) `
    -WorktreeDays ([int]$worktreeDays.Value) `
    -LogRotateMb ([int]$logMb.Value) `
    -ScheduleTime "09:00"

  $workerArgs = Convert-ToProcessArguments -Values $argList
  $logPath = Convert-ToProcessArguments -Values @($script:currentOutputPath)
  $psi.Arguments = "/d /c powershell.exe $workerArgs > $logPath 2>&1"

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $psi

  $script:currentMode = if ($InstallTask) { "task" } elseif ($Apply) { "apply" } else { "inspect" }
  $script:currentProcess = $process
  [void]$process.Start()
  $pollTimer.Start()
}

$inspectButton.Add_Click({ Start-Run -Apply:$false -InstallTask:$false })
$applyButton.Add_Click({ Start-Run -Apply:$true -InstallTask:$false })
$installTaskButton.Add_Click({ Start-Run -Apply:$false -InstallTask:$true })
$openReportsButton.Add_Click({ Open-PathIfExists -Path (Join-Path $codexHomeBox.Text "maintenance\reports") })
$openBackupsButton.Add_Click({ Open-PathIfExists -Path (Join-Path $codexHomeBox.Text "maintenance\backups") })

$form.Add_FormClosing({
  if ($script:currentProcess -and -not $script:currentProcess.HasExited) {
    $choice = [System.Windows.Forms.MessageBox]::Show(
      "A run is still active. Close the window anyway?",
      "Keep Codex Fast",
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
      $_.Cancel = $true
    }
  }
})

[void]$form.ShowDialog()
