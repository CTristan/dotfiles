#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
library="$script_dir/../share/asf-backup/asf-backup.zsh"
if [[ ! -r "$library" ]]; then
  library="$script_dir/asf-backup.zsh"
  if [[ ! -r "$library" ]]; then
    print -u2 -r -- "ASF backup library is missing beside the script and in ~/.local/share/asf-backup"
    exit 1
  fi
fi
source "$library"
if asf_main_backup "$@"; then
  exit 0
else
  result_code=$?
  exit "$result_code"
fi
