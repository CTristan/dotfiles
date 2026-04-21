# dotfiles

Personal macOS dotfiles managed with [chezmoi](https://www.chezmoi.io/). Source of truth for `.zshrc`, `.gitconfig`, the Brave Search env template (Bitwarden-backed), the Obsidian → local-mirror sync script + LaunchAgent, and an age-encrypted `~/.claude/CLAUDE.md`.

## What's inside

| Path (rendered)                                  | Purpose                                                         |
| ------------------------------------------------ | --------------------------------------------------------------- |
| `~/.zshrc`                                       | Oh My Zsh + Dracula, PATH, Secretive SSH agent, pnpm/bun shims  |
| `~/.gitconfig`                                   | git LFS, SSH commit signing, include for `~/.config/git/config.local` |
| `~/.chezmoi.toml`                                | chezmoi config — editor = `code`, Bitwarden unlock = auto        |
| `~/.config/brave-search/env.sh`                  | Brave API key from Bitwarden (template)                          |
| `~/.local/bin/sync-obsidian.sh`                  | Mirrors the iCloud Obsidian vault → `~/claude/<vault>/`          |
| `~/Library/LaunchAgents/com.user.obsidian-mirror.plist` | Runs the sync every 5 min                                 |
| `~/.claude/CLAUDE.md`                            | Age-encrypted private Claude instructions                        |

## Restoring to a new Mac

Work through these in order. Anything missing a prerequisite will surface as a `chezmoi apply` error; fix and re-run.

### 1. Install Homebrew

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Then follow the on-screen instructions to add `brew` to your PATH (needed for the rest of the steps).

### 2. Install the tools chezmoi depends on

```sh
brew install chezmoi age bitwarden-cli
brew install --cask secretive
```

- `chezmoi` applies the dotfiles.
- `age` decrypts `encrypted_CLAUDE.md.age`.
- `bitwarden-cli` (`bw`) renders the Brave Search env template.
- `Secretive` provides the SSH agent socket used for both git commit signing and auth (see `dot_zshrc:42`).

### 3. Set up Bitwarden

```sh
bw login           # one-time, stores a session
export BW_SESSION="$(bw unlock --raw)"
```

Create (or confirm you already have) the following vault items before applying:

| Item name      | Field   | Consumed by                                |
| -------------- | ------- | ------------------------------------------ |
| `Brave Search` | `token` | `~/.config/brave-search/env.sh` (API key)  |

If an item is missing, template rendering fails loudly and chezmoi will tell you which file.

### 4. Restore the age identity

`~/.config/chezmoi/chezmoi.toml` on the old Mac points at an age identity file (typically `~/.config/chezmoi/key.txt`). That file is **not** in this repo by design. On the new Mac, recover it from your password manager or encrypted backup and drop it at the same path. Without it, `encrypted_CLAUDE.md.age` won't decrypt.

Verify with:

```sh
age --decrypt -i ~/.config/chezmoi/key.txt \
    ~/.local/share/chezmoi/home/dot_claude/encrypted_CLAUDE.md.age \
    | head
```

### 5. Provision the SSH signing key

`.gitconfig` signs commits via SSH using the Secretive agent.

1. Open Secretive → create (or import) an ed25519 signing key. If you want hardware-backed signing, back it with the Yubikey's Secure Enclave equivalent via Secretive's settings.
2. Add the **public** key to GitHub → Settings → SSH and GPG keys, type = **Signing Key**. Add it a second time as an **Authentication Key** if you want to use it for `git push` over SSH.
3. Create `~/.config/git/allowed_signers` (not tracked here — sensitive-ish) with one line:

   ```
   1764856+CTristan@users.noreply.github.com ssh-ed25519 AAAA…your-pubkey…
   ```

4. Optionally create `~/.config/git/config.local` for any machine-local overrides (`[user]` section variations, work repos, etc.). It's pulled in via the `[include] path` at the bottom of `.gitconfig`.

### 6. Install Oh My Zsh + the Dracula theme

`.zshrc` expects Oh My Zsh at `$HOME/.oh-my-zsh`, with `ZSH_THEME="dracula"`.

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
git clone https://github.com/dracula/zsh.git ~/.oh-my-zsh/themes/dracula-src
ln -s ~/.oh-my-zsh/themes/dracula-src/dracula.zsh-theme ~/.oh-my-zsh/themes/dracula.zsh-theme
```

### 7. Apply the dotfiles

```sh
chezmoi init --apply https://github.com/CTristan/dotfiles.git
```

This clones the repo to `~/.local/share/chezmoi`, renders all templates (Bitwarden + age), and writes files into `$HOME`. Re-run `chezmoi apply` any time secrets or templates change.

Sanity-check:

```sh
chezmoi doctor
chezmoi diff        # should print nothing
```

### 8. Load the Obsidian sync LaunchAgent

chezmoi drops the plist at `~/Library/LaunchAgents/com.user.obsidian-mirror.plist`, but launchd won't run it until you tell it to:

```sh
launchctl bootstrap "gui/$UID" ~/Library/LaunchAgents/com.user.obsidian-mirror.plist
launchctl kickstart -k "gui/$UID/com.user.obsidian-mirror"   # run it once immediately
tail -f /tmp/obsidian-mirror.log                             # verify output
```

Also: sign into iCloud and enable Obsidian iCloud sync so `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/<vault>/` actually exists. If you have multiple vaults, export `VAULT_NAME` in the LaunchAgent or your shell before the script runs.

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
- Git signing: `git -C some-repo commit --allow-empty -m test` — Secretive taps/confirms.
- Obsidian mirror: `ls ~/claude/<vault>/` populated after a few minutes.
- Brave API: `echo $BRAVE_API_KEY` in a fresh shell — set to the Bitwarden value.

## Updating the dotfiles from another Mac

```sh
chezmoi cd          # enters ~/.local/share/chezmoi
# …edit files, stage, commit, push…
chezmoi apply       # re-renders templates locally
```

`[git] autoCommit = true` in `.chezmoi.toml.tmpl` means `chezmoi add` / `chezmoi edit` auto-commits; pushes are manual (`autoPush = false`).
