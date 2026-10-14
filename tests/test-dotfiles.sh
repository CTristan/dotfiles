#!/bin/bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHEZMOI_BIN="$(command -v chezmoi || true)"
ZSH_BIN="$(command -v zsh || true)"
PYTHON_BIN="$(command -v python3 || true)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

[ -n "$CHEZMOI_BIN" ] || fail 'chezmoi is required for the scratch render test'
[ -n "$ZSH_BIN" ] || fail 'zsh is required for the shell startup test'
[ -n "$PYTHON_BIN" ] || fail 'python3 is required to clean the temporary test directory'

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-test.XXXXXX")"
cleanup() {
  "$PYTHON_BIN" - "$TEST_ROOT" <<'PY'
import shutil
import sys

shutil.rmtree(sys.argv[1], ignore_errors=True)
PY
}
trap cleanup EXIT

SOURCE_ROOT="$TEST_ROOT/source"
TEST_HOME="$TEST_ROOT/home"
TEST_CONFIG="$TEST_HOME/.config/chezmoi/chezmoi.toml"
TEST_CACHE="$TEST_ROOT/cache"
TEST_STATE="$TEST_ROOT/state"
mkdir -p "$SOURCE_ROOT" "$TEST_HOME/.config/chezmoi" "$TEST_HOME/.claude" \
  "$TEST_HOME/.codex" "$TEST_HOME/.config/git" "$TEST_HOME/.config/brave-search"
cp "$REPO_ROOT/.chezmoiroot" "$SOURCE_ROOT/.chezmoiroot"
cp -R "$REPO_ROOT/home" "$SOURCE_ROOT/home"

printf 'keep claude data\n' > "$TEST_HOME/.claude/keep.txt"
printf 'keep codex data\n' > "$TEST_HOME/.codex/keep.txt"
printf '[user]\nname = "scratch identity"\n' > "$TEST_HOME/.config/git/config.local"
printf 'stale generated file\n' > "$TEST_HOME/.config/brave-search/env.sh"

ISOLATED_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
if env PATH="$ISOLATED_PATH" /bin/sh -c 'command -v bw >/dev/null 2>&1'; then
  fail 'test PATH unexpectedly exposes Bitwarden CLI'
fi

env HOME="$TEST_HOME" PATH="$ISOLATED_PATH" \
  "$CHEZMOI_BIN" --source "$SOURCE_ROOT" --destination "$TEST_HOME" \
  --config "$TEST_CONFIG" --cache "$TEST_CACHE" --persistent-state "$TEST_STATE" \
  init --apply --force --config-path "$TEST_CONFIG"

[ -f "$TEST_HOME/.zshrc" ] || fail 'chezmoi did not render .zshrc'
[ -f "$TEST_HOME/.gitconfig" ] || fail 'chezmoi did not render .gitconfig'
grep -qF 'Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh' "$TEST_HOME/.zshrc" || fail 'rendered zsh config does not recognize the Secretive agent socket'
[ -f "$TEST_CONFIG" ] || fail 'chezmoi did not render its configuration'
if grep -Eq '^[[:space:]]*\[bitwarden\]' "$TEST_CONFIG"; then
  fail 'rendered chezmoi configuration still enables Bitwarden integration'
fi
pass 'scratch chezmoi initialization and rendering succeed without Bitwarden CLI'

ALLOWED_SIGNERS_PATH="$(git config --file "$TEST_HOME/.gitconfig" --get gpg.ssh.allowedSignersFile)"
[ "$ALLOWED_SIGNERS_PATH" = '~/.gitallowedsigners' ] || fail "Git allowed-signers path is not ~/.gitallowedsigners: $ALLOWED_SIGNERS_PATH"
[ "$(git config --file "$TEST_HOME/.gitconfig" --get log.showSignature)" = true ] || fail 'Git log signature display is not enabled'
pass 'rendered Git config uses the exact machine-local allowed-signers path'

[ ! -e "$TEST_HOME/.config/brave-search/env.sh" ] || fail 'retired Brave env target remains'
[ -d "$TEST_HOME/.config/brave-search" ] || fail 'retirement removed the parent directory'
pass 'chezmoi removes only the retired Brave env file'

for preserved in \
  "$TEST_HOME/.claude/keep.txt" \
  "$TEST_HOME/.codex/keep.txt" \
  "$TEST_HOME/.config/git/config.local"; do
  [ -f "$preserved" ] || fail "chezmoi removed an unrelated target: $preserved"
done
grep -qx 'keep claude data' "$TEST_HOME/.claude/keep.txt" || fail 'Claude directory contents changed'
grep -qx 'keep codex data' "$TEST_HOME/.codex/keep.txt" || fail 'Codex directory contents changed'
grep -qx 'name = "scratch identity"' "$TEST_HOME/.config/git/config.local" || fail 'local Git config changed'
pass 'scratch apply preserves unrelated user directories and Git configuration'

if grep -Eiq 'brave|claude|bitwarden|BW_SESSION|/Users/' \
  "$REPO_ROOT/home/dot_zshrc" "$REPO_ROOT/home/.chezmoi.toml.tmpl" \
  "$TEST_HOME/.zshrc" "$TEST_CONFIG"; then
  fail 'shell or chezmoi configuration contains a removed integration or hard-coded user path'
fi

mkdir -p "$TEST_HOME/.oh-my-zsh/themes"
cat > "$TEST_HOME/.oh-my-zsh/oh-my-zsh.sh" <<'EOF'
[[ "$ZSH_THEME" == dracula ]] || return 1
[[ -f "$ZSH/themes/dracula.zsh-theme" ]] || return 1
source "$ZSH/themes/dracula.zsh-theme"
EOF
cat > "$TEST_HOME/.oh-my-zsh/themes/dracula.zsh-theme" <<'EOF'
typeset -g DOTFILES_TEST_DRACULA_LOADED=1
EOF

if ! HOME="$TEST_HOME" ZDOTDIR="$TEST_HOME" PATH="$ISOLATED_PATH" \
  SSH_AUTH_SOCK="$TEST_ROOT/existing-agent.sock" \
  DOTFILES_TEST_AGENT="$TEST_ROOT/existing-agent.sock" \
  "$ZSH_BIN" -i -c '[[ "$DOTFILES_TEST_DRACULA_LOADED" == 1 && "$PNPM_HOME" == "$HOME/Library/pnpm" && "$SSH_AUTH_SOCK" == "$DOTFILES_TEST_AGENT" ]]' \
  >/dev/null 2>&1; then
  fail 'fresh zsh startup failed with the Oh My Zsh and Dracula stubs'
fi
pass 'fresh zsh startup loads the configured theme and home-relative paths'
