#!/bin/zsh
# Git snapshot backup of the Obsidian production vault -> private GitHub repo.
# Managed by chezmoi (CTristan/dotfiles) — contains NO secrets.
# Runs via the com.user.vault-backup LaunchAgent (hourly + at load) and ad-hoc.
#
# STRICTLY READ-ONLY ON THE VAULT: detached git dir at $GIT_DIR with
# core.worktree -> vault; only vault-read-only git verbs are used
# (add/commit/push/diff/rev-list). NEVER add checkout/restore/clean/
# reset --hard here — restores go through a separate clone + the
# obsidian-mirror.sh promote flow.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin

VAULT="${VAULT_BACKUP_WORKTREE:-$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Personal}"
GIT_DIR="${VAULT_BACKUP_GIT_DIR:-$HOME/.local/state/vault-backup.git}"
BRANCH="${VAULT_BACKUP_BRANCH:-main}"
MIN_MD="${VAULT_BACKUP_MIN_MD:-1000}"          # vault holds ~1533 .md files today
MAX_DELETE="${VAULT_BACKUP_MAX_DELETE:-100}"   # abort if snapshot would delete more tracked files
HYDRATE_TIMEOUT="${VAULT_BACKUP_HYDRATE_TIMEOUT:-60}"
LOG_FILE="$HOME/Library/Logs/vault-backup.log"
LOCK_FILE="$HOME/.local/state/vault-backup.lock"

log()   { echo "$(date '+%Y-%m-%d %H:%M:%S') [vault-backup] $*"; }
fatal() { log "FATAL: $*"; exit 1; }
g()     { git --git-dir="$GIT_DIR" --work-tree="$VAULT" "$@"; }

# Single-instance lock: kernel releases on process death — no stale-lock handling.
zmodload zsh/system
: >>"$LOCK_FILE"
if ! zsystem flock -t 0 "$LOCK_FILE" 2>/dev/null; then
  log "another run holds the lock; exiting"
  exit 0
fi

# Self-rotate: truncate in place at 5MB (safe against launchd's O_APPEND fd;
# a mv would detach launchd from the file).
if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE")" -gt 5242880 ]; then
  : >"$LOG_FILE"
  log "log truncated at 5MB"
fi

[ -d "$VAULT" ]   || fatal "vault not found: $VAULT"
[ -d "$GIT_DIR" ] || fatal "backup git dir missing: $GIT_DIR (run the one-time bootstrap)"

# Best-effort iCloud hydration (bounded); MIN_MD/MAX_DELETE are the backstop.
if [ -n "$(find "$VAULT" -name '*.icloud' -print -quit 2>/dev/null)" ]; then
  log "iCloud placeholders present; requesting hydration"
  if command -v brctl >/dev/null 2>&1; then
    find "$VAULT" -name '*.icloud' -print0 2>/dev/null \
      | while IFS= read -r -d '' f; do brctl download "$f" 2>/dev/null || true; done
    tries=0
    while [ -n "$(find "$VAULT" -name '*.icloud' -print -quit 2>/dev/null)" ]; do
      tries=$((tries + 1))
      [ "$tries" -gt "$HYDRATE_TIMEOUT" ] && break
      sleep 1
    done
  fi
  [ -z "$(find "$VAULT" -name '*.icloud' -print -quit 2>/dev/null)" ] \
    || log "WARN: placeholders remain after ~${HYDRATE_TIMEOUT}s; continuing under guards"
fi

# Enumerate the vault, capturing find's real exit and stderr — never swallow it.
# A launchd job cannot READ a third-party iCloud container (iCloud~md~obsidian)
# without Full Disk Access: `[ -d ]` (stat) passes but find/readdir returns
# "Operation not permitted". Without this guard, pipefail + set -e would kill
# the run silently (exit 1, empty log) and the backup would appear to work.
errf="$(mktemp -t vault-backup.XXXXXX)"
files="$(find "$VAULT" -type f -name '*.md' 2>"$errf")" && find_rc=0 || find_rc=$?
if [ "$find_rc" -ne 0 ] || grep -qiE 'not permitted|permission denied' "$errf"; then
  msg="$(head -1 "$errf" 2>/dev/null)"; rm -f "$errf"
  fatal "cannot read vault ($VAULT): ${msg:-find exited $find_rc}. If this says 'Operation not permitted', grant Full Disk Access to ~/.local/bin/vault-backup-helper in System Settings > Privacy & Security > Full Disk Access, then run: launchctl kickstart -k gui/\$(id -u)/com.user.vault-backup"
fi
rm -f "$errf"

# Mass-eviction floor: an evicted note's real filename is ABSENT on disk,
# so a largely-evicted vault looks nearly empty.
if [ -z "$files" ]; then md_count=0; else md_count="$(printf '%s\n' "$files" | wc -l | tr -d ' ')"; fi
[ "$md_count" -ge "$MIN_MD" ] \
  || fatal "only $md_count .md files on disk (< $MIN_MD); vault looks evicted/unmounted — refusing to snapshot"

# Snapshot
g add -A
del_count="$(g diff --cached --name-only --diff-filter=D | wc -l | tr -d ' ')"
if [ "$del_count" -gt "$MAX_DELETE" ]; then
  g reset -q   # index-only (--mixed); never touches the worktree
  fatal "$del_count tracked files staged for deletion (> $MAX_DELETE); suspected eviction — aborted, no commit"
fi
if g diff --cached --quiet 2>/dev/null; then
  log "no changes since last snapshot"
else
  g commit -q -m "Vault snapshot $(date '+%Y-%m-%d %H:%M')"
  # --root so the very first (parentless) commit enumerates its files instead of logging 0.
  log "committed: $(g diff-tree --root --no-commit-id --name-only -r HEAD | wc -l | tr -d ' ') paths ($del_count deletions)"
fi

# Push anything unpushed (drains commits stranded by earlier offline runs);
# skip the network when the remote is already current.
need_push=1
if g rev-parse -q --verify "refs/remotes/origin/$BRANCH" >/dev/null 2>&1; then
  [ "$(g rev-list --count "origin/$BRANCH..$BRANCH" 2>/dev/null || echo 1)" -gt 0 ] || need_push=0
fi
if [ "$need_push" -eq 0 ]; then
  log "remote up to date; done"
  exit 0
fi
if g push -q origin "$BRANCH"; then
  log "pushed to origin/$BRANCH; done"
else
  log "WARN: push failed (offline or auth?); commit is safe locally, next run retries"
  exit 2
fi
