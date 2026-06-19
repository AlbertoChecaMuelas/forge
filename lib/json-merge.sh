#!/usr/bin/env bash
# lib/json-merge.sh — JSON merge utilities for forge
# Compatible with bash 3.2+. Uses only indexed arrays (no associative arrays).
# All writes are atomic: tmpfile + jq empty + mv.
set -euo pipefail

# Guard against double-loading
if [ -n "${_FORGE_JSON_MERGE_LOADED:-}" ]; then
  return 0
fi
_FORGE_JSON_MERGE_LOADED=1

type -t forge_err >/dev/null 2>&1 || forge_err() { echo "[forge] ERROR: $1" >&2; }
type -t forge_warn >/dev/null 2>&1 || forge_warn() { echo "[forge] WARN: $1" >&2; }

# forge_json_get_path <file> <jq_path>
# Prints JSON value at jq_path in file, or "null" if absent.
forge_json_get_path() {
  local file="$1"
  local jq_path="$2"

  if [ ! -f "$file" ]; then
    echo "null"
    return 0
  fi

  jq -c "$jq_path" "$file" 2>/dev/null || echo "null"
}

# forge_json_set_path <file> <jq_path> <json_value>
# Atomically sets jq_path = json_value in file.
# Creates file as {} if it doesn't exist.
forge_json_set_path() {
  local file="$1"
  local jq_path="$2"
  local json_value="$3"

  # Create file if missing
  if [ ! -f "$file" ]; then
    local tmp_init
    tmp_init="$(mktemp)"
    printf '{}' > "$tmp_init"
    jq empty "$tmp_init" || { rm -f "$tmp_init"; echo "[settings] ERROR: cannot create empty JSON for $file" >&2; forge_err "cannot create empty JSON for $file"; return 1; }
    mv "$tmp_init" "$file"
  fi

  local tmp
  tmp="$(mktemp)"
  # Use --argjson to pass the value as JSON
  jq "$jq_path = \$val" --argjson val "$json_value" "$file" > "$tmp" || {
    rm -f "$tmp"
    echo "[settings] ERROR: jq failed to set $jq_path in $file" >&2
    forge_err "jq failed to set $jq_path in $file"
    return 1
  }
  jq empty "$tmp" || {
    rm -f "$tmp"
    echo "[settings] ERROR: result is not valid JSON for $file" >&2
    forge_err "result is not valid JSON for $file"
    return 1
  }
  mv "$tmp" "$file"
}

# _forge_json_merge_backup <target_file>
# Creates .pre-forge on first run.
# On subsequent runs: creates forge-bak-<epoch> ONLY if target differs from .pre-forge.
# Decision: idempotent re-install (same content) does NOT create new backup files.
_forge_json_merge_backup() {
  local target="$1"
  local pre_arsenal="${target}.pre-forge"

  if [ ! -f "$pre_arsenal" ]; then
    # First time: create .pre-forge
    cp "$target" "$pre_arsenal"
    echo "[settings] backup created: $pre_arsenal"
  else
    # Subsequent times: only backup if target differs from .pre-forge
    if ! diff -q "$target" "$pre_arsenal" >/dev/null 2>&1; then
      local bak
      bak="${target}.forge-bak-$(date +%s)"
      cp "$target" "$bak"
      echo "[settings] additional backup: $bak"
    else
      echo "[settings] no change since .pre-forge, skipping additional backup"
    fi
  fi
}

# forge_merge_component_settings <component_name> <target_settings_file> [--target-dir=<path>]
# Reads settings_key and managed_paths from shared/components/<component_name>.json.
#
# Behaviour:
#   - If settings_key is non-null/non-empty: merge that single key (see below).
#   - If settings_key is null/empty AND managed_paths is non-empty: read each
#     managed_paths entry directly from shared/settings.shared.json and merge it
#     into <target_settings_file> (handles the agents component).
#   - If both settings_key is null/empty AND managed_paths is empty: no-op.
#
# For plain dotted paths (e.g. "statusLine", "permissions.allow", "model"):
#   Extracts the fragment at .<path> from shared/settings.shared.json
#   and merges it into <target_settings_file> under the same path.
#   For "permissions.allow" / "permissions.deny": merges each entry from
#   shared into the target array (union, idempotent — no duplicates).
#
# For hooks.PreToolUse array entries (settings_key of the form
#   "hooks.PreToolUse.<identifier>-entry"):
#   The outer-array entry in hooks.PreToolUse is a container object with
#   a "hooks" array (nested Claude Code format). The function searches
#   shared/settings.shared.json's hooks.PreToolUse[*].hooks[*].command for
#   a value containing the component identifier (e.g. "branch-guard", "rtk"),
#   finds its parent container entry, and appends the whole container to the
#   target's hooks.PreToolUse array (idempotent: skips if an inner hook command
#   matching the identifier already exists in any container).
#
# --target-dir=<path>: substitutes {TARGET_DIR} placeholder in values read from
#   shared/settings.shared.json before writing them to the target file.
forge_merge_component_settings() {
  local component_name="$1"
  local target_file="$2"

  # Parse optional --target-dir argument
  local _target_dir=""
  local _arg
  for _arg in "${@:3}"; do
    case "$_arg" in
      --target-dir=*)
        _target_dir="${_arg#--target-dir=}"
        ;;
    esac
  done

  local _root="${ARSENAL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local manifest="$_root/shared/components/${component_name}.json"

  if [ ! -f "$manifest" ]; then
    echo "[settings] ERROR: unknown component '${component_name}' (no manifest at shared/components/${component_name}.json)" >&2
    forge_err "unknown component '${component_name}'"
    return 1
  fi

  # Read settings_key and managed_paths from the component manifest
  local settings_key
  settings_key="$(jq -r '.settings_key // empty' "$manifest")"

  local shared_file="$_root/shared/settings.shared.json"
  if [ ! -f "$shared_file" ]; then
    echo "[settings] ERROR: shared settings file not found: $shared_file" >&2
    forge_err "shared settings file not found: $shared_file"
    return 1
  fi

  # ---------------------------------------------------------------------------
  # Helper: substitute {TARGET_DIR} in a JSON value string (if --target-dir given)
  # ---------------------------------------------------------------------------
  _amcs_substitute() {
    local _val="$1"
    if [ -n "$_target_dir" ]; then
      # Use jq to perform the substitution on any string values
      printf '%s' "$_val" | jq --arg td "$_target_dir" \
        'if type == "string" then gsub("\\{TARGET_DIR\\}"; $td)
         else walk(if type == "string" then gsub("\\{TARGET_DIR\\}"; $td) else . end)
         end' 2>/dev/null || printf '%s' "$_val"
    else
      printf '%s' "$_val"
    fi
  }

  # ---------------------------------------------------------------------------
  # Case A: settings_key is null/empty — use managed_paths directly
  # ---------------------------------------------------------------------------
  if [ -z "$settings_key" ] || [ "$settings_key" = "null" ]; then
    local num_mp
    num_mp="$(jq -r '.managed_paths | length' "$manifest")"

    # No-op when managed_paths is also empty
    if [ "$num_mp" -eq 0 ]; then
      return 0
    fi

    # Ensure target file exists
    if [ ! -f "$target_file" ]; then
      local tmp_init
      tmp_init="$(mktemp)"
      printf '{}' > "$tmp_init"
      mv "$tmp_init" "$target_file"
    fi

    local _mp_i=0
    while [ "$_mp_i" -lt "$num_mp" ]; do
      local _mp_path
      _mp_path="$(jq -r ".managed_paths[$_mp_i]" "$manifest")"

      # Read the value from shared (full overwrite semantics)
      local _fragment
      _fragment="$(jq -c ".${_mp_path}" "$shared_file" 2>/dev/null)"
      if [ -z "$_fragment" ] || [ "$_fragment" = "null" ]; then
        _mp_i=$((_mp_i + 1))
        continue
      fi
      # Apply {TARGET_DIR} substitution if needed
      _fragment="$(_amcs_substitute "$_fragment")"
      # Use forge_json_set_path for atomic set (supports dotted paths like permissions.allow)
      forge_json_set_path "$target_file" ".${_mp_path}" "$_fragment"
      echo "[settings] merged component '${component_name}' managed path '.${_mp_path}' into $target_file"
      _mp_i=$((_mp_i + 1))
    done

    return 0
  fi

  # ---------------------------------------------------------------------------
  # Case B: settings_key is non-null — original single-key merge logic
  # ---------------------------------------------------------------------------

  # Detect hooks.PreToolUse array-entry pattern: "hooks.PreToolUse.<identifier>-entry"
  # Marker convention: the nested Claude Code format uses a container object with a
  # "hooks" array; each inner item has a "command" field. We search
  # hooks.PreToolUse[*].hooks[*].command for the identifier to find the container.
  if [[ "$settings_key" == hooks.PreToolUse.*-entry ]]; then
    # Extract identifier from settings_key: strip prefix and "-entry" suffix
    local hook_identifier
    hook_identifier="${settings_key#hooks.PreToolUse.}"  # remove "hooks.PreToolUse."
    hook_identifier="${hook_identifier%-entry}"            # remove "-entry" suffix

    # Find the container entry whose inner hooks[*].command contains the identifier
    local entry
    entry="$(jq -c \
      --arg id "$hook_identifier" \
      '.hooks.PreToolUse[] | select(.hooks // [] | map(select(.command | test($id))) | length > 0)' \
      "$shared_file" 2>/dev/null | head -n1)"

    if [ -z "$entry" ] || [ "$entry" = "null" ]; then
      echo "[settings] WARNING: no hooks.PreToolUse container found for identifier '${hook_identifier}' in $shared_file, skipping" >&2
      return 0
    fi

    # Apply {TARGET_DIR} substitution on the whole container entry
    if [ -n "$_target_dir" ]; then
      entry="$(printf '%s' "$entry" | jq --arg td "$_target_dir" \
        'walk(if type == "string" then gsub("\\{TARGET_DIR\\}"; $td) else . end)' 2>/dev/null)" || true
    fi

    # Create target with empty hooks.PreToolUse array if not present
    if [ ! -f "$target_file" ]; then
      local tmp_init
      tmp_init="$(mktemp)"
      printf '{}' > "$tmp_init"
      mv "$tmp_init" "$target_file"
    fi

    # Append container to target's hooks.PreToolUse[] if not already present (idempotent)
    # Identify duplicates by searching inner hooks[*].command for the identifier
    local already_present
    already_present="$(jq -r \
      --arg id "$hook_identifier" \
      '(.hooks.PreToolUse // []) | map(.hooks // [] | map(select(.command | test($id))) | length) | add // 0' \
      "$target_file" 2>/dev/null)"

    if [ "${already_present:-0}" -gt 0 ]; then
      echo "[settings] hook entry '${hook_identifier}' already present in $target_file, skipping (idempotent)"
      return 0
    fi

    local tmp
    tmp="$(mktemp)"
    jq \
      --argjson entry "$entry" \
      '.hooks.PreToolUse = ((.hooks.PreToolUse // []) + [$entry])' \
      "$target_file" > "$tmp" || {
        rm -f "$tmp"
        echo "[settings] ERROR: jq failed to append hooks.PreToolUse entry for '${hook_identifier}'" >&2
        forge_err "jq failed to append hooks.PreToolUse entry for '${hook_identifier}'"
        return 1
      }
    jq empty "$tmp" || {
      rm -f "$tmp"
      echo "[settings] ERROR: result is not valid JSON for $target_file" >&2
      forge_err "result is not valid JSON for $target_file"
      return 1
    }
    mv "$tmp" "$target_file"
    echo "[settings] merged component '${component_name}' hook entry '${hook_identifier}' into $target_file"
    return 0
  fi

  # Detect hooks.SessionStart array-entry pattern: "hooks.SessionStart.<identifier>-entry"
  # SessionStart entries have NO matcher field — only a "hooks" array. Identification
  # uses the same inner hooks[*].command search as PreToolUse.
  if [[ "$settings_key" == hooks.SessionStart.*-entry ]]; then
    # Extract identifier from settings_key: strip prefix and "-entry" suffix
    local hook_identifier
    hook_identifier="${settings_key#hooks.SessionStart.}"  # remove "hooks.SessionStart."
    hook_identifier="${hook_identifier%-entry}"              # remove "-entry" suffix

    # Find the container entry whose inner hooks[*].command contains the identifier
    local entry
    entry="$(jq -c \
      --arg id "$hook_identifier" \
      '.hooks.SessionStart[] | select(.hooks // [] | map(select(.command | test($id))) | length > 0)' \
      "$shared_file" 2>/dev/null | head -n1)"

    if [ -z "$entry" ] || [ "$entry" = "null" ]; then
      echo "[settings] WARNING: no hooks.SessionStart container found for identifier '${hook_identifier}' in $shared_file, skipping" >&2
      return 0
    fi

    # Apply {TARGET_DIR} substitution on the whole container entry
    if [ -n "$_target_dir" ]; then
      entry="$(printf '%s' "$entry" | jq --arg td "$_target_dir" \
        'walk(if type == "string" then gsub("\\{TARGET_DIR\\}"; $td) else . end)' 2>/dev/null)" || true
    fi

    # Create target with empty hooks.SessionStart array if not present
    if [ ! -f "$target_file" ]; then
      local tmp_init
      tmp_init="$(mktemp)"
      printf '{}' > "$tmp_init"
      mv "$tmp_init" "$target_file"
    fi

    # Append container to target's hooks.SessionStart[] if not already present (idempotent)
    # Identify duplicates by searching inner hooks[*].command for the identifier
    local already_present
    already_present="$(jq -r \
      --arg id "$hook_identifier" \
      '(.hooks.SessionStart // []) | map(.hooks // [] | map(select(.command | test($id))) | length) | add // 0' \
      "$target_file" 2>/dev/null)"

    if [ "${already_present:-0}" -gt 0 ]; then
      echo "[settings] SessionStart hook entry '${hook_identifier}' already present in $target_file, skipping (idempotent)"
      return 0
    fi

    local tmp
    tmp="$(mktemp)"
    jq \
      --argjson entry "$entry" \
      '.hooks.SessionStart = ((.hooks.SessionStart // []) + [$entry])' \
      "$target_file" > "$tmp" || {
        rm -f "$tmp"
        echo "[settings] ERROR: jq failed to append hooks.SessionStart entry for '${hook_identifier}'" >&2
        forge_err "jq failed to append hooks.SessionStart entry for '${hook_identifier}'"
        return 1
      }
    jq empty "$tmp" || {
      rm -f "$tmp"
      echo "[settings] ERROR: result is not valid JSON for $target_file" >&2
      forge_err "result is not valid JSON for $target_file"
      return 1
    }
    mv "$tmp" "$target_file"
    echo "[settings] merged component '${component_name}' SessionStart hook entry '${hook_identifier}' into $target_file"
    return 0
  fi

  # Plain dotted path: extract the fragment from shared/settings.shared.json
  local fragment
  fragment="$(jq -c ".${settings_key}" "$shared_file" 2>/dev/null)" || {
    echo "[settings] ERROR: jq failed to read .${settings_key} from $shared_file" >&2
    forge_err "jq failed to read .${settings_key} from $shared_file"
    return 1
  }

  if [ -z "$fragment" ] || [ "$fragment" = "null" ]; then
    echo "[settings] WARNING: .${settings_key} not found in $shared_file, skipping" >&2
  else
    # Apply {TARGET_DIR} substitution
    fragment="$(_amcs_substitute "$fragment")"

    # Merge the fragment into target_settings_file using forge_json_set_path
    forge_json_set_path "$target_file" ".${settings_key}" "$fragment"
    echo "[settings] merged component '${component_name}' settings_key '${settings_key}' into $target_file"
  fi

  # Merge any additional plain managed_paths beyond settings_key (e.g. the
  # statusline component also manages subagentStatusLine). Bracket-syntax
  # paths (hooks.PreToolUse[...]) belong to the settings_key branch above.
  local _extra_n _extra_i _extra_path _extra_fragment
  _extra_n="$(jq -r '.managed_paths | length' "$manifest")"
  _extra_i=0
  while [ "$_extra_i" -lt "$_extra_n" ]; do
    _extra_path="$(jq -r ".managed_paths[$_extra_i]" "$manifest")"
    if [ "$_extra_path" = "$settings_key" ] || [[ "$_extra_path" == *\[* ]]; then
      _extra_i=$((_extra_i + 1))
      continue
    fi
    _extra_fragment="$(jq -c ".${_extra_path}" "$shared_file" 2>/dev/null)"
    if [ -n "$_extra_fragment" ] && [ "$_extra_fragment" != "null" ]; then
      _extra_fragment="$(_amcs_substitute "$_extra_fragment")"
      forge_json_set_path "$target_file" ".${_extra_path}" "$_extra_fragment"
      echo "[settings] merged component '${component_name}' managed path '.${_extra_path}' into $target_file"
    fi
    _extra_i=$((_extra_i + 1))
  done
  return 0
}

# forge_unmerge_component_settings <component_name> <target_settings_file>
# Inverse of forge_merge_component_settings.
# Reads managed_paths from shared/components/<component_name>.json and removes
# the corresponding keys/entries from <target_settings_file>.
#
# Path conventions:
#   - Plain dotted path (e.g. "statusLine", "model"):
#       Delete the top-level key entirely from the target.
#   - "permissions.allow" / "permissions.deny":
#       Remove only the entries owned by this component (those present in
#       shared/settings.shared.json at the same path) leaving user-added
#       entries intact.
#   - "hooks.PreToolUse[<identifier>]" bracket syntax:
#       Remove only the entry whose "command" field contains <identifier>;
#       leave all other entries intact.
#
# If managed_paths is empty ([]), this is a no-op.
# Idempotent: running unmerge twice produces no second-pass diff.
forge_unmerge_component_settings() {
  local component_name="$1"
  local target_file="$2"

  local _root="${ARSENAL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local manifest="$_root/shared/components/${component_name}.json"

  if [ ! -f "$manifest" ]; then
    echo "[settings] ERROR: unknown component '${component_name}' (no manifest at shared/components/${component_name}.json)" >&2
    forge_err "unknown component '${component_name}'"
    return 1
  fi

  # If target does not exist, nothing to unmerge
  if [ ! -f "$target_file" ]; then
    return 0
  fi

  # No-op when settings_key is null (agents component: managed_paths are handled
  # exclusively by forge_merge_component_settings and not tracked individually
  # in the unmerge path — the full uninstall relies on pre-forge restore).
  local _unmerge_settings_key
  _unmerge_settings_key="$(jq -r '.settings_key // empty' "$manifest")"
  if [ -z "$_unmerge_settings_key" ] || [ "$_unmerge_settings_key" = "null" ]; then
    return 0
  fi

  # Read managed_paths
  local num_paths
  num_paths="$(jq -r '.managed_paths | length' "$manifest")"

  # No-op when managed_paths is empty
  if [ "$num_paths" -eq 0 ]; then
    return 0
  fi

  local shared_file="$_root/shared/settings.shared.json"

  local i=0
  while [ "$i" -lt "$num_paths" ]; do
    local path
    path="$(jq -r ".managed_paths[$i]" "$manifest")"

    # Detect hooks.PreToolUse[<identifier>] bracket syntax
    if [[ "$path" == hooks.PreToolUse\[*\] ]]; then
      # Extract identifier from brackets
      local hook_identifier
      hook_identifier="${path#hooks.PreToolUse[}"
      hook_identifier="${hook_identifier%]}"

      # Check if any container entry contains the identifier in its inner hooks[*].command
      # (nested Claude Code format: PreToolUse[].hooks[].command)
      local present_count
      present_count="$(jq -r \
        --arg id "$hook_identifier" \
        '(.hooks.PreToolUse // []) | map(.hooks // [] | map(select(.command | test($id))) | length) | add // 0' \
        "$target_file" 2>/dev/null)"

      if [ "${present_count:-0}" -gt 0 ]; then
        local tmp
        tmp="$(mktemp)"
        jq \
          --arg id "$hook_identifier" \
          '.hooks.PreToolUse = ((.hooks.PreToolUse // []) | map(select(.hooks // [] | map(select(.command | test($id))) | length == 0)))' \
          "$target_file" > "$tmp" || {
            rm -f "$tmp"
            echo "[settings] ERROR: jq failed to remove hooks.PreToolUse entry for '${hook_identifier}'" >&2
            forge_err "jq failed to remove hooks.PreToolUse entry for '${hook_identifier}'"
            return 1
          }
        jq empty "$tmp" || {
          rm -f "$tmp"
          echo "[settings] ERROR: result is not valid JSON for $target_file" >&2
          forge_err "result is not valid JSON for $target_file"
          return 1
        }
        mv "$tmp" "$target_file"
        echo "[settings] removed component '${component_name}' hook entry '${hook_identifier}' from $target_file"
      else
        echo "[settings] hook entry '${hook_identifier}' not present in $target_file, skipping (idempotent)"
      fi

      i=$((i + 1))
      continue
    fi

    # Detect permissions.allow or permissions.deny — remove only component-owned entries
    if [ "$path" = "permissions.allow" ] || [ "$path" = "permissions.deny" ]; then
      # Only process if the key already exists in the target (guard: don't create empty parent)
      local _perm_top _perm_sub _perm_exists
      _perm_top="${path%%.*}"   # "permissions"
      _perm_sub="${path#*.}"    # "allow" or "deny"
      _perm_exists="$(jq -r --arg top "$_perm_top" --arg sub "$_perm_sub" \
        'has($top) and (.[$top] | has($sub))' "$target_file" 2>/dev/null)"
      if [ "$_perm_exists" != "true" ]; then
        echo "[settings] .${path} not present in $target_file, skipping (idempotent)"
        i=$((i + 1))
        continue
      fi

      # Entries owned by this component are those present in shared/settings.shared.json
      if [ ! -f "$shared_file" ]; then
        echo "[settings] WARNING: shared settings file not found: $shared_file, skipping permissions unmerge" >&2
        i=$((i + 1))
        continue
      fi

      local component_entries
      component_entries="$(jq -c ".${path} // []" "$shared_file" 2>/dev/null)"

      if [ -z "$component_entries" ] || [ "$component_entries" = "null" ] || [ "$component_entries" = "[]" ]; then
        i=$((i + 1))
        continue
      fi

      # Remove only the entries that appear in component_entries from the target array
      local tmp
      tmp="$(mktemp)"
      jq \
        --argjson owned "$component_entries" \
        --arg perm "$path" \
        '($perm | split(".")) as $parts |
         ($parts[0]) as $top |
         ($parts[1]) as $sub |
         .[$top][$sub] = ((.[$top][$sub] // []) | map(select(. as $entry | $owned | map(select(. == $entry)) | length == 0)))' \
        "$target_file" > "$tmp" || {
          rm -f "$tmp"
          echo "[settings] ERROR: jq failed to unmerge ${path} for component '${component_name}'" >&2
          forge_err "jq failed to unmerge ${path} for component '${component_name}'"
          return 1
        }
      jq empty "$tmp" || {
        rm -f "$tmp"
        echo "[settings] ERROR: result is not valid JSON for $target_file" >&2
        forge_err "result is not valid JSON for $target_file"
        return 1
      }
      mv "$tmp" "$target_file"
      echo "[settings] removed component '${component_name}' entries from .${path} in $target_file"

      i=$((i + 1))
      continue
    fi

    # Detect hooks.SessionStart[<identifier>] bracket syntax
    # SessionStart entries have NO matcher field — entry is identified by inner
    # hooks[*].command containing the identifier string.
    if [[ "$path" == hooks.SessionStart\[*\] ]]; then
      # Extract identifier from brackets
      local hook_identifier
      hook_identifier="${path#hooks.SessionStart[}"
      hook_identifier="${hook_identifier%]}"

      # Check if any container entry contains the identifier in its inner hooks[*].command
      local present_count
      present_count="$(jq -r \
        --arg id "$hook_identifier" \
        '(.hooks.SessionStart // []) | map(.hooks // [] | map(select(.command | test($id))) | length) | add // 0' \
        "$target_file" 2>/dev/null)"

      if [ "${present_count:-0}" -gt 0 ]; then
        local tmp
        tmp="$(mktemp)"
        jq \
          --arg id "$hook_identifier" \
          '.hooks.SessionStart = ((.hooks.SessionStart // []) | map(select(.hooks // [] | map(select(.command | test($id))) | length == 0)))' \
          "$target_file" > "$tmp" || {
            rm -f "$tmp"
            echo "[settings] ERROR: jq failed to remove hooks.SessionStart entry for '${hook_identifier}'" >&2
            forge_err "jq failed to remove hooks.SessionStart entry for '${hook_identifier}'"
            return 1
          }
        jq empty "$tmp" || {
          rm -f "$tmp"
          echo "[settings] ERROR: result is not valid JSON for $target_file" >&2
          forge_err "result is not valid JSON for $target_file"
          return 1
        }
        mv "$tmp" "$target_file"
        echo "[settings] removed component '${component_name}' SessionStart hook entry '${hook_identifier}' from $target_file"
      else
        echo "[settings] SessionStart hook entry '${hook_identifier}' not present in $target_file, skipping (idempotent)"
      fi

      i=$((i + 1))
      continue
    fi

    # Plain dotted path: delete the key from the target
    # Determine the top-level key (first segment before the first dot)
    local top_key
    top_key="${path%%.*}"

    # Check if the key exists before attempting deletion (idempotent)
    local key_present
    key_present="$(jq -r "has(\"${top_key}\")" "$target_file" 2>/dev/null)"

    if [ "$key_present" = "true" ]; then
      local tmp
      tmp="$(mktemp)"
      jq "del(.${top_key})" "$target_file" > "$tmp" || {
        rm -f "$tmp"
        echo "[settings] ERROR: jq failed to delete .${top_key} from $target_file" >&2
        forge_err "jq failed to delete .${top_key} from $target_file"
        return 1
      }
      jq empty "$tmp" || {
        rm -f "$tmp"
        echo "[settings] ERROR: result is not valid JSON for $target_file" >&2
        forge_err "result is not valid JSON for $target_file"
        return 1
      }
      mv "$tmp" "$target_file"
      echo "[settings] removed component '${component_name}' key '.${top_key}' from $target_file"
    else
      echo "[settings] key '.${top_key}' not present in $target_file, skipping (idempotent)"
    fi

    i=$((i + 1))
  done

  return 0
}
