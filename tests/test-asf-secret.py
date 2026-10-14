import json
import os
import pty
import select
import signal
import subprocess
import sys
import tempfile
import termios
import time
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "home/dot_local/bin/executable_setup-asf-secret"
WRITER_SOURCE = REPO / "home/dot_local/share/asf-backup/asf-keychain-write.c"
PASSPHRASE = "synthetic-test-passphrase-$-never-print"
SESSION = "synthetic-test-session-never-print"
TEST_KEYCHAIN_PASSWORD = "synthetic-isolated-keychain-password"

SECURITY_MOCK = r'''#!/bin/zsh
session_state=absent
[[ -n "${BW_SESSION:-}" ]] && session_state=present
print -r -- "$* session=$session_state" >> "$TEST_SECURITY_LOG"
if [[ -f "$TEST_KEYCHAIN_ITEM" ]]; then
  exit 0
fi
exit 44
'''

BW_MOCK = r'''#!/bin/zsh
set -eu
name="$1"
shift
arguments="$*"
session_state=absent
[[ -n "${BW_SESSION:-}" ]] && session_state=present
print -r -- "$name${arguments:+ $arguments} session=$session_state" >> "$TEST_BW_LOG"
case "$name" in
  status)
    if [[ "$session_state" == present ]]; then
      print '{"status":"unlocked"}'
    else
      print -r -- "{\"status\":\"$TEST_BW_INITIAL_STATUS\"}"
    fi
    ;;
  login|unlock)
    print -r -- "$TEST_SESSION"
    ;;
  lock)
    ;;
  sync)
    [[ "${TEST_BW_SYNC_EXIT:-0}" == 0 ]] || exit "$TEST_BW_SYNC_EXIT"
    ;;
  list)
    if [[ "${TEST_BW_MODE:-}" == signal-list ]]; then
      kill -INT "$(<"$TEST_SCRIPT_PID_FILE")"
    fi
    cat "$TEST_ITEMS_JSON"
    ;;
  get)
    cat "$TEST_ITEM_JSON"
    [[ "${TEST_BW_GET_EXIT:-0}" == 0 ]] || exit "$TEST_BW_GET_EXIT"
    ;;
  *)
    exit 1
    ;;
esac
'''

BREW_MOCK = r'''#!/bin/zsh
session_state=absent
[[ -n "${BW_SESSION:-}" ]] && session_state=present
print -r -- "$* session=$session_state" >> "$TEST_BREW_LOG"
[[ "$*" == "install bitwarden-cli" ]] || exit 1
command cp "$TEST_BW_TEMPLATE" "$TEST_MOCK_BIN/bw"
command chmod 700 "$TEST_MOCK_BIN/bw"
'''

CLANG_MOCK = r'''#!/bin/zsh
session_state=absent
[[ -n "${BW_SESSION:-}" ]] && session_state=present
print -r -- "$* session=$session_state" >> "$TEST_CLANG_LOG"
output=''
while (( $# )); do
  if [[ "$1" == -o && $# -ge 2 ]]; then
    output="$2"
    shift
  fi
  shift
done
[[ -n "$output" ]] || exit 1
command cp "$TEST_WRITER_TEMPLATE" "$output"
command chmod 700 "$output"
'''

WRITER_MOCK = r'''#!/bin/zsh
set -eu
session_state=absent
[[ -n "${BW_SESSION:-}" ]] && session_state=present
print -r -- "writer session=$session_state argc=$#" >> "$TEST_WRITER_LOG"
command cat > "$TEST_CAPTURE"
[[ -s "$TEST_CAPTURE" ]] || exit 1
case "${TEST_WRITER_MODE:-success}" in
  duplicate)
    : > "$TEST_KEYCHAIN_ITEM"
    exit 3
    ;;
  failure)
    exit 1
    ;;
  success)
    : > "$TEST_KEYCHAIN_ITEM"
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
'''

KEYCHAIN_CREATE_HELPER = r'''#include <Security/Security.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 3) return 1;
    SecKeychainRef keychain = NULL;
    UInt32 length = (UInt32)strlen(argv[2]);
    OSStatus status = SecKeychainCreate(argv[1], length, argv[2], false, NULL, &keychain);
    if (status == errSecSuccess) {
        status = SecKeychainUnlock(keychain, length, argv[2], true);
    }
    if (keychain != NULL) CFRelease(keychain);
    return status == errSecSuccess ? 0 : 1;
}
'''


class AsfSecretTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asf-secret-test-")
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.writer = self.bin / "asf-keychain-write"
        self.writer_template = self.root / "writer-template"
        self.write_executable(self.writer_template, WRITER_MOCK)
        self.write_executable(self.writer, WRITER_MOCK)
        self.items = self.root / "items.json"
        self.item = self.root / "item.json"
        self.keychain_item = self.root / "keychain-item"
        self.security_log = self.root / "security.log"
        self.bw_log = self.root / "bw.log"
        self.brew_log = self.root / "brew.log"
        self.clang_log = self.root / "clang.log"
        self.writer_log = self.root / "writer.log"
        self.capture = self.root / "writer-input"

        self.write_executable(self.bin / "security", SECURITY_MOCK)
        self.write_executable(self.bin / "bw", BW_MOCK)
        self.write_executable(self.bin / "brew", BREW_MOCK)
        self.write_executable(self.bin / "clang", CLANG_MOCK)

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def write_executable(path, content):
        path.write_text(content)
        path.chmod(0o700)

    def env(self, writer_override=True):
        test_keys = {
            "BW_SESSION",
            "ASF_SECRET_TOOLS_PATH",
            "ASF_KEYCHAIN_WRITER",
            "ASF_KEYCHAIN_WRITER_SOURCE",
        }
        result = {key: value for key, value in os.environ.items() if key not in test_keys}
        result.update(
            {
                "HOME": str(self.home),
                "USER": "asf-test-user",
                "PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
                "ASF_SECRET_TOOLS_PATH": str(self.bin),
                "TEST_KEYCHAIN_ITEM": str(self.keychain_item),
                "TEST_SECURITY_LOG": str(self.security_log),
                "TEST_BW_LOG": str(self.bw_log),
                "TEST_BREW_LOG": str(self.brew_log),
                "TEST_CLANG_LOG": str(self.clang_log),
                "TEST_WRITER_LOG": str(self.writer_log),
                "TEST_CAPTURE": str(self.capture),
                "TEST_WRITER_TEMPLATE": str(self.writer_template),
                "TEST_MOCK_BIN": str(self.bin),
                "TEST_BW_TEMPLATE": str(self.root / "bw-template"),
                "TEST_ITEMS_JSON": str(self.items),
                "TEST_ITEM_JSON": str(self.item),
                "TEST_BW_INITIAL_STATUS": "unauthenticated",
                "TEST_SESSION": SESSION,
                "TEST_WRITER_MODE": "success",
            }
        )
        Path(result["TEST_BW_TEMPLATE"]).write_text(BW_MOCK)
        if writer_override:
            result["ASF_KEYCHAIN_WRITER"] = str(self.writer)
        return result

    def run_script(self, *args, env=None):
        return subprocess.run(
            [str(SCRIPT), *args],
            cwd=REPO,
            env=env or self.env(),
            text=True,
            capture_output=True,
            timeout=10,
        )

    def set_bw_fixture(self, notes, item):
        self.items.write_text(json.dumps(notes))
        self.item.write_text(json.dumps(item))

    def assert_no_sensitive_output(self, result):
        combined = result.stdout + result.stderr
        self.assertNotIn(PASSPHRASE, combined)
        self.assertNotIn(SESSION, combined)

    def test_check_missing_is_read_only_and_does_not_compile(self):
        env = self.env(writer_override=False)
        env["ASF_KEYCHAIN_WRITER_SOURCE"] = str(WRITER_SOURCE)
        result = self.run_script("--check", env=env)

        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse((self.home / ".local").exists())
        self.assertFalse(self.clang_log.exists())
        self.assertFalse(self.bw_log.exists())
        self.assertFalse(self.brew_log.exists())
        self.assertNotIn("-w", self.security_log.read_text())
        self.assert_no_sensitive_output(result)

    def test_check_existing_secret_is_ready_without_bw_or_writer(self):
        self.keychain_item.touch()
        env = self.env(writer_override=False)
        result = self.run_script("--check", env=env)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.clang_log.exists())
        self.assertFalse(self.bw_log.exists())
        self.assertFalse(self.brew_log.exists())
        self.assertFalse(self.writer_log.exists())
        self.assertNotIn("-w", self.security_log.read_text())
        self.assert_no_sensitive_output(result)

    def test_existing_keychain_secret_skips_bw_and_install(self):
        self.keychain_item.touch()
        result = self.run_script(env=self.env())

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.bw_log.exists())
        self.assertFalse(self.brew_log.exists())
        self.assertFalse(self.writer_log.exists())
        self.assert_no_sensitive_output(result)

    def test_noninteractive_missing_secret_is_pending_without_bw_session(self):
        result = self.run_script(env=self.env())

        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse(self.bw_log.exists())
        self.assertFalse(self.brew_log.exists())
        self.assertFalse(self.writer_log.exists())
        self.assert_no_sensitive_output(result)

    def test_import_uses_exact_secure_note_and_hidden_field(self):
        self.set_bw_fixture(
            [
                {"id": "near-match", "name": "dotfiles: ASF backup copy", "type": 2},
                {"id": "login-item", "name": "dotfiles: ASF backup", "type": 1},
                {"id": "exact-note", "name": "dotfiles: ASF backup", "type": 2},
            ],
            {
                "id": "exact-note",
                "name": "dotfiles: ASF backup",
                "type": 2,
                "fields": [
                    {"name": "passphrase", "type": 0, "value": "wrong-field"},
                    {"name": "other", "type": 1, "value": "wrong-name"},
                    {"name": "passphrase", "type": 1, "value": PASSPHRASE},
                ],
            },
        )
        env = self.env(writer_override=False)
        env["ASF_KEYCHAIN_WRITER_SOURCE"] = str(WRITER_SOURCE)
        env["BW_SESSION"] = SESSION
        result = self.run_script(env=env)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.capture.read_bytes(), PASSPHRASE.encode())
        bw_calls = self.bw_log.read_text().splitlines()
        sync_positions = [index for index, call in enumerate(bw_calls) if call.startswith("sync ")]
        self.assertEqual(len(sync_positions), 1)
        self.assertLess(sync_positions[0], next(index for index, call in enumerate(bw_calls) if call.startswith("list ")))
        self.assertIn("get item exact-note", self.bw_log.read_text())
        self.assertNotIn("lock ", self.bw_log.read_text())
        self.assertIn("session=absent", self.writer_log.read_text())
        self.assertTrue(self.clang_log.exists())
        self.assertNotIn("-w", self.security_log.read_text())
        self.assert_no_sensitive_output(result)

    def test_sync_failure_is_pending_without_lookup_or_keychain_writer(self):
        self.set_bw_fixture(
            [{"id": "exact-note", "name": "dotfiles: ASF backup", "type": 2}],
            {
                "id": "exact-note",
                "name": "dotfiles: ASF backup",
                "type": 2,
                "fields": [{"name": "passphrase", "type": 1, "value": PASSPHRASE}],
            },
        )
        env = self.env(writer_override=False)
        env["ASF_KEYCHAIN_WRITER_SOURCE"] = str(WRITER_SOURCE)
        env["BW_SESSION"] = SESSION
        env["TEST_BW_SYNC_EXIT"] = "1"
        result = self.run_script(env=env)

        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("network connectivity", result.stderr)
        bw_calls = self.bw_log.read_text()
        self.assertIn("sync session=present", bw_calls)
        self.assertNotIn("list items", bw_calls)
        self.assertNotIn("get item", bw_calls)
        self.assertFalse(self.writer_log.exists())
        self.assertFalse(self.clang_log.exists())
        self.assertFalse(self.keychain_item.exists())
        self.assert_no_sensitive_output(result)

    def test_import_preserves_trailing_newlines_in_passphrase(self):
        passphrase = "synthetic-passphrase-with-newlines\n\n"
        self.set_bw_fixture(
            [{"id": "exact-note", "name": "dotfiles: ASF backup", "type": 2}],
            {
                "id": "exact-note",
                "name": "dotfiles: ASF backup",
                "type": 2,
                "fields": [{"name": "passphrase", "type": 1, "value": passphrase}],
            },
        )
        env = self.env()
        env["BW_SESSION"] = SESSION
        result = self.run_script(env=env)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.capture.read_bytes(), passphrase.encode())
        self.assert_no_sensitive_output(result)

    def test_duplicate_secure_notes_are_rejected_before_get(self):
        self.set_bw_fixture(
            [
                {"id": "one", "name": "dotfiles: ASF backup", "type": 2},
                {"id": "two", "name": "dotfiles: ASF backup", "type": 2},
            ],
            {"fields": []},
        )
        env = self.env()
        env["BW_SESSION"] = SESSION
        result = self.run_script(env=env)

        self.assertEqual(result.returncode, 1)
        self.assertNotIn("get item", self.bw_log.read_text())
        self.assertFalse(self.writer_log.exists())
        self.assert_no_sensitive_output(result)

    def test_missing_hidden_field_is_rejected_without_keychain_write(self):
        self.set_bw_fixture(
            [{"id": "exact-note", "name": "dotfiles: ASF backup", "type": 2}],
            {
                "id": "exact-note",
                "name": "dotfiles: ASF backup",
                "type": 2,
                "fields": [{"name": "passphrase", "type": 0, "value": PASSPHRASE}],
            },
        )
        env = self.env()
        env["BW_SESSION"] = SESSION
        result = self.run_script(env=env)

        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.keychain_item.exists())
        self.assertFalse(self.writer_log.exists())
        self.assert_no_sensitive_output(result)

    def test_empty_hidden_field_is_rejected(self):
        self.set_bw_fixture(
            [{"id": "exact-note", "name": "dotfiles: ASF backup", "type": 2}],
            {
                "id": "exact-note",
                "name": "dotfiles: ASF backup",
                "type": 2,
                "fields": [{"name": "passphrase", "type": 1, "value": ""}],
            },
        )
        env = self.env()
        env["BW_SESSION"] = SESSION
        result = self.run_script(env=env)

        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.keychain_item.exists())
        self.assertFalse(self.writer_log.exists())
        self.assert_no_sensitive_output(result)

    def test_ambiguous_hidden_fields_are_rejected_even_if_one_is_empty(self):
        self.set_bw_fixture(
            [{"id": "exact-note", "name": "dotfiles: ASF backup", "type": 2}],
            {
                "id": "exact-note",
                "name": "dotfiles: ASF backup",
                "type": 2,
                "fields": [
                    {"name": "passphrase", "type": 1, "value": ""},
                    {"name": "passphrase", "type": 1, "value": PASSPHRASE},
                ],
            },
        )
        env = self.env()
        env["BW_SESSION"] = SESSION
        result = self.run_script(env=env)

        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.keychain_item.exists())
        self.assertFalse(self.writer_log.exists())
        self.assert_no_sensitive_output(result)

    def test_retrieved_note_metadata_must_match_selected_note(self):
        base = {
            "id": "exact-note",
            "name": "dotfiles: ASF backup",
            "type": 2,
            "fields": [{"name": "passphrase", "type": 1, "value": PASSPHRASE}],
        }
        for field, value in (("id", "different-id"), ("name", "different-name"), ("type", 1)):
            with self.subTest(field=field):
                self.keychain_item.unlink(missing_ok=True)
                self.writer_log.unlink(missing_ok=True)
                self.set_bw_fixture(
                    [{"id": "exact-note", "name": "dotfiles: ASF backup", "type": 2}],
                    {**base, field: value},
                )
                env = self.env()
                env["BW_SESSION"] = SESSION
                result = self.run_script(env=env)

                self.assertEqual(result.returncode, 1)
                self.assertFalse(self.keychain_item.exists())
                self.assertFalse(self.writer_log.exists())
                self.assert_no_sensitive_output(result)

    def test_failed_get_that_prints_valid_json_never_reaches_writer(self):
        self.set_bw_fixture(
            [{"id": "exact-note", "name": "dotfiles: ASF backup", "type": 2}],
            {
                "id": "exact-note",
                "name": "dotfiles: ASF backup",
                "type": 2,
                "fields": [{"name": "passphrase", "type": 1, "value": PASSPHRASE}],
            },
        )
        env = self.env()
        env["BW_SESSION"] = SESSION
        env["TEST_BW_GET_EXIT"] = "1"
        result = self.run_script(env=env)

        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.keychain_item.exists())
        self.assertFalse(self.writer_log.exists())
        self.assert_no_sensitive_output(result)

    def test_duplicate_keychain_add_does_not_overwrite(self):
        self.set_bw_fixture(
            [{"id": "exact-note", "name": "dotfiles: ASF backup", "type": 2}],
            {
                "id": "exact-note",
                "name": "dotfiles: ASF backup",
                "type": 2,
                "fields": [{"name": "passphrase", "type": 1, "value": PASSPHRASE}],
            },
        )
        env = self.env()
        env["BW_SESSION"] = SESSION
        env["TEST_WRITER_MODE"] = "duplicate"
        result = self.run_script(env=env)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.keychain_item.exists())
        self.assertEqual(len(self.writer_log.read_text().splitlines()), 1)
        self.assertNotIn("-U", self.writer_log.read_text())
        self.assert_no_sensitive_output(result)

    def test_selected_import_installs_bw_and_locks_owned_session_on_failure(self):
        self.set_bw_fixture([], {"fields": []})
        (self.bin / "bw").unlink()
        env = self.env()
        env["TEST_BW_INITIAL_STATUS"] = "unauthenticated"

        result = self.run_tty([str(SCRIPT)], env, b"b\n")

        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.brew_log.read_text().strip(), "install bitwarden-cli session=absent")
        bw_calls = self.bw_log.read_text()
        self.assertIn("login --raw session=absent", bw_calls)
        self.assertIn("lock session=present", bw_calls)
        self.assertNotIn(SESSION, bw_calls)
        self.assertFalse(self.writer_log.exists())
        self.assert_no_sensitive_output(result)

    def test_interrupt_locks_only_the_owned_session(self):
        self.set_bw_fixture([], {"fields": []})
        env = self.env()
        env["TEST_BW_INITIAL_STATUS"] = "unauthenticated"
        env["TEST_BW_MODE"] = "signal-list"
        env["TEST_SCRIPT_PID_FILE"] = str(self.root / "script.pid")

        result = self.run_tty([str(SCRIPT)], env, b"b\n")

        self.assertEqual(result.returncode, 130, result.stderr)
        self.assertIn("lock session=present", self.bw_log.read_text())
        self.assert_no_sensitive_output(result)

    def test_caller_owned_session_is_not_locked_and_is_not_inherited_by_writer(self):
        self.set_bw_fixture(
            [{"id": "exact-note", "name": "dotfiles: ASF backup", "type": 2}],
            {
                "id": "exact-note",
                "name": "dotfiles: ASF backup",
                "type": 2,
                "fields": [{"name": "passphrase", "type": 1, "value": PASSPHRASE}],
            },
        )
        env = self.env()
        env["BW_SESSION"] = SESSION
        result = self.run_script(env=env)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("lock ", self.bw_log.read_text())
        self.assertIn("session=absent", self.writer_log.read_text())
        self.assert_no_sensitive_output(result)

    @unittest.skipUnless(sys.platform == "darwin", "Security.framework is available only on macOS")
    def test_real_helper_adds_to_an_isolated_keychain_and_never_overwrites(self):
        keychain = self.root / "isolated.keychain-db"
        binary = self.root / "asf-keychain-write"
        keychain_setup_source = self.root / "create-keychain.c"
        keychain_setup = self.root / "create-keychain"
        isolated_home = self.root / "security-home"
        isolated_home.mkdir()
        env = {
            "HOME": str(isolated_home),
            "USER": "asf-test-user",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        }
        keychain_setup_source.write_text(KEYCHAIN_CREATE_HELPER)
        create_compile = subprocess.run(
            [
                "/usr/bin/clang",
                "-Wno-deprecated-declarations",
                "-o",
                str(keychain_setup),
                str(keychain_setup_source),
                "-framework",
                "Security",
                "-framework",
                "CoreFoundation",
            ],
            env=env,
            capture_output=True,
            timeout=30,
        )
        self.assertEqual(create_compile.returncode, 0, create_compile.stderr.decode(errors="replace"))
        create = subprocess.run(
            [str(keychain_setup), str(keychain), TEST_KEYCHAIN_PASSWORD],
            env=env,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(create.returncode, 0, create.stderr.decode(errors="replace"))

        production_build = subprocess.run(
            [
                "/usr/bin/clang",
                "-O2",
                "-Wall",
                "-Wextra",
                "-Wno-deprecated-declarations",
                "-o",
                str(self.root / "asf-keychain-write-production-build"),
                str(WRITER_SOURCE),
                "-framework",
                "Security",
                "-framework",
                "CoreFoundation",
            ],
            env=env,
            capture_output=True,
            timeout=30,
        )
        self.assertEqual(production_build.returncode, 0, production_build.stderr.decode(errors="replace"))

        macro = f'-DASF_TEST_KEYCHAIN_PATH="{keychain}"'
        compile_result = subprocess.run(
            [
                "/usr/bin/clang",
                "-O2",
                "-Wall",
                "-Wextra",
                "-Wno-deprecated-declarations",
                macro,
                "-o",
                str(binary),
                str(WRITER_SOURCE),
                "-framework",
                "Security",
                "-framework",
                "CoreFoundation",
            ],
            env=env,
            capture_output=True,
            timeout=30,
        )
        self.assertEqual(compile_result.returncode, 0, compile_result.stderr.decode(errors="replace"))

        first = subprocess.run([str(binary)], input=PASSPHRASE.encode(), env=env, capture_output=True, timeout=10)
        self.assertEqual(first.returncode, 0, first.stderr.decode(errors="replace"))
        self.assert_helper_restores_terminal_echo(binary, env)
        replacement = subprocess.run(
            [str(binary)], input=b"replacement-must-not-win", env=env, capture_output=True, timeout=10
        )
        self.assertEqual(replacement.returncode, 3, replacement.stderr.decode(errors="replace"))
        readback = subprocess.run(
            [
                "/usr/bin/security",
                "find-generic-password",
                "-s",
                "asf-backup",
                "-a",
                "asf-test-user",
                "-w",
                str(keychain),
            ],
            env=env,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(readback.returncode, 0, readback.stderr.decode(errors="replace"))
        self.assertEqual(readback.stdout.rstrip(b"\n"), PASSPHRASE.encode())
        self.assertNotIn(PASSPHRASE.encode(), first.stdout + first.stderr + replacement.stdout + replacement.stderr)
        self.assertNotIn(TEST_KEYCHAIN_PASSWORD.encode(), create.stdout + create.stderr)

    def assert_helper_restores_terminal_echo(self, binary, env):
        pid, master = pty.fork()
        if pid == 0:
            os.execve(str(binary), [str(binary)], env)
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.05)
                if ready:
                    try:
                        os.read(master, 4096)
                    except OSError:
                        break
                try:
                    terminal = termios.tcgetattr(master)
                    break
                except (OSError, termios.error):
                    continue
            else:
                self.fail("Keychain writer did not configure its terminal")

            self.assertEqual(terminal[3] & termios.ECHO, 0, "terminal echo should be disabled while reading")
            os.kill(pid, signal.SIGTERM)
            deadline = time.monotonic() + 5
            status = None
            while status is None and time.monotonic() < deadline:
                waited, child_status = os.waitpid(pid, os.WNOHANG)
                if waited == pid:
                    status = child_status
                else:
                    time.sleep(0.02)
            if status is None:
                os.kill(pid, signal.SIGKILL)
                _, status = os.waitpid(pid, 0)
                self.fail("Keychain writer did not exit after SIGTERM")
            self.assertEqual(os.waitstatus_to_exitcode(status), 143)
            restored = termios.tcgetattr(master)
            self.assertNotEqual(restored[3] & termios.ECHO, 0, "terminal echo must be restored on SIGTERM")
        finally:
            os.close(master)

    def run_tty(self, command, env, input_bytes):
        pid, master = pty.fork()
        if pid == 0:
            os.chdir(REPO)
            os.execve(command[0], command, env)
        pid_file = env.get("TEST_SCRIPT_PID_FILE")
        if pid_file:
            Path(pid_file).write_text(str(pid))
        output = bytearray()
        try:
            os.write(master, input_bytes)
            deadline = time.monotonic() + 8
            status = None
            while status is None and time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    try:
                        output.extend(os.read(master, 4096))
                    except OSError:
                        break
                waited, child_status = os.waitpid(pid, os.WNOHANG)
                if waited == pid:
                    status = child_status
            if status is None:
                os.kill(pid, signal.SIGKILL)
                _, status = os.waitpid(pid, 0)
                self.fail("setup-asf-secret did not finish in the test terminal")
            while True:
                try:
                    ready, _, _ = select.select([master], [], [], 0)
                    if not ready:
                        break
                    chunk = os.read(master, 4096)
                    if not chunk:
                        break
                    output.extend(chunk)
                except OSError:
                    break
        finally:
            os.close(master)
        return subprocess.CompletedProcess(
            command,
            os.waitstatus_to_exitcode(status),
            output.decode(errors="replace"),
            "",
        )


if __name__ == "__main__":
    unittest.main()
