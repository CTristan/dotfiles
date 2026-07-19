#!/bin/zsh
# Test suite for the vault sync loop (backup-vault.sh). Exercises every guard
# against throwaway git repos in a temp dir — it NEVER touches the production
# vault or the real detached git dir, so it is safe to run anytime.
#
# Run it after changing backup-vault.sh:
#   ~/.local/share/vault-backup/test-vault-sync.zsh
# By default it tests the DEPLOYED script (~/.local/bin/backup-vault.sh); to test
# an un-applied chezmoi source copy instead, point SYNC_SCRIPT at it:
#   SYNC_SCRIPT=~/.local/share/chezmoi/home/dot_local/bin/executable_backup-vault.sh \
#     ~/.local/share/vault-backup/test-vault-sync.zsh
#
# Exits 0 iff every case passes. Each case sets up a fresh origin + author clone
# + a detached-git-dir device (mirroring production layout), drives the script
# with VAULT_*/VAULT_SYNC_* env overrides, and asserts on exit code + log + disk.
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin

SYNC_SCRIPT="${SYNC_SCRIPT:-$HOME/.local/bin/backup-vault.sh}"
[ -f "$SYNC_SCRIPT" ] || { echo "script under test not found: $SYNC_SCRIPT (run 'chezmoi apply' first, or set SYNC_SCRIPT)"; exit 1; }

ROOT="$(mktemp -d -t vault-sync-test)"
[ -d "$ROOT" ] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$ROOT"' EXIT INT TERM   # clean up on normal exit, failure, or Ctrl-C
# Isolated HOME so the script's hardcoded LOCK_FILE/LOG_FILE ($HOME/...) resolve
# into the temp tree — NOT the live lock (would flake against the 5-min job, and
# make it skip a cycle) or the production log (its 5MB self-rotate would truncate it).
mkdir -p "$ROOT/home/.local/state" "$ROOT/home/Library/Logs"
PASS=0; FAIL=0
declare -a RESULTS

ok()   { PASS=$((PASS+1)); RESULTS+=("PASS  $1"); }
bad()  { FAIL=$((FAIL+1)); RESULTS+=("FAIL  $1  -- $2"); }

# Fresh origin + author clone + device (detached git dir + worktree), main branch.
fresh() {
  rm -rf "$ROOT/wk"; mkdir -p "$ROOT/wk"
  ORIGIN="$ROOT/wk/origin.git"; AUTHOR="$ROOT/wk/author"; GD="$ROOT/wk/device.git"; WT="$ROOT/wk/worktree"
  git init -q --bare -b main "$ORIGIN"
  git clone -q "$ORIGIN" "$AUTHOR" 2>/dev/null
  ( cd "$AUTHOR"
    git config user.name a; git config user.email a@x; git config core.ignorecase false
    git config commit.gpgsign false                # personal-vault stays unsigned; global gpgsign=true would else tap
    for i in 1 2 3 4 5; do echo "note $i" > "note$i.md"; done
    mkdir -p sub; echo "Foo original" > "Foo.md"
    git add -A; git commit -q -m "base"; git push -q -u origin main )
  git clone -q --bare "$ORIGIN" "$GD"
  git --git-dir="$GD" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git --git-dir="$GD" fetch -q origin
  mkdir -p "$WT"
  git --git-dir="$GD" config core.bare false
  git --git-dir="$GD" config core.worktree "$WT"
  git --git-dir="$GD" config core.ignorecase true
  git --git-dir="$GD" config core.precomposeunicode true
  git --git-dir="$GD" config commit.gpgsign false
  git --git-dir="$GD" config gc.autoDetach false
  git --git-dir="$GD" config user.name dev
  git --git-dir="$GD" config user.email dev@x
  # Materialize the worktree (the harness may checkout; the SCRIPT never does).
  git --git-dir="$GD" --work-tree="$WT" checkout -f main -- . 2>/dev/null
  git --git-dir="$GD" --work-tree="$WT" reset -q --mixed HEAD
}

# Author-side helper: make an agent commit on origin/main.
agent_push() { ( cd "$AUTHOR" && git pull -q origin main && "$@" && git add -A && git commit -q -m "agent" && git push -q origin main ); }

# Run the script under test against the device with given extra env; capture exit + log.
run() {
  local logf="$ROOT/wk/run.log"; : > "$logf"
  # HOME isolates lock/log into the temp tree; the two explicit guard vars the
  # suite never sets otherwise (ALLOW_OBSIDIAN, BRANCH) are pinned so an exported
  # value in the caller's shell can't skew a result. EXTRA comes last so a case's
  # override (e.g. ALLOW_OBSIDIAN=1 in test 7) still wins.
  env HOME="$ROOT/home" \
      VAULT_BACKUP_WORKTREE="$WT" VAULT_BACKUP_GIT_DIR="$GD" \
      VAULT_BACKUP_MIN_MD="${MIN_MD:-1}" VAULT_BACKUP_MAX_DELETE="${MAXDEL:-100}" \
      VAULT_SYNC_QUIESCE="${QUIESCE:-0}" VAULT_SYNC_DEVICE=scratch \
      VAULT_SYNC_ALLOW_OBSIDIAN=0 VAULT_BACKUP_BRANCH=main \
      ${EXTRA:+$EXTRA} \
      zsh "$SYNC_SCRIPT" > "$logf" 2>&1
  RC=$?; LOG="$(cat "$logf")"
}
haslog() { print -r -- "$LOG" | grep -qF "$1"; }
in_wt()  { [ -e "$WT/$1" ]; }
origin_has_branch() { git --git-dir="$ORIGIN" show-ref --verify -q "refs/heads/$1"; }
origin_has_file()   { git --git-dir="$ORIGIN" cat-file -e "main:$1" 2>/dev/null; }
head_has_file()     { git --git-dir="$GD" cat-file -e "HEAD:$1" 2>/dev/null; }

echo "=== vault sync suite (script under test: $SYNC_SCRIPT) ==="

# --- 1: behind-only fast-forward ---
fresh
agent_push sh -c 'echo agentA > agentA.md'
run
{ [ "$RC" -eq 0 ] && in_wt agentA.md && haslog "integrated origin/main"; } \
  && ok "1 behind-only ff" || bad "1 behind-only ff" "rc=$RC log=[$LOG]"

# --- 2: diverged merge commit ---
fresh
echo "localB" > "$WT/localB.md"
agent_push sh -c 'echo agentC > agentC.md'
QUIESCE=0 run
{ [ "$RC" -eq 0 ] && in_wt localB.md && in_wt agentC.md && haslog "snapshot committed" && haslog "integrated origin/main" && haslog "pushed" \
    && origin_has_file localB.md && origin_has_file agentC.md; } \
  && ok "2 diverged merge" || bad "2 diverged merge" "rc=$RC log=[$LOG]"

# --- 3: content conflict -> device branch + abort ---
fresh
agent_push sh -c 'echo agentline > note1.md'     # agent changes note1
echo "localline" > "$WT/note1.md"                # local changes same file
run
{ [ "$RC" -eq 2 ] && haslog "saved local state to origin/device-scratch" && haslog "merge --abort restored" \
    && origin_has_branch device-scratch && [ "$(cat "$WT/note1.md")" = "localline" ] \
    && ! grep -q '<<<<<<<' "$WT/note1.md"; } \
  && ok "3 conflict -> device branch + abort" || bad "3 conflict" "rc=$RC note1=[$(cat "$WT/note1.md")] log=[$LOG]"

# --- 4: dead-run recovery (stale MERGE_HEAD cleared before snapshot) ---
fresh
agent_push sh -c 'echo agent4 > note2.md'
echo "local4" > "$WT/note2.md"
git --git-dir="$GD" --work-tree="$WT" add -A
git --git-dir="$GD" --work-tree="$WT" commit -q -m "local4"
git --git-dir="$GD" --work-tree="$WT" fetch -q origin
git --git-dir="$GD" --work-tree="$WT" merge --no-edit origin/main >/dev/null 2>&1  # leaves MERGE_HEAD + markers
have_mh_before=$([ -f "$GD/MERGE_HEAD" ] && echo yes || echo no)
run
# After preflight abort it re-diverges and exits 2 via the handler; key: preflight fired, main is marker-free.
main_markers=$(git --git-dir="$ORIGIN" grep -q '<<<<<<<' main -- 2>/dev/null && echo yes || echo no)
{ [ "$have_mh_before" = yes ] && haslog "stale MERGE_HEAD from a prior dead run" && [ "$main_markers" = no ] \
    && [ "$RC" -eq 2 ] && origin_has_branch device-scratch; } \
  && ok "4 dead-run recovery (no marker commit)" || bad "4 dead-run" "mh_before=$have_mh_before markers=$main_markers rc=$RC log=[$LOG]"

# --- 5: pre-write refusal (nonzero, no MERGE_HEAD) handled cleanly ---
fresh
# An old untracked file that collides with an incoming ADD; a separate hot file
# keeps the snapshot skipped so it stays untracked at merge time.
echo "local-untracked" > "$WT/refuse.md"; touch -t 202601010000 "$WT/refuse.md"
echo "hot" > "$WT/hot-trigger.md"                # fresh mtime -> quiesce skips snapshot
agent_push sh -c 'echo agent-refuse > refuse.md'
QUIESCE=180 run
{ [ "$RC" -eq 2 ] && haslog "merge refused pre-write (no MERGE_HEAD)" && [ ! -f "$GD/MERGE_HEAD" ] \
    && [ "$(cat "$WT/refuse.md")" = "local-untracked" ]; } \
  && ok "5 pre-write refusal handled" || bad "5 pre-write refusal" "rc=$RC refuse=[$(cat "$WT/refuse.md")] log=[$LOG]"

# --- 6: incoming mass-delete refused ---
fresh
agent_push sh -c 'rm note1.md note2.md note3.md'
MAXDEL=2 run
{ [ "$RC" -eq 2 ] && haslog "incoming delta deletes 3 tracked files" && in_wt note1.md && in_wt note3.md; } \
  && ok "6 incoming mass-delete refused" || bad "6 mass-delete" "rc=$RC log=[$LOG]"

# --- 7: .obsidian/ block (and override) ---
fresh
agent_push sh -c 'mkdir -p .obsidian/plugins/x && echo "code()" > .obsidian/plugins/x/main.js'
run
block_ok=$({ [ "$RC" -eq 2 ] && haslog "touches .obsidian/" && ! in_wt .obsidian/plugins/x/main.js; } && echo y || echo n)
EXTRA="VAULT_SYNC_ALLOW_OBSIDIAN=1" run
override_ok=$({ [ "$RC" -eq 0 ] && in_wt .obsidian/plugins/x/main.js; } && echo y || echo n)
unset EXTRA
{ [ "$block_ok" = y ] && [ "$override_ok" = y ]; } \
  && ok "7 .obsidian block + override" || bad "7 obsidian" "block=$block_ok override=$override_ok rc=$RC log=[$LOG]"

# --- 8: case-fold collision refused ---
fresh
( cd "$AUTHOR" && git pull -q origin main
  blob=$(printf 'lower' | git hash-object -w --stdin)
  git update-index --add --cacheinfo 100644,"$blob",foo.md
  git commit -q -m "agent adds foo.md case-variant"; git push -q origin main )
run
{ [ "$RC" -eq 2 ] && haslog "case-collides with a tracked path" && [ "$(cat "$WT/Foo.md")" = "Foo original" ]; } \
  && ok "8 case collision refused" || bad "8 case collision" "rc=$RC Foo=[$(cat "$WT/Foo.md" 2>/dev/null)] log=[$LOG]"

# --- 9: three-dot guard does NOT false-trip on many local adds ---
fresh
for i in 1 2 3 4 5; do echo "local new $i" > "$WT/localnew$i.md"; done
agent_push sh -c 'echo agent9 > agent9.md'
MAXDEL=2 QUIESCE=0 run
{ [ "$RC" -eq 0 ] && ! haslog "incoming delta deletes" && haslog "integrated origin/main" \
    && in_wt localnew5.md && in_wt agent9.md; } \
  && ok "9 three-dot no false-trip" || bad "9 three-dot" "rc=$RC log=[$LOG]"

# --- 10: quiesce skips snapshot, integrate still runs ---
fresh
echo "uncommitted-local" > "$WT/draft.md"; touch "$WT/draft.md"   # fresh -> hot
agent_push sh -c 'echo agent10 > agent10.md'
QUIESCE=180 run
draft_tracked=$(git --git-dir="$GD" --work-tree="$WT" ls-files draft.md)
{ [ "$RC" -eq 0 ] && haslog "skipping snapshot this cycle" && haslog "integrated origin/main" \
    && in_wt agent10.md && in_wt draft.md && [ -z "$draft_tracked" ]; } \
  && ok "10 quiesce skip snapshot" || bad "10 quiesce" "rc=$RC draft_tracked=[$draft_tracked] log=[$LOG]"

# --- 11: offline fetch -> warn, push path still reached ---
fresh
echo "local11" > "$WT/local11.md"
git --git-dir="$GD" remote set-url origin "$ROOT/wk/does-not-exist.git"
QUIESCE=0 run
{ [ "$RC" -eq 2 ] && haslog "fetch failed (offline?)" && haslog "push failed after retry" \
    && head_has_file local11.md; } \
  && ok "11 offline fetch warn + push path" || bad "11 offline" "rc=$RC log=[$LOG]"

# --- 12: MIN_MD floor still fatals ---
fresh
MIN_MD=999999 run
{ [ "$RC" -eq 1 ] && haslog "vault looks evicted/unmounted"; } \
  && ok "12 MIN_MD floor" || bad "12 MIN_MD" "rc=$RC log=[$LOG]"

# --- 13: residual placeholder now fatal ---
fresh
echo "" > "$WT/ghost.md.icloud"
EXTRA="VAULT_BACKUP_HYDRATE_TIMEOUT=1" run
{ [ "$RC" -eq 1 ] && haslog "placeholders remain" && haslog "refusing to snapshot"; } \
  && ok "13 residual placeholder fatal" || bad "13 residual placeholder" "rc=$RC log=[$LOG]"
unset EXTRA

# --- 14: conflict-copy scan flags untracked ' 2.md' only, not tracked sequels ---
fresh
echo "sequel note" > "$WT/Pikmin 2.md"            # a legitimately-named note...
git --git-dir="$GD" --work-tree="$WT" add -A
git --git-dir="$GD" --work-tree="$WT" commit -q -m "add tracked sequel note"   # ...that is TRACKED
echo "icloud-race" > "$WT/Draft 2.md"             # an UNTRACKED ' 2.md' (simulated race copy)
echo "hot" > "$WT/hot.md"; touch "$WT/hot.md"     # keep snapshot skipped so Draft 2.md stays untracked
agent_push sh -c 'echo agent14 > agent14.md'
QUIESCE=180 run
{ [ "$RC" -eq 0 ] && haslog "conflict copies (untracked ' 2.md'): " && haslog "Draft 2.md" && ! haslog "Pikmin 2.md"; } \
  && ok "14 conflict-copy scan (untracked only)" || bad "14 conflict-copy scan" "rc=$RC log=[$LOG]"

echo
echo "=== results ==="
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
