#!/usr/bin/env python3
"""Exercise bootstrap failure handling without changing the host."""
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="dfboot-", dir="/tmp")
        self.addCleanup(self.scratch.cleanup)
        self.home = Path(self.scratch.name)
        self.bin = self.home / "tools"
        self.bin.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), PATH=f"{self.bin}:/usr/bin:/bin", REPO_DIR=str(ROOT))
        for name in ("BW_SESSION", "GH_TOKEN", "GITHUB_TOKEN"):
            self.env.pop(name, None)

    def tool(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body + "\n")
        path.chmod(0o755)

    def run_stage(self, body, check=0):
        setup = f'CHECK={check}; NO_BITWARDEN=0; clt_ready=1; brew_ready=1; source "$REPO_DIR/scripts/bootstrap-lib.sh"; interactive() {{ return 1; }}; '
        return subprocess.run(["/bin/bash", "-c", setup + body], env=self.env, capture_output=True, text=True)

    def test_argument_validation_and_help_do_not_touch_home(self):
        before = sorted(self.home.rglob("*"))
        for args, code in ((["--help"], 0), (["--skip", "invalid"], 1), (["--skip"], 1), (["--invalid"], 1)):
            result = subprocess.run(["/bin/bash", str(ROOT / "bootstrap"), *args], env=self.env, capture_output=True)
            self.assertEqual(result.returncode, code, result.stderr)
        self.assertEqual(before, sorted(self.home.rglob("*")))

    def test_read_only_run_has_no_installs_auth_signing_or_apply(self):
        self.tool("uname", 'if [ "$1" = -s ]; then echo Darwin; else echo arm64; fi')
        self.tool("xcode-select", 'exit 0')
        self.tool("xcrun", 'echo /usr/bin/clang')
        self.tool("brew", 'if [ "$1" = list ]; then exit 0; fi; echo FORBIDDEN >&2; exit 99')
        self.tool("chezmoi", 'case "$1" in source-path) echo "$REPO_DIR/home";; execute-template) echo "$HOME/.config/chezmoi/chezmoi.toml";; --source) [ "$3" = status ] || exit 99;; *) exit 99;; esac')
        self.tool("gh", '[ "$1 $2" = "auth status" ] || exit 99; exit 1')
        for command in ("bw", "open", "launchctl", "security", "ssh-keygen"):
            self.tool(command, 'echo FORBIDDEN >&2; exit 99')
        self.env["DOTFILES_TOOLS_PATH"] = str(self.bin)
        before = {str(p): p.read_bytes() for p in self.home.rglob("*") if p.is_file()}
        result = subprocess.run(["/bin/bash", str(ROOT / "bootstrap"), "--check", "--skip", "asf,vault,runtimes"], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertNotIn("FORBIDDEN", result.stdout + result.stderr)
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.home.rglob("*") if p.is_file()})

    def test_config_migration_preserves_unrelated_settings_and_private_backup(self):
        config = self.home / ".config/chezmoi/chezmoi.toml"
        config.parent.mkdir(parents=True)
        original = '[data]\nkeep = "value"\n[bitwarden]\nunlock = "auto"\n[edit]\ncommand = "code"\n[git]\nautoCommit = true\n'
        config.write_text(original)
        config.chmod(0o600)
        self.tool("chezmoi", 'echo "$HOME/.config/chezmoi/chezmoi.toml"')
        result = self.run_stage("migrate_chezmoi_config")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(config.read_text(), '[data]\nkeep = "value"\n[edit]\ncommand = "code"\n[git]\nautoCommit = true\n')
        backups = list(config.parent.glob("*.before-bootstrap-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), original)
        self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)
        second = self.run_stage("migrate_chezmoi_config")
        self.assertEqual(second.returncode, 0)
        self.assertEqual(len(list(config.parent.glob("*.before-bootstrap-*"))), 1)

    def test_config_check_is_read_only(self):
        config = self.home / ".config/chezmoi/chezmoi.toml"
        config.parent.mkdir(parents=True)
        config.write_text('[bitwarden]\nunlock = "auto"\n[edit]\ncommand = "code"\n')
        self.tool("chezmoi", 'echo "$HOME/.config/chezmoi/chezmoi.toml"')
        original = config.read_bytes()
        result = self.run_stage("migrate_chezmoi_config", check=1)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(config.read_bytes(), original)
        self.assertEqual(len(list(config.parent.iterdir())), 1)

    def test_local_conflict_does_not_force_apply_or_reset(self):
        self.tool("chezmoi", 'case "$1" in execute-template) echo "$HOME/.config/chezmoi/chezmoi.toml";; --source) case "$3" in init|diff) exit 0;; apply) echo conflict >&2; exit 1;; *) exit 99;; esac;; *) exit 99;; esac')
        config = self.home / ".config/chezmoi/chezmoi.toml"
        config.parent.mkdir(parents=True)
        config.write_text('[edit]\ncommand = "code"\n')
        zshrc = self.home / ".zshrc"
        zshrc.write_text("local changes\n")
        result = self.run_stage("dotfiles_setup")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(zshrc.read_text(), "local changes\n")
        self.assertNotIn("--force", (ROOT / "scripts/bootstrap-lib.sh").read_text())

    def test_shell_install_reuses_existing_files(self):
        omz = self.home / ".oh-my-zsh"
        theme = omz / "themes/dracula-src"
        theme.mkdir(parents=True)
        (omz / "oh-my-zsh.sh").write_text("original shell framework\n")
        (theme / "dracula.zsh-theme").write_text("original theme\n")
        zshrc = self.home / ".zshrc"
        zshrc.write_text("preserve my shell\n")
        self.tool("git", 'echo FORBIDDEN >&2; exit 99')
        result = self.run_stage("shell_setup")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(zshrc.read_text(), "preserve my shell\n")
        self.assertTrue((omz / "themes/dracula.zsh-theme").is_symlink())
        result = self.run_stage("shell_setup")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_pending_component_does_not_prevent_independent_component(self):
        body = 'pending=0; failed=0; report() { printf "%s %s\\n" "$1" "$2"; }; first() { return 2; }; second() { echo independent-complete; }; run_component first first; run_component second second'
        result = self.run_stage(body)
        self.assertEqual(result.returncode, 0)
        self.assertIn("first pending", result.stdout)
        self.assertIn("independent-complete", result.stdout)
        self.assertIn("second complete", result.stdout)

    def test_no_bitwarden_option_reaches_importer_and_blocks_activation_on_failure(self):
        local_bin = self.home / ".local/bin"
        local_bin.mkdir(parents=True)
        secret = local_bin / "setup-asf-secret"
        secret.write_text('#!/bin/bash\n[ "$1" = --no-bitwarden ] || exit 99\necho manual-entry-selected\nexit 2\n')
        secret.chmod(0o755)
        setup = local_bin / "setup-asf"
        setup.write_text('#!/bin/bash\necho FORBIDDEN >&2\nexit 99\n')
        setup.chmod(0o755)
        fixture = self.home / "fixture-repo/home/dot_local/bin"
        fixture.mkdir(parents=True)
        (fixture / "executable_setup-asf-secret").write_bytes(secret.read_bytes())
        (fixture / "executable_setup-asf").write_bytes(setup.read_bytes())
        local_share = self.home / ".local/share/asf-backup"
        local_share.mkdir(parents=True)
        (local_share / "asf-backup.zsh").write_text("fixture-library\n")
        fixture_share = fixture.parent / "share/asf-backup"
        fixture_share.mkdir(parents=True)
        (fixture_share / "asf-backup.zsh").write_text("fixture-library\n")
        self.env["REPO_DIR"] = str(fixture.parents[2])
        self.env["BOOTSTRAP_LIB"] = str(ROOT / "scripts/bootstrap-lib.sh")
        result = subprocess.run(["/bin/bash", "-c", 'CHECK=0; NO_BITWARDEN=1; source "$BOOTSTRAP_LIB"; asf_setup'], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("manual-entry-selected", result.stdout)
        self.assertNotIn("FORBIDDEN", result.stdout + result.stderr)

    def test_stale_deployed_asf_library_never_invokes_helpers(self):
        local_bin = self.home / ".local/bin"
        local_bin.mkdir(parents=True)
        fixture = self.home / "fixture-repo/home/dot_local/bin"
        fixture.mkdir(parents=True)
        for name in ("setup-asf-secret", "setup-asf"):
            deployed = local_bin / name
            deployed.write_text('#!/bin/bash\necho FORBIDDEN >&2\nexit 99\n')
            deployed.chmod(0o755)
            (fixture / f"executable_{name}").write_bytes(deployed.read_bytes())
        fixture_share = fixture.parent / "share/asf-backup"
        fixture_share.mkdir(parents=True)
        (fixture_share / "asf-backup.zsh").write_text("current-library\n")
        local_share = self.home / ".local/share/asf-backup"
        local_share.mkdir(parents=True)
        (local_share / "asf-backup.zsh").write_text("stale-library\n")
        self.env["REPO_DIR"] = str(fixture.parents[2])
        self.env["BOOTSTRAP_LIB"] = str(ROOT / "scripts/bootstrap-lib.sh")
        result = subprocess.run(["/bin/bash", "-c", 'CHECK=1; NO_BITWARDEN=0; source "$BOOTSTRAP_LIB"; asf_setup'], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertNotIn("FORBIDDEN", result.stdout + result.stderr)

    def test_downloaded_launcher_reuses_configured_checkout_without_git_writes(self):
        launcher = self.home / "launcher"
        launcher.mkdir()
        entry = launcher / "bootstrap"
        entry.write_bytes((ROOT / "bootstrap").read_bytes())
        checkout = self.home / "configured-checkout"
        (checkout / "scripts").mkdir(parents=True)
        (checkout / "home").mkdir()
        (checkout / ".chezmoiroot").write_text("home\n")
        (checkout / "scripts/bootstrap-lib.sh").write_text('bootstrap_components() { echo reused-configured-checkout; }\n')
        (checkout / "uncommitted.txt").write_text("preserve local work\n")
        self.env["TEST_CHECKOUT"] = str(checkout)
        self.env["DOTFILES_TOOLS_PATH"] = str(self.bin)
        self.tool("uname", 'if [ "$1" = -s ]; then echo Darwin; else echo arm64; fi')
        self.tool("xcode-select", 'exit 0')
        self.tool("xcrun", 'echo /usr/bin/clang')
        self.tool("brew", 'exit 0')
        self.tool("chezmoi", '[ "$1" = source-path ] || exit 99; echo "$TEST_CHECKOUT/home"')
        self.tool("git", 'case "$*" in *" remote get-url origin") echo https://github.com/CTristan/dotfiles.git;; *) echo FORBIDDEN >&2; exit 99;; esac')
        result = subprocess.run(["/bin/bash", str(entry), "--check"], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("reused-configured-checkout", result.stdout)
        self.assertEqual((checkout / "uncommitted.txt").read_text(), "preserve local work\n")
        self.assertNotIn("FORBIDDEN", result.stdout + result.stderr)

    def signing_fixture(self):
        agent_path = self.home / "Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
        agent_path.parent.mkdir(parents=True)
        agent = socket.socket(socket.AF_UNIX)
        self.addCleanup(agent.close)
        agent.bind(str(agent_path))
        public = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBootstrapFixtureKey"
        self.env["TEST_PUBLIC_KEY"] = public
        self.env["TEST_GIT_CALLS"] = str(self.home / "git-calls")
        self.tool("ssh-add", 'echo "$TEST_PUBLIC_KEY fixture-comment"')
        self.tool("git", 'case " $* " in *" commit "*) echo commit >> "$TEST_GIT_CALLS"; exit 0;; *" verify-commit "*) echo verify >> "$TEST_GIT_CALLS"; exit 0;; esac\nexec /usr/bin/git "$@"')
        self.tool("gh", 'case "$1" in auth) exit 0;; api) echo "$TEST_PUBLIC_KEY fixture-comment"; exit 0;; *) exit 99;; esac')
        config_dir = self.home / ".config/git"
        config_dir.mkdir(parents=True)
        local = config_dir / "config.local"
        local.write_text('[credential]\nhelper = test-helper\n[core]\nautocrlf = false\n')
        local.chmod(0o640)
        old_signers = config_dir / "allowed_signers"
        old_signers.write_text("other@example.invalid ssh-ed25519 legacy-key\n")
        signers = self.home / ".gitallowedsigners"
        signers.write_text("existing@example.invalid ssh-ed25519 existing-key\n")
        signers.chmod(0o644)
        (self.home / ".gitconfig").write_text('[user]\nname = setup-test\nemail = setup-test@example.invalid\n[gpg "ssh"]\nallowedSignersFile = ~/.config/git/allowed_signers\n[include]\npath = ~/.config/git/config.local\n')
        return public, local, old_signers, signers

    def test_signing_preserves_local_config_signers_and_modes_on_repeat_runs(self):
        public, local, old_signers, signers = self.signing_fixture()
        for _ in range(2):
            result = self.run_stage("signing_setup")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("helper = test-helper", local.read_text())
        self.assertIn("autocrlf = false", local.read_text())
        self.assertEqual(local.stat().st_mode & 0o777, 0o640)
        self.assertEqual(signers.stat().st_mode & 0o777, 0o644)
        lines = signers.read_text().splitlines()
        self.assertEqual(lines.count(f"setup-test@example.invalid {public}"), 1)
        self.assertIn("existing@example.invalid ssh-ed25519 existing-key", lines)
        self.assertIn("other@example.invalid ssh-ed25519 legacy-key", lines)
        self.assertEqual(old_signers.read_text(), "other@example.invalid ssh-ed25519 legacy-key\n")
        calls = Path(self.env["TEST_GIT_CALLS"]).read_text().splitlines()
        self.assertEqual(calls, ["commit", "verify", "commit", "verify"])

    def test_local_signing_setup_finishes_even_when_github_login_is_pending(self):
        public, local, _, signers = self.signing_fixture()
        self.tool("gh", 'exit 1')
        result = self.run_stage("signing_setup")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn(f"setup-test@example.invalid {public}", signers.read_text())
        self.assertIn("signingkey", local.read_text())
        self.assertEqual(Path(self.env["TEST_GIT_CALLS"]).read_text().splitlines(), ["commit", "verify"])

    def test_registration_check_never_refreshes_auth_or_writes_keys(self):
        self.tool("gh", 'case "$1 $2" in "auth status") exit 0;; "api --hostname") echo "[]"; exit 0;; *) echo FORBIDDEN >&2; exit 99;; esac')
        result = self.run_stage('register_secretive_key "ssh-ed25519 fixture-key"', check=1)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("FORBIDDEN", result.stdout + result.stderr)

    def test_packages_reuse_existing_tools_and_apps(self):
        for tool in ("chezmoi", "gh", "git-lfs", "jq", "pnpm", "bun", "python3"):
            self.tool(tool, "exit 0")
        applications = self.home / "Applications"
        for app in ("Secretive", "Obsidian", "Docker"):
            (applications / f"{app}.app").mkdir(parents=True)
        self.tool("brew", 'case "$1 $2" in "bundle install") for item in chezmoi gh git-lfs jq pnpm bun python; do case " $HOMEBREW_BUNDLE_BREW_SKIP " in *" $item "*) ;; *) exit 99;; esac; done; for item in secretive obsidian docker-desktop; do case " $HOMEBREW_BUNDLE_CASK_SKIP " in *" $item "*) ;; *) exit 99;; esac; done; exit 0;; *) echo FORBIDDEN >&2; exit 99;; esac')
        result = self.run_stage('DOTFILES_SKIP=""; skip_component() { return 1; }; packages')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("FORBIDDEN", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
