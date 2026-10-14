#!/bin/zsh
# Exercise vault setup against scratch homes and local bare repositories.
# The suite never contacts GitHub or iCloud and replaces launchctl, clang,
# codesign, and gh with local test doubles.
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${VAULT_SETUP_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SETUP_SOURCE="$REPO_ROOT/home/dot_local/bin/executable_setup-vault-backup"
SYNC_SOURCE="$REPO_ROOT/home/dot_local/bin/executable_backup-vault.sh"
HELPER_SOURCE="$REPO_ROOT/home/dot_local/share/vault-backup/vault-backup-helper.c"
PLIST_SOURCE="$REPO_ROOT/home/Library/LaunchAgents/com.user.vault-backup.plist.tmpl"

for source in "$SETUP_SOURCE" "$SYNC_SOURCE" "$HELPER_SOURCE" "$PLIST_SOURCE"; do
  [[ -f "$source" ]] || { print -u2 -- "source file missing: $source"; exit 1; }
done

ROOT=$(mktemp -d -t vault-setup-test)
[[ -d "$ROOT" ]] || { print -u2 -- "mktemp failed"; exit 1; }
trap 'rm -rf "$ROOT"' EXIT INT TERM

PASS=0
FAIL=0
typeset -a RESULTS

ok()  { PASS=$((PASS + 1)); RESULTS+=("PASS  $1"); }
bad() { FAIL=$((FAIL + 1)); RESULTS+=("FAIL  $1 -- $2"); }

new_case() {
  CASE="$ROOT/$1"
  TEST_HOME="$CASE/home"
  TOOLS="$CASE/tools"
  EVENTS="$CASE/events.log"
  SERVICE_STATE="$CASE/service-loaded"
  VAULT="$CASE/vault"
  ORIGIN="$CASE/origin.git"
  AUTHOR="$CASE/author"
  GDIR="$TEST_HOME/.local/state/vault-backup.git"
  mkdir -p "$TOOLS" "$TEST_HOME/.local/bin" "$TEST_HOME/.local/share/vault-backup" \
    "$TEST_HOME/Library/LaunchAgents" "$VAULT"
  : > "$EVENTS"

  cp "$SETUP_SOURCE" "$TEST_HOME/.local/bin/setup-vault-backup"
  cp "$SYNC_SOURCE" "$TEST_HOME/.local/bin/backup-vault.sh"
  cp "$HELPER_SOURCE" "$TEST_HOME/.local/share/vault-backup/vault-backup-helper.c"
  cp "$PLIST_SOURCE" "$TEST_HOME/Library/LaunchAgents/com.user.vault-backup.plist"
  chmod +x "$TEST_HOME/.local/bin/setup-vault-backup" "$TEST_HOME/.local/bin/backup-vault.sh"

  cat > "$TOOLS/gh" <<'MOCK'
#!/bin/zsh
if [[ "$1 ${2:-}" == "auth status" ]]; then
  [[ "${VAULT_SETUP_TEST_GH_AUTH:-yes}" == yes ]]
  exit $?
fi
exit 0
MOCK

  cat > "$TOOLS/clang" <<'MOCK'
#!/bin/zsh
output=""
while (( $# > 0 )); do
  if [[ "$1" == -o && $# -ge 2 ]]; then
    output="$2"
    shift 2
  else
    shift
  fi
done
[[ -n "$output" ]] || exit 1
print -r -- "clang $output" >> "$VAULT_SETUP_TEST_EVENTS"
cat > "$output" <<'HELPER'
#!/bin/zsh
if [[ "${1:-}" == --check && "${VAULT_SETUP_TEST_FDA:-yes}" != yes ]]; then
  print -r -- "preflight pending: the helper cannot read the vault; grant Full Disk Access"
  exit 2
fi
if [[ -z "${1:-}" ]]; then
  case "${VAULT_SETUP_TEST_SYNC_MODE:-real}" in
    lock)
      print -r -- "another run holds the lock; exiting"
      exit 0
      ;;
    hot)
      print -r -- "incoming delta touches recently-edited note.md; deferring integration one cycle"
      exit 0
      ;;
    offline)
      print -r -- "WARN: fetch failed (offline?); skipping integrate, will still attempt push"
      print -r -- "remote up to date; done"
      exit 0
      ;;
  esac
fi
exec /bin/zsh "$HOME/.local/bin/backup-vault.sh" "$@"
HELPER
chmod +x "$output"
MOCK

  cat > "$TOOLS/codesign" <<'MOCK'
#!/bin/zsh
print -r -- "codesign $*" >> "$VAULT_SETUP_TEST_EVENTS"
exit 0
MOCK

  cat > "$TOOLS/launchctl" <<'MOCK'
#!/bin/zsh
print -r -- "launchctl $*" >> "$VAULT_SETUP_TEST_EVENTS"
case "$1" in
  print)
    [[ -f "$VAULT_SETUP_TEST_SERVICE_STATE" ]]
    exit $?
    ;;
  bootstrap)
    : > "$VAULT_SETUP_TEST_SERVICE_STATE"
    exit 0
    ;;
  bootout)
    rm -f "$VAULT_SETUP_TEST_SERVICE_STATE"
    exit 0
    ;;
esac
exit 1
MOCK

  chmod +x "$TOOLS/gh" "$TOOLS/clang" "$TOOLS/codesign" "$TOOLS/launchctl"

  git init -q --bare -b main "$ORIGIN"
  git clone -q "$ORIGIN" "$AUTHOR" 2>/dev/null
  (
    cd "$AUTHOR"
    git config user.name setup-test
    git config user.email setup-test@example.invalid
    git config core.ignorecase false
    git config commit.gpgsign false
    print -r -- "base" > "$VAULT/note.md"
    cp "$VAULT/note.md" "$VAULT/second.md"
    print -r -- "base" > "$AUTHOR/.keep"
    git add -A
    git commit -q -m base
    git push -q -u origin main
  )
  cp "$AUTHOR/.keep" "$VAULT/.keep"
  touch -t 202001010000 "$VAULT"/*(N) 2>/dev/null || true

  export HOME="$TEST_HOME"
  export VAULT_SETUP_TOOLS_PATH="$TOOLS"
  export VAULT_SETUP_TEST_EVENTS="$EVENTS"
  export VAULT_SETUP_TEST_SERVICE_STATE="$SERVICE_STATE"
  export VAULT_BACKUP_WORKTREE="$VAULT"
  export VAULT_BACKUP_GIT_DIR="$GDIR"
  export VAULT_BACKUP_REPO_URL="$ORIGIN"
  export VAULT_BACKUP_BRANCH=main
  export VAULT_BACKUP_MIN_MD=1
  export VAULT_BACKUP_MAX_DELETE=100
  export VAULT_BACKUP_HYDRATE_TIMEOUT=1
  export VAULT_SYNC_QUIESCE=0
  export VAULT_SYNC_DEVICE=setup-test
  export VAULT_SYNC_ALLOW_OBSIDIAN=0
  unset VAULT_SETUP_TEST_FDA VAULT_SETUP_TEST_SYNC_MODE VAULT_SETUP_TEST_GH_AUTH
  unset VAULT_SETUP_TEST_OLD_HELPER_CALLED
}

run_setup() {
  local log_file="$CASE/setup.log"
  /bin/zsh "$TEST_HOME/.local/bin/setup-vault-backup" "$@" > "$log_file" 2>&1
  RC=$?
  OUTPUT="$(cat "$log_file")"
}

has_output() { print -r -- "$OUTPUT" | grep -qF "$1"; }
count_event() { grep -c "$1" "$EVENTS" 2>/dev/null || true; }

home_snapshot() {
  local entry
  while IFS= read -r entry; do
    if [[ -d "$entry" ]]; then
      print -r -- "D ${entry#$TEST_HOME/}"
    elif [[ -f "$entry" ]]; then
      print -r -- "F ${entry#$TEST_HOME/} $(shasum -a 256 "$entry" | awk '{print $1}')"
    elif [[ -L "$entry" ]]; then
      print -r -- "L ${entry#$TEST_HOME/} $(readlink "$entry")"
    fi
  done < <(find "$TEST_HOME" -print | LC_ALL=C sort)
}

echo "=== vault setup suite (scratch home: $ROOT) ==="

# Old helpers ignore --check. A missing hash manifest must prevent invocation before setup rebuilds the helper.
new_case stale-helper
OLD_HELPER_CALLED="$CASE/old-helper-called"
export VAULT_SETUP_TEST_OLD_HELPER_CALLED="$OLD_HELPER_CALLED"
cat > "$TEST_HOME/.local/bin/vault-backup-helper" <<'OLD'
#!/bin/zsh
: > "$VAULT_SETUP_TEST_OLD_HELPER_CALLED"
exit 0
OLD
chmod +x "$TEST_HOME/.local/bin/vault-backup-helper"
run_setup --check
{ [[ "$RC" -eq 2 ]] && has_output "source or binary changed" \
    && [[ ! -e "$OLD_HELPER_CALLED" ]] && [[ "$(count_event '^clang ')" -eq 0 ]]; } \
  && ok "--check never invokes an outdated helper without a hash manifest" \
  || bad "outdated helper --check" "rc=$RC output=[$OUTPUT]"

# FDA denial leaves the helper and history ready for a later run, but never loads the agent.
new_case missing-fda
VAULT_SETUP_TEST_FDA=no run_setup
{ [[ "$RC" -eq 2 ]] && has_output "Full Disk Access" && [[ ! -e "$SERVICE_STATE" ]] \
    && [[ ! -e "$TEST_HOME/.local/state/vault-backup.lock" ]] \
    && [[ ! -e "$TEST_HOME/Library/Logs/vault-backup.log" ]] && [[ -d "$GDIR" ]]; } \
  && ok "missing FDA leaves prepared history pending without a service" \
  || bad "missing FDA" "rc=$RC output=[$OUTPUT]"
VAULT_SETUP_TEST_FDA=yes run_setup
{ [[ "$RC" -eq 0 ]] && has_output "A complete vault sync cycle succeeded" \
    && [[ -e "$SERVICE_STATE" ]] && [[ "$(count_event '^clang ')" -eq 1 ]]; } \
  && ok "granting FDA and rerunning completes setup" \
  || bad "resume after FDA" "rc=$RC output=[$OUTPUT]"

# The live preflight rejects iCloud placeholders and a low file count before sync writes or launchd activation.
new_case placeholder
print -r -- "not hydrated" > "$VAULT/ghost.md.icloud"
run_setup
{ [[ "$RC" -eq 2 ]] && has_output "iCloud placeholders remain" && [[ ! -e "$SERVICE_STATE" ]] \
    && [[ ! -e "$TEST_HOME/.local/state/vault-backup.lock" ]] \
    && [[ ! -e "$TEST_HOME/Library/Logs/vault-backup.log" ]]; } \
  && ok "placeholder vault stays pending without sync or service" \
  || bad "placeholder vault" "rc=$RC output=[$OUTPUT]"

new_case low-markdown
VAULT_BACKUP_MIN_MD=1000 run_setup
{ [[ "$RC" -eq 2 ]] && has_output "only 2 Markdown files are readable" && [[ ! -e "$SERVICE_STATE" ]] \
    && [[ ! -e "$TEST_HOME/.local/state/vault-backup.lock" ]] \
    && [[ ! -e "$TEST_HOME/Library/Logs/vault-backup.log" ]]; } \
  && ok "low Markdown count stays pending without sync or service" \
  || bad "low Markdown count" "rc=$RC output=[$OUTPUT]"

# A zero exit from the sync process is insufficient when it only skipped or could not reach the remote.
new_case incomplete-sync
VAULT_SETUP_TEST_SYNC_MODE=lock run_setup
lock_rc=$RC
lock_output="$OUTPUT"
VAULT_SETUP_TEST_SYNC_MODE=hot run_setup
hot_rc=$RC
hot_output="$OUTPUT"
VAULT_SETUP_TEST_SYNC_MODE=offline run_setup
offline_rc=$RC
offline_output="$OUTPUT"
{ [[ "$lock_rc" -eq 2 ]] && [[ "$hot_rc" -eq 2 ]] && [[ "$offline_rc" -eq 2 ]] \
    && print -r -- "$lock_output" | grep -qF "another run holds the lock" \
    && print -r -- "$hot_output" | grep -qF "deferring integration one cycle" \
    && print -r -- "$offline_output" | grep -qF "fetch failed (offline?)" \
    && [[ ! -e "$SERVICE_STATE" ]] && [[ "$(count_event '^launchctl bootstrap ')" -eq 0 ]]; } \
  && ok "lock, hot-file, and offline cycles do not count as completion" \
  || bad "incomplete sync cycles" "lock=$lock_rc hot=$hot_rc offline=$offline_rc"

unset VAULT_SETUP_TEST_SYNC_MODE
run_setup
{ [[ "$RC" -eq 0 ]] && [[ -e "$SERVICE_STATE" ]] && has_output "A complete vault sync cycle succeeded"; } \
  && ok "a later completed sync enables the agent" \
  || bad "completion after skipped cycles" "rc=$RC output=[$OUTPUT]"

# A content change rebuilds the FDA binary and stops an already-loaded agent until access is rechecked.
print -r -- "/* test-only source change */" >> "$TEST_HOME/.local/share/vault-backup/vault-backup-helper.c"
clang_before_rebuild="$(count_event '^clang ')"
VAULT_SETUP_TEST_FDA=no run_setup
{ [[ "$RC" -eq 2 ]] && has_output "Helper rebuilt" && [[ ! -e "$SERVICE_STATE" ]] \
    && [[ "$(count_event '^clang ')" -eq $((clang_before_rebuild + 1)) ]] \
    && [[ "$(count_event '^launchctl bootout ')" -eq 1 ]]; } \
  && ok "helper content change stops the agent and requires FDA recheck" \
  || bad "helper rebuild FDA gate" "rc=$RC output=[$OUTPUT]"
VAULT_SETUP_TEST_FDA=yes run_setup
{ [[ "$RC" -eq 0 ]] && [[ -e "$SERVICE_STATE" ]] \
    && [[ "$(count_event '^clang ')" -eq $((clang_before_rebuild + 1)) ]]; } \
  && ok "rechecked helper resumes without a second rebuild" \
  || bad "resume after helper rebuild" "rc=$RC output=[$OUTPUT]"

# --check reports a ready setup without changing files, compiling, bootstrapping, or syncing.
before_snapshot="$(home_snapshot)"
before_clang="$(count_event '^clang ')"
before_bootstrap="$(count_event '^launchctl bootstrap ')"
run_setup --check
after_snapshot="$(home_snapshot)"
{ [[ "$RC" -eq 0 ]] && has_output "locally ready: vault is readable" \
    && [[ "$before_snapshot" == "$after_snapshot" ]] \
    && [[ "$(count_event '^clang ')" -eq "$before_clang" ]] \
    && [[ "$(count_event '^launchctl bootstrap ')" -eq "$before_bootstrap" ]]; } \
  && ok "--check is read-only after setup" \
  || bad "read-only --check" "rc=$RC output=[$OUTPUT]"

# Repeated setup keeps detached-Git history and local vault work, and does not rebuild the unchanged helper.
before_commits=$(git --git-dir="$GDIR" rev-list --count HEAD)
print -r -- "local work" > "$VAULT/local-kept.md"
touch -t 202001010000 "$VAULT/local-kept.md"
run_setup
after_commits=$(git --git-dir="$GDIR" rev-list --count HEAD)
{ [[ "$RC" -eq 0 ]] && [[ -f "$VAULT/local-kept.md" ]] \
    && git --git-dir="$GDIR" cat-file -e HEAD:local-kept.md \
    && git --git-dir="$ORIGIN" cat-file -e refs/heads/main:local-kept.md \
    && (( after_commits > before_commits )) \
    && [[ "$(count_event '^clang ')" -eq "$before_clang" ]]; } \
  && ok "reruns preserve local work and Git history without rebuilding" \
  || bad "repeat setup" "rc=$RC before=$before_commits after=$after_commits output=[$OUTPUT]"

echo
echo "=== results ==="
for result in "${RESULTS[@]}"; do print -r -- "  $result"; done
echo
echo "PASS=$PASS  FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
