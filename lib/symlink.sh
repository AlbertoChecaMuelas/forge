#!/usr/bin/env bash
# lib/symlink.sh — Symlink management for forge
# Compatible with bash 3.2+. Uses only indexed arrays (no associative arrays).
set -euo pipefail

# Guard against double-loading
if [ -n "${_FORGE_SYMLINK_LOADED:-}" ]; then
  return 0
fi
_FORGE_SYMLINK_LOADED=1

type -t forge_err >/dev/null 2>&1 || forge_err() { echo "[forge] ERROR: $1" >&2; }

# forge_symlink <source_abs> <dest_abs>
# Creates or repairs a symlink at dest pointing to source.
# Idempotent: no-op if already correct.
forge_symlink() {
  local src="$1"
  local dest="$2"

  # Reject relative paths
  case "$src" in
    /*) ;;
    *) echo "[symlink] ERROR: source must be absolute path: $src" >&2; forge_err "symlink: source must be absolute path: $src"; return 1 ;;
  esac
  case "$dest" in
    /*) ;;
    *) echo "[symlink] ERROR: dest must be absolute path: $dest" >&2; forge_err "symlink: dest must be absolute path: $dest"; return 1 ;;
  esac

  # Create parent directory if needed
  local dest_dir
  dest_dir="$(dirname "$dest")"
  if [ ! -d "$dest_dir" ]; then
    mkdir -p "$dest_dir" || { echo "[symlink] ERROR: cannot create dir $dest_dir" >&2; forge_err "symlink: cannot create dir $dest_dir"; return 1; }
    echo "[symlink] created dir $dest_dir"
  fi

  # Case 1: dest does not exist at all
  if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
    ln -s "$src" "$dest" || { echo "[symlink] ERROR: cannot create symlink $dest" >&2; forge_err "symlink: cannot create symlink $dest"; return 1; }
    echo "[symlink] created $dest -> $src"
    return 0
  fi

  # Case 2: dest is a symlink
  if [ -L "$dest" ]; then
    local current_target
    current_target="$(readlink "$dest")"
    if [ "$current_target" = "$src" ]; then
      # Already correct — no-op
      echo "[symlink] ok (already linked) -> $dest"
      return 0
    else
      # Wrong symlink — backup and replace
      local backup
      backup="${dest}.forge-bak-$(date +%s)"
      mv "$dest" "$backup" || { echo "[symlink] ERROR: cannot backup $dest" >&2; forge_err "symlink: cannot backup $dest"; return 1; }
      echo "[symlink] backup created: $backup"
      ln -s "$src" "$dest" || { echo "[symlink] ERROR: cannot create symlink $dest" >&2; forge_err "symlink: cannot create symlink $dest"; return 1; }
      echo "[symlink] relinked $dest -> $src (was -> $current_target)"
      return 0
    fi
  fi

  # Case 3: dest is a regular file or directory — backup and replace
  local backup
  backup="${dest}.forge-bak-$(date +%s)"
  mv "$dest" "$backup" || { echo "[symlink] ERROR: cannot backup $dest" >&2; forge_err "symlink: cannot backup $dest"; return 1; }
  echo "[symlink] backup created: $backup (was regular file/dir)"
  ln -s "$src" "$dest" || { echo "[symlink] ERROR: cannot create symlink $dest" >&2; forge_err "symlink: cannot create symlink $dest"; return 1; }
  echo "[symlink] created $dest -> $src"
  return 0
}

# forge_unlink <dest_abs>
# Removes a symlink. If dest.pre-forge exists, restores it.
# Does NOT touch regular files (logs warning).
forge_unlink() {
  local dest="$1"

  # Reject relative paths
  case "$dest" in
    /*) ;;
    *) echo "[symlink] ERROR: dest must be absolute path: $dest" >&2; forge_err "symlink: dest must be absolute path: $dest"; return 1 ;;
  esac

  if [ -L "$dest" ]; then
    rm "$dest" || { echo "[symlink] ERROR: cannot remove symlink $dest" >&2; forge_err "symlink: cannot remove symlink $dest"; return 1; }
    echo "[symlink] removed symlink $dest"

    # Reserved for future use: restores .pre-forge next to symlinked file (unused by current callers)
    local pre_forge="${dest}.pre-forge"
    if [ -e "$pre_forge" ]; then
      mv "$pre_forge" "$dest" || { echo "[symlink] ERROR: cannot restore $pre_forge" >&2; forge_err "symlink: cannot restore $pre_forge"; return 1; }
      echo "[symlink] restored $dest from .pre-forge"
    fi
    return 0
  fi

  # Not a symlink — log warning and do nothing
  if [ -e "$dest" ]; then
    echo "[symlink] WARNING: $dest is not a symlink, not removing" >&2
    return 0
  fi

  # Doesn't exist at all — silent no-op
  return 0
}
