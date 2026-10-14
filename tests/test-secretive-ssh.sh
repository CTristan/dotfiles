#!/bin/bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHEZMOI_BIN="$(command -v chezmoi || true)"
SSH_BIN="$(command -v ssh || true)"
PYTHON_BIN="$(command -v python3 || true)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

[ -n "$CHEZMOI_BIN" ] || fail 'chezmoi is required for the scratch render test'
[ -n "$SSH_BIN" ] || fail 'OpenSSH client is required for effective-configuration checks'
[ -n "$PYTHON_BIN" ] || fail 'python3 is required to clean the scratch directory'

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/secretive-ssh-test.XXXXXX")"
cleanup() {
  "$PYTHON_BIN" - "$TEST_ROOT" <<'PY'
import shutil
import sys

shutil.rmtree(sys.argv[1], ignore_errors=True)
PY
}
trap cleanup EXIT

SOURCE_ROOT="$TEST_ROOT/source"
mkdir -p "$SOURCE_ROOT/private_dot_ssh"
cp "$ROOT/home/private_dot_ssh/modify_config" "$SOURCE_ROOT/private_dot_ssh/modify_config"
CONFIG_FILE="$TEST_ROOT/chezmoi.toml"
printf '# empty test config\n' > "$CONFIG_FILE"

apply_config() {
  local test_home="$1"
  mkdir -p "$test_home"
  HOME="$test_home" "$CHEZMOI_BIN" \
    --source "$SOURCE_ROOT" \
    --destination "$test_home" \
    --config "$CONFIG_FILE" \
    --cache "$TEST_ROOT/cache" \
    --persistent-state "$TEST_ROOT/state" \
    apply --force --no-tty
}

ssh_value() {
  local config="$1" host="$2" key="$3"
  "$SSH_BIN" -G -F "$config" "$host" 2>/dev/null \
    | awk -v key="$key" '$1 == key { print $2; exit }'
}

assert_value() {
  local actual="$1" expected="$2" label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected [$expected], got [$actual]"
}

file_mode() {
  "$PYTHON_BIN" - "$1" <<'PY'
import os
import stat
import sys

print(f"{stat.S_IMODE(os.stat(sys.argv[1]).st_mode):04o}")
PY
}

# A new machine gets a usable default while SSH expands ~ to the current user's home.
FRESH_HOME="$TEST_ROOT/fresh-home"
apply_config "$FRESH_HOME"
FRESH_CONFIG="$FRESH_HOME/.ssh/config"
[ -f "$FRESH_CONFIG" ] || fail 'chezmoi did not create ~/.ssh/config on a fresh machine'
[ "$(file_mode "$FRESH_HOME/.ssh")" = 0700 ] || fail "fresh ~/.ssh directory is not private (mode $(file_mode "$FRESH_HOME/.ssh"))"
grep -qxF '# >>> chezmoi managed Secretive SSH agent >>>' "$FRESH_CONFIG" || fail 'managed block start marker is missing'
grep -qxF 'Host *' "$FRESH_CONFIG" || fail 'managed agent setting is not in a Host * block'
grep -qxF '    IdentityAgent ~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh' "$FRESH_CONFIG" || fail 'Secretive socket path is not home-relative'
FRESH_EFFECTIVE="$(ssh_value "$FRESH_CONFIG" github.com identityagent)"
EXPECTED_EFFECTIVE="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
assert_value "$FRESH_EFFECTIVE" "$EXPECTED_EFFECTIVE" 'fresh default IdentityAgent'
pass 'fresh config uses Secretive for hosts without an explicit agent'

# The managed region moves to the end on rerun and never duplicates itself.
cp "$FRESH_CONFIG" "$TEST_ROOT/fresh-before-repeat"
apply_config "$FRESH_HOME"
cmp -s "$TEST_ROOT/fresh-before-repeat" "$FRESH_CONFIG" || fail 'reapplying the managed block changed the config'
[ "$(grep -cF '# >>> chezmoi managed Secretive SSH agent >>>' "$FRESH_CONFIG")" -eq 1 ] || fail 'reapplying duplicated the managed block'
pass 'repeated chezmoi apply is idempotent'

# Existing aliases, includes, Match rules, and machine-local values stay intact.
EXISTING_HOME="$TEST_ROOT/existing-home"
mkdir -p "$EXISTING_HOME/.ssh"
chmod 700 "$EXISTING_HOME/.ssh"
cat > "$EXISTING_HOME/.ssh/config" <<EOF
# machine-local ssh settings
Include $EXISTING_HOME/.ssh/machine-local.conf

Host workbox.example
    HostName 192.0.2.17
    User admin
    Port 2222
    IdentityAgent /tmp/workbox-agent.sock

Match host *.corp.example
    User corpuser
EOF
cat > "$EXISTING_HOME/.ssh/machine-local.conf" <<'EOF'
Host office
    HostName office.internal
    User officeuser
    Port 2200
EOF
printf 'private key sentinel\n' > "$EXISTING_HOME/.ssh/id_ed25519"
chmod 600 "$EXISTING_HOME/.ssh/id_ed25519"
apply_config "$EXISTING_HOME"
EXISTING_CONFIG="$EXISTING_HOME/.ssh/config"
[ "$(file_mode "$EXISTING_HOME/.ssh")" = 0700 ] || fail "existing ~/.ssh directory mode changed from 700 (now $(file_mode "$EXISTING_HOME/.ssh"))"
[ "$(file_mode "$EXISTING_HOME/.ssh/id_ed25519")" = 0600 ] || fail 'existing private key permissions changed'
grep -qxF 'private key sentinel' "$EXISTING_HOME/.ssh/id_ed25519" || fail 'existing private key contents changed'
pass 'fresh and existing ~/.ssh stay mode 700; existing private keys stay mode 600 and intact'
grep -qxF "Include $EXISTING_HOME/.ssh/machine-local.conf" "$EXISTING_CONFIG" || fail 'existing Include directive was changed'
grep -qxF 'Match host *.corp.example' "$EXISTING_CONFIG" || fail 'existing Match section was changed'
grep -qxF '    IdentityAgent /tmp/workbox-agent.sock' "$EXISTING_CONFIG" || fail 'machine-local host override was changed'

assert_value "$(ssh_value "$EXISTING_CONFIG" workbox.example user)" admin 'existing Host user'
assert_value "$(ssh_value "$EXISTING_CONFIG" workbox.example port)" 2222 'existing Host port'
assert_value "$(ssh_value "$EXISTING_CONFIG" workbox.example identityagent)" /tmp/workbox-agent.sock 'existing Host agent override'
assert_value "$(ssh_value "$EXISTING_CONFIG" office user)" officeuser 'included Host user'
assert_value "$(ssh_value "$EXISTING_CONFIG" office port)" 2200 'included Host port'
assert_value "$(ssh_value "$EXISTING_CONFIG" office identityagent)" "$EXPECTED_EFFECTIVE" 'default agent after Include'
assert_value "$(ssh_value "$EXISTING_CONFIG" build.corp.example user)" corpuser 'existing Match user'
assert_value "$(ssh_value "$EXISTING_CONFIG" build.corp.example identityagent)" "$EXPECTED_EFFECTIVE" 'default agent after Match'
assert_value "$(ssh_value "$EXISTING_CONFIG" github.com identityagent)" "$EXPECTED_EFFECTIVE" 'default agent after existing sections'
pass 'Host, Match, Include, and machine-local SSH settings remain effective'

# An earlier user choice wins by OpenSSH precedence; bootstrap must leave setup pending.
CONFLICT_HOME="$TEST_ROOT/conflict-home"
mkdir -p "$CONFLICT_HOME/.ssh"
cat > "$CONFLICT_HOME/.ssh/config" <<'EOF'
Host github.com
    User git
    IdentityAgent /tmp/user-selected-agent.sock
EOF
apply_config "$CONFLICT_HOME"
CONFLICT_CONFIG="$CONFLICT_HOME/.ssh/config"
assert_value "$(ssh_value "$CONFLICT_CONFIG" github.com identityagent)" /tmp/user-selected-agent.sock 'preserved GitHub override'
SOCKET="$CONFLICT_HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
mkdir -p "$(dirname "$SOCKET")"
SOCKET_TARGET="$TEST_ROOT/agent.sock"
"$PYTHON_BIN" - "$SOCKET_TARGET" <<'PY'
import socket
import sys

sock = socket.socket(socket.AF_UNIX)
sock.bind(sys.argv[1])
sock.close()
PY
ln -s "$SOCKET_TARGET" "$SOCKET"
STATUS_OUTPUT="$TEST_ROOT/secretive-status.log"
set +e
(
  export HOME="$CONFLICT_HOME"
  # The bootstrap library only declares functions while it is sourced.
  # shellcheck source=../scripts/bootstrap-lib.sh
  . "$ROOT/scripts/bootstrap-lib.sh"
  secretive_ssh_status
) > "$STATUS_OUTPUT" 2>&1
STATUS_RC=$?
set -e
[ "$STATUS_RC" -eq 2 ] || fail "conflicting IdentityAgent should report pending (exit 2), got $STATUS_RC"
grep -qF 'overrides Secretive' "$STATUS_OUTPUT" || fail 'bootstrap did not explain the preserved IdentityAgent override'
grep -qxF '    IdentityAgent /tmp/user-selected-agent.sock' "$CONFLICT_CONFIG" || fail "bootstrap check changed the user's SSH setting"
pass 'conflicting earlier IdentityAgent stays preserved and bootstrap reports pending'

printf 'PASS: Secretive SSH config tests complete\n'
