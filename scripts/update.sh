#!/usr/bin/env bash
set -Eeuo pipefail

OWNER="${OWNER:-aklozyp}"
REPO="${REPO:-Moddex}"
ASSET_SUFFIX="${ASSET_SUFFIX:--linux-amd64.tar.gz}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }

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
    AUTO_RUN=1 bash ./download.sh
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
# Stop services before replacing artifacts (installer will re-enable/start)
sudo systemctl stop moddex-backend moddex-caddy || true

# Run the regular downloader in non-interactive mode
AUTO_RUN=1 VERSION="$LATEST" bash ./download.sh

echo "[INFO] Update complete."
