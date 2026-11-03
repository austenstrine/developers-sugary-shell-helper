#!/usr/bin/env bash
# Symlink bin/dssh into ~/.local/bin (or DEST_DIR).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$root/bin/dssh"
dest_dir="${DEST_DIR:-$HOME/.local/bin}"
dest="$dest_dir/dssh"

if [[ ! -x "$src" ]]; then
  echo "install: missing executable $src" >&2
  exit 1
fi

mkdir -p "$dest_dir"
ln -sfn "$src" "$dest"
echo "installed: $dest -> $src"
echo "ensure $dest_dir is on PATH, then run: dssh help"
echo "optional: export DSSH_BIN=$src"
