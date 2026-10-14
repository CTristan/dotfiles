#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
setup_script="$repo_dir/home/dot_local/bin/executable_setup-asf"
backup_script="$repo_dir/home/dot_local/bin/executable_backup-asf-config.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/asf-setup-test.XXXXXX")"
tools="$test_root/tools"
mkdir -m 700 "$tools"

cleanup() {
  /bin/rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  print -u2 -r -- "FAIL: $*"
  exit 1
}

pass() {
  print -r -- "PASS: $*"
}

cat >"$tools/security" <<'MOCK'
#!/bin/zsh
print -r -- "$*" >>"$ASF_TEST_SECURITY_LOG"
if [[ "$1" == find-generic-password ]]; then
  local read_password=0 arg
  for arg in "$@"; do
    [[ "$arg" == -w ]] && read_password=1
  done
  [[ "${ASF_TEST_KEYCHAIN_EXISTS:-1}" == 1 ]] || exit 44
  if (( read_password )); then
    [[ "${ASF_TEST_KEYCHAIN_READABLE:-1}" == 1 ]] || exit 36
    print -r -- "${ASF_TEST_PASSPHRASE:-test-passphrase}"
  fi
  exit 0
fi
if [[ "$1" == add-generic-password ]]; then
  print -r -- "unexpected add request" >>"$ASF_TEST_SECURITY_LOG"
  exit 1
fi
exit 64
MOCK

cat >"$tools/launchctl" <<'MOCK'
#!/bin/zsh
command="$1"
if [[ "$command" == print ]]; then
  label="${2##*/}"
  [[ -f "$ASF_TEST_LAUNCH_STATE/$label" ]] || exit 3
  print -r -- "arguments = {"
  while IFS= read -r argument; do
    print -r -- "  $argument"
  done <"$ASF_TEST_LAUNCH_STATE/$label"
  print -r -- "}"
  exit 0
fi
if [[ "$command" == bootstrap ]]; then
  domain="$2"
  plist="$3"
  label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist")"
  if [[ "${ASF_TEST_REQUIRE_ARCHIVE:-0}" == 1 && "$label" == com.user.archisteamfarm ]]; then
    /usr/bin/find "$ASF_RESTORE_ARCHIVE_DIR" -type f -name SHA256SUMS -print -quit | /usr/bin/grep -q .
    [[ -f "$ASF_DIR/config/ASF.json" ]] || exit 70
  fi
  print -r -- "bootstrap $label $domain" >>"$ASF_TEST_LAUNCH_EVENTS"
  /usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$plist" \
    | /usr/bin/awk 'NR > 1 && $0 !~ /^}/ { sub(/^[[:space:]]+/, ""); print }' \
    >"$ASF_TEST_LAUNCH_STATE/$label"
  exit $?
fi
if [[ "$command" == bootout ]]; then
  label="${2##*/}"
  print -r -- "bootout $label" >>"$ASF_TEST_LAUNCH_EVENTS"
  /bin/rm -f -- "$ASF_TEST_LAUNCH_STATE/$label"
  exit 0
fi
exit 64
MOCK

cat >"$tools/brctl" <<'MOCK'
#!/bin/zsh
if [[ "${ASF_TEST_BRCTL_DELAY:-0}" != 0 ]]; then
  exec /bin/sleep "$ASF_TEST_BRCTL_DELAY"
fi
print -r -- "download $*" >>"$ASF_TEST_BRCTL_LOG"
exit 0
MOCK

cat >"$tools/gh" <<'MOCK'
#!/bin/zsh
if [[ "$1" == release && "$2" == download ]]; then
  : >ASF-osx-arm64.zip
  exit 0
fi
exit 64
MOCK

cat >"$tools/ditto" <<'MOCK'
#!/bin/zsh
[[ "$1" == -xk && "${2:t}" == ASF-osx-arm64.zip ]] || exit 64
mkdir -p "$3/ASF-osx-arm64"
cat >"$3/ASF-osx-arm64/ArchiSteamFarm" <<'BIN'
#!/bin/sh
exit 0
BIN
chmod 700 "$3/ASF-osx-arm64/ArchiSteamFarm"
MOCK
chmod 700 "$tools/security" "$tools/launchctl" "$tools/brctl" "$tools/gh" "$tools/ditto"

reset_case() {
  local name="$1"
  export HOME="$test_root/$name/home"
  mkdir -p "$HOME" "$test_root/$name/tmp"
  mkdir -p "$HOME/.local/bin" "$HOME/.local/share/asf-backup"
  cp -p "$repo_dir/home/dot_local/bin/executable_setup-asf" "$HOME/.local/bin/setup-asf"
  cp -p "$repo_dir/home/dot_local/share/asf-backup/asf-backup.zsh" "$HOME/.local/share/asf-backup/asf-backup.zsh"
  export ASF_DIR="$HOME/ArchiSteamFarm"
  export ASF_BACKUPS_DIR="$HOME/ASF-Backups"
  export ASF_STATE_DIR="$HOME/state"
  export ASF_LOCK_FILE="$ASF_STATE_DIR/asf-config.lock"
  export ASF_RESTORE_ARCHIVE_DIR="$HOME/ASF-Restore-Archives"
  export ASF_LAUNCH_AGENTS_DIR="$HOME/LaunchAgents"
  export ASF_TMP_ROOT="$test_root/$name/tmp"
  export ASF_HYDRATE_TIMEOUT=1
  export ASF_KEEP=14
  export ASF_TOOLS_PATH="$tools"
  export ASF_SECRET_SCRIPT="$HOME/no-setup-asf-secret"
  export ASF_TEST_LAUNCH_STATE="$test_root/$name/loaded"
  export ASF_TEST_LAUNCH_EVENTS="$test_root/$name/launch-events"
  export ASF_TEST_SECURITY_LOG="$test_root/$name/security-events"
  export ASF_TEST_BRCTL_LOG="$test_root/$name/brctl-events"
  export ASF_TEST_KEYCHAIN_EXISTS=1
  export ASF_TEST_KEYCHAIN_READABLE=1
  export ASF_TEST_PASSPHRASE=test-passphrase
  export ASF_TEST_REQUIRE_ARCHIVE=0
  unset ASF_TEST_BRCTL_DELAY ASF_OPENSSL_BIN
  mkdir -p "$ASF_TEST_LAUNCH_STATE"
  : >"$ASF_TEST_LAUNCH_EVENTS"
  : >"$ASF_TEST_SECURITY_LOG"
  : >"$ASF_TEST_BRCTL_LOG"
}

write_plist() {
  local plist_path="$1" label="$2"
  shift 2
  mkdir -p "${plist_path:h}"
  python3 - "$plist_path" "$label" "$@" <<'PY'
import plistlib
import sys
path, label, *arguments = sys.argv[1:]
with open(path, "wb") as stream:
    plistlib.dump(
        {"Label": label, "Umask": 63, "ProgramArguments": arguments},
        stream,
        fmt=plistlib.FMT_XML,
    )
PY
}

write_agents() {
  write_plist "$ASF_LAUNCH_AGENTS_DIR/com.user.archisteamfarm.plist" \
    com.user.archisteamfarm "$ASF_DIR/ArchiSteamFarm" --no-restart --service
  write_plist "$ASF_LAUNCH_AGENTS_DIR/com.user.asf-backup.plist" \
    com.user.asf-backup /bin/zsh "$HOME/.local/bin/backup-asf-config.sh"
}

make_config() {
  mkdir -p "$ASF_DIR/config"
  print -r -- '{"Enabled":true,"SteamLogin":"example"}' >"$ASF_DIR/config/ASF.json"
}

make_binary() {
  mkdir -p "$ASF_DIR"
  cat >"$ASF_DIR/ArchiSteamFarm" <<'BIN'
#!/bin/sh
exit 0
BIN
  chmod 700 "$ASF_DIR/ArchiSteamFarm"
}

make_encrypted_snapshot() {
  local destination="$1" source="$test_root/snapshot-source" plain="$test_root/snapshot.tar.gz"
  /bin/rm -rf -- "$source"
  mkdir -p "$source/config" "${destination:h}"
  print -r -- '{"Enabled":true,"SteamLogin":"restored"}' >"$source/config/ASF.json"
  /usr/bin/tar -czf "$plain" -C "$source" config
  PW="$ASF_TEST_PASSPHRASE" /usr/bin/openssl enc -aes-256-cbc -pbkdf2 -salt \
    -pass env:PW -in "$plain" -out "$destination"
  chmod 600 "$destination"
}

expect_status() {
  local expected="$1" actual
  shift
  if "$@"; then
    actual=0
  else
    actual=$?
  fi
  [[ "$actual" == "$expected" ]] || fail "expected status $expected, got $actual: $*"
}

reset_case check-readonly
security_count_before="$(/usr/bin/wc -l <"$ASF_TEST_SECURITY_LOG")"
expect_status 2 /bin/zsh "$setup_script" --check
[[ ! -e "$ASF_STATE_DIR" ]] || fail "--check created the ASF state directory"
[[ ! -e "$ASF_BACKUPS_DIR" ]] || fail "--check created the backup directory"
security_count_after="$(/usr/bin/wc -l <"$ASF_TEST_SECURITY_LOG")"
[[ "$security_count_before" == "$security_count_after" ]] || fail "--check read Keychain"
pass "setup --check is observational and returns pending without config"

reset_case no-snapshot
expect_status 2 /bin/zsh "$setup_script"
[[ ! -s "$ASF_TEST_LAUNCH_EVENTS" ]] || fail "setup loaded an agent without config or a snapshot"
[[ ! -e "$ASF_DIR/config" ]] || fail "setup created an empty config directory"
[[ ! -s "$ASF_TEST_SECURITY_LOG" ]] || fail "setup read Keychain without a config or snapshot"
[[ -x "$ASF_DIR/ArchiSteamFarm" ]] || fail "setup did not install ASF for initial manual configuration"
[[ -z "$(/usr/bin/find "$ASF_TMP_ROOT" -mindepth 1 -maxdepth 1 -name 'asf-setup.*' -print -quit)" ]] \
  || fail "pending setup left the ASF download staging directory behind"
pass "missing config and snapshot stays pending without enabling agents"

reset_case scalar-config
mkdir -p "$ASF_DIR/config"
print -r -- 'true' >"$ASF_DIR/config/ASF.json"
make_binary
write_agents
expect_status 2 /bin/zsh "$setup_script"
[[ ! -s "$ASF_TEST_LAUNCH_EVENTS" ]] || fail "setup loaded an agent with scalar JSON"
[[ "$(<"$ASF_DIR/config/ASF.json")" == true ]] || fail "setup changed the existing invalid config"
pass "scalar JSON is rejected and existing config is preserved"

reset_case unreadable-keychain
make_config
make_binary
write_agents
export ASF_TEST_KEYCHAIN_READABLE=0
expect_status 2 /bin/zsh "$setup_script"
[[ ! -s "$ASF_TEST_LAUNCH_EVENTS" ]] || fail "setup loaded an agent with unreadable Keychain credentials"
/usr/bin/grep -q 'find-generic-password -s asf-backup$' "$ASF_TEST_SECURITY_LOG" \
  || fail "setup did not perform the metadata-only existence check"
if /usr/bin/grep -q 'add-generic-password' "$ASF_TEST_SECURITY_LOG"; then
  fail "setup attempted to replace an unreadable Keychain item"
fi
pass "unreadable Keychain items are left unchanged"

reset_case bad-snapshot
make_binary
write_agents
mkdir -p "$ASF_BACKUPS_DIR"
print -r -- 'not an encrypted ASF snapshot' >"$ASF_BACKUPS_DIR/asf-config-20200101-000000.tar.gz.enc"
expect_status 1 /bin/zsh "$setup_script"
[[ ! -s "$ASF_TEST_LAUNCH_EVENTS" ]] || fail "setup loaded an agent after restore validation failed"
[[ ! -e "$ASF_DIR/config" ]] || fail "setup installed config from an invalid snapshot"
[[ -z "$(/usr/bin/find "$ASF_DIR" -maxdepth 1 -type d -name '.asf-restore.*' -print -quit)" ]] \
  || fail "setup left plaintext restore staging after decryption failed"
archive_manifest="$(/usr/bin/find "$ASF_RESTORE_ARCHIVE_DIR" -type f -name SHA256SUMS -print -quit)"
[[ -n "$archive_manifest" ]] || fail "setup did not preserve the failed snapshot before restore"
pass "invalid encrypted snapshots are preserved but never restored or activated"

reset_case restore-and-idempotency
make_binary
write_agents
mkdir -p "$ASF_BACKUPS_DIR"
make_encrypted_snapshot "$ASF_BACKUPS_DIR/asf-config-20251001-010101.tar.gz.enc"
export ASF_TEST_REQUIRE_ARCHIVE=1
expect_status 0 /bin/zsh "$setup_script"
[[ -f "$ASF_DIR/config/ASF.json" ]] || fail "validated snapshot was not restored"
[[ "$(/usr/bin/stat -f %Lp "$ASF_DIR")" == 700 ]] || fail "ASF install directory is not private"
[[ "$(/usr/bin/stat -f %Lp "$ASF_DIR/config")" == 700 ]] || fail "restored config directory is not private"
[[ "$(/usr/bin/stat -f %Lp "$ASF_DIR/config/ASF.json")" == 600 ]] || fail "restored ASF.json is not private"
/usr/bin/plutil -convert xml1 -o /dev/null "$ASF_DIR/config/ASF.json" >/dev/null 2>&1 \
  || fail "restored ASF.json is not valid object JSON"
archive_manifest="$(/usr/bin/find "$ASF_RESTORE_ARCHIVE_DIR" -type f -name SHA256SUMS -print -quit)"
[[ -n "$archive_manifest" ]] || fail "restored snapshot has no durable archive manifest"
archived_snapshot="${archive_manifest:h}/asf-config-20251001-010101.tar.gz.enc"
expected_hash="$(/usr/bin/shasum -a 256 "$archived_snapshot" | /usr/bin/awk '{print $1}')"
/usr/bin/grep -Fq "$expected_hash  asf-config-20251001-010101.tar.gz.enc" "$archive_manifest" \
  || fail "archive manifest does not verify the private snapshot copy"
bootstrap_count="$(/usr/bin/grep -c '^bootstrap ' "$ASF_TEST_LAUNCH_EVENTS")"
[[ "$bootstrap_count" == 2 ]] || fail "setup did not load both agents"
archive_count_before="$(/usr/bin/find "$ASF_RESTORE_ARCHIVE_DIR" -type f -name SHA256SUMS | /usr/bin/wc -l)"
expect_status 0 /bin/zsh "$setup_script"
bootstrap_count_after="$(/usr/bin/grep -c '^bootstrap ' "$ASF_TEST_LAUNCH_EVENTS")"
[[ "$bootstrap_count_after" == "$bootstrap_count" ]] || fail "idempotent setup reloaded an unchanged agent"
archive_count_after="$(/usr/bin/find "$ASF_RESTORE_ARCHIVE_DIR" -type f -name SHA256SUMS | /usr/bin/wc -l)"
[[ "$archive_count_after" == "$archive_count_before" ]] || fail "idempotent setup duplicated an archived snapshot"
security_count_before="$(/usr/bin/wc -l <"$ASF_TEST_SECURITY_LOG")"
expect_status 0 /bin/zsh "$setup_script" --check
security_count_after="$(/usr/bin/wc -l <"$ASF_TEST_SECURITY_LOG")"
[[ "$security_count_after" == "$security_count_before" ]] || fail "ready check read the Keychain secret"
pass "restore is staged, archived before activation, and repeat setup leaves agents unchanged"

reset_case existing-config-permissions
make_config
make_binary
write_agents
expect_status 0 /bin/zsh "$setup_script"
[[ "$(/usr/bin/stat -f %Lp "$ASF_DIR")" == 700 ]] || fail "existing ASF install directory is not private"
[[ "$(/usr/bin/stat -f %Lp "$ASF_DIR/config")" == 700 ]] || fail "existing config directory is not private"
[[ "$(/usr/bin/stat -f %Lp "$ASF_DIR/config/ASF.json")" == 600 ]] || fail "existing ASF.json is not private"
pass "existing valid ASF config is secured before service activation"

reset_case archived-newest-with-missing-older-copy
make_binary
write_agents
mkdir -p "$ASF_BACKUPS_DIR" "$ASF_RESTORE_ARCHIVE_DIR/asf-snapshots-seed"
newest_source="$ASF_BACKUPS_DIR/asf-config-20251002-010101.tar.gz.enc"
older_source="$ASF_BACKUPS_DIR/asf-config-20251001-010101.tar.gz.enc"
make_encrypted_snapshot "$newest_source"
make_encrypted_snapshot "$older_source"
cp -p "$newest_source" "$ASF_RESTORE_ARCHIVE_DIR/asf-snapshots-seed/${newest_source:t}"
newest_hash="$(/usr/bin/shasum -a 256 "$newest_source" | /usr/bin/awk '{print $1}')"
print -r -- "$newest_hash  ${newest_source:t}" >"$ASF_RESTORE_ARCHIVE_DIR/asf-snapshots-seed/SHA256SUMS"
chmod 600 "$ASF_RESTORE_ARCHIVE_DIR/asf-snapshots-seed/${newest_source:t}" \
  "$ASF_RESTORE_ARCHIVE_DIR/asf-snapshots-seed/SHA256SUMS"
expect_status 0 /bin/zsh "$setup_script"
[[ -f "$ASF_DIR/config/ASF.json" ]] || fail "setup did not restore a previously archived newest snapshot"
/usr/bin/grep -q 'restored' "$ASF_DIR/config/ASF.json" \
  || fail "setup restored the wrong snapshot after archiving a missing older one"
pass "an existing archive of the newest snapshot remains the restore source when older copies are newly archived"

reset_case bounded-hydration
make_binary
write_agents
mkdir -p "$ASF_BACKUPS_DIR"
print -r -- 'placeholder' >"$ASF_BACKUPS_DIR/unfinished.icloud"
export ASF_TEST_BRCTL_DELAY=8
expect_status 2 /bin/zsh "$setup_script"
[[ ! -s "$ASF_TEST_LAUNCH_EVENTS" ]] || fail "setup loaded an agent while iCloud hydration was pending"
pass "iCloud hydration is bounded and leaves agents disabled while pending"

reset_case backup-keychain-failure
make_config
mkdir -p "$ASF_BACKUPS_DIR"
print -r -- old-snapshot >"$ASF_BACKUPS_DIR/asf-config-20200101-000000.tar.gz.enc"
export ASF_TEST_KEYCHAIN_EXISTS=0
expect_status 1 /bin/zsh "$backup_script"
[[ "$(/usr/bin/find "$ASF_BACKUPS_DIR" -maxdepth 1 -type f -name 'asf-config-*.tar.gz.enc' | /usr/bin/wc -l)" -eq 1 ]] \
  || fail "Keychain failure changed existing snapshots"
pass "backup Keychain failure preserves the existing snapshot set"

reset_case backup-encryption-failure
make_config
mkdir -p "$ASF_BACKUPS_DIR"
print -r -- old-snapshot >"$ASF_BACKUPS_DIR/asf-config-20200101-000000.tar.gz.enc"
cat >"$tools/openssl-fail" <<'FAIL'
#!/bin/sh
exit 1
FAIL
chmod 700 "$tools/openssl-fail"
export ASF_OPENSSL_BIN="$tools/openssl-fail"
expect_status 1 /bin/zsh "$backup_script"
[[ "$(/usr/bin/find "$ASF_BACKUPS_DIR" -maxdepth 1 -type f -name 'asf-config-*.tar.gz.enc' | /usr/bin/wc -l)" -eq 1 ]] \
  || fail "encryption failure changed existing snapshots"
[[ -z "$(/usr/bin/find "$ASF_TMP_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
  || fail "backup encryption failure left plaintext staging behind"
pass "backup encryption failure preserves the existing snapshot set"

reset_case backup-validation-failure
make_config
mkdir -p "$ASF_BACKUPS_DIR"
print -r -- old-snapshot >"$ASF_BACKUPS_DIR/asf-config-20200101-000000.tar.gz.enc"
cat >"$tools/openssl-invalid" <<'INVALID'
#!/bin/sh
output=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = -out ]; then
    shift
    output="$1"
  fi
  shift
done
printf 'invalid snapshot data\n' >"$output"
INVALID
chmod 700 "$tools/openssl-invalid"
export ASF_OPENSSL_BIN="$tools/openssl-invalid"
expect_status 1 /bin/zsh "$backup_script"
[[ "$(/usr/bin/find "$ASF_BACKUPS_DIR" -maxdepth 1 -type f -name 'asf-config-*.tar.gz.enc' | /usr/bin/wc -l)" -eq 1 ]] \
  || fail "snapshot validation failure changed existing snapshots"
[[ -z "$(/usr/bin/find "$ASF_TMP_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
  || fail "snapshot validation failure left plaintext staging behind"
pass "backup validation failure preserves prior snapshots and removes plaintext staging"

reset_case backup-rotation
make_config
mkdir -p "$ASF_BACKUPS_DIR"
export ASF_TEST_PASSPHRASE=$'test-passphrase\n'
for day in {1..15}; do
  print -r -- "old-$day" >"$ASF_BACKUPS_DIR/asf-config-202001$(printf '%02d' "$day")-000000.tar.gz.enc"
done
expect_status 0 /bin/zsh "$backup_script"
snapshot_count="$(/usr/bin/find "$ASF_BACKUPS_DIR" -maxdepth 1 -type f -name 'asf-config-*.tar.gz.enc' | /usr/bin/wc -l)"
[[ "$snapshot_count" -eq 14 ]] || fail "successful backup retained $snapshot_count snapshots instead of 14"
[[ ! -e "$ASF_BACKUPS_DIR/asf-config-20200101-000000.tar.gz.enc" ]] || fail "oldest snapshot was not rotated"
[[ -e "$ASF_BACKUPS_DIR/asf-config-20200103-000000.tar.gz.enc" ]] || fail "newer retained snapshot was removed"
typeset -a published_snapshots=("$ASF_BACKUPS_DIR"/asf-config-*.tar.gz.enc(NOn))
newest_snapshot="${published_snapshots[1]}"
validation="$test_root/backup-rotation/verify"
mkdir -m 700 "$validation"
if ! asf_validation_result="$(/bin/zsh -c 'source "$1"; asf_init_paths; asf_validate_encrypted_snapshot "$2" "$ASF_TEST_PASSPHRASE" "$3"' _ "$repo_dir/home/dot_local/share/asf-backup/asf-backup.zsh" "$newest_snapshot" "$validation")"; then
  fail "published snapshot is not decryptable and valid: $asf_validation_result"
fi
pass "backup publishes a decryptable AES-256-CBC PBKDF2 snapshot before retaining the newest 14"
[[ -x "$ASF_BACKUPS_DIR/setup-asf.sh" && -f "$ASF_BACKUPS_DIR/asf-backup.zsh" ]] \
  || fail "backup did not publish adjacent standalone recovery helpers"
expect_status 2 /bin/zsh "$ASF_BACKUPS_DIR/setup-asf.sh" --check
pass "copied setup script resolves its adjacent recovery library"

reset_case backup-prune-pending
make_config
mkdir -p "$ASF_BACKUPS_DIR"
for day in {1..15}; do
  print -r -- "old-$day" >"$ASF_BACKUPS_DIR/asf-config-202001$(printf '%02d' "$day")-000000.tar.gz.enc"
done
print -r -- 'placeholder' >"$ASF_BACKUPS_DIR/unavailable.icloud"
expect_status 2 /bin/zsh "$backup_script"
snapshot_count="$(/usr/bin/find "$ASF_BACKUPS_DIR" -maxdepth 1 -type f -name 'asf-config-*.tar.gz.enc' | /usr/bin/wc -l)"
[[ "$snapshot_count" -eq 16 ]] || fail "unsafe prune removed old snapshots after publishing the new one"
pass "incomplete iCloud inventory skips pruning and keeps all old snapshots"

print -r -- "All ASF setup and backup tests passed."
