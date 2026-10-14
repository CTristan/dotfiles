# Shared by setup-asf and backup-asf-config.sh so restore and backup use the
# same lock, archive format, and snapshot validation rules.

typeset -g ASF_SERVICE_LABEL=com.user.archisteamfarm
typeset -g ASF_BACKUP_LABEL=com.user.asf-backup
typeset -g ASF_PASSPHRASE=''
typeset -g ASF_LOCK_FD=''
typeset -g ASF_TTY_ECHO_DISABLED=0
typeset -g ASF_CHILD_PID=''
typeset -g ASF_LAST_SNAPSHOT=''
typeset -ga ASF_SNAPSHOTS
typeset -ga ASF_CLEANUP_DIRS
typeset -ga ASF_CLEANUP_FILES
typeset -gA ASF_ARCHIVE_HASHES

asf_init_paths() {
  local path_prefix
  ASF_DIR="${ASF_DIR:-$HOME/Library/Application Support/ArchiSteamFarm}"
  ASF_BACKUPS_DIR="${ASF_BACKUPS_DIR:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/ASF-Backups}"
  ASF_STATE_DIR="${ASF_STATE_DIR:-$HOME/.local/state}"
  ASF_LOCK_FILE="${ASF_LOCK_FILE:-$ASF_STATE_DIR/asf-config.lock}"
  ASF_RESTORE_ARCHIVE_DIR="${ASF_RESTORE_ARCHIVE_DIR:-$HOME/Library/Application Support/ASF Restore Archives}"
  ASF_LAUNCH_AGENTS_DIR="${ASF_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
  ASF_TMP_ROOT="${ASF_TMP_ROOT:-${TMPDIR:-/tmp}}"
  ASF_HYDRATE_TIMEOUT="${ASF_HYDRATE_TIMEOUT:-60}"
  ASF_KEEP="${ASF_KEEP:-14}"

  path_prefix="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
  if [[ -n "${ASF_TOOLS_PATH:-}" ]]; then
    path_prefix="$ASF_TOOLS_PATH:$path_prefix"
  fi
  export PATH="$path_prefix"

  ASF_OPENSSL_BIN="${ASF_OPENSSL_BIN:-$(command -v openssl 2>/dev/null)}"
  ASF_PLUTIL_BIN="${ASF_PLUTIL_BIN:-/usr/bin/plutil}"
  ASF_SHASUM_BIN="${ASF_SHASUM_BIN:-/usr/bin/shasum}"
  ASF_SETUP_SCRIPT="$HOME/.local/bin/setup-asf"
  ASF_LIBRARY_SCRIPT="$HOME/.local/share/asf-backup/asf-backup.zsh"
  ASF_SECRET_SCRIPT="${ASF_SECRET_SCRIPT:-$HOME/.local/bin/setup-asf-secret}"
  ASF_BACKUP_SCRIPT="$HOME/.local/bin/backup-asf-config.sh"
  ASF_SERVICE_PLIST="$ASF_LAUNCH_AGENTS_DIR/$ASF_SERVICE_LABEL.plist"
  ASF_BACKUP_PLIST="$ASF_LAUNCH_AGENTS_DIR/$ASF_BACKUP_LABEL.plist"
  ASF_GUI_DOMAIN="gui/$(id -u)"

  ASF_SNAPSHOTS=()
  ASF_CLEANUP_DIRS=()
  ASF_CLEANUP_FILES=()
  ASF_ARCHIVE_HASHES=()
  ASF_CHILD_PID=''
  ASF_LAST_SNAPSHOT=''
}

asf_log() {
  print -r -- "$(date '+%Y-%m-%d %H:%M:%S') [asf] $*"
}

asf_error() {
  print -u2 -r -- "$(date '+%Y-%m-%d %H:%M:%S') [asf] ERROR: $*"
}

asf_pending() {
  asf_log "PENDING: $*"
  return 2
}

asf_cleanup() {
  if [[ -n "$ASF_CHILD_PID" ]]; then
    kill "$ASF_CHILD_PID" 2>/dev/null || true
    wait "$ASF_CHILD_PID" 2>/dev/null || true
    ASF_CHILD_PID=''
  fi
  if (( ASF_TTY_ECHO_DISABLED )); then
    stty echo </dev/tty 2>/dev/null || true
    ASF_TTY_ECHO_DISABLED=0
  fi

  local cleanup_path
  for cleanup_path in "${ASF_CLEANUP_FILES[@]}"; do
    case "$cleanup_path" in
      "$ASF_BACKUPS_DIR"/.asf-config-*.tmp.*|"$ASF_BACKUPS_DIR"/.asf-recovery-*.tmp.*)
        if [[ -f "$cleanup_path" || -L "$cleanup_path" ]]; then
          /bin/rm -f -- "$cleanup_path" 2>/dev/null || true
        fi
        ;;
    esac
  done
  for cleanup_path in "${ASF_CLEANUP_DIRS[@]}"; do
    case "$cleanup_path" in
      "$ASF_DIR"/.asf-restore.*|"$ASF_TMP_ROOT"/asf-setup.*|"$ASF_TMP_ROOT"/asf-backup.*|"$ASF_RESTORE_ARCHIVE_DIR"/.asf-snapshots.*|"$ASF_RESTORE_ARCHIVE_DIR"/.asf-pruned.*)
        if [[ -d "$cleanup_path" ]]; then
          /bin/rm -rf -- "$cleanup_path" 2>/dev/null || true
        fi
        ;;
    esac
  done
  ASF_CLEANUP_FILES=()
  ASF_CLEANUP_DIRS=()

  if [[ -n "$ASF_LOCK_FD" ]]; then
    zsystem flock -u "$ASF_LOCK_FD" 2>/dev/null || true
    ASF_LOCK_FD=''
  fi
  unset ASF_PASSPHRASE
}

asf_register_temp_dir() {
  ASF_CLEANUP_DIRS+=("$1")
}

asf_register_temp_file() {
  ASF_CLEANUP_FILES+=("$1")
}

asf_forget_temp_dir() {
  local target="$1"
  local -a remaining
  local cleanup_path
  for cleanup_path in "${ASF_CLEANUP_DIRS[@]}"; do
    [[ "$cleanup_path" == "$target" ]] || remaining+=("$cleanup_path")
  done
  ASF_CLEANUP_DIRS=("${remaining[@]}")
}

asf_lock_acquire() {
  local timeout="${1:-0}"
  if [[ -L "$ASF_LOCK_FILE" ]]; then
    asf_error "ASF lock path is a symlink; refusing to change its target"
    return 1
  fi
  zmodload zsh/system 2>/dev/null || {
    asf_error "zsh/system is unavailable; cannot protect ASF state"
    return 1
  }
  if ! mkdir -p "${ASF_LOCK_FILE:h}"; then
    asf_error "cannot create the ASF state directory"
    return 1
  fi
  if ! : >>"$ASF_LOCK_FILE"; then
    asf_error "cannot create the ASF lock file"
    return 1
  fi
  chmod 600 "$ASF_LOCK_FILE" 2>/dev/null || true
  if zsystem flock -t "$timeout" -f ASF_LOCK_FD "$ASF_LOCK_FILE"; then
    return 0
  fi
  ASF_LOCK_FD=''
  asf_pending "another ASF setup or backup run is active"
  return 2
}

asf_lock_check() {
  [[ -e "$ASF_LOCK_FILE" ]] || return 0
  zmodload zsh/system 2>/dev/null || {
    asf_error "zsh/system is unavailable; cannot inspect ASF setup state"
    return 1
  }
  if zsystem flock -r -t 0 -f ASF_LOCK_FD "$ASF_LOCK_FILE"; then
    zsystem flock -u "$ASF_LOCK_FD" 2>/dev/null || true
    ASF_LOCK_FD=''
    return 0
  fi
  ASF_LOCK_FD=''
  asf_pending "another ASF setup or backup run is active"
  return 2
}

asf_config_present() {
  [[ -f "$ASF_DIR/config/ASF.json" && ! -L "$ASF_DIR/config/ASF.json" ]]
}

asf_validate_json() {
  setopt local_options pipefail
  local json_path="$1"
  [[ -s "$json_path" && -f "$json_path" && ! -L "$json_path" ]] || return 1
  [[ -x "$ASF_PLUTIL_BIN" ]] || return 1
  "$ASF_PLUTIL_BIN" -convert xml1 -o - "$json_path" 2>/dev/null \
    | awk '/<plist[[:space:]][^>]*>/ { getline; if ($0 ~ /^[[:space:]]*<dict>/) valid=1; exit } END { exit !valid }'
}

asf_validate_config_dir() {
  local config_dir="$1"
  [[ -d "$config_dir" && ! -L "$config_dir" ]] || return 1
  asf_validate_json "$config_dir/ASF.json"
}

asf_secure_config_tree() {
  local config_dir="$1"
  [[ -d "$config_dir" && ! -L "$config_dir" ]] || return 1
  find "$config_dir" -type d -exec chmod go-rwx {} + || {
    asf_error "could not restrict ASF config directory permissions"
    return 1
  }
  find "$config_dir" -type f -exec chmod go-rwx {} + || {
    asf_error "could not restrict ASF config file permissions"
    return 1
  }
}

asf_sha256() {
  local output hash
  output="$("$ASF_SHASUM_BIN" -a 256 "$1")" || return 1
  hash="${output%% *}"
  [[ ${#hash} -eq 64 ]] || return 1
  print -r -- "$hash"
}

asf_refresh_snapshots() {
  ASF_SNAPSHOTS=()
  [[ -d "$ASF_BACKUPS_DIR" ]] || return 0
  [[ -r "$ASF_BACKUPS_DIR" && -x "$ASF_BACKUPS_DIR" ]] || {
    asf_error "cannot read the iCloud ASF backup folder"
    return 1
  }
  ASF_SNAPSHOTS=("$ASF_BACKUPS_DIR"/asf-config-*.tar.gz.enc(NOn))
}

asf_find_placeholder() {
  local directory="$1"
  [[ -d "$directory" ]] || return 0
  find "$directory" -maxdepth 1 -type f -name '*.icloud' -print -quit 2>/dev/null
}

asf_hydrate_backups() {
  local require_snapshot="$1"
  local placeholder='' elapsed=0 output snapshot_path needs_download=0
  local -i timeout="$ASF_HYDRATE_TIMEOUT"
  if [[ ! -d "$ASF_BACKUPS_DIR" ]]; then
    (( require_snapshot )) && asf_pending "iCloud backup folder is missing; sign in to iCloud Drive and retry"
    return $(( require_snapshot ? 2 : 0 ))
  fi

  asf_refresh_snapshots || return 1
  placeholder="$(asf_find_placeholder "$ASF_BACKUPS_DIR")" || {
    asf_error "cannot inspect the iCloud backup folder"
    return 1
  }
  [[ -n "$placeholder" ]] && needs_download=1
  for snapshot_path in "${ASF_SNAPSHOTS[@]}"; do
    output="$(/bin/ls -ldO "$snapshot_path" 2>/dev/null)" || {
      asf_error "cannot inspect an iCloud ASF snapshot"
      return 1
    }
    [[ "$output" == *dataless* ]] && needs_download=1
  done
  if (( needs_download )) || { (( require_snapshot )) && (( ${#ASF_SNAPSHOTS[@]} == 0 )); }; then
    if command -v brctl >/dev/null 2>&1; then
      brctl download "$ASF_BACKUPS_DIR" >/dev/null 2>&1 &
      ASF_CHILD_PID=$!
      elapsed=0
      while kill -0 "$ASF_CHILD_PID" 2>/dev/null; do
        if (( elapsed >= timeout )); then
          kill "$ASF_CHILD_PID" 2>/dev/null || true
          wait "$ASF_CHILD_PID" 2>/dev/null || true
          ASF_CHILD_PID=''
          asf_pending "iCloud hydration did not finish within ${timeout}s; wait and retry"
          return 2
        fi
        sleep 1 || {
          asf_error "could not wait for iCloud hydration"
          return 1
        }
        (( elapsed += 1 ))
      done
      wait "$ASF_CHILD_PID" 2>/dev/null || true
      ASF_CHILD_PID=''
    fi
    elapsed=0
    while true; do
      asf_refresh_snapshots || return 1
      placeholder="$(asf_find_placeholder "$ASF_BACKUPS_DIR")" || {
        asf_error "cannot inspect the iCloud backup folder"
        return 1
      }
      needs_download=0
      [[ -n "$placeholder" ]] && needs_download=1
      for snapshot_path in "${ASF_SNAPSHOTS[@]}"; do
        output="$(/bin/ls -ldO "$snapshot_path" 2>/dev/null)" || {
          asf_error "cannot inspect an iCloud ASF snapshot"
          return 1
        }
        [[ "$output" == *dataless* ]] && needs_download=1
      done
      if (( ! needs_download )) && { (( ! require_snapshot )) || (( ${#ASF_SNAPSHOTS[@]} > 0 )); }; then
        break
      fi
      if (( elapsed >= timeout )); then
        if (( needs_download )); then
          asf_pending "iCloud backup files are still placeholders; wait for hydration and retry"
        else
          asf_pending "no downloaded ASF snapshot is available; finish ASF setup manually and retry"
        fi
        return 2
      fi
      sleep 1 || {
        asf_error "could not wait for iCloud hydration"
        return 1
      }
      (( elapsed += 1 ))
    done
  fi
  return 0
}

asf_archive_snapshot_list() {
  local label="$1"
  shift
  local -a snapshots=("$@")
  local -a missing
  local source before after copied copy_hash manifest tmp final stamp archive_dir existing existing_hash temp_label suffix
  local saved_newest=''
  ASF_ARCHIVE_HASHES=()
  ASF_LAST_SNAPSHOT=''
  ASF_LAST_ARCHIVE=''
  (( ${#snapshots[@]} > 0 )) || return 0

  if [[ -L "$ASF_RESTORE_ARCHIVE_DIR" || ( -e "$ASF_RESTORE_ARCHIVE_DIR" && ! -d "$ASF_RESTORE_ARCHIVE_DIR" ) ]]; then
    asf_error "private ASF restore archive path is not a regular directory"
    return 1
  fi
  if ! mkdir -p "$ASF_RESTORE_ARCHIVE_DIR"; then
    asf_error "cannot create the private ASF restore archive directory"
    return 1
  fi
  chmod 700 "$ASF_RESTORE_ARCHIVE_DIR" || {
    asf_error "cannot secure the private ASF restore archive directory"
    return 1
  }

  for source in "${snapshots[@]}"; do
    [[ -f "$source" && ! -L "$source" ]] || {
      asf_error "a listed ASF snapshot is not a regular file; no service was started"
      return 1
    }
    before="$(asf_sha256 "$source")" || {
      asf_error "cannot hash an ASF snapshot; no service was started"
      return 1
    }
    existing=''
    if [[ "$label" == asf-snapshots ]]; then
      for archive_dir in "$ASF_RESTORE_ARCHIVE_DIR"/asf-snapshots-*(N/); do
        [[ -d "$archive_dir" && ! -L "$archive_dir" ]] || continue
        archive_dir="${archive_dir%/}"
        existing="$archive_dir/${source:t}"
        if [[ -f "$existing" && ! -L "$existing" ]]; then
          existing_hash="$(asf_sha256 "$existing")" || return 1
          if [[ "$before" == "$existing_hash" ]]; then
            ASF_ARCHIVE_HASHES[$source]="$before"
            [[ "$source" == "${snapshots[1]}" ]] && saved_newest="$existing"
            existing="$archive_dir"
            break
          fi
        fi
        existing=''
      done
    fi
    if [[ -z "$existing" ]]; then
      missing+=("$source")
    fi
  done
  if (( ${#missing[@]} == 0 )); then
    ASF_LAST_SNAPSHOT="$saved_newest"
    asf_log "all ${#snapshots[@]} encrypted snapshot(s) are already preserved and verified"
    return 0
  fi

  temp_label="$label"
  [[ "$temp_label" == asf-* ]] && temp_label="${temp_label#asf-}"
  tmp="$(mktemp -d "$ASF_RESTORE_ARCHIVE_DIR/.asf-${temp_label}.XXXXXX")" || {
    asf_error "cannot create a temporary snapshot archive"
    return 1
  }
  asf_register_temp_dir "$tmp"
  chmod 700 "$tmp" || return 1
  manifest="$tmp/SHA256SUMS"
  : >"$manifest" || return 1
  chmod 600 "$manifest" || return 1

  for source in "${missing[@]}"; do
    [[ -f "$source" && ! -L "$source" ]] || {
      asf_error "a listed ASF snapshot is not a regular file; no service was started"
      return 1
    }
    before="$(asf_sha256 "$source")" || {
      asf_error "cannot hash an ASF snapshot; no service was started"
      return 1
    }
    copied="$tmp/${source:t}"
    cp -p "$source" "$copied" || {
      asf_error "cannot copy ASF snapshots to the private restore archive"
      return 1
    }
    chmod 600 "$copied" || return 1
    after="$(asf_sha256 "$source")" || return 1
    copy_hash="$(asf_sha256 "$copied")" || return 1
    if [[ "$before" != "$after" || "$before" != "$copy_hash" ]]; then
      asf_error "snapshot changed while it was being archived; no service was started"
      return 1
    fi
    print -r -- "$before  ${source:t}" >>"$manifest" || return 1
    ASF_ARCHIVE_HASHES[$source]="$before"
    [[ "$source" == "${snapshots[1]}" ]] && saved_newest="$tmp/${source:t}"
  done

  stamp="$(date '+%Y%m%d-%H%M%S')" || {
    asf_error "could not timestamp the private snapshot archive"
    return 1
  }
  suffix="${tmp:t}"
  suffix="${suffix#.asf-${temp_label}.}"
  final="$ASF_RESTORE_ARCHIVE_DIR/${label}-$stamp-$suffix"
  if [[ -e "$final" ]]; then
    final="$final-$$"
  fi
  mv -n "$tmp" "$final" || {
    asf_error "cannot publish the private ASF restore archive"
    return 1
  }
  if [[ -d "$tmp" || ! -d "$final" ]]; then
    asf_error "cannot publish the private ASF restore archive"
    return 1
  fi
  asf_forget_temp_dir "$tmp"
  ASF_LAST_ARCHIVE="$final"
  if [[ -n "$saved_newest" ]]; then
    if [[ "$saved_newest" == "$tmp/"* ]]; then
      ASF_LAST_SNAPSHOT="$final/${saved_newest:t}"
    else
      ASF_LAST_SNAPSHOT="$saved_newest"
    fi
  fi
  asf_log "preserved ${#missing[@]} new encrypted snapshot(s) in the private restore archive"
}

asf_archive_snapshots() {
  asf_archive_snapshot_list asf-snapshots "${ASF_SNAPSHOTS[@]}"
}

asf_load_keychain_passphrase() {
  local password=''
  if ! command -v security >/dev/null 2>&1; then
    asf_error "macOS Keychain access is unavailable"
    return 1
  fi
  password="$(security find-generic-password -s asf-backup -w 2>/dev/null; print -rn -- $'\034')" || password=''
  [[ "$password" == *$'\034' ]] || password=''
  password="${password%$'\034'}"
  [[ "$password" == *$'\n' ]] && password="${password%$'\n'}"
  if [[ -z "$password" ]]; then
    unset password
    return 1
  fi
  ASF_PASSPHRASE="$password"
  unset password
  return 0
}

asf_setup_passphrase() {
  if asf_load_keychain_passphrase; then
    asf_log "backup passphrase is available in Keychain"
    return 0
  fi
  if ! command -v security >/dev/null 2>&1; then
    asf_error "macOS Keychain access is unavailable"
    return 1
  fi
  if security find-generic-password -s asf-backup >/dev/null 2>&1; then
    asf_pending "the ASF Keychain item exists but is unreadable; it was left unchanged"
    return 2
  fi
  if [[ -x "$ASF_SECRET_SCRIPT" ]]; then
    "$ASF_SECRET_SCRIPT" --no-bitwarden || {
      asf_pending "run setup-asf-secret --no-bitwarden to add the ASF passphrase to Keychain"
      return 2
    }
  elif [[ -r /dev/tty && -w /dev/tty ]]; then
    print -u2 -r -- "Add the existing ASF backup passphrase to Keychain. Input is hidden by macOS Security."
    if ! security add-generic-password -a "$USER" -s asf-backup -l "ASF config backup passphrase" -T /usr/bin/security -w; then
      asf_pending "the ASF passphrase was not added; run setup-asf-secret and retry"
      return 2
    fi
  else
    asf_pending "run setup-asf-secret --no-bitwarden to add the ASF passphrase to Keychain"
    return 2
  fi
  if ! asf_load_keychain_passphrase; then
    asf_pending "the ASF passphrase is not readable from Keychain; its existing item was left unchanged"
    return 2
  fi
  asf_log "backup passphrase is available in Keychain"
}

asf_validate_archive() {
  local archive="$1" work_dir="$2" entry type
  local members="$work_dir/members"
  local details="$work_dir/details"
  if ! tar -tzf "$archive" >"$members" 2>/dev/null; then
    asf_error "encrypted snapshot does not contain a valid tar archive"
    return 1
  fi
  if ! grep -Fxq 'config/ASF.json' "$members"; then
    asf_error "snapshot is missing config/ASF.json"
    return 1
  fi
  while IFS= read -r entry; do
    case "$entry" in
      config|config/|config/*) ;;
      *) asf_error "snapshot contains a path outside config/"; return 1 ;;
    esac
    if [[ "$entry" == /* || "$entry" == ../* || "$entry" == */../* || "$entry" == */.. || "$entry" == config/. || "$entry" == *'/./'* ]]; then
      asf_error "snapshot contains an unsafe path"
      return 1
    fi
  done <"$members"
  if ! tar -tvzf "$archive" >"$details" 2>/dev/null; then
    asf_error "snapshot member metadata is invalid"
    return 1
  fi
  while IFS= read -r entry; do
    type="${entry[1]}"
    case "$type" in
      -|d) ;;
      *) asf_error "snapshot contains a link or special file; restore was refused"; return 1 ;;
    esac
  done <"$details"
  return 0
}

asf_validate_encrypted_snapshot() {
  local snapshot="$1" password="$2" work_dir="$3"
  local plain="$work_dir/snapshot.tar.gz"
  [[ -s "$snapshot" && -f "$snapshot" && ! -L "$snapshot" ]] || {
    asf_error "snapshot is missing or is not a regular file"
    return 1
  }
  [[ -x "$ASF_OPENSSL_BIN" ]] || {
    asf_error "OpenSSL is unavailable"
    return 1
  }
  if ! PW="$password" "$ASF_OPENSSL_BIN" enc -d -aes-256-cbc -pbkdf2 -pass env:PW -in "$snapshot" -out "$plain" 2>/dev/null; then
    asf_error "snapshot decryption failed"
    return 1
  fi
  chmod 600 "$plain" || return 1
  asf_validate_archive "$plain" "$work_dir"
}

asf_restore_snapshot() {
  local snapshot="$1" stage unpacked
  stage="$(mktemp -d "$ASF_DIR/.asf-restore.XXXXXX")" || {
    asf_error "cannot create private restore staging"
    return 1
  }
  asf_register_temp_dir "$stage"
  chmod 700 "$stage" || return 1
  if ! asf_validate_encrypted_snapshot "$snapshot" "$ASF_PASSPHRASE" "$stage"; then
    return 1
  fi
  unpacked="$stage/unpacked"
  mkdir -m 700 "$unpacked" || return 1
  if ! tar -xzf "$stage/snapshot.tar.gz" -C "$unpacked" 2>/dev/null; then
    asf_error "snapshot extraction failed"
    return 1
  fi
  if ! asf_validate_config_dir "$unpacked/config"; then
    asf_error "restored config/ASF.json is invalid"
    return 1
  fi
  if ! asf_secure_config_tree "$unpacked/config"; then
    return 1
  fi
  if [[ -e "$ASF_DIR/config" || -L "$ASF_DIR/config" ]]; then
    asf_pending "ASF config appeared during restore; existing files were left unchanged"
    return 2
  fi
  if ! mv -n "$unpacked/config" "$ASF_DIR/config" || [[ -e "$unpacked/config" || -L "$unpacked/config" ]]; then
    if [[ -e "$ASF_DIR/config" || -L "$ASF_DIR/config" ]]; then
      asf_pending "ASF config appeared during restore; existing files were left unchanged"
      return 2
    fi
    asf_error "could not install the validated ASF config"
    return 1
  fi
  asf_validate_config_dir "$ASF_DIR/config" || {
    asf_error "installed ASF config failed validation"
    return 1
  }
  asf_secure_config_tree "$ASF_DIR/config" || return 1
  asf_log "restored the validated newest ASF snapshot"
  asf_remove_temp_dir "$stage"
}

asf_remove_temp_dir() {
  local target="$1"
  case "$target" in
    "$ASF_DIR"/.asf-restore.*|"$ASF_TMP_ROOT"/asf-setup.*|"$ASF_TMP_ROOT"/asf-backup.*|"$ASF_RESTORE_ARCHIVE_DIR"/.asf-snapshots.*)
      /bin/rm -rf -- "$target" || return 1
      asf_forget_temp_dir "$target"
      ;;
    *)
      asf_error "refused to remove a path outside ASF temporary storage"
      return 1
      ;;
  esac
}

asf_install_binary() {
  setopt local_options pipefail
  local tmp src entry url
  if [[ -x "$ASF_DIR/ArchiSteamFarm" ]]; then
    asf_log "ASF binary is already present"
    return 0
  fi
  tmp="$(mktemp -d "$ASF_TMP_ROOT/asf-setup.XXXXXX")" || {
    asf_error "cannot create a temporary ASF download directory"
    return 1
  }
  asf_register_temp_dir "$tmp"
  chmod 700 "$tmp" || return 1
  asf_log "downloading ASF for Apple silicon"
  if command -v gh >/dev/null 2>&1; then
    if ! (cd "$tmp" && gh release download --repo JustArchiNET/ArchiSteamFarm --pattern 'ASF-osx-arm64.zip'); then
      asf_error "ASF download failed"
      return 1
    fi
  else
    url="$(curl -fsSL https://api.github.com/repos/JustArchiNET/ArchiSteamFarm/releases/latest \
      | awk -F'"' '/browser_download_url/ && /ASF-osx-arm64\.zip/ {print $4; exit}')" || url=''
    if [[ -z "$url" ]] || ! curl -fsSL -o "$tmp/ASF-osx-arm64.zip" "$url"; then
      asf_error "could not download the ASF release"
      return 1
    fi
  fi
  if ! ditto -xk "$tmp/ASF-osx-arm64.zip" "$tmp/unzipped"; then
    asf_error "ASF release extraction failed"
    return 1
  fi
  src="$tmp/unzipped"
  [[ -d "$src/ASF-osx-arm64" ]] && src="$src/ASF-osx-arm64"
  [[ -d "$src" ]] || { asf_error "ASF release contents are missing"; return 1; }
  for entry in "$src"/*(DN); do
    [[ "${entry:t}" == config ]] && continue
    cp -Rp -n "$entry" "$ASF_DIR/" || {
      asf_error "could not install ASF release files"
      return 1
    }
  done
  if [[ ! -x "$ASF_DIR/ArchiSteamFarm" ]]; then
    asf_error "ASF release did not install an executable"
    return 1
  fi
  chmod +x "$ASF_DIR/ArchiSteamFarm" || return 1
  xattr -d com.apple.quarantine "$ASF_DIR/ArchiSteamFarm" 2>/dev/null || true
  asf_log "ASF binary installed without replacing existing config files"
}

asf_plist_valid() {
  local plist="$1" expected_label="$2" label
  [[ -f "$plist" && ! -L "$plist" ]] || return 2
  "$ASF_PLUTIL_BIN" -lint "$plist" >/dev/null 2>&1 || return 1
  label="$("$ASF_PLUTIL_BIN" -extract Label raw -o - "$plist" 2>/dev/null)" || return 1
  [[ "$label" == "$expected_label" ]] || return 1
  "$ASF_PLUTIL_BIN" -type ProgramArguments "$plist" >/dev/null 2>&1 || return 1
  return 0
}

asf_plist_arguments() {
  setopt local_options extended_glob
  local plist="$1" text line
  local -a args
  text="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$plist" 2>/dev/null)" || return 1
  for line in "${(@f)text}"; do
    [[ "$line" == 'Array {' || "$line" == '}' ]] && continue
    line="${line##[[:space:]]#}"
    [[ -n "$line" ]] && args+=("$line")
  done
  (( ${#args[@]} > 0 )) || return 1
  print -rl -- "${args[@]}"
}

asf_printed_arguments() {
  setopt local_options extended_glob
  local output="$1" line inside=0
  local -a args
  for line in "${(@f)output}"; do
    if [[ "$line" == *'arguments = {'* ]]; then
      inside=1
      continue
    fi
    (( inside )) || continue
    line="${line##[[:space:]]#}"
    [[ "$line" == '}'* ]] && break
    [[ -n "$line" ]] && args+=("$line")
  done
  (( ${#args[@]} > 0 )) || return 1
  print -rl -- "${args[@]}"
}

asf_agent_marker() {
  print -r -- "$ASF_STATE_DIR/agent-${1}.sha256"
}

asf_agent_matches() {
  local label="$1" plist="$2" output expected_text actual_text expected_hash marker saved_hash
  local -a expected_args actual_args
  output="$(launchctl print "$ASF_GUI_DOMAIN/$label" 2>/dev/null)" || return 1
  expected_text="$(asf_plist_arguments "$plist")" || return 1
  actual_text="$(asf_printed_arguments "$output")" || return 1
  expected_args=("${(@f)expected_text}")
  actual_args=("${(@f)actual_text}")
  (( ${#expected_args[@]} == ${#actual_args[@]} )) || return 1
  local i
  for (( i = 1; i <= ${#expected_args[@]}; i++ )); do
    [[ "${expected_args[$i]}" == "${actual_args[$i]}" ]] || return 1
  done
  expected_hash="$(asf_sha256 "$plist")" || return 1
  marker="$(asf_agent_marker "$label")"
  if [[ -f "$marker" ]]; then
    saved_hash="$(<"$marker")"
    [[ "$saved_hash" == "$expected_hash" ]] || return 1
  fi
  return 0
}

asf_record_agent_hash() {
  local label="$1" plist="$2" marker tmp hash
  hash="$(asf_sha256 "$plist")" || return 1
  marker="$(asf_agent_marker "$label")"
  tmp="$(mktemp "$ASF_STATE_DIR/.agent-${label}.tmp.XXXXXX")" || return 1
  if ! print -r -- "$hash" >"$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$marker"; then
    /bin/rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
}

asf_agent_loaded() {
  launchctl print "$ASF_GUI_DOMAIN/$1" >/dev/null 2>&1
}

asf_stop_agent() {
  local label="$1"
  if asf_agent_loaded "$label"; then
    if ! launchctl bootout "$ASF_GUI_DOMAIN/$label" >/dev/null 2>&1; then
      asf_error "could not stop $label"
      return 1
    fi
  fi
}

asf_ensure_agent() {
  local label="$1" plist="$2"
  if asf_agent_matches "$label" "$plist"; then
    asf_record_agent_hash "$label" "$plist" || {
      asf_error "could not record the loaded $label configuration"
      return 1
    }
    asf_log "$label is already loaded with the current configuration"
    return 0
  fi
  if asf_agent_loaded "$label"; then
    launchctl bootout "$ASF_GUI_DOMAIN/$label" >/dev/null 2>&1 || {
      asf_error "could not replace the loaded $label configuration"
      return 1
    }
  fi
  if ! launchctl bootstrap "$ASF_GUI_DOMAIN" "$plist"; then
    if asf_agent_matches "$label" "$plist"; then
      asf_record_agent_hash "$label" "$plist" || return 1
      asf_log "$label was loaded by another setup run"
      return 0
    fi
    asf_error "could not load $label"
    return 1
  fi
  if ! asf_agent_matches "$label" "$plist"; then
    asf_error "$label did not load with the expected configuration"
    return 1
  fi
  asf_record_agent_hash "$label" "$plist" || {
    asf_error "could not record the loaded $label configuration"
    return 1
  }
  asf_log "loaded $label"
}

asf_check() {
  local pending=0 failure=0 plist_rc
  if [[ ! -x "$ASF_DIR/ArchiSteamFarm" ]]; then
    asf_log "PENDING: ASF binary is not installed"
    pending=1
  fi
  if ! asf_config_present; then
    if [[ -e "$ASF_DIR/config" || -L "$ASF_DIR/config" ]]; then
      asf_error "ASF config directory exists without a regular config/ASF.json"
      failure=1
    else
      asf_log "PENDING: config/ASF.json is not present"
      pending=1
    fi
  elif ! asf_validate_config_dir "$ASF_DIR/config"; then
    asf_error "config/ASF.json is invalid"
    failure=1
  fi

  if asf_plist_valid "$ASF_SERVICE_PLIST" "$ASF_SERVICE_LABEL"; then
    plist_rc=0
  else
    plist_rc=$?
  fi
  if (( plist_rc == 2 )); then
    asf_log "PENDING: ASF service LaunchAgent is not installed"
    pending=1
  elif (( plist_rc != 0 )); then
    asf_error "ASF service LaunchAgent is invalid"
    failure=1
  fi
  if asf_plist_valid "$ASF_BACKUP_PLIST" "$ASF_BACKUP_LABEL"; then
    plist_rc=0
  else
    plist_rc=$?
  fi
  if (( plist_rc == 2 )); then
    asf_log "PENDING: ASF backup LaunchAgent is not installed"
    pending=1
  elif (( plist_rc != 0 )); then
    asf_error "ASF backup LaunchAgent is invalid"
    failure=1
  fi

  if ! command -v launchctl >/dev/null 2>&1; then
    asf_error "launchctl is unavailable"
    failure=1
  else
    if [[ -f "$ASF_SERVICE_PLIST" ]] && ! asf_agent_matches "$ASF_SERVICE_LABEL" "$ASF_SERVICE_PLIST"; then
      asf_log "PENDING: ASF service LaunchAgent is not loaded with the current configuration"
      pending=1
    fi
    if [[ -f "$ASF_BACKUP_PLIST" ]] && ! asf_agent_matches "$ASF_BACKUP_LABEL" "$ASF_BACKUP_PLIST"; then
      asf_log "PENDING: ASF backup LaunchAgent is not loaded with the current configuration"
      pending=1
    fi
  fi
  (( failure )) && return 1
  (( pending )) && return 2
  asf_log "READY: ASF config, binary, and both LaunchAgents are present"
  return 0
}

asf_main_setup() {
  local rc
  asf_init_paths
  if (( $# == 1 )) && [[ "$1" == --check ]]; then
    if asf_lock_check; then
      :
    else
      return $?
    fi
    asf_check
    return $?
  fi
  if (( $# != 0 )); then
    print -u2 -r -- "Usage: setup-asf [--check]"
    return 1
  fi

  if asf_lock_acquire 0; then
    :
  else
    return $?
  fi
  trap 'asf_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 129' HUP
  trap 'exit 143' TERM

  if [[ -L "$ASF_DIR" || ( -e "$ASF_DIR" && ! -d "$ASF_DIR" ) ]]; then
    asf_pending "ASF install path is not a regular directory; existing files were left unchanged"
    return 2
  fi
  if [[ ! -d "$ASF_DIR" ]]; then
    mkdir -p "$ASF_DIR" || {
      asf_error "cannot create the ASF install directory"
      return 1
    }
    chmod 700 "$ASF_DIR" || return 1
  else
    chmod 700 "$ASF_DIR" || {
      asf_error "could not restrict the ASF install directory permissions"
      return 1
    }
  fi
  if ! mkdir -p "$HOME/Library/Logs"; then
    asf_error "cannot create the ASF log directory"
    return 1
  fi

  if asf_hydrate_backups 0; then
    :
  else
    return $?
  fi
  if (( ${#ASF_SNAPSHOTS[@]} > 0 )); then
    if ! asf_archive_snapshots; then
      return 1
    fi
  fi

  if [[ -e "$ASF_DIR/config" || -L "$ASF_DIR/config" ]]; then
    if ! asf_validate_config_dir "$ASF_DIR/config"; then
      asf_pending "an existing ASF config is incomplete or invalid; it was left unchanged"
      return 2
    fi
    if ! asf_secure_config_tree "$ASF_DIR/config"; then
      return 1
    fi
    asf_log "validated existing ASF config; restore skipped"
  else
    if asf_hydrate_backups 1; then
      :
    else
      rc=$?
      if (( rc == 2 )); then
        if ! asf_install_binary; then
          return 1
        fi
      fi
      return "$rc"
    fi
    if (( ${#ASF_SNAPSHOTS[@]} == 0 )); then
      if ! asf_install_binary; then
        return 1
      fi
      asf_pending "no hydrated ASF snapshot is available; configure ASF manually and retry"
      return 2
    fi
    if [[ -z "$ASF_LAST_SNAPSHOT" ]]; then
      if ! asf_archive_snapshots; then
        return 1
      fi
    fi
    if asf_setup_passphrase; then
      :
    else
      return $?
    fi
    if asf_restore_snapshot "$ASF_LAST_SNAPSHOT"; then
      :
    else
      return $?
    fi
  fi

  if asf_setup_passphrase; then
    :
  else
    return $?
  fi
  if ! asf_validate_config_dir "$ASF_DIR/config"; then
    asf_error "ASF config failed its final validation"
    return 1
  fi
  if ! asf_install_binary; then
    return 1
  fi
  if [[ ! -x "$ASF_DIR/ArchiSteamFarm" ]]; then
    asf_error "ASF executable is missing after installation"
    return 1
  fi

  if asf_plist_valid "$ASF_SERVICE_PLIST" "$ASF_SERVICE_LABEL"; then
    rc=0
  else
    rc=$?
  fi
  if (( rc == 2 )); then
    asf_pending "ASF LaunchAgent plist is missing; apply the dotfiles and retry"
    return 2
  elif (( rc != 0 )); then
    asf_error "ASF LaunchAgent plist is invalid"
    return 1
  fi
  if asf_plist_valid "$ASF_BACKUP_PLIST" "$ASF_BACKUP_LABEL"; then
    rc=0
  else
    rc=$?
  fi
  if (( rc == 2 )); then
    asf_pending "ASF backup LaunchAgent plist is missing; apply the dotfiles and retry"
    return 2
  elif (( rc != 0 )); then
    asf_error "ASF backup LaunchAgent plist is invalid"
    return 1
  fi

  if ! asf_ensure_agent "$ASF_SERVICE_LABEL" "$ASF_SERVICE_PLIST"; then
    return 1
  fi
  if ! asf_ensure_agent "$ASF_BACKUP_LABEL" "$ASF_BACKUP_PLIST"; then
    return 1
  fi
  asf_check
}

asf_prune_snapshots() {
  local -a candidates
  local -i i keep
  local source before archive rc
  [[ "$ASF_KEEP" == <-> ]] && (( ASF_KEEP > 0 )) || {
    asf_error "ASF_KEEP must be a positive integer; pruning was skipped"
    return 1
  }
  keep="$ASF_KEEP"
  if asf_hydrate_backups 0; then
    :
  else
    return $?
  fi
  local placeholder
  placeholder="$(asf_find_placeholder "$ASF_BACKUPS_DIR")" || {
    asf_error "cannot confirm the iCloud backup inventory; pruning was skipped"
    return 2
  }
  if [[ -n "$placeholder" ]]; then
    asf_pending "iCloud inventory is still incomplete; pruning was skipped"
    return 2
  fi
  if ! asf_refresh_snapshots; then
    return 1
  fi
  (( ${#ASF_SNAPSHOTS[@]} > keep )) || return 0
  for (( i = keep + 1; i <= ${#ASF_SNAPSHOTS[@]}; i++ )); do
    source="${ASF_SNAPSHOTS[$i]}"
    [[ -f "$source" && ! -L "$source" ]] || {
      asf_error "an ASF snapshot is not a regular file; pruning was skipped"
      return 2
    }
    candidates+=("$source")
  done
  if ! asf_archive_snapshot_list asf-pruned "${candidates[@]}"; then
    asf_error "could not preserve snapshots selected for pruning; old files were kept"
    return 1
  fi
  archive="$ASF_LAST_ARCHIVE"
  for source in "${candidates[@]}"; do
    before="$(asf_sha256 "$source")" || {
      asf_pending "could not recheck an old snapshot; pruning was skipped"
      return 2
    }
    if [[ "$before" != "${ASF_ARCHIVE_HASHES[$source]}" ]]; then
      asf_pending "an old snapshot changed during pruning; all source files were kept"
      return 2
    fi
  done
  for source in "${candidates[@]}"; do
    if ! /bin/rm -f -- "$source"; then
      asf_error "could not remove an old snapshot; remaining copies are preserved in $archive"
      return 1
    fi
  done
  case "$archive" in
    "$ASF_RESTORE_ARCHIVE_DIR"/asf-pruned-*)
      /bin/rm -rf -- "$archive" 2>/dev/null || asf_log "prune completed; private recovery copies remain at $archive"
      ;;
  esac
  asf_log "pruned ${#candidates[@]} old snapshot(s); newest $keep remain"
}

asf_main_backup() {
  local rc safe_to_prune=1 work source_dir archive_file validation_dir stamp candidate publish_tmp suffix
  asf_init_paths
  if (( $# != 0 )); then
    print -u2 -r -- "Usage: backup-asf-config.sh"
    return 1
  fi
  if asf_lock_acquire "${ASF_BACKUP_LOCK_TIMEOUT:-120}"; then
    :
  else
    return $?
  fi
  trap 'asf_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 129' HUP
  trap 'exit 143' TERM

  if [[ ! -d "$ASF_DIR/config" || -L "$ASF_DIR/config" ]]; then
    asf_pending "ASF config directory is missing or unsafe"
    return 2
  fi
  if ! asf_validate_config_dir "$ASF_DIR/config"; then
    asf_error "ASF config is invalid; no backup was written"
    return 1
  fi
  if asf_load_keychain_passphrase; then
    :
  else
    asf_error "could not read the asf-backup passphrase from Keychain"
    return 1
  fi

  if asf_hydrate_backups 0; then
    :
  else
    rc=$?
    if (( rc == 2 )); then
      safe_to_prune=0
      asf_log "backup will continue; pruning is disabled until iCloud inventory is complete"
    else
      return "$rc"
    fi
  fi
  if [[ -L "$ASF_BACKUPS_DIR" ]]; then
    asf_error "ASF backup destination is a symlink; no backup was written"
    return 1
  fi
  if ! mkdir -p "$ASF_BACKUPS_DIR"; then
    asf_error "cannot create the iCloud ASF backup folder"
    return 1
  fi
  work="$(mktemp -d "$ASF_TMP_ROOT/asf-backup.XXXXXX")" || {
    asf_error "cannot create private ASF backup staging"
    return 1
  }
  asf_register_temp_dir "$work"
  chmod 700 "$work" || return 1
  source_dir="$work/source"
  mkdir -m 700 "$source_dir" || return 1
  if ! cp -Rp "$ASF_DIR/config" "$source_dir/config"; then
    asf_error "could not copy ASF config to private staging"
    return 1
  fi
  if ! asf_validate_config_dir "$source_dir/config"; then
    asf_error "copied ASF config failed validation; no backup was written"
    return 1
  fi
  archive_file="$work/config.tar.gz"
  if ! tar -czf "$archive_file" -C "$source_dir" config; then
    asf_error "could not archive ASF config"
    return 1
  fi
  chmod 600 "$archive_file" || return 1
  local encrypted="$work/asf-config.tar.gz.enc"
  if [[ ! -x "$ASF_OPENSSL_BIN" ]] || ! PW="$ASF_PASSPHRASE" "$ASF_OPENSSL_BIN" enc -aes-256-cbc -pbkdf2 -salt -pass env:PW -in "$archive_file" -out "$encrypted"; then
    asf_error "ASF snapshot encryption failed; existing snapshots were kept"
    return 1
  fi
  chmod 600 "$encrypted" || return 1
  validation_dir="$work/validation"
  mkdir -m 700 "$validation_dir" || return 1
  if ! asf_validate_encrypted_snapshot "$encrypted" "$ASF_PASSPHRASE" "$validation_dir"; then
    asf_error "encrypted ASF snapshot failed validation; existing snapshots were kept"
    return 1
  fi

  stamp="$(date '+%Y%m%d-%H%M%S')" || {
    asf_error "could not timestamp the encrypted ASF snapshot"
    return 1
  }
  candidate="$ASF_BACKUPS_DIR/asf-config-$stamp.tar.gz.enc"
  suffix=1
  while [[ -e "$candidate" || -L "$candidate" ]]; do
    candidate="$ASF_BACKUPS_DIR/asf-config-$stamp-$(printf '%02d' "$suffix").tar.gz.enc"
    (( suffix += 1 ))
  done
  publish_tmp="$(mktemp "$ASF_BACKUPS_DIR/.asf-config-$stamp.tmp.XXXXXX")" || {
    asf_error "cannot stage the encrypted snapshot in iCloud"
    return 1
  }
  chmod 600 "$publish_tmp" || return 1
  asf_register_temp_file "$publish_tmp"
  if ! cp "$encrypted" "$publish_tmp"; then
    asf_error "could not copy the validated snapshot into iCloud staging"
    return 1
  fi
  if ! asf_validate_encrypted_snapshot "$publish_tmp" "$ASF_PASSPHRASE" "$validation_dir"; then
    asf_error "iCloud staging copy failed validation; existing snapshots were kept"
    return 1
  fi
  if ! mv -n "$publish_tmp" "$candidate" || [[ -e "$publish_tmp" || -L "$publish_tmp" ]]; then
    asf_error "could not atomically publish the encrypted snapshot"
    return 1
  fi
  asf_log "published validated encrypted snapshot ${candidate:t}"

  if ! asf_publish_recovery_helpers; then
    return 1
  fi

  if (( safe_to_prune )); then
    if asf_prune_snapshots; then
      :
    else
      rc=$?
      if (( rc == 2 )); then
        asf_log "new snapshot is safe; pruning remains pending"
        return 2
      else
        return "$rc"
      fi
    fi
  else
    asf_log "skipped pruning because iCloud did not provide a complete inventory"
    return 2
  fi
}

asf_publish_recovery_helper() {
  local source_file="$1" destination="$2" mode="$3" publish_tmp
  [[ -f "$source_file" && ! -L "$source_file" ]] || {
    asf_error "standalone recovery source is missing or unsafe: ${source_file:t}"
    return 1
  }
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -f "$destination" && ! -L "$destination" ]] || {
      asf_error "standalone recovery destination is not a regular file: ${destination:t}"
      return 1
    }
  fi
  publish_tmp="$(mktemp "$ASF_BACKUPS_DIR/.asf-recovery-${destination:t}.tmp.XXXXXX")" || {
    asf_error "cannot stage standalone recovery helper ${destination:t}"
    return 1
  }
  asf_register_temp_file "$publish_tmp"
  if ! cp -p "$source_file" "$publish_tmp" || ! chmod "$mode" "$publish_tmp" || ! cmp -s "$source_file" "$publish_tmp"; then
    asf_error "could not verify standalone recovery helper ${destination:t}"
    return 1
  fi
  if ! mv -f "$publish_tmp" "$destination"; then
    asf_error "could not publish standalone recovery helper ${destination:t}"
    return 1
  fi
  asf_log "published standalone recovery helper ${destination:t}"
}

asf_publish_recovery_helpers() {
  asf_publish_recovery_helper "$ASF_LIBRARY_SCRIPT" "$ASF_BACKUPS_DIR/asf-backup.zsh" 600 || return 1
  asf_publish_recovery_helper "$ASF_SETUP_SCRIPT" "$ASF_BACKUPS_DIR/setup-asf.sh" 700
}
