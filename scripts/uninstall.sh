#!/usr/bin/env bash
#
# Clipnest uninstaller — one command for macOS and Linux (Ubuntu).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/uninstall.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/uninstall.sh | bash -s -- --purge
#
# By default this removes the APP only and KEEPS your clipboard history,
# snippets and settings. Deleting that data is opt-in: pass --purge (or set
# CLIPNEST_PURGE=1). Nothing is ever deleted silently.
#
# Optional environment variables:
#   CLIPNEST_PURGE=1    Same as --purge: also delete your data and settings.
#   CLIPNEST_DRY_RUN=1  Print every action without doing it.

set -euo pipefail

CLIPNEST_DRY_RUN="${CLIPNEST_DRY_RUN:-0}"
PURGE="${CLIPNEST_PURGE:-0}"

# --- macOS paths (fixed names; bundle id com.clipnest.app) --------------------
MAC_APP="/Applications/Clipnest.app"
MAC_PROCESS_PATTERN="Clipnest.app/Contents/MacOS/Clipnest"
MAC_BUNDLE_ID="com.clipnest.app"
MAC_DATA_RELPATHS=(
  "Library/Application Support/Clipnest"
  "Library/Preferences/${MAC_BUNDLE_ID}.plist"
  "Library/Caches/${MAC_BUNDLE_ID}"
  "Library/HTTPStorages/${MAC_BUNDLE_ID}"
)

# --- Linux names ---------------------------------------------------------------
LINUX_PACKAGES=(clipnest clipnest-ocr clipnest-ocr-data)
LINUX_EXTENSION_UUID="clipnest@clipnest.app"
LINUX_AUTOSTART_FILE="clipnest.desktop"

die() {
  echo "error: $*" >&2
  exit 1
}

# run CMD...: execute, or just print under CLIPNEST_DRY_RUN=1.
run() {
  if [ "${CLIPNEST_DRY_RUN}" = "1" ]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

# safe_rm PATH: rm -rf, but only for a non-empty path that lies strictly inside
# $HOME (never "", "/", or $HOME itself). Every caller builds PATH from fixed
# constants + $HOME / XDG variables.
safe_rm() {
  local target="${1:-}"
  local home="${HOME:-}"
  home="${home%/}"
  if [ -z "${home}" ] || [ "${home}" = "/" ]; then
    die "HOME is empty or '/'; refusing to delete anything."
  fi
  case "${target}" in
    ""|"/"|"${home}"|"${home}/") die "refusing to delete unsafe path '${target}'." ;;
    "${home}"/*) ;;
    *) die "refusing to delete '${target}': not inside ${home}." ;;
  esac
  case "${target}" in *"/../"*|*"/..") die "refusing path with '..': ${target}" ;; esac
  if [ -e "${target}" ] || [ -L "${target}" ]; then
    run rm -rf "${target:?}"
    [ "${CLIPNEST_DRY_RUN}" = "1" ] || echo "    removed ${target}"
  else
    echo "    (not present) ${target}"
  fi
}

uninstall_macos() {
  echo "==> macOS detected."
  if pgrep -f "${MAC_PROCESS_PATTERN}" >/dev/null 2>&1; then
    echo "==> Quitting Clipnest…"
    run osascript -e 'tell application "Clipnest" to quit' || true
    if [ "${CLIPNEST_DRY_RUN}" != "1" ]; then
      sleep 2
    fi
    if pgrep -f "${MAC_PROCESS_PATTERN}" >/dev/null 2>&1; then
      run pkill -f "${MAC_PROCESS_PATTERN}" || true
    fi
  else
    echo "==> Clipnest is not running."
  fi

  echo "==> Removing the app…"
  safe_rm_abs_app
  echo "    Note: if you enabled 'Launch at login', macOS lists a stale Clipnest entry"
  echo "    under System Settings -> General -> Login Items; remove it there if shown."

  if [ "${PURGE}" = "1" ]; then
    echo "==> Purging your data and settings (--purge)…"
    local rel
    for rel in "${MAC_DATA_RELPATHS[@]}"; do
      safe_rm "${HOME}/${rel}"
    done
    echo "==> Resetting Clipnest's Accessibility permission…"
    echo "    (clears the stale grant for ${MAC_BUNDLE_ID} so a future reinstall starts clean)"
    run tccutil reset Accessibility "${MAC_BUNDLE_ID}" || true
  else
    echo "==> Keeping your history, snippets and settings (re-run with --purge to delete them)."
  fi
  finish
}

# The app lives in /Applications (outside $HOME), so it has its own guard.
safe_rm_abs_app() {
  [ "${MAC_APP}" = "/Applications/Clipnest.app" ] || die "unexpected app path '${MAC_APP}'."
  if [ -d "${MAC_APP}" ]; then
    run rm -rf "${MAC_APP:?}"
    [ "${CLIPNEST_DRY_RUN}" = "1" ] || echo "    removed ${MAC_APP}"
  else
    echo "    (not present) ${MAC_APP}"
  fi
}

uninstall_linux() {
  echo "==> Linux detected."
  if [ "$(id -u)" -eq 0 ]; then
    die "run this as your normal user, not root — it uses sudo only where needed."
  fi
  command -v dpkg-query >/dev/null 2>&1 || die "dpkg-query not found; this uninstaller supports apt-based systems (Ubuntu)."
  if [ "${CLIPNEST_DRY_RUN}" != "1" ]; then
    command -v sudo >/dev/null 2>&1 || die "required tool 'sudo' not found."
    command -v apt-get >/dev/null 2>&1 || die "required tool 'apt-get' not found."
  fi

  local pkg installed=()
  for pkg in "${LINUX_PACKAGES[@]}"; do
    # After a default uninstall a package sits in 'config-files' (dpkg 'rc');
    # --purge must still purge it, or the clipnest-input group is left behind.
    case "$(dpkg-query -W -f='${db:Status-Status}' "${pkg}" 2>/dev/null)" in
      installed) installed+=("${pkg}") ;;
      config-files) [ "${PURGE}" = "1" ] && installed+=("${pkg}") ;;
    esac
  done

  local verb="remove"
  [ "${PURGE}" = "1" ] && verb="purge"

  if [ "${#installed[@]}" -gt 0 ]; then
    echo "==> Running: sudo apt-get ${verb} -y ${installed[*]}"
    run sudo apt-get "${verb}" -y "${installed[@]}"
  else
    echo "==> No Clipnest packages installed."
  fi

  echo "==> Removing the autostart entry (if any)…"
  local config_home="${XDG_CONFIG_HOME:-${HOME}/.config}"
  local data_home="${XDG_DATA_HOME:-${HOME}/.local/share}"
  safe_rm "${config_home}/autostart/${LINUX_AUTOSTART_FILE}"

  local ext_dir="${data_home}/gnome-shell/extensions/${LINUX_EXTENSION_UUID}"
  if [ -e "${ext_dir}" ]; then
    echo "==> Removing the per-user GNOME Shell extension…"
    if command -v gnome-extensions >/dev/null 2>&1; then
      run gnome-extensions disable "${LINUX_EXTENSION_UUID}" || true
    fi
    safe_rm "${ext_dir}"
  fi

  if [ "${PURGE}" = "1" ]; then
    echo "==> Purging your data and settings (--purge)…"
    safe_rm "${data_home}/Clipnest"
    safe_rm "${config_home}/clipnest"
    if [ "${CLIPNEST_DRY_RUN}" != "1" ] && getent group clipnest-input >/dev/null 2>&1; then
      echo "    Note: the clipnest-input group still exists; remove it with: sudo delgroup clipnest-input"
    else
      echo "    The clipnest-input group is removed by 'apt-get purge'. If you had opted in"
      echo "    to auto-paste, log out and back in for the group change to take effect."
    fi
  else
    echo "==> Keeping your history, snippets and settings in ${data_home}/Clipnest"
    echo "    and ${config_home}/clipnest (re-run with --purge to delete them)."
  fi
  finish
}

usage() {
  cat <<'USAGE'
Usage: curl -fsSL https://raw.githubusercontent.com/AayushGour/clipnest/main/scripts/uninstall.sh | bash [-s -- --purge]

Removes Clipnest on macOS or Linux (Ubuntu). Your history, snippets and
settings are kept unless you pass --purge (or set CLIPNEST_PURGE=1).
Set CLIPNEST_DRY_RUN=1 to print every action without changing anything.
USAGE
}

# 2: say what actually happened in a dry run.
finish() {
  if [ "${CLIPNEST_DRY_RUN}" = "1" ]; then
    echo "Dry run complete. Nothing was changed."
  else
    echo "Done. Clipnest has been removed."
  fi
}

main() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --purge) PURGE=1 ;;
      -h|--help) usage; return 0 ;;
      *) die "unknown option '${arg}' (supported: --purge)." ;;
    esac
  done
  [ "${CLIPNEST_DRY_RUN}" = "1" ] && echo "==> Dry run: nothing will be changed."
  case "$(uname -s)" in
    Darwin) uninstall_macos ;;
    Linux) uninstall_linux ;;
    *) die "unsupported OS '$(uname -s)'. Clipnest supports macOS and Linux (Ubuntu)." ;;
  esac
}

# CLIPNEST_SOURCE_ONLY=1 lets tests source the functions without running them.
# All code above is function definitions, so a truncated `curl | bash` download
# can never run a partial uninstall.
if [ "${CLIPNEST_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
