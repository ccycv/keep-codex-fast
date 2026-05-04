# Keep Codex Fast

Windows-first maintenance tool for Codex Desktop state.

Safe defaults:

- inspect-only unless you pass `-Apply`
- backup first before any change
- archive and move files, never delete them
- refuse apply mode while Codex looks open
- support Windows Codex state and WSL Codex state

## What It Helps With

- large active chats slowing Codex down
- stale worktrees left in hot storage
- oversized `.log` files
- old sessions that should be history, not active state
- path cleanup for Windows extended paths like `\\?\C:\...`
- quick visibility into Codex storage, databases, plugins, memories, and background processes

## Files

- `Keep-CodexFast.ps1` - main Windows script
- `Keep-CodexFast-GUI.ps1` - built-in Windows GUI
- `keep-codex-fast.cmd` - simple Windows launcher
- `keep-codex-fast-gui.cmd` - GUI launcher for normal Windows users
- `keep-codex-fast-wsl.sh` - WSL helper

## Requirements

- Windows PowerShell 5.1+
- optional: WSL if you want WSL inspection/cleanup
- optional: Windows Task Scheduler if you want weekly automation

## Quick Start

Open the Windows GUI:

```powershell
.\keep-codex-fast-gui.cmd
```

Or:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Keep-CodexFast-GUI.ps1
```

Inspect only:

```powershell
.\Keep-CodexFast.ps1
```

Inspect Windows + WSL:

```powershell
.\Keep-CodexFast.ps1 -IncludeWsl
```

If WSL auto-discovery returns nothing:

```powershell
.\Keep-CodexFast.ps1 -IncludeWsl -WslDistro Ubuntu
```

Run the WSL helper directly inside WSL:

```bash
CODEX_FAST_APPLY=0 bash ./keep-codex-fast-wsl.sh
```

## Apply Cleanup

Close Codex first, then run:

```powershell
.\Keep-CodexFast.ps1 -Apply -IncludeWsl
```

In the GUI, use `Inspect` first, then `Apply Cleanup`.

Defaults:

- keep last 10 days of active sessions
- move older active sessions into `archived_sessions`
- create simple handoff docs before archiving sessions
- move worktrees older than 14 days into `archived_worktrees`
- rotate `.log` files larger than 100 MB into `archived_logs`
- normalize `\\?\` Windows path prefixes
- report broken config paths without editing them

Keep more history active:

```powershell
.\Keep-CodexFast.ps1 -Apply -IncludeWsl -SessionDaysToKeep 14 -WorktreeDaysToKeep 30
```

## Weekly Automation

Install a Sunday scheduled task at `09:00`:

```powershell
.\Keep-CodexFast.ps1 -InstallScheduledTask -IncludeWsl
```

The GUI also includes an `Install Weekly Task` button.

Change the time:

```powershell
.\Keep-CodexFast.ps1 -InstallScheduledTask -IncludeWsl -ScheduleTime 18:00
```

The scheduled task runs with `-Apply`. If Codex is open, the script falls back to inspect mode.

## Output

Windows reports:

```text
%USERPROFILE%\.codex\maintenance\reports
```

Windows backups:

```text
%USERPROFILE%\.codex\maintenance\backups
```

WSL reports:

```text
~/.codex/maintenance/reports
```

WSL backups:

```text
~/.codex/maintenance/backups
```

## Notes

- no deletes
- no process killing
- the GUI uses built-in WinForms, so normal Windows machines do not need extra packages
- SQLite files are backed up but not rotated as logs
- handoff docs are mechanical, not AI summaries
- secret auth/token files are not backed up unless `-IncludeSecretsBackup` is passed
- if Windows cannot bridge into a WSL distro cleanly, the main script reports that instead of failing the whole run

## License

MIT
