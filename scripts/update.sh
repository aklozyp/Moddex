#!/usr/bin/env bash
set -Eeuo pipefail

OWNER="${OWNER:-aklozyp}"
REPO="${REPO:-Moddex}"
ASSET_SUFFIX="${ASSET_SUFFIX:--linux-amd64.tar.gz}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }

# --- Host lock against parallel installations and updates (issue #108) ------
#
# update.sh holds the same host-wide advisory lock (flock) as install.sh
# across its mutating phase: the service stop plus the staged installation.
# A second installation or update run then fails fast with the running
# operation's ID (holder PID and start time from the lock metadata) instead
# of changing the same artifacts, environment files, unit, and service in
# parallel; it makes no changes of its own. The kernel releases the lock when
# this process ends, including on SIGKILL, and no child still carries the
# inherited lock descriptor (for example the staged installer still running
# after this updater was killed), so a crashed update never leaves a
# permanent lock; the file itself stays in place as the lock target and
# carries only diagnostic metadata for error messages (lock validity comes
# from the kernel lock alone). The default /run/moddex/install.lock lives in
# a root-owned runtime directory; MODDEX_LOCK_FILE relocates it for isolated
# test fixtures. Holding the lock requires root, like the service operations
# of this script; the bundled installer reenters the held lock through the
# recorded PID in MODDEX_LOCK_PID.
MODDEX_LOCK_FILE="${MODDEX_LOCK_FILE:-/run/moddex/install.lock}"
UPDATE_LOCK_PID=""

# Prints "pid start" from the lock file's metadata line
# ("pid=<pid> start=<utc> op=<operation>"); both fields are empty when the
# file is unreadable or its content is not a metadata line.
install_lock_holder_fields() {
  local line="" pid="" start=""
  IFS= read -r line < "$MODDEX_LOCK_FILE" 2>/dev/null || line=""
  case "$line" in
    pid=[0-9]*\ *)
      pid="${line#pid=}"
      pid="${pid%% *}"
      start="${line#*start=}"
      start="${start%% *}"
      printf '%s %s\n' "$pid" "$start"
      ;;
  esac
}

release_update_lock() {
  if [[ -n "$UPDATE_LOCK_PID" ]]; then
    UPDATE_LOCK_PID=""
    flock -u 9 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
  fi
}

acquire_update_lock() {
  local holder holder_pid="" holder_start="" lock_dir
  command -v flock >/dev/null 2>&1 ||
    { echo "[ERROR] flock is unavailable, but Moddex serializes concurrent installation and update runs with it. Install the util-linux package (or your distribution's flock provider), then rerun scripts/update.sh; the service was not stopped." >&2; exit 1; }
  [[ "$MODDEX_LOCK_FILE" == /* ]] ||
    { echo "[ERROR] MODDEX_LOCK_FILE must be an absolute file path (received: $MODDEX_LOCK_FILE). Set an absolute lock file path, then rerun scripts/update.sh; the service was not stopped." >&2; exit 1; }
  if [[ -e "$MODDEX_LOCK_FILE" && ! -f "$MODDEX_LOCK_FILE" ]]; then
    echo "[ERROR] The Moddex lock path $MODDEX_LOCK_FILE exists but is not a regular file. Remove or replace it, then rerun scripts/update.sh; the service was not stopped." >&2
    exit 1
  fi
  lock_dir="${MODDEX_LOCK_FILE%/*}"
  # -m 0755 applies to the leaf (the lock directory itself), which is exactly
  # the created target here; parents keep their existing permissions.
  # shellcheck disable=SC2174
  if ! mkdir -p -m 0755 -- "$lock_dir"; then
    echo "[ERROR] Could not create the Moddex lock directory $lock_dir. Run this update as root (for example sudo -E bash scripts/update.sh) or create the directory as root, then rerun scripts/update.sh; the service was not stopped." >&2
    exit 1
  fi
  if ! { : >> "$MODDEX_LOCK_FILE"; } 2>/dev/null; then
    echo "[ERROR] Cannot write the Moddex lock file $MODDEX_LOCK_FILE. Run this update as root, then rerun scripts/update.sh; the service was not stopped." >&2
    exit 1
  fi
  exec 9>> "$MODDEX_LOCK_FILE"
  if flock -n 9; then
    UPDATE_LOCK_PID="$$"
    : > "$MODDEX_LOCK_FILE"
    printf 'pid=%s start=%s op=%s\n' "$$" "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)" "update" >&9
    echo "[INFO] Acquired the Moddex host lock ($MODDEX_LOCK_FILE, operation PID $$)."
    return 0
  fi
  holder="$(install_lock_holder_fields)" || holder=""
  holder_pid="${holder%% *}"
  if [[ "$holder" == *" "* ]]; then
    holder_start="${holder#* }"
  fi
  if [[ -z "$holder_pid" ]]; then
    echo "[ERROR] Another Moddex installation or update is currently running and holds the host lock ($MODDEX_LOCK_FILE); its operation ID could not be read. Wait for the running installation or update to finish, then rerun scripts/update.sh; the service was not stopped." >&2
    exit 1
  fi
  if kill -0 "$holder_pid" 2>/dev/null; then
    echo "[ERROR] Another Moddex installation or update is currently running (operation PID $holder_pid, started ${holder_start:-unknown}). Wait for it to finish, then rerun scripts/update.sh; the service was not stopped." >&2
    exit 1
  fi
  echo "[ERROR] The Moddex host lock ($MODDEX_LOCK_FILE) could not be acquired; it is recorded for PID $holder_pid (started ${holder_start:-unknown}), which is not running anymore. The lock is held by another local process that did not record itself: check for other Moddex installation or update activity, then rerun scripts/update.sh; the service was not stopped." >&2
  exit 1
}

resolve_downloader() {
  local script_dir
  script_dir="$(CDPATH="" cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || {
    echo "[ERROR] Could not resolve the updater directory. Extract the complete Moddex bundle again and run its scripts/update.sh." >&2
    exit 1
  }
  DOWNLOAD_SCRIPT="$script_dir/download.sh"
  [[ -f "$DOWNLOAD_SCRIPT" && -r "$DOWNLOAD_SCRIPT" ]] || {
    echo "[ERROR] Bundled download.sh is missing or unreadable. Extract the complete Moddex bundle again, keep download.sh beside update.sh, and retry." >&2
    exit 1
  }
}

pick_downloader() {
  if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
  elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
  else
    echo "Need curl or wget" >&2; exit 1
  fi
}
http_head_latest_tag() {
  local latest_url="https://github.com/${OWNER}/${REPO}/releases/latest"
  case "$DOWNLOADER" in
    curl) curl -fsSLI "$latest_url" | awk -F': ' 'tolower($1)=="location"{print $2}' | tail -n1 | tr -d '\r' ;;
    wget) wget -q --server-response --spider "$latest_url" 2>&1 | awk '/^  Location: /{print $2}' | tail -n1 | tr -d '\r' ;;
  esac
}

installed_version() {
  if [[ -f /opt/moddex/VERSION ]]; then
    sed -n '1p' /opt/moddex/VERSION | tr -d '\r\n'
  else
    echo "unknown"
  fi
}

is_installed() {
  [[ -f /opt/moddex/app.jar ]] || systemctl list-units --type=service --all 2>/dev/null | grep -q 'moddex-backend.service' || return 1
}

require_cmd sha256sum
require_cmd tar
require_cmd systemctl
require_cmd mktemp
pick_downloader

CURR="unknown"
if is_installed; then
  CURR="$(installed_version)"
fi

redirect="$(http_head_latest_tag)"
LATEST="${redirect##*/}"
[[ -n "$LATEST" ]] || { echo "Could not determine latest tag" >&2; exit 1; }

echo "[INFO] Installed version: $CURR"
echo "[INFO] Latest available:  $LATEST"

if ! is_installed; then
  read -r -p "Moddex is not installed. Install now? [y/N] " a
  if [[ "${a,,}" == y* ]]; then
    resolve_downloader
    AUTO_RUN=1 bash "$DOWNLOAD_SCRIPT"
  else
    echo "Aborted."
  fi
  exit 0
fi

if [[ "$CURR" == "$LATEST" ]]; then
  echo "[INFO] Already up-to-date."
  exit 0
fi

echo "[INFO] Updating to $LATEST ..."
resolve_downloader

STAGE_DIR="$(mktemp -d -t moddex-update.XXXXXX)" || {
  echo "[ERROR] Could not create a staging directory for the update. Check the permissions of the temporary directory (TMPDIR), then rerun scripts/update.sh." >&2
  exit 1
}
cleanup_update_stage() { release_update_lock; rm -rf -- "$STAGE_DIR"; }
trap cleanup_update_stage EXIT

# Download the release, verify the published checksum, and stage the complete
# bundle BEFORE stopping the running service, so a failed download or
# verification never extends the downtime; the installed version keeps running.
stage_status=0
AUTO_RUN=1 VERSION="$LATEST" bash "$DOWNLOAD_SCRIPT" --stage-only "$STAGE_DIR" || stage_status=$?
if [[ "$stage_status" -ne 0 ]]; then
  echo "[ERROR] Downloading or verifying the update failed before Moddex was stopped; the installed version keeps running. Resolve the network or release problem, then rerun scripts/update.sh." >&2
  exit "$stage_status"
fi

# The staged bundle is complete and checksum-verified. Before the first
# mutation of this update (the service stop), acquire the host lock so a
# parallel installation or update run fails fast instead of changing the same
# artifacts, environment files, unit, and service (issue #108); the bundled
# installer reenters the held lock via the recorded operation PID.
acquire_update_lock

echo "[INFO] Update staged and verified; stopping the Moddex service ..."
sudo systemctl stop moddex-backend || true

install_status=0
MODDEX_LOCK_PID="$UPDATE_LOCK_PID" AUTO_RUN=1 VERSION="$LATEST" bash "$DOWNLOAD_SCRIPT" --install-staged "$STAGE_DIR" || install_status=$?
if [[ "$install_status" -ne 0 ]]; then
  echo "[ERROR] Installing the staged update failed after Moddex was stopped. Rerun scripts/update.sh once the problem is fixed, or bring the service back up with 'sudo systemctl start moddex-backend.service'." >&2
  exit "$install_status"
fi

echo "[INFO] Update complete."
