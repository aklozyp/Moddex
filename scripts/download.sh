#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Configuration
# ==============================================================================
OWNER="${OWNER:-aklozyp}"
REPO="${REPO:-Moddex}"
ASSET_SUFFIX="${ASSET_SUFFIX:--linux-amd64.tar.gz}"   # e.g. "-linux-amd64.tar.gz"

# Inputs/Flags
VERSION="${VERSION:-}"          # e.g. "v0.1.1"; empty => latest
AUTO_RUN="${AUTO_RUN:-0}"       # 1 => automatically run installer at the end
INSTALL_DIR="${MODDEX_INSTALL_DIR:-}" # Target directory; if empty, ask interactively

# ==============================================================================
# Helper functions
# ==============================================================================
log() { printf '[INFO] %s\n' "$*" >&2; }
die() { printf '[ERR ] %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

pick_downloader() {
  if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
  elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
  else
    die "Need curl or wget"
  fi
}

http_get_stdout() {
  case "$DOWNLOADER" in
    curl) curl -fsSL "$1" ;;
    wget) wget -qO- "$1" ;;
  esac
}

download_to_file() {
  local url="$1" out="$2"
  case "$DOWNLOADER" in
    curl) curl -fsSL "$url" -o "$out" ;;
    wget) wget -q "$url" -O "$out" ;;
  esac
}

read_yn() {
  local prompt="$1" default="${2:-n}" reply
  read -r -p "$prompt " reply || true
  reply="${reply:-$default}"
  printf '%s' "$reply"
}

resolve_install_dir() {
  if [[ -n "$INSTALL_DIR" ]]; then
    mkdir -p "$INSTALL_DIR"
    return
  fi
  if [[ -n "${XDG_DATA_HOME:-}" ]]; then
    INSTALL_DIR="$XDG_DATA_HOME/moddex"
  elif [[ -n "${HOME:-}" ]]; then
    INSTALL_DIR="$HOME/.local/share/moddex"
  else
    INSTALL_DIR="/opt/moddex"
  fi
  printf 'Extraction directory [%s]: ' "$INSTALL_DIR" >&2
  local reply; read -r reply || true
  if [[ -n "$reply" ]]; then INSTALL_DIR="$reply"; fi
  mkdir -p "$INSTALL_DIR"
}

# ==============================================================================
# Start
# ==============================================================================
require_cmd tar
require_cmd sha256sum
pick_downloader

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# ------------------------------------------------------------------------------
# Determine release
# ------------------------------------------------------------------------------
if [[ -z "$VERSION" ]]; then
  latest_url="https://github.com/${OWNER}/${REPO}/releases/latest"
  case "$DOWNLOADER" in
    curl) redirect="$(curl -fsSLI "$latest_url" | awk -F': ' 'tolower($1)=="location"{print $2}' | tail -n1 | tr -d '\r')" ;;
    wget) redirect="$(wget -q --server-response --spider "$latest_url" 2>&1 | awk '/^  Location: /{print $2}' | tail -n1 | tr -d '\r')" ;;
  esac
  VERSION="${redirect##*/}"
  [[ -n "$VERSION" ]] || die "Could not determine latest release tag"
  log "Using latest release: $VERSION"
else
  log "Using specified release: $VERSION"
fi

TARBALL_BASENAME="moddex-${VERSION}${ASSET_SUFFIX}"
TARBALL_URL="https://github.com/${OWNER}/${REPO}/releases/download/${VERSION}/${TARBALL_BASENAME}"
SHA_URL="${TARBALL_URL}.sha256"

# ------------------------------------------------------------------------------
# Downloads
# ------------------------------------------------------------------------------
TARBALL="$TMPDIR/$TARBALL_BASENAME"
SHA_FILE="$TMPDIR/${TARBALL_BASENAME}.sha256"

log "Downloading bundle: $TARBALL_URL"
download_to_file "$TARBALL_URL" "$TARBALL"

log "Downloading checksum: ${SHA_URL}"
download_to_file "$SHA_URL" "$SHA_FILE"

# ------------------------------------------------------------------------------
# Checksum verification
# ------------------------------------------------------------------------------
log "Verifying checksum"
(
  cd "$TMPDIR"
  sha256sum -c "$(basename "$SHA_FILE")"
)

# ------------------------------------------------------------------------------
# Extract and run installer
# ------------------------------------------------------------------------------
resolve_install_dir
log "Extracting bundle into $INSTALL_DIR"
tar -xzf "$TARBALL" -C "$INSTALL_DIR"

INSTALLER="$INSTALL_DIR/scripts/install.sh"
if [[ ! -f "$INSTALLER" ]]; then
  INSTALLER="$(find "$INSTALL_DIR" -maxdepth 3 -path '*/scripts/install.sh' -type f | head -n 1 || true)"
fi
[[ -n "${INSTALLER:-}" && -f "$INSTALLER" ]] || die "Installer script not found inside bundle"

chmod +x "$INSTALLER"

if [[ "$AUTO_RUN" == "1" ]]; then
  log "AUTO_RUN enabled — executing installer"
  if [[ "${EUID:-$(id -u)}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
    exec sudo "$INSTALLER"
  else
    exec "$INSTALLER"
  fi
else
  reply="$(read_yn "Run installer now? [y/N]")"
  if [[ "${reply,,}" == y* ]]; then
    log "Executing installer"
    if [[ "${EUID:-$(id -u)}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
      exec sudo "$INSTALLER"
    else
      exec "$INSTALLER"
    fi
  else
    log "Skipping automatic run"
  fi
fi
