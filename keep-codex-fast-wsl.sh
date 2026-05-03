#!/usr/bin/env bash
set -euo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
APPLY="${CODEX_FAST_APPLY:-0}"
SESSION_DAYS="${CODEX_FAST_SESSION_DAYS:-10}"
WORKTREE_DAYS="${CODEX_FAST_WORKTREE_DAYS:-14}"
LOG_MB="${CODEX_FAST_LOG_MB:-100}"
STAMP="$(date +%Y%m%d-%H%M%S)"
MAINT="$CODEX_HOME/maintenance"
REPORT_DIR="$MAINT/reports"

mkdir -p "$REPORT_DIR"

bytes_human() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN {
    if (b >= 1073741824) printf "%.2f GB", b / 1073741824;
    else if (b >= 1048576) printf "%.2f MB", b / 1048576;
    else if (b >= 1024) printf "%.2f KB", b / 1024;
    else printf "%d B", b;
  }'
}

dir_size() {
  local path="$1"
  if [ ! -e "$path" ]; then
    echo 0
    return
  fi
  du -sb "$path" 2>/dev/null | awk '{print $1}'
}

backup_first() {
  local backup="$MAINT/backups/$STAMP"
  mkdir -p "$backup"
  local items=(
    config.toml
    .codex-global-state.json
    session_index.jsonl
    state_5.sqlite
    state_5.sqlite-shm
    state_5.sqlite-wal
    logs_2.sqlite
    logs_2.sqlite-shm
    logs_2.sqlite-wal
    memories
    skills
    plugins
    automations
    sqlite
  )
  for item in "${items[@]}"; do
    if [ -e "$CODEX_HOME/$item" ]; then
      mkdir -p "$(dirname "$backup/$item")"
      cp -a "$CODEX_HOME/$item" "$backup/$item"
    fi
  done
  echo "$backup"
}

handoff_doc() {
  local session="$1"
  local handoff_dir="$MAINT/handoffs/$STAMP"
  local name
  name="$(basename "$session" .jsonl)"
  mkdir -p "$handoff_dir"
  {
    echo "# Codex Session Handoff"
    echo
    echo "Archived session: \`$session\`"
    echo "Size: $(bytes_human "$(stat -c%s "$session" 2>/dev/null || echo 0)")"
    echo "Last modified: $(date -r "$session" --iso-8601=seconds 2>/dev/null || true)"
    echo
    echo "## Reactivation Prompt"
    echo
    echo "Continue from archived Codex session \`$(basename "$session")\`. Inspect the archived JSONL if exact context is needed, then make a concise current-state summary before changing files."
    echo
    echo "## Last Session Lines"
    echo
    echo '```jsonl'
    tail -n 30 "$session" 2>/dev/null || true
    echo '```'
  } > "$handoff_dir/$name.md"
  echo "$handoff_dir/$name.md"
}

archive_sessions() {
  local count=0
  local total=0
  local archive="$CODEX_HOME/archived_sessions"
  if [ ! -d "$CODEX_HOME/sessions" ]; then
    echo "0 0"
    return
  fi
  while IFS= read -r -d '' session; do
    count=$((count + 1))
    total=$((total + $(stat -c%s "$session" 2>/dev/null || echo 0)))
    if [ "$APPLY" = "1" ]; then
      mkdir -p "$archive"
      handoff_doc "$session" >/dev/null
      local dest="$archive/$(basename "$session")"
      local i=1
      while [ -e "$dest" ]; do
        dest="$archive/$(basename "$session" .jsonl)-$i.jsonl"
        i=$((i + 1))
      done
      mv "$session" "$dest"
    fi
  done < <(find "$CODEX_HOME/sessions" -type f -name '*.jsonl' -mtime +"$SESSION_DAYS" -print0 2>/dev/null)
  echo "$count $total"
}

move_worktrees() {
  local count=0
  if [ ! -d "$CODEX_HOME/worktrees" ]; then
    echo 0
    return
  fi
  while IFS= read -r -d '' dir; do
    count=$((count + 1))
    if [ "$APPLY" = "1" ]; then
      local archive="$CODEX_HOME/archived_worktrees/$STAMP"
      mkdir -p "$archive"
      local dest="$archive/$(basename "$dir")"
      local i=1
      while [ -e "$dest" ]; do
        dest="$archive/$(basename "$dir")-$i"
        i=$((i + 1))
      done
      mv "$dir" "$dest"
    fi
  done < <(find "$CODEX_HOME/worktrees" -mindepth 1 -maxdepth 1 -type d -mtime +"$WORKTREE_DAYS" -print0 2>/dev/null)
  echo "$count"
}

rotate_logs() {
  local count=0
  local min_bytes=$((LOG_MB * 1024 * 1024))
  while IFS= read -r -d '' log; do
    count=$((count + 1))
    if [ "$APPLY" = "1" ]; then
      local rel="${log#$CODEX_HOME/}"
      local dest="$CODEX_HOME/archived_logs/$STAMP/$rel"
      mkdir -p "$(dirname "$dest")"
      mv "$log" "$dest"
    fi
  done < <(find "$CODEX_HOME" -type f -name '*.log' -size +"${min_bytes}"c -print0 2>/dev/null)
  echo "$count"
}

if [ ! -d "$CODEX_HOME" ]; then
  echo "Codex home not found: $CODEX_HOME"
  exit 0
fi

backup_path=""
if [ "$APPLY" = "1" ]; then
  backup_path="$(backup_first)"
fi

read -r session_count session_bytes < <(archive_sessions)
worktree_count="$(move_worktrees)"
log_count="$(rotate_logs)"
mode="inspect"
if [ "$APPLY" = "1" ]; then
  mode="apply"
fi

report="$REPORT_DIR/$STAMP-wsl.md"
{
  echo "# Keep Codex Fast WSL Report"
  echo
  echo "Mode: $mode"
  echo "Codex home: \`$CODEX_HOME\`"
  echo "Generated: $(date --iso-8601=seconds)"
  echo
  echo "## Storage"
  echo
  for name in sessions archived_sessions worktrees archived_worktrees archived_logs cache plugins skills memories sqlite; do
    size="$(dir_size "$CODEX_HOME/$name")"
    echo "- $name: $(bytes_human "$size")"
  done
  echo
  echo "## Planned Or Applied"
  echo
  echo "- Sessions archived/planned: $session_count ($(bytes_human "$session_bytes"))"
  echo "- Worktrees moved/planned: $worktree_count"
  echo "- Logs rotated/planned: $log_count"
  if [ -n "$backup_path" ]; then
    echo "- Backup: \`$backup_path\`"
  fi
  echo
  echo "## Largest Active Sessions"
  echo
  if [ -d "$CODEX_HOME/sessions" ]; then
    find "$CODEX_HOME/sessions" -type f -name '*.jsonl' -printf '%s %p\n' 2>/dev/null | sort -nr | head -10 | while read -r size path; do
      echo "- $(bytes_human "$size") \`$path\`"
    done
  fi
} > "$report"

echo "WSL report: $report"
echo "Mode: $mode"
echo "Sessions archived/planned: $session_count"
echo "Worktrees moved/planned: $worktree_count"
echo "Logs rotated/planned: $log_count"
