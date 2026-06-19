#!/usr/bin/env bash
# lib/rtk.sh — RTK (Rust Token Killer) decision tree for forge
# Compatible with bash 3.2+. Uses only indexed arrays (no associative arrays).
# Log prefix: [rtk]
# IMPORTANT: forge_rtk_decide always returns 0.
#            RTK failures are soft (install_failed / version_mismatch in state).
set -euo pipefail

# Guard against double-loading
if [ -n "${_ARSENAL_RTK_LOADED:-}" ]; then
  return 0
fi
_ARSENAL_RTK_LOADED=1

# Fallback no-op if arsenal_warn is not loaded yet
type -t arsenal_warn >/dev/null 2>&1 || arsenal_warn() { echo "[arsenal] WARN: $1" >&2; }

# ---------------------------------------------------------------------------
# forge_rtk_detect
# Prints: "absent" | "<semver>" | "collision"
# ---------------------------------------------------------------------------
forge_rtk_detect() {
  # Check if rtk is in PATH
  if ! command -v rtk >/dev/null 2>&1; then
    # Fallback: check whether the forge-managed binary exists on disk even
    # though it is not on PATH (common after a fresh Path A install before the
    # user has sourced ~/.zshrc).
    local _ondisk_rtk="$HOME/.forge/bin/rtk"
    if [ -x "$_ondisk_rtk" ]; then
      local _ondisk_ver
      _ondisk_ver="$("$_ondisk_rtk" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
      if [ -n "$_ondisk_ver" ]; then
        echo "installed:${_ondisk_ver}"
        return 0
      fi
    fi
    echo "absent"
    return 0
  fi

  local version_output
  version_output="$(rtk --version 2>&1)" || true

  # Detect PATH-shadowing: forge binary present, $HOME/.forge/bin is in PATH,
  # but a different rtk wins PATH precedence with a different version.
  # Only fires when $HOME/.forge/bin is actually configured in PATH — if it is not
  # configured at all, there is nothing to shadow (a different warning handles that).
  local _path_rtk _forge_rtk="$HOME/.forge/bin/rtk"
  _path_rtk="$(command -v rtk 2>/dev/null || true)"
  case ":${PATH}:" in
    *":$HOME/.forge/bin:"*)
      if [ -x "$_forge_rtk" ] && [ -n "$_path_rtk" ] && [ "$_path_rtk" != "$_forge_rtk" ]; then
        local _path_ver _forge_ver
        _path_ver="$(rtk --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        _forge_ver="$("$_forge_rtk" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        if [ -n "$_path_ver" ] && [ -n "$_forge_ver" ] && [ "$_path_ver" != "$_forge_ver" ]; then
          echo "shadowed:${_path_rtk}:${_path_ver}:${_forge_ver}"
          return 0
        fi
      fi
      ;;
  esac

  # Expected: "rtk 0.42.0" or "rtk 0.42.0 ..."
  # Regex: starts with "rtk " followed by a semver
  if printf '%s\n' "$version_output" | grep -qE '^rtk[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+'; then
    # Extract the version number
    local ver
    ver="$(printf '%s\n' "$version_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    echo "$ver"
    return 0
  fi

  # Binary exists but output doesn't match the expected RTK format → collision
  echo "collision"
  return 0
}

# ---------------------------------------------------------------------------
# forge_rtk_compare <detected_version> <pinned_version>
# Prints: "eq" | "lt" | "gt"
# Uses sort -V for version comparison (compatible with bash 3.2).
# ---------------------------------------------------------------------------
forge_rtk_compare() {
  local det="$1"
  local pin="$2"

  if [ "$det" = "$pin" ]; then
    echo "eq"
    return 0
  fi

  # Sort both versions and check which comes first
  local lower
  lower="$(printf '%s\n%s\n' "$det" "$pin" | sort -V | head -1)"

  if [ "$lower" = "$det" ]; then
    # det sorts before pin → det < pin
    echo "lt"
  else
    # pin sorts before det → det > pin
    echo "gt"
  fi
}

# ---------------------------------------------------------------------------
# _forge_rtk_inject_path_snippet
# Injects a PATH snippet into the user's shell profile files so that
# ~/.forge/bin is available in every new shell session.
# Idempotent: safe to call multiple times; skips already-patched files.
# Does NOT create profile files that do not already exist.
# ---------------------------------------------------------------------------
_forge_rtk_inject_path_snippet() {
  local _marker_open="# >>> forge rtk path >>>"
  local _marker_close="# <<< forge rtk path <<<"
  # shellcheck disable=SC2016
  local _snippet_body='case ":$PATH:" in *":$HOME/.forge/bin:"*) ;; *) export PATH="$HOME/.forge/bin:$PATH" ;; esac'

  local _profile
  for _profile in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.zprofile" "$HOME/.bash_profile"; do
    # Skip files that do not exist (do NOT create new ones)
    [ -f "$_profile" ] || continue

    # Skip if marker already present (idempotent)
    if grep -qF "$_marker_open" "$_profile"; then
      continue
    fi

    # Ensure the file ends with a newline before appending
    if [ -s "$_profile" ]; then
      local _last_char
      _last_char="$(tail -c1 "$_profile")"
      if [ "$_last_char" != "" ]; then
        printf '\n' >> "$_profile"
      fi
    fi

    printf '%s\n%s\n%s\n' "$_marker_open" "$_snippet_body" "$_marker_close" >> "$_profile"
    echo "[rtk] PATH snippet añadido a ${_profile}"
  done
}

# ---------------------------------------------------------------------------
# forge_rtk_remove_binary
# Removes the forge-pinned RTK binary (~/.forge/bin/rtk) and prunes the
# ~/.forge/bin and ~/.forge directories when they end up empty.
# Idempotent: a missing binary is a no-op.
# ---------------------------------------------------------------------------
forge_rtk_remove_binary() {
  local _rtk_bin="$HOME/.forge/bin/rtk"
  if [ -e "$_rtk_bin" ] || [ -L "$_rtk_bin" ]; then
    rm -f "$_rtk_bin"
    echo "[rtk] RTK eliminado: ${_rtk_bin/#$HOME/\~}"
  else
    echo "[rtk] RTK ya estaba desinstalado (${_rtk_bin/#$HOME/\~} no presente)"
  fi
  rmdir "$HOME/.forge/bin" 2>/dev/null || true
  rmdir "$HOME/.forge" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# forge_rtk_strip_path_snippet
# Removes the marked PATH snippet block (see _forge_rtk_inject_path_snippet)
# from every shell profile that contains it. Idempotent.
# ---------------------------------------------------------------------------
forge_rtk_strip_path_snippet() {
  # Match both the legacy atenea-arsenal marker (backward-compat) and the new forge marker.
  local _profile _profile_tmp
  for _profile in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.zprofile" "$HOME/.bash_profile"; do
    [ -f "$_profile" ] || continue
    grep -qF '# >>> forge rtk path >>>' "$_profile" \
      || grep -qF '# >>> atenea-arsenal rtk path >>>' "$_profile" \
      || continue
    _profile_tmp="$(mktemp)"
    sed '/# >>> forge rtk path >>>/,/# <<< forge rtk path <<</d;/# >>> atenea-arsenal rtk path >>>/,/# <<< atenea-arsenal rtk path <<</d' \
      "$_profile" > "$_profile_tmp" && mv "$_profile_tmp" "$_profile"
    echo "[rtk] PATH snippet eliminado de $_profile"
  done
}

# ---------------------------------------------------------------------------
# forge_rtk_adjust_via_tarball
# Downloads the pinned RTK release from GitHub, verifies SHA256, and installs
# the binary to ~/.forge/bin/rtk.
# Sets _RTK_INSTALLED_BY_US="true" on success.
# Sets _RTK_INSTALL_FAILED=1 and returns 1 on any error.
# ---------------------------------------------------------------------------
forge_rtk_adjust_via_tarball() {
  # 1. Read pinned version
  local pinned
  pinned="$(cat "$ARSENAL_ROOT/rtk/VERSION" 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$pinned" ]; then
    arsenal_warn "[rtk] No se pudo leer la versión pinned de rtk/VERSION"
    _RTK_INSTALL_FAILED=1
    return 1
  fi

  # 2. Detect OS and arch
  local _os _arch
  _os="$(uname -s)"
  _arch="$(uname -m)"
  # Normalize arm64 -> aarch64
  [ "$_arch" = "arm64" ] && _arch="aarch64"

  # 3. Map to asset name
  local _asset
  case "${_os}-${_arch}" in
    Darwin-aarch64)  _asset="rtk-aarch64-apple-darwin.tar.gz" ;;
    Darwin-x86_64)   _asset="rtk-x86_64-apple-darwin.tar.gz" ;;
    Linux-aarch64)   _asset="rtk-aarch64-unknown-linux-gnu.tar.gz" ;;
    Linux-x86_64)    _asset="rtk-x86_64-unknown-linux-musl.tar.gz" ;;
    *)
      arsenal_warn "[rtk] Plataforma no soportada: ${_os}-${_arch}"
      _RTK_INSTALL_FAILED=1
      return 1
      ;;
  esac

  # 4. Idempotency: already at pinned version?
  if [ -x "$HOME/.forge/bin/rtk" ]; then
    local _cur_ver
    _cur_ver="$("$HOME/.forge/bin/rtk" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [ "$_cur_ver" = "$pinned" ]; then
      echo "[rtk] Ya en versión pinned ($pinned); omitiendo descarga."
      _RTK_INSTALLED_BY_US="true"
      _forge_rtk_inject_path_snippet
      return 0
    fi
  fi

  # 5. Verify curl
  if ! command -v curl >/dev/null 2>&1; then
    arsenal_warn "[rtk] curl no encontrado; instálalo para continuar."
    _RTK_INSTALL_FAILED=1
    return 1
  fi

  # 6. Temp dir (explicit cleanup on every return path; no EXIT trap to avoid
  #    set -u failure when the trap fires after the function returns and the
  #    local variable is out of scope)
  local _tmpdir
  _tmpdir="$(mktemp -d)"

  local _base_url="https://github.com/rtk-ai/rtk/releases/download/v${pinned}"

  # 7. Download asset and checksums
  echo "[rtk] Descargando RTK ${pinned} (${_asset})..."
  if ! curl -fsSL --retry 3 "${_base_url}/${_asset}" -o "$_tmpdir/${_asset}"; then
    arsenal_warn "[rtk] Error al descargar ${_asset}"
    rm -rf "$_tmpdir"
    _RTK_INSTALL_FAILED=1
    return 1
  fi
  if ! curl -fsSL --retry 3 "${_base_url}/checksums.txt" -o "$_tmpdir/checksums.txt"; then
    arsenal_warn "[rtk] Error al descargar checksums.txt"
    rm -rf "$_tmpdir"
    _RTK_INSTALL_FAILED=1
    return 1
  fi

  # 8. Verify SHA256
  local _expected_sha _actual_sha
  _expected_sha="$(grep " ${_asset}$" "$_tmpdir/checksums.txt" | awk '{print $1}')"
  if [ -z "$_expected_sha" ]; then
    arsenal_warn "[rtk] No se encontró el checksum para ${_asset} en checksums.txt"
    rm -rf "$_tmpdir"
    _RTK_INSTALL_FAILED=1
    return 1
  fi
  if command -v shasum >/dev/null 2>&1; then
    _actual_sha="$(shasum -a 256 "$_tmpdir/${_asset}" | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    _actual_sha="$(sha256sum "$_tmpdir/${_asset}" | awk '{print $1}')"
  else
    arsenal_warn "[rtk] No se encontró shasum ni sha256sum para verificar el checksum"
    rm -rf "$_tmpdir"
    _RTK_INSTALL_FAILED=1
    return 1
  fi
  if [ "$_actual_sha" != "$_expected_sha" ]; then
    arsenal_warn "[rtk] Checksum SHA256 no coincide para ${_asset} (esperado: ${_expected_sha}, obtenido: ${_actual_sha})"
    rm -rf "$_tmpdir"
    _RTK_INSTALL_FAILED=1
    return 1
  fi

  # 9. Extract and locate binary
  if ! tar -xzf "$_tmpdir/${_asset}" -C "$_tmpdir"; then
    arsenal_warn "[rtk] Error al extraer el tarball ${_asset}"
    rm -rf "$_tmpdir"
    _RTK_INSTALL_FAILED=1
    return 1
  fi
  local _binary
  _binary="$(find "$_tmpdir" -name rtk -type f -perm -u+x | head -1)"
  if [ -z "$_binary" ]; then
    arsenal_warn "[rtk] No se encontró el binario rtk en el tarball"
    rm -rf "$_tmpdir"
    _RTK_INSTALL_FAILED=1
    return 1
  fi

  # 10. Install
  mkdir -p "$HOME/.forge/bin"
  mv "$_binary" "$HOME/.forge/bin/rtk"
  chmod +x "$HOME/.forge/bin/rtk"

  # 11. PATH check (non-fatal)
  case ":${PATH}:" in
    *":$HOME/.forge/bin:"*) ;;
    *)
      arsenal_warn "[rtk] $HOME/.forge/bin no está en PATH → Añade $HOME/.forge/bin a tu PATH en ~/.zshrc o ~/.bashrc"
      ;;
  esac

  # 12. Verify installed binary
  local _installed_ver
  _installed_ver="$("$HOME/.forge/bin/rtk" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ "$_installed_ver" != "$pinned" ]; then
    arsenal_warn "[rtk] El binario instalado reporta versión ${_installed_ver}, esperada ${pinned}"
    rm -rf "$_tmpdir"
    _RTK_INSTALL_FAILED=1
    return 1
  fi

  _forge_rtk_inject_path_snippet
  echo "[rtk] source ~/.zshrc (o abre un terminal nuevo) para que 'rtk' esté disponible en PATH."
  echo "[rtk] RTK ${pinned} instalado en $HOME/.forge/bin/rtk"
  rm -rf "$_tmpdir"
  return 0
}

# ---------------------------------------------------------------------------
# _forge_rtk_prompt_adjust <pinned> <action_label>
# Shared helper: reads ARSENAL_RTK_ADJUST env var (yes|no), falls back to tty prompt.
# Backward-compat: ARSENAL_RTK_DOWNGRADE is still accepted as a deprecated alias.
# If both are set, ARSENAL_RTK_ADJUST takes precedence. Used for both
# upgrade (lt) and downgrade (gt) branches; covers any non-eq adjustment.
# On yes/y: calls forge_rtk_adjust_via_tarball; sets state vars.
# On no/n/non-tty: sets _RTK_VERSION_MISMATCH=1.
# ---------------------------------------------------------------------------
_forge_rtk_prompt_adjust() {
  local pinned="$1"
  local action_label="$2"

  # Resolve env var: ARSENAL_RTK_ADJUST is primary; ARSENAL_RTK_DOWNGRADE is
  # a deprecated alias kept for backward compatibility. Primary wins if both set.
  local env_choice="${ARSENAL_RTK_ADJUST:-${ARSENAL_RTK_DOWNGRADE:-}}"
  local env_var_name="ARSENAL_RTK_ADJUST"
  if [ -z "${ARSENAL_RTK_ADJUST:-}" ] && [ -n "${ARSENAL_RTK_DOWNGRADE:-}" ]; then
    env_var_name="ARSENAL_RTK_DOWNGRADE"
    echo "[rtk] WARN: ARSENAL_RTK_DOWNGRADE está deprecado; usa ARSENAL_RTK_ADJUST" >&2
  fi
  case "$env_choice" in
    yes)
      echo "[rtk] $env_var_name=yes, $action_label automático"
      if forge_rtk_adjust_via_tarball; then
        echo "[rtk] $action_label completado a $pinned"
        _RTK_DETECTED_VERSION="$pinned"
        _RTK_INSTALLED_BY_US="true"
      else
        echo "[rtk] ERROR: $action_label automático falló" >&2
        _RTK_VERSION_MISMATCH=1
      fi
      return 0
      ;;
    no)
      echo "[rtk] $env_var_name=no, skip $action_label"
      _RTK_VERSION_MISMATCH=1
      return 0
      ;;
    "")
      : # fall through al flujo tty/prompt existente
      ;;
    *)
      echo "[rtk] WARN: $env_var_name='$env_choice' no reconocido (usa yes|no); aplicando flujo por defecto" >&2
      ;;
  esac

  # Check if stdin is a tty (or if the RTK_FORCE_TTY env var is set for testing)
  local is_tty=0
  if [ -t 0 ] || [ "${RTK_FORCE_TTY:-}" = "1" ]; then
    is_tty=1
  fi

  if [ "$is_tty" = "0" ]; then
    echo "[rtk] stdin no es tty, skip prompt" >&2
    _RTK_VERSION_MISMATCH=1
    return 0
  fi

  # Interactive prompt
  local ans=""
  read -r -p "[rtk] ¿Ajustar a $pinned? [y/N] " ans || true

  if printf '%s\n' "$ans" | grep -qE '^[Yy]$'; then
    if forge_rtk_adjust_via_tarball; then
      echo "[rtk] $action_label completado a $pinned"
      _RTK_DETECTED_VERSION="$pinned"
      _RTK_INSTALLED_BY_US="true"
    else
      echo "[rtk] adjust falló; instalar manualmente con:" >&2
      echo "[rtk]   bash install.sh rtk install" >&2
      _RTK_VERSION_MISMATCH=1
    fi
  else
    echo "[rtk] $action_label rechazado por el usuario"
    _RTK_VERSION_MISMATCH=1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# forge_rtk_decide
# Core decision tree. Always returns 0 (soft failures recorded in state vars).
#
# After calling this function, the caller can inspect:
#   _RTK_INSTALLED_BY_US   : "true" | "false" | ""
#   _RTK_DETECTED_VERSION  : semver or ""
#   _RTK_INSTALL_FAILED    : 1 or ""  (unset/empty means success)
#   _RTK_VERSION_MISMATCH  : 1 or ""
#
# The caller is responsible for persisting these to the state file.
# ---------------------------------------------------------------------------
forge_rtk_decide() {
  # Reset output vars
  _RTK_INSTALLED_BY_US=""
  _RTK_DETECTED_VERSION=""
  _RTK_INSTALL_FAILED=""
  _RTK_VERSION_MISMATCH=""

  local pinned
  pinned="$(cat "$ARSENAL_ROOT/rtk/VERSION" 2>/dev/null || echo "0.42.4")"

  local detected
  detected="$(forge_rtk_detect)"

  # --- Branch: collision ---
  if [ "$detected" = "collision" ]; then
    echo "[rtk] ERROR colisión con otro binario rtk; abortando RTK, continuando resto" >&2
    _RTK_INSTALL_FAILED=1
    arsenal_warn "RTK: colisión con otro binario 'rtk' en PATH (probable Rust Type Kit)" "Desinstala el otro binario o ajusta PATH; luego: bash install.sh rtk install"
    return 0
  fi

  # --- Branch: shadowed ---
  case "$detected" in
    shadowed:*)
      local _shadow_winner _shadow_ver _arsenal_ver
      _shadow_winner="$(printf '%s\n' "$detected" | cut -d: -f2)"
      _shadow_ver="$(printf '%s\n' "$detected" | cut -d: -f3)"
      _arsenal_ver="$(printf '%s\n' "$detected" | cut -d: -f4)"
      arsenal_warn "RTK ${_shadow_ver} instalado vía Homebrew sombrea al de forge (${_arsenal_ver})." \
        "Para solucionar:
  1. brew uninstall rtk
  2. bash install.sh rtk install
  3. source ~/.zshrc (o abre un terminal nuevo)"
      return 0
      ;;
  esac

  # --- Branch: absent ---
  if [ "$detected" = "absent" ]; then
    echo "[rtk] rtk no encontrado; se instalará la versión pinned ($pinned)" >&2
    _forge_rtk_prompt_adjust "$pinned" "install"
    return 0
  fi

  # --- Branch: installed:<version> (on-disk but not on PATH) ---
  case "$detected" in
    installed:*)
      local _ondisk_ver
      _ondisk_ver="${detected#installed:}"
      echo "[rtk] binario en ~/.forge/bin ($_ondisk_ver) pero fuera de PATH" >&2
      if [ "$_ondisk_ver" = "$pinned" ]; then
        _forge_rtk_inject_path_snippet
        _RTK_DETECTED_VERSION="$_ondisk_ver"
        _RTK_INSTALLED_BY_US="true"
        echo "[rtk] ok pinned ($pinned); PATH snippet asegurado"
        return 0
      else
        detected="$_ondisk_ver"
        _RTK_DETECTED_VERSION="$_ondisk_ver"
      fi
      ;;
  esac

  # At this point detected is a semver string
  _RTK_DETECTED_VERSION="$detected"

  local cmp
  cmp="$(forge_rtk_compare "$detected" "$pinned")"

  # --- Branch: eq ---
  if [ "$cmp" = "eq" ]; then
    echo "[rtk] ok pinned ($pinned)"
    # Only set installed_by_us=false if no prior state (preserve existing state)
    if [ -z "$_RTK_INSTALLED_BY_US" ]; then
      _RTK_INSTALLED_BY_US="false"
    fi
    return 0
  fi

  # --- Branch: lt (upgrade needed) ---
  if [ "$cmp" = "lt" ]; then
    echo "[rtk] rtk $detected detectado; upgrade automático deshabilitado" >&2
    echo "[rtk]   bash install.sh rtk install" >&2
    arsenal_warn "RTK $detected detectado (upgrade automático deshabilitado)" "bash install.sh rtk install"
    _forge_rtk_prompt_adjust "$pinned" "upgrade"
    return 0
  fi

  # --- Branch: gt (detected > pin, non-certified version) ---
  if [ "$cmp" = "gt" ]; then
    echo "[rtk] WARNING: versión $detected > pin $pinned (no certificada)" >&2
    arsenal_warn "RTK $detected > pin $pinned (versión no certificada)" "bash install.sh rtk install"
    _forge_rtk_prompt_adjust "$pinned" "downgrade"
    return 0
  fi

  # Should never reach here
  return 0
}
