#!/bin/zsh
# Bidirectional git sync of the Obsidian vault <-> private GitHub repo (personal-vault).
# Managed by chezmoi (CTristan/dotfiles) — contains NO secrets.
# Runs via the com.user.vault-backup LaunchAgent (every 5 min + at load) and ad-hoc.
#
# The repo's main branch is the CANONICAL source of truth, shared with AI
# collaborators that read AND write it. This job is this Mac's sync client: it
# snapshots local vault edits up, and integrates others' commits down into the
# live iCloud vault.
#
# WRITE CONTRACT — the ONLY git verbs permitted to touch the vault worktree are
# `merge` and `merge --abort`, and only behind the guards below (incoming-delete
# cap, .obsidian/ block, case-collision check, hot-file defer). NEVER add
# checkout/restore/clean/reset --hard: a maintainer "simplifying" the merge away,
# or reaching for those, breaks the guard preconditions this contract rests on.
# The detached git dir keeps .git out of iCloud — no .git working tree ever lives
# inside the container.
#
# On conflict the job saves local state to a device branch, notifies, aborts the
# merge to restore the worktree, and exits 2 for manual resolution (see the
# failure handler). Recovery: resolve on origin/main, then let the next cycle sync.
#
# Exit codes: 0 = synced/clean · 1 = hard fatal (unreadable/evicted/bad state) ·
# 2 = needs attention (conflict, guard-refused integration, push failed).
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin

VAULT="${VAULT_BACKUP_WORKTREE:-$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/Personal}"
GIT_DIR="${VAULT_BACKUP_GIT_DIR:-$HOME/.local/state/vault-backup.git}"
BRANCH="${VAULT_BACKUP_BRANCH:-main}"
MIN_MD="${VAULT_BACKUP_MIN_MD:-1000}"          # vault holds ~1533 .md files today
MAX_DELETE="${VAULT_BACKUP_MAX_DELETE:-100}"   # abort if a snapshot OR an incoming delta would remove more tracked files
HYDRATE_TIMEOUT="${VAULT_BACKUP_HYDRATE_TIMEOUT:-60}"
QUIESCE_SECS="${VAULT_SYNC_QUIESCE:-180}"      # skip snapshot / defer integration while the vault was edited this recently
ALLOW_OBSIDIAN="${VAULT_SYNC_ALLOW_OBSIDIAN:-0}"  # override the .obsidian/ integration block for an owner-reviewed cycle
DEVICE="${VAULT_SYNC_DEVICE:-$(hostname -s 2>/dev/null || echo device)}"
DEVICE_BRANCH="device-${DEVICE:l}"             # conflict-recovery branch; device-owned by construction
LOG_FILE="$HOME/Library/Logs/vault-backup.log"
LOCK_FILE="$HOME/.local/state/vault-backup.lock"

log()    { echo "$(date '+%Y-%m-%d %H:%M:%S') [vault-sync] $*"; }
fatal()  { log "FATAL: $*"; exit 1; }
g()      { git --git-dir="$GIT_DIR" --work-tree="$VAULT" "$@"; }
# Best-effort desktop alert; must never kill the script (guarded + osascript optional).
notify() { command -v osascript >/dev/null 2>&1 && osascript -e "display notification \"$1\" with title \"Vault sync\"" >/dev/null 2>&1 || true; }

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

# Stale index.lock: we hold the flock, so a single instance is guaranteed — an
# index.lock older than a few minutes can only be debris from a killed run.
if [ -f "$GIT_DIR/index.lock" ] && [ -n "$(find "$GIT_DIR/index.lock" -mmin +5 2>/dev/null)" ]; then
  rm -f "$GIT_DIR/index.lock" && log "removed stale index.lock (held flock; provably stale)"
fi

# Dead-run recovery: a prior cycle that died mid-conflict leaves MERGE_HEAD. If we
# snapshot now, `add -A` marks the conflicted paths resolved and the next commit
# bakes the <<<<<<< markers into a real merge commit that gets pushed to canonical
# main. Clear it BEFORE the snapshot phase, always.
if [ -f "$GIT_DIR/MERGE_HEAD" ]; then
  log "WARN: stale MERGE_HEAD from a prior dead run; aborting it before snapshot"
  notify "Vault sync recovered from an interrupted merge."
  g merge --abort 2>/dev/null || fatal "could not abort stale merge (MERGE_HEAD present); resolve $GIT_DIR by hand"
fi

# Best-effort iCloud hydration (bounded). In bidirectional mode residual
# placeholders are FATAL, not warn-and-continue: an evicted note's real filename
# is absent on disk, so `add -A` would stage its deletion and PUSH that removal to
# the shared source of truth (and turn later edits into modify/delete conflicts).
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
    || fatal "placeholders remain after ~${HYDRATE_TIMEOUT}s; vault not fully hydrated — refusing to snapshot (would push eviction-deletions)"
fi

# Enumerate the vault, capturing find's real exit and stderr — never swallow it.
# A launchd job cannot READ a third-party iCloud container (iCloud~md~obsidian)
# without Full Disk Access: `[ -d ]` (stat) passes but find/readdir returns
# "Operation not permitted". Without this guard, pipefail + set -e would kill
# the run silently (exit 1, empty log) and the sync would appear to work.
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

# ---- Snapshot (local edits up) ----------------------------------------------
# Quiesce debounce: if the vault was edited very recently, skip the snapshot this
# cycle so half-written notes don't become canonical commits agents read. Fetch +
# integrate still run below — this only defers committing local work.
if [ -n "$(find "$VAULT" -type f -newermt "-${QUIESCE_SECS} seconds" -print -quit 2>/dev/null)" ]; then
  log "vault edited <${QUIESCE_SECS}s ago; skipping snapshot this cycle (integrate/push still run)"
else
  g add -A
  del_count="$(g diff --cached --name-only --diff-filter=D | wc -l | tr -d ' ')"
  if [ "$del_count" -gt "$MAX_DELETE" ]; then
    g reset -q   # index-only (--mixed); never touches the worktree
    fatal "$del_count tracked files staged for deletion (> $MAX_DELETE); suspected eviction — aborted, no commit"
  fi
  if g diff --cached --quiet 2>/dev/null; then
    log "no local changes since last snapshot"
  else
    g commit -q -m "Vault snapshot $(date '+%Y-%m-%d %H:%M')"
    # --root so the very first (parentless) commit enumerates its files instead of logging 0.
    log "snapshot committed: $(g diff-tree --root --no-commit-id --name-only -r HEAD | wc -l | tr -d ' ') paths ($del_count deletions)"
  fi
fi

# ---- Fetch ------------------------------------------------------------------
if g fetch -q origin 2>/dev/null; then
  fetched=1
else
  log "WARN: fetch failed (offline?); skipping integrate, will still attempt push"
  fetched=0
fi

# ---- Integrate (others' commits down — the sanctioned vault writer) ---------
# All incoming-delta inspection is three-dot (merge-base..origin) = the ACTUAL
# incoming change. Two-dot would read every local addition as a phantom incoming
# deletion and false-trip the guards in the normal diverged state.
if [ "$fetched" -eq 1 ]; then
  behind="$(g rev-list --count "HEAD..origin/$BRANCH" 2>/dev/null || echo 0)"
else
  behind=0
fi

if [ "$behind" -gt 0 ]; then
  DELTA="HEAD...origin/$BRANCH"

  # Guard: .obsidian/ carries executable plugin code; a prompt-injectable agent
  # committing there is code execution in Obsidian within one cycle. Manual only.
  if [ "$ALLOW_OBSIDIAN" != "1" ] \
     && g diff --name-only "$DELTA" | grep -qE '(^|/)\.obsidian/'; then
    log "REFUSED: incoming delta touches .obsidian/ (plugin/config code); integration blocked. Review manually, then re-run with VAULT_SYNC_ALLOW_OBSIDIAN=1."
    notify "Vault sync blocked: incoming .obsidian/ change needs manual review."
    exit 2
  fi

  # Guard: incoming mass-deletion (symmetric with the outgoing snapshot cap).
  in_del="$(g diff --name-only --diff-filter=D "$DELTA" | wc -l | tr -d ' ')"
  if [ "$in_del" -gt "$MAX_DELETE" ]; then
    log "REFUSED: incoming delta deletes $in_del tracked files (> $MAX_DELETE); suspected bad agent commit. Raise VAULT_BACKUP_MAX_DELETE for a legitimate reorg."
    notify "Vault sync blocked: incoming change deletes $in_del files."
    exit 2
  fi

  # Guard: case-fold collision. On case-insensitive APFS an incoming ADD of
  # foo.md when local tracks Foo.md is NOT a merge conflict — the checkout writes
  # one inode and silently clobbers the other's content. Refuse before merging.
  added="$(g diff --name-only --diff-filter=A "$DELTA")"
  if [ -n "$added" ]; then
    tracked="$(g ls-files)"
    collision=""
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      plc="${p:l}"
      while IFS= read -r t; do
        [ -z "$t" ] && continue
        [ "${t:l}" = "$plc" ] && [ "$t" != "$p" ] && { collision="$p <-> $t"; break; }
      done <<< "$tracked"
      [ -n "$collision" ] && break
    done <<< "$added"
    if [ -n "$collision" ]; then
      log "REFUSED: incoming add case-collides with a tracked path ($collision); merge would clobber on APFS. Rename one on origin/$BRANCH."
      notify "Vault sync blocked: filename case collision ($collision)."
      exit 2
    fi
  fi

  # Guard: hot file. If any path in the incoming delta was edited locally in the
  # last QUIESCE_SECS, an open Obsidian buffer could autosave over the merged
  # content. Defer one cycle rather than race the editor.
  hot=""
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    f="$VAULT/$p"
    [ -f "$f" ] && [ -n "$(find "$f" -newermt "-${QUIESCE_SECS} seconds" -print -quit 2>/dev/null)" ] && { hot="$p"; break; }
  done <<< "$(g diff --name-only "$DELTA")"
  if [ -n "$hot" ]; then
    log "incoming delta touches recently-edited '$hot' (<${QUIESCE_SECS}s); deferring integration one cycle"
    exit 0
  fi

  # Merge — NEVER bare: an unwrapped nonzero merge under set -e would skip the
  # handler and leave conflict markers in live notes for iCloud to sync everywhere.
  if g merge --no-edit "origin/$BRANCH"; then
    log "integrated origin/$BRANCH ($behind commit(s))"
    # Detection only: iCloud may materialize "Note 2.md" copies during the merge
    # write window. Only UNTRACKED such files are suspect — the snapshot phase
    # already committed any pre-existing ones, and legitimately-named sequel notes
    # ("Pikmin 2.md") are tracked, so untracked-filtering excludes the false hits.
    copies="$(g ls-files --others --exclude-standard 2>/dev/null | grep -E ' 2\.md$' | head -5 || true)"
    [ -n "$copies" ] && log "WARN: possible iCloud conflict copies (untracked ' 2.md'): $(printf '%s' "$copies" | tr '\n' ';')"
  else
    # Failure handler, ORDERED so recovery-critical steps run regardless of the
    # merge-failure shape (content conflict leaves MERGE_HEAD; a pre-write refusal
    # exits nonzero with NO MERGE_HEAD, where `merge --abort` would itself fatal).
    # (a) get local state off-machine FIRST — device-owned branch, lease-forced.
    if g push --force-with-lease -q origin "HEAD:refs/heads/$DEVICE_BRANCH" 2>/dev/null; then
      log "saved local state to origin/$DEVICE_BRANCH for recovery"
    else
      log "WARN: could not push recovery branch origin/$DEVICE_BRANCH"
    fi
    notify "Vault sync CONFLICT — manual resolution needed (local state saved to $DEVICE_BRANCH)."
    # (b) restore the worktree, branched on MERGE_HEAD.
    if [ -f "$GIT_DIR/MERGE_HEAD" ]; then
      if g merge --abort 2>/dev/null; then log "merge --abort restored the worktree"; else log "WARN: merge --abort failed; $GIT_DIR needs manual cleanup"; fi
    else
      log "merge refused pre-write (no MERGE_HEAD); worktree untouched"
    fi
    exit 2
  fi
fi

# ---- Push (local commits up) ------------------------------------------------
ahead="$(g rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo 0)"
if [ "$ahead" -eq 0 ]; then
  log "remote up to date; done"
  exit 0
fi
if g push -q origin "$BRANCH" 2>/dev/null; then
  log "pushed $ahead commit(s) to origin/$BRANCH; done"
  exit 0
fi

# Non-ff (an agent pushed between our fetch and push) or offline. One bounded
# retry: re-fetch, re-integrate, re-push. Clean up any MERGE_HEAD the retry leaves
# so the next cycle's dead-run recovery isn't needed.
log "push rejected/failed; one retry after re-fetch"
if g fetch -q origin 2>/dev/null && g merge --no-edit "origin/$BRANCH" 2>/dev/null; then
  if g push -q origin "$BRANCH" 2>/dev/null; then
    log "pushed after retry; done"
    exit 0
  fi
else
  [ -f "$GIT_DIR/MERGE_HEAD" ] && { g merge --abort 2>/dev/null || true; }
fi
log "WARN: push failed after retry; commit is safe locally, next cycle retries"
notify "Vault sync: push failed, will retry next cycle."
exit 2
