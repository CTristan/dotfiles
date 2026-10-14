#!/bin/bash

run_component() {
  local label="$1" result
  shift
  "$@"
  result=$?
  component_result="$result"
  case "$result" in
    0) report "$label" complete ;;
    2) report "$label" pending "Rerun bootstrap after the action above." ;;
    *) report "$label" failed "Resolve the error above, then rerun bootstrap." ;;
  esac
  return 0
}

formula_present() {
  local executable="$1"
  [ "$executable" != python ] || executable=python3
  command -v "$executable" >/dev/null 2>&1 || brew list --formula --versions "$1" >/dev/null 2>&1
}

cask_present() {
  local app
  case "$1" in secretive) app=Secretive ;; obsidian) app=Obsidian ;; docker-desktop) app=Docker ;; *) return 1 ;; esac
  [ -d "/Applications/$app.app" ] || [ -d "$HOME/Applications/$app.app" ] || brew list --cask --versions "$1" >/dev/null 2>&1
}

packages() {
  local package missing=0 formula_skip="${HOMEBREW_BUNDLE_BREW_SKIP:-}" cask_skip="${HOMEBREW_BUNDLE_CASK_SKIP:-}"
  local formulae="chezmoi gh git-lfs jq" casks="secretive"
  [ "$brew_ready" -eq 1 ] || { echo "Homebrew is needed to install packages."; return 2; }
  skip_component vault || casks="$casks obsidian"
  if ! skip_component runtimes; then formulae="$formulae pnpm bun python"; casks="$casks docker-desktop"; fi
  # Local inventories avoid API refreshes and reuse manually installed tools.
  for package in $formulae; do
    if formula_present "$package"; then formula_skip="$formula_skip $package"; elif [ "$CHECK" -eq 1 ]; then echo "Package missing: $package"; missing=1; fi
  done
  for package in $casks; do
    if cask_present "$package"; then cask_skip="$cask_skip $package"; elif [ "$CHECK" -eq 1 ]; then echo "Package missing: $package"; missing=1; fi
  done
  if [ "$CHECK" -eq 1 ]; then [ "$missing" -eq 0 ] || return 2; return 0; fi
  [ "$clt_ready" -eq 1 ] || { echo "Complete the Command Line Tools installation first."; return 2; }
  HOMEBREW_BUNDLE_BREW_SKIP="$formula_skip" HOMEBREW_BUNDLE_CASK_SKIP="$cask_skip" brew bundle install --no-upgrade --file="$REPO_DIR/Brewfile" || return 1
  for package in $formulae; do formula_present "$package" || { echo "Package still missing: $package"; missing=1; }; done
  for package in $casks; do cask_present "$package" || { echo "Package still missing: $package"; missing=1; }; done
  [ "$missing" -eq 0 ] || return 2
}

shell_setup() {
  local omz="$HOME/.oh-my-zsh" theme="$HOME/.oh-my-zsh/themes/dracula-src"
  if [ "$CHECK" -eq 0 ]; then
    [ "$clt_ready" -eq 1 ] || return 2
    command -v git >/dev/null 2>&1 || return 2
    if [ ! -e "$omz" ]; then
      git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$omz" || return 1
    fi
    [ -f "$omz/oh-my-zsh.sh" ] || { echo "Existing Oh My Zsh directory is incomplete: $omz"; return 2; }
    if [ ! -e "$theme" ]; then
      git clone --depth=1 https://github.com/dracula/zsh.git "$theme" || return 1
    fi
    [ -f "$theme/dracula.zsh-theme" ] || { echo "Dracula checkout is incomplete: $theme"; return 2; }
    if [ ! -e "$omz/themes/dracula.zsh-theme" ] && [ ! -L "$omz/themes/dracula.zsh-theme" ]; then
      ln -s dracula-src/dracula.zsh-theme "$omz/themes/dracula.zsh-theme" || return 1
    fi
  fi
  [ -f "$omz/oh-my-zsh.sh" ] && [ -f "$omz/themes/dracula.zsh-theme" ] || { echo "Oh My Zsh and Dracula need installation."; return 2; }
}

has_bitwarden_config() {
  [ -f "$1" ] && awk '/^[[:space:]]*\[bitwarden\][[:space:]]*(#.*)?$/ { found=1 } END { exit !found }' "$1"
}

migrate_chezmoi_config() {
  local config="$HOME/.config/chezmoi/chezmoi.toml" temporary archive
  command -v chezmoi >/dev/null 2>&1 || return 2
  config="$(chezmoi execute-template '{{ .chezmoi.configFile }}' 2>/dev/null)" || return 1
  [ -n "$config" ] || { echo "Could not determine the chezmoi config path."; return 1; }
  if has_bitwarden_config "$config"; then
    if [ "$CHECK" -eq 1 ]; then
      echo "The old Bitwarden auto-unlock section needs migration."
      return 2
    fi
    archive="$config.before-bootstrap-$(date +%Y%m%d-%H%M%S)-$$"
    cp -p "$config" "$archive" && chmod 600 "$archive" || return 1
    temporary="$(mktemp "$(dirname "$config")/.chezmoi-migrate.XXXXXX")" || return 1
    if ! awk '
      /^[[:space:]]*\[bitwarden\][[:space:]]*(#.*)?$/ { dropping=1; next }
      /^[[:space:]]*\[/ { dropping=0 }
      !dropping { print }
    ' "$config" > "$temporary" || ! chmod 600 "$temporary" || ! mv "$temporary" "$config"; then
      rm -f "$temporary"
      return 1
    fi
  elif [ ! -f "$config" ] && [ "$CHECK" -eq 0 ]; then
    chezmoi --source "$REPO_DIR" init || return 1
  fi
}

dotfiles_setup() {
  local changes
  [ "$CHECK" -eq 1 ] || [ "$clt_ready" -eq 1 ] || { echo "Complete the Command Line Tools installation first."; return 2; }
  command -v chezmoi >/dev/null 2>&1 || { echo "Install chezmoi first."; return 2; }
  migrate_chezmoi_config || return $?
  if [ "$CHECK" -eq 1 ]; then
    changes="$(chezmoi --source "$REPO_DIR" status)" || return 1
    [ -z "$changes" ] || { echo "Dotfiles have pending changes; run bootstrap to apply them."; return 2; }
  else
    chezmoi --source "$REPO_DIR" diff || return 1
    # Native conflict handling preserves destination edits; scripts stay explicit.
    chezmoi --source "$REPO_DIR" apply --exclude scripts || return 1
  fi
}

github_setup() {
  command -v gh >/dev/null 2>&1 || { echo "Install GitHub CLI first."; return 2; }
  if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    if [ "$CHECK" -eq 1 ] || ! interactive; then
      echo "Sign into GitHub: gh auth login --hostname github.com --git-protocol https --web"
      return 2
    fi
    gh auth login --hostname github.com --git-protocol https --web || return 2
  fi
  if [ "$CHECK" -eq 0 ]; then gh auth setup-git --hostname github.com || return 1; fi
}

register_secretive_key() {
  local selected="$1" endpoint keys missing="" scopes="" account answer temporary result
  command -v gh >/dev/null 2>&1 && gh auth status --hostname github.com >/dev/null 2>&1 || { echo "Sign into GitHub to register the selected public key."; return 2; }
  for endpoint in user/ssh_signing_keys user/keys; do
    keys="$(gh api --hostname github.com "$endpoint" --paginate --jq '.[].key' 2>/dev/null | awk '{print $1 " " $2}')" || keys=""
    if ! printf '%s\n' "$keys" | grep -qxF "$selected"; then
      missing="$missing $endpoint"
      case "$endpoint" in user/ssh_signing_keys) scopes="${scopes:+$scopes,}write:ssh_signing_key" ;; user/keys) scopes="${scopes:+$scopes,}write:public_key" ;; esac
    fi
  done
  [ -n "$missing" ] || return 0
  if [ "$CHECK" -eq 1 ] || ! interactive; then
    echo "Run bootstrap in a terminal to check or register the missing GitHub authentication/signing key."
    return 2
  fi
  account="$(gh api --hostname github.com user --jq .login)" || return 2
  printf '%s\n' "$selected" | ssh-keygen -lf - || return 1
  read -r -p "Register this public key for GitHub account $account (authentication and signing as needed)? [y/N] " answer || return 2
  case "$answer" in y|Y|yes) ;; *) return 2 ;; esac
  gh auth refresh --hostname github.com --scopes "$scopes" || return 2
  temporary="$(mktemp -t dotfiles-public-key)" || return 1
  if ! jq -n --arg title "$(hostname -s) Secretive" --arg key "$selected" '{title: $title, key: $key}' > "$temporary"; then rm -f "$temporary"; return 1; fi
  for endpoint in $missing; do
    # Recheck after scope approval so retries do not create duplicate keys.
    keys="$(gh api --hostname github.com "$endpoint" --paginate --jq '.[].key' 2>/dev/null | awk '{print $1 " " $2}')" || { rm -f "$temporary"; return 2; }
    if ! printf '%s\n' "$keys" | grep -qxF "$selected"; then
      gh api --hostname github.com --method POST "$endpoint" --input "$temporary" >/dev/null
      result=$?
      [ "$result" -eq 0 ] || { rm -f "$temporary"; return 2; }
    fi
    keys="$(gh api --hostname github.com "$endpoint" --paginate --jq '.[].key' | awk '{print $1 " " $2}')" || { rm -f "$temporary"; return 2; }
    printf '%s\n' "$keys" | grep -qxF "$selected" || { rm -f "$temporary"; return 2; }
  done
  rm -f "$temporary"
}

secretive_ssh_status() {
  local socket="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh" effective
  [ -f "$HOME/.ssh/config" ] || { echo "Apply the managed SSH configuration first."; return 2; }
  [ -S "$socket" ] || { echo "Open Secretive to start its SSH agent."; return 2; }
  effective="$(ssh -G -F "$HOME/.ssh/config" github.com 2>/dev/null | awk '$1 == "identityagent" { print $2; exit }')" || { echo "SSH configuration could not be inspected."; return 1; }
  case "$effective" in "$socket"|'~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh') return 0 ;; esac
  echo "An earlier SSH IdentityAgent setting overrides Secretive for github.com; review ~/.ssh/config, then rerun bootstrap."
  return 2
}

signing_setup() {
  local socket="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
  local keys current key selected count index email identity signer_dir signing_file signers local_config test_repo existing_signers line local_mode signer_mode
  [ "$clt_ready" -eq 1 ] || { echo "Command Line Tools are needed to configure signing."; return 2; }
  if [ ! -S "$socket" ]; then
    if [ "$CHECK" -eq 0 ] && interactive; then open -a Secretive >/dev/null 2>&1 || true; fi
    echo "Open Secretive and create this Mac's signing key, then rerun bootstrap."
    return 2
  fi
  keys="$(SSH_AUTH_SOCK="$socket" ssh-add -L 2>/dev/null)" || { echo "Create or enable a key in Secretive."; return 2; }
  [ -n "$keys" ] || return 2
  signer_dir="$HOME/.config/git"
  signing_file="$signer_dir/signing-key.pub"
  local_config="$signer_dir/config.local"
  signers="$HOME/.gitallowedsigners"
  current="$(git config --get user.signingkey 2>/dev/null)" || current=""
  case "$current" in
    key::*) current="${current#key::}" ;;
    ssh-*) ;;
    *) current="${current/#\~/$HOME}"; if [ -f "$current" ]; then current="$(cat "$current")"; else current=""; fi ;;
  esac
  selected=""
  count=0
  while IFS= read -r key; do
    count=$((count + 1))
    if [ -n "$current" ] && [ "$(printf '%s\n' "$key" | awk '{ print $1 " " $2 }')" = "$(printf '%s\n' "$current" | awk '{ print $1 " " $2 }')" ]; then selected="$key"; fi
  done <<< "$keys"
  if [ -z "$selected" ]; then
    if [ "$CHECK" -eq 1 ]; then echo "Select a Secretive signing key by running bootstrap."; return 2; fi
    if [ "$count" -eq 1 ]; then
      selected="$keys"
    elif interactive; then
      index=0
      while IFS= read -r key; do
        index=$((index + 1))
        printf '%s: ' "$index"
        printf '%s\n' "$key" | ssh-keygen -lf - || return 1
      done <<< "$keys"
      read -r -p "Signing key number: " index || return 2
      case "$index" in ''|*[!0-9]*) return 2 ;; esac
      [ "$index" -ge 1 ] && [ "$index" -le "$count" ] || return 2
      selected="$(printf '%s\n' "$keys" | sed -n "${index}p")"
    else
      echo "Multiple keys are available; rerun bootstrap in a terminal to choose one."
      return 2
    fi
  fi
  selected="$(printf '%s\n' "$selected" | awk '{ print $1 " " $2 }')"
  email="$(git config --get user.email 2>/dev/null)" || email=""
  identity="$(git config --get user.name 2>/dev/null)" || identity=""
  [ -n "$email" ] || { echo "Configure your Git identity before signing setup."; return 2; }
  [ -n "$identity" ] || { echo "Configure your Git name before signing setup."; return 2; }
  if [ "$CHECK" -eq 1 ]; then
    [ -n "$current" ] && [ -f "$signers" ] && grep -qxF "$email $selected" "$signers" || { echo "Git signing configuration needs setup."; return 2; }
    [ "$(git config --path --get gpg.ssh.allowedSignersFile 2>/dev/null)" = "$signers" ] && [ "$(git config --get gpg.format 2>/dev/null)" = ssh ] && [ "$(git config --get commit.gpgsign 2>/dev/null)" = true ] && [ "$(git config --get log.showSignature 2>/dev/null)" = true ] || { echo "Git signing settings need setup."; return 2; }
    echo "Local signing configuration is present; run bootstrap for a signing and registration test."
    register_secretive_key "$selected"
    return $?
  fi
  mkdir -p "$signer_dir" || return 1
  local_mode=""; signer_mode=""
  [ ! -f "$local_config" ] || local_mode="$(stat -f%Lp "$local_config")"
  [ ! -f "$signers" ] || signer_mode="$(stat -f%Lp "$signers")"
  existing_signers="$(git config --path --get gpg.ssh.allowedSignersFile 2>/dev/null)" || existing_signers=""
  if [ -z "$existing_signers" ] && [ -f "$signer_dir/allowed_signers" ]; then existing_signers="$signer_dir/allowed_signers"; fi
  if [ -e "$signing_file" ] && ! grep -qxF "$selected" "$signing_file"; then
    cp -p "$signing_file" "$signing_file.before-bootstrap-$(date +%Y%m%d-%H%M%S)-$$" || return 1
  fi
  printf '%s\n' "$selected" > "$signing_file" || return 1
  git config --file "$local_config" user.signingkey "$signing_file" || return 1
  git config --file "$local_config" gpg.ssh.allowedSignersFile "$signers" || return 1
  git config --file "$local_config" gpg.format ssh || return 1
  git config --file "$local_config" commit.gpgsign true || return 1
  git config --file "$local_config" log.showSignature true || return 1
  [ -f "$signers" ] || : > "$signers"
  for existing_signers in "$existing_signers" "$signer_dir/allowed_signers"; do
    if [ -n "$existing_signers" ] && [ "$existing_signers" != "$signers" ] && [ -f "$existing_signers" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] || grep -qxF "$line" "$signers" || printf '%s\n' "$line" >> "$signers" || return 1
      done < "$existing_signers"
    fi
  done
  grep -qxF "$email $selected" "$signers" || printf '%s %s\n' "$email" "$selected" >> "$signers" || return 1
  chmod "${local_mode:-600}" "$local_config" && chmod 600 "$signing_file" && chmod "${signer_mode:-600}" "$signers" || return 1
  test_repo="$(mktemp -d -t dotfiles-signing-test)" || return 1
  if ! git -C "$test_repo" init -q || ! SSH_AUTH_SOCK="$socket" git -C "$test_repo" -c core.hooksPath=/dev/null -c user.name="$identity" -c user.email="$email" -c user.signingkey="$signing_file" -c gpg.ssh.allowedSignersFile="$signers" -c commit.gpgsign=true -c gpg.format=ssh commit --allow-empty -m "Verified local signing" >/dev/null || ! git -C "$test_repo" -c gpg.ssh.allowedSignersFile="$signers" verify-commit HEAD; then
    rm -rf "$test_repo"
    echo "Signing did not verify; approve Secretive's request and rerun bootstrap."
    return 2
  fi
  rm -rf "$test_repo"
  register_secretive_key "$selected"
}

asf_setup() {
  local secret="$HOME/.local/bin/setup-asf-secret" setup="$HOME/.local/bin/setup-asf" result
  [ -x "$secret" ] && [ -x "$setup" ] || { echo "Apply the managed setup helpers first."; return 2; }
  cmp -s "$secret" "$REPO_DIR/home/dot_local/bin/executable_setup-asf-secret" && cmp -s "$setup" "$REPO_DIR/home/dot_local/bin/executable_setup-asf" || { echo "Apply the current ASF helpers before running setup or its status check."; return 2; }
  cmp -s "$HOME/.local/share/asf-backup/asf-backup.zsh" "$REPO_DIR/home/dot_local/share/asf-backup/asf-backup.zsh" || { echo "Apply the current ASF recovery library before running setup or its status check."; return 2; }
  if [ "$CHECK" -eq 1 ]; then
    "$secret" --check || return $?
    "$setup" --check
    return $?
  fi
  if [ "$NO_BITWARDEN" -eq 1 ]; then "$secret" --no-bitwarden; else "$secret"; fi
  result=$?
  [ "$result" -eq 0 ] || return "$result"
  "$setup"
}

vault_setup() {
  local setup="$HOME/.local/bin/setup-vault-backup"
  [ -x "$setup" ] || { echo "Apply the Obsidian setup helper first."; return 2; }
  cmp -s "$setup" "$REPO_DIR/home/dot_local/bin/executable_setup-vault-backup" || { echo "Apply the current Obsidian helper before running setup or its status check."; return 2; }
  cmp -s "$HOME/.local/bin/backup-vault.sh" "$REPO_DIR/home/dot_local/bin/executable_backup-vault.sh" && cmp -s "$HOME/.local/share/vault-backup/vault-backup-helper.c" "$REPO_DIR/home/dot_local/share/vault-backup/vault-backup-helper.c" || { echo "Apply the current Obsidian sync script and helper source before running setup or its status check."; return 2; }
  if [ "$CHECK" -eq 1 ]; then "$setup" --check; else "$setup"; fi
}

runtimes_setup() {
  local tool
  for tool in pnpm bun python3 docker; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Install the remaining runtime: $tool"; return 2; }
  done
  pnpm --version >/dev/null && bun --version >/dev/null && python3 --version >/dev/null || return 1
  if ! docker info >/dev/null 2>&1; then
    if [ "$CHECK" -eq 0 ] && interactive; then open -a Docker >/dev/null 2>&1 || true; fi
    echo "Finish Docker Desktop's first launch, then rerun bootstrap."
    return 2
  fi
}

bootstrap_components() {
  local dotfiles_ready
  run_component Packages packages
  run_component Shell shell_setup
  run_component Dotfiles dotfiles_setup
  dotfiles_ready="$component_result"
  run_component GitHub github_setup
  run_component "Secretive SSH" secretive_ssh_status
  run_component "Git signing" signing_setup
  if skip_component asf; then report ASF skipped; elif [ "$CHECK" -eq 0 ] && [ "$dotfiles_ready" -ne 0 ]; then report ASF pending "Apply the current dotfiles before enabling services."; else run_component ASF asf_setup; fi
  if skip_component vault; then report "Obsidian vault" skipped; elif [ "$CHECK" -eq 0 ] && [ "$dotfiles_ready" -ne 0 ]; then report "Obsidian vault" pending "Apply the current dotfiles before enabling services."; else run_component "Obsidian vault" vault_setup; fi
  if skip_component runtimes; then report Runtimes skipped; else run_component Runtimes runtimes_setup; fi
}
