# dotfiles

Personal macOS dotfiles managed with [chezmoi](https://www.chezmoi.io/). The repository manages the shell and Git configuration, ASF setup and encrypted backups, and Obsidian vault backups. The guided bootstrap installs and configures the selected components on Apple-silicon Macs.

## Set up a new Mac

Run this command in Terminal on the new Mac:

```sh
bootstrap_file="$(mktemp)"
trap 'rm -f "$bootstrap_file"' EXIT
curl -fsSL 'https://raw.githubusercontent.com/CTristan/dotfiles/main/bootstrap' -o "$bootstrap_file"
/bin/bash "$bootstrap_file"
```

The bootstrap installs missing Command Line Tools and Homebrew, then clones the checkout to `~/.local/share/chezmoi` or reuses the existing chezmoi checkout for this repository. It runs the selected setup stages in order and pauses for account sign-in, key selection, permissions, or other steps that need you. After resolving a pending step, rerun the bootstrap to continue.

From the checkout path reported by setup, run `./bootstrap` to resume. The bootstrap applies dotfiles from that checkout, respects `.chezmoiroot`, and uses chezmoi’s conflict handling. It installs Oh My Zsh and Dracula without allowing their installers to replace an existing `~/.zshrc`; the chezmoi editor preference remains `code`.

All components are selected by default. Use these options to inspect or customize a run:

```sh
./bootstrap --check
./bootstrap --no-bitwarden
./bootstrap --skip asf,vault,runtimes
```

`--check` only reports observed status; it does not install software, authenticate, prompt for signing, change services, or write files. Each component is reported as complete, pending user action, skipped, or failed. The command exits with `0` when all selected components are complete, `2` when a user action is pending, and `1` when a step fails.

## Installed components

The default package set includes chezmoi, GitHub CLI, Git LFS, jq, Secretive, and Obsidian. The optional runtime group is also selected by default and includes Docker Desktop, pnpm, Bun, and Python. Use `--skip runtimes` to omit that group.

Secretive is installed automatically as a Homebrew cask. On first launch, create or select the signing key in Secretive; key creation and any Touch ID approval remain manual. The [Secretive Git guide](https://github.com/maxgoedjen/secretive-config-instructions/blob/main/apps/git.md) covers that step. Bootstrap configures `~/.ssh/config`, `~/.zshrc`, and Git to use Secretive, then verifies a signed commit in a temporary repository. When GitHub registration is needed, bootstrap shows the key fingerprint and account for review before adding any missing SSH authentication or commit-signing key. It requests the `write:public_key` and `write:ssh_signing_key` OAuth scopes as needed; see [GitHub’s SSH signing key API](https://docs.github.com/en/rest/users/ssh-signing-keys) and [SSH key API](https://docs.github.com/en/rest/users/keys).

Git reads its signing key and allowed-signers path through `~/.gitconfig` and its included local configuration. Bootstrap keeps the selected public key and other machine-specific signing settings in local configuration, and adds the key to `~/.gitallowedsigners`. Each allowed-signers line follows [OpenSSH’s format](https://man.openbsd.org/ssh-keygen#ALLOWED_SIGNERS): the Git email followed by the public key type and key data, for example: `<git-email> ssh-ed25519 <base64-public-key>`. The path is configured as `~/.gitallowedsigners`; bootstrap also enables signature display in Git logs. If the older `~/.config/git/allowed_signers` exists, setup preserves it and carries its entries forward.

## ArchiSteamFarm

The bootstrap reuses an ASF passphrase already in the login Keychain. If no Keychain item exists, choose the optional Bitwarden importer or enter the passphrase manually with hidden input. `--no-bitwarden` selects manual entry. Bitwarden CLI is installed only when you choose its importer, and its vault still requires an interactive login and unlock.

For the importer, create a Bitwarden Secure Note named `dotfiles: ASF backup` with one hidden custom field named `passphrase`. Put the **existing ASF backup passphrase** in that field; do not rotate it. The importer requires one exact note match and stops with instructions if the note is missing or duplicated. It does not save the Bitwarden master password or session. Dotfile rendering and shell startup do not require Bitwarden.

Before enabling the ASF agents, setup downloads private copies of the available iCloud snapshots and verifies their hashes. It tests restoration in a staging directory and checks for usable configuration before loading either LaunchAgent. If there is no usable snapshot, setup remains pending until you install ASF, configure the bots, and complete Steam Guard; rerun `./bootstrap` afterward.

The backup helper serializes setup and backup runs. It publishes a complete encrypted snapshot only after validation, then keeps the newest 14 snapshots. A failed credential read, encryption, or validation leaves existing snapshots intact. After setup, confirm that the ASF service is running and that a new encrypted snapshot appears in iCloud Drive.

## Obsidian vault backups

The bootstrap prepares the existing vault backup helper and detached Git history, then waits for any required Full Disk Access approval. Open and sign in to Obsidian, make sure the vault is readable and hydrated from iCloud, and grant the permission identified by the setup prompt. Synchronization is enabled only after the vault passes its safeguards, and setup remains pending until a backup cycle succeeds. Rerun `./bootstrap` to resume.

## Updating the checkout

```sh
cd "$HOME/.local/share/chezmoi"
git pull --ff-only
./bootstrap
```

These commands use chezmoi’s default checkout path; use the path reported by setup if an existing checkout lives elsewhere. The bootstrap rechecks the actual installed state on each run and leaves local checkout changes in place.
