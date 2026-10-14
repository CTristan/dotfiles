# dotfiles

Personal macOS dotfiles managed with [chezmoi](https://www.chezmoi.io/). Source of truth for `.zshrc`, `.gitconfig`, and the Brave Search env template (Bitwarden-backed).

> Claude Code config — `~/.claude/` (including `CLAUDE.md`, skills, and scripts) — lives in the **separate private** repo [`CTristan/dotclaude`](https://github.com/CTristan/dotclaude), **not here**. This public repo only manages portable machine dotfiles.

## What's inside

| Path (rendered)                                  | Purpose                                                         |
| ------------------------------------------------ | --------------------------------------------------------------- |
| `~/.zshrc`                                       | Oh My Zsh + Dracula, PATH, Secretive SSH agent, pnpm/bun shims, `claude` wrapper |
| `~/.gitconfig`                                   | git LFS, SSH commit signing, include for `~/.config/git/config.local` |
| `~/.chezmoi.toml`                                | chezmoi config — editor = `code`, Bitwarden unlock = auto        |
| `~/.config/brave-search/env.sh`                  | Brave API key from Bitwarden (template, fault-tolerant, mode 0600) |
| `~/.local/bin/setup-asf`                         | Install or restore ArchiSteamFarm and load its LaunchAgents      |
| `~/.local/bin/backup-asf-config.sh`               | Encrypted, rotating ASF config backups in iCloud Drive            |
| `~/Library/LaunchAgents/com.user.archisteamfarm.plist` | Start and supervise ASF in your user session                |
| `~/Library/LaunchAgents/com.user.asf-backup.plist` | Back up ASF config at login and daily at 03:00 local time         |

## Restoring to a new Mac

Work through these in order. Anything missing a prerequisite will surface as a `chezmoi apply` error; fix and re-run.

### 1. Install Homebrew

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Then follow the on-screen instructions to add `brew` to your PATH (needed for the rest of the steps).

### 2. Install the tools chezmoi depends on

```sh
brew install chezmoi bitwarden-cli jq
brew install --cask secretive
```

- `chezmoi` applies the dotfiles.
- `bitwarden-cli` (`bw`) + `jq` render the Brave Search env template.
- `Secretive` provides the SSH agent socket used for both git commit signing and auth (see `dot_zshrc`).

### 3. Set up Bitwarden (for the Brave Search key)

```sh
bw login           # one-time, stores a session
export BW_SESSION="$(bw unlock --raw)"
```

Create (or confirm you already have) the following vault item:

| Item name      | Field   | Consumed by                                |
| -------------- | ------- | ------------------------------------------ |
| `Brave Search` | `token` | `~/.config/brave-search/env.sh` (API key)  |

The template is **fault-tolerant**: a locked/missing vault renders an *empty* key instead of aborting `chezmoi apply`. So export `BW_SESSION` (unlocked) **before** applying if you want the key actually written; otherwise re-run `chezmoi apply` once the vault is unlocked.

### 4. Provision the SSH signing key

`.gitconfig` signs commits via SSH using the Secretive agent. The signer is a **hardware-backed key that requires a physical tap** — on this machine a Secure Enclave / Touch ID key via Secretive (`ecdsa-sha2-nistp256`); a Yubikey-resident key (often `ssh-ed25519`) works the same way.

1. Open Secretive → create (or import) a signing key. For Secure-Enclave/Touch-ID signing it'll be an `ecdsa-sha2-nistp256` key; for a Yubikey use whatever the key provides (commonly `ed25519`).
2. Add the **public** key to GitHub → Settings → SSH and GPG keys, type = **Signing Key**. Add it a second time as an **Authentication Key** if you want to use it for `git push` over SSH.
3. Create `~/.config/git/allowed_signers` (not tracked here — sensitive-ish) with one line matching your key's type, e.g.:

   ```
   1764856+CTristan@users.noreply.github.com ecdsa-sha2-nistp256 AAAA…your-pubkey…
   ```

4. Optionally create `~/.config/git/config.local` for any machine-local overrides (the `[user] signingkey` path, work repos, etc.). It's pulled in via the `[include] path` at the bottom of `.gitconfig`.

### 5. Install Oh My Zsh + the Dracula theme

`.zshrc` expects Oh My Zsh at `$HOME/.oh-my-zsh`, with `ZSH_THEME="dracula"`.

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
git clone https://github.com/dracula/zsh.git ~/.oh-my-zsh/themes/dracula-src
ln -s ~/.oh-my-zsh/themes/dracula-src/dracula.zsh-theme ~/.oh-my-zsh/themes/dracula.zsh-theme
```

### 6. Apply the dotfiles

```sh
chezmoi init --apply https://github.com/CTristan/dotfiles.git
```

This clones the repo to `~/.local/share/chezmoi`, renders the templates, and writes files into `$HOME`. Re-run `chezmoi apply` any time secrets or templates change.

Sanity-check:

```sh
chezmoi doctor
chezmoi diff        # should print nothing (env.sh may diff if BW_SESSION isn't set)
```

### 7. Set up ArchiSteamFarm (Apple silicon)

`chezmoi apply` deploys the ASF setup helper, backup script, and two per-user LaunchAgents. It does not install ASF. The ASF backup passphrase is stored in Bitwarden.

Before starting the backup agent, preserve the existing iCloud snapshots because its first run removes snapshots older than the newest 14. In Finder, open iCloud Drive → `ASF-Backups`, choose **Download Now**, and wait for the encrypted snapshots to finish downloading. Run this zsh snippet before the helper to make a private, timestamped copy and compare every snapshot's hash:

```sh
icloud="$HOME/Library/Mobile Documents/com~apple~CloudDocs/ASF-Backups"
archive_root="$HOME/Library/Application Support/ASF Restore Archives"
archive="$archive_root/$(date +%Y-%m-%d-%H%M%S)"
mkdir -p "$archive_root" && chmod 700 "$archive_root" || exit 1
mkdir "$archive" && chmod 700 "$archive" || exit 1
snapshots=("$icloud"/asf-config-*.tar.gz.enc(N))
(( ${#snapshots} > 0 )) || { echo "No downloaded ASF snapshots found" >&2; exit 1; }
for snapshot in "${snapshots[@]}"; do
  cp -p "$snapshot" "$archive/" || exit 1
done
for snapshot in "${snapshots[@]}"; do
  name="${snapshot##*/}"
  source_hash="$(shasum -a 256 "$snapshot" | awk '{print $1}')"
  archive_hash="$(shasum -a 256 "$archive/$name" | awk '{print $1}')"
  [ "$source_hash" = "$archive_hash" ] || { echo "SHA-256 mismatch: $name" >&2; exit 1; }
done
echo "Verified ${#snapshots} snapshots in $archive"
```

If a usable backup exists, run the helper after preserving the snapshots:

```sh
~/.local/bin/setup-asf
```

The helper downloads ASF's native `osx-arm64` build if it is missing; the build includes its .NET runtime, so no separate .NET installation is needed. If the passphrase is not already in your login Keychain, the helper prompts for it with terminal input hidden and stores it there. It restores the newest downloaded snapshot only when `~/Library/Application Support/ArchiSteamFarm/config/ASF.json` is absent, then loads both LaunchAgents. The ASF service starts in your user session. The backup agent runs immediately when the helper loads it (`RunAtLoad`), at login, and daily at 03:00 local time; it does not run while you are logged out. Its immediate `RunAtLoad` execution prunes snapshots older than the newest 14 during setup.

If no usable backup exists, do not run the helper yet: it still loads both agents when no snapshot is present. Install the native ASF build using the [official setup guide](https://github.com/JustArchiNET/ArchiSteamFarm/wiki/Setting-up), create the global and bot configuration, and run ASF in the foreground to authenticate the bots with Steam. Complete any Steam Guard prompts locally, then stop the foreground ASF process before running the helper to prevent duplicate instances or IPC port conflicts. Once `config/ASF.json` exists, run `~/.local/bin/setup-asf`; it will skip restoration and load the agents.

Verify the service and backup agents, then check each bot's Steam connection in the local ASF interface (usually `http://127.0.0.1:1242` when IPC is enabled):

```sh
launchctl print "gui/$(id -u)/com.user.archisteamfarm"
launchctl print "gui/$(id -u)/com.user.asf-backup"
```

Confirm `~/Library/Logs/asf-backup.log` reports `done` and a new encrypted snapshot appears in iCloud Drive's `ASF-Backups` folder. To test a snapshot without printing or extracting its contents, set `snapshot` to its path and run this in zsh; replace the timestamp in the example filename. The passphrase is read without echo and is passed to OpenSSL through the environment, not as a command-line value:

```sh
snapshot="$HOME/Library/Mobile Documents/com~apple~CloudDocs/ASF-Backups/asf-config-YYYYMMDD-HHMMSS.tar.gz.enc"
setopt pipefail
read -rs 'PW?ASF backup passphrase: '
export PW
if /usr/bin/openssl enc -d -aes-256-cbc -pbkdf2 -pass env:PW -in "$snapshot" | tar -tzf - >/dev/null; then
  echo "Snapshot integrity check passed"
else
  echo "Snapshot integrity check failed" >&2
fi
unset PW
unsetopt pipefail
```

### 8. Clone the private Claude Code repo

`~/.claude/` (and the `claude` shell wrapper that `.zshrc` defines) lives in the separate **private** repo, not in chezmoi:

```sh
git clone https://github.com/CTristan/dotclaude.git ~/.claude
```

The `claude()` function in `.zshrc` falls back to the real `claude` binary until this is present, so the shell won't break if you skip it.

### 9. Install optional runtimes referenced by PATH

`.zshrc` prepends these to PATH whether or not they exist. Install whichever you want:

```sh
brew install --cask docker           # adds ~/.docker/completions to fpath
brew install pnpm                    # ~/Library/pnpm
brew install oven-sh/bun/bun         # ~/.bun/bin
brew install python                  # backs the `python=python3` alias
```

### 10. Verify

- New shell: `exec zsh` — Dracula theme loads, no errors.
- Git signing: `git -C some-repo commit --allow-empty -m test` — Secretive/Touch ID (or your Yubikey) prompts for a tap.
- Brave API: `echo $BRAVE_API_KEY` in a fresh shell — set to the Bitwarden value (if the vault was unlocked at apply time).

## Updating the dotfiles from another Mac

```sh
chezmoi cd          # enters ~/.local/share/chezmoi
# …edit files, stage, commit, push…
chezmoi apply       # re-renders templates locally
```

`[git] autoCommit = true` in `.chezmoi.toml.tmpl` means `chezmoi add` / `chezmoi edit` auto-commits; pushes are manual (`autoPush = false`).
