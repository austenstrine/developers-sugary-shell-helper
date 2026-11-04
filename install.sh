#!/usr/bin/env bash
# Symlink bin/dssh and bin/rlog.sh into ~/.local/bin (or DEST_DIR).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest_dir="${DEST_DIR:-$HOME/.local/bin}"

install_link() {
  local src="$1"
  local dest="$2"
  if [[ ! -x "$src" ]]; then
    echo "install: missing executable $src" >&2
    exit 1
  fi
  ln -sfn "$src" "$dest"
  echo "installed: $dest -> $src"
}

mkdir -p "$dest_dir"
install_link "$root/bin/dssh" "$dest_dir/dssh"
install_link "$root/bin/rlog.sh" "$dest_dir/rlog.sh"
echo "ensure $dest_dir is on PATH, then run: dssh help"
echo "optional: export DSSH_BIN=$root/bin/dssh"
