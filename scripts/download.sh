#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Configuration
# ==============================================================================
OWNER="${OWNER:-aklozyp}"
REPO="${REPO:-Moddex}"
ASSET_SUFFIX="${ASSET_SUFFIX:--linux-amd64.tar.gz}"   # e.g. "-linux-amd64.tar.gz"

# Optional: Self-check of the script (if available)
SCRIPT_OWNER="${MODDEX_SCRIPT_OWNER:-aklozyp}"
SCRIPT_REPO="${MODDEX_SCRIPT_REPO:-Moddex-build}"
SCRIPT_SHA_URL_DEFAULT="https://github.com/${SCRIPT_OWNER}/${SCRIPT_REPO}/releases/latest/download/download.sh.sha256"
SCRIPT_SHA_URL="${MODDEX_DOWNLOAD_SHA_URL:-$SCRIPT_SHA_URL_DEFAULT}"

# Inputs/Flags
VERSION="${VERSION:-}"          # e.g. "v0.1.0"; empty => latest
AUTO_RUN="${AUTO_RUN:-0}"       # 1 => automatically run installer at the end
INSTALL_DIR="${MODDEX_INSTALL_DIR:-}" # Target directory; if empty, ask interactively

# ==============================================================================
# Helper functions
# ==============================================================================
log() { printf '[INFO] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
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
  local url="$1"
  case "$DOWNLOADER" in
    curl) curl -fsSL "$url" ;;
    wget) wget -qO- "$url" ;;
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
  # Try sensible defaults
  if [[ -n "${XDG_DATA_HOME:-}" ]]; then
    INSTALL_DIR="$XDG_DATA_HOME/moddex"
  elif [[ -n "${HOME:-}" ]]; then
    INSTALL_DIR="$HOME/.local/share/moddex"
  else
    INSTALL_DIR="/opt/moddex"
  fi
  printf 'Installation directory [%s]: ' "$INSTALL_DIR" >&2
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
# Optional: Self-checksum (if source is reachable)
# ------------------------------------------------------------------------------
if [[ -n "${SCRIPT_SHA_URL:-}" ]]; then
  if checksum_line="$(http_get_stdout "$SCRIPT_SHA_URL" 2>/dev/null | awk 'NF {print; exit}')" && [[ -n "$checksum_line" ]]; then
    expected_script_sha="$(printf '%s\n' "$checksum_line" | awk '{print $1}')"
    # Calculate hash of this (running) script, if started from disk
    if [[ -n "${BASH_SOURCE[0]:-}" && -r "${BASH_SOURCE[0]}" ]]; then
      actual_script_sha="$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')"
      if [[ "$expected_script_sha" != "$actual_script_sha" ]]; then
        warn "download.sh checksum mismatch (expected $expected_script_sha, got $actual_script_sha) — continue at your own risk"
      else
        log "download.sh checksum OK"
      fi
    else
      warn "Cannot read current script for self-check; skipping"
    fi
  else
    warn "No script checksum available at $SCRIPT_SHA_URL; skipping self-check"
  fi
fi

# ------------------------------------------------------------------------------
# Determine release
# ------------------------------------------------------------------------------
if [[ -z "$VERSION" ]]; then
  # Get latest tag via HTTP Location header (without jq)
  latest_url="https://github.com/${OWNER}/${REPO}/releases/latest"
  case "$DOWNLOADER" in
    curl)
      redirect="$(curl -fsSLI "$latest_url" | awk -F': ' 'tolower($1)=="location"{print $2}' | tail -n1 | tr -d '\r')"
      ;;
    wget)
      redirect="$(wget -q --server-response --spider "$latest_url" 2>&1 | awk '/^  Location: /{print $2}' | tail -n1 | tr -d '\r')"
      ;;
  esac
  # redirect usually looks like: .../tag/v0.1.0
  VERSION="${redirect##*/}"
  [[ -n "$VERSION" ]] || die "Could not determine latest release tag"
  log "Using latest release: $VERSION"
else
  log "Using specified release: $VERSION"
fi

TARBALL_BASENAME="moddex-${VERSION}${ASSET_SUFFIX}"
SUMS_NAME="SHA256SUMS"
TARBALL_URL="https://github.com/${OWNER}/${REPO}/releases/download/${VERSION}/${TARBALL_BASENAME}"
SUMS_URL="https://github.com/${OWNER}/${REPO}/releases/download/${VERSION}/${SUMS_NAME}"

# ------------------------------------------------------------------------------
# Downloads
# ------------------------------------------------------------------------------
TARBALL="$TMPDIR/$TARBALL_BASENAME"
SUMS_FILE="$TMPDIR/$SUMS_NAME"

log "Downloading bundle: $TARBALL_URL"
download_to_file "$TARBALL_URL" "$TARBALL"

log "Downloading checksums: $SUMS_URL"
if ! download_to_file "$SUMS_URL" "$SUMS_FILE"; then
  die "Could not download checksum list from $SUMS_URL"
fi

# ------------------------------------------------------------------------------
# Robust checksum verification (independent of local filename)
# ------------------------------------------------------------------------------
log "Verifying checksum"
# 1) Try exact matching line (sha256sum format: "<hash>  <filename>")
if ! expected="$(awk -v f="$TARBALL_BASENAME" '$2==f || $NF==f {print $1; exit}' "$SUMS_FILE")"; then
  expected=""
fi

# 2) Fallback: tolerant grep (in case of spaces/tabs etc.)
if [[ -z "$expected" ]]; then
  expected="$(grep -E "^[0-9a-fA-F]{64}[[:space:]]+[*]?${TARBALL_BASENAME}$" "$SUMS_FILE" | awk '{print $1; exit}' || true)"
fi

if [[ -z "$expected" ]]; then
  die "No matching checksum entry for '$TARBALL_BASENAME' found in $SUMS_NAME"
fi

actual="$(sha256sum "$TARBALL" | awk '{print $1}')"
if [[ "$expected" != "$actual" ]]; then
  die "Checksum verification failed for $TARBALL_BASENAME
Expected: $expected
Actual:   $actual"
fi
log "Checksum OK"

# ------------------------------------------------------------------------------
# Extract and run installer
# ------------------------------------------------------------------------------
resolve_install_dir
log "Extracting bundle into $INSTALL_DIR"
tar -xzf "$TARBALL" -C "$INSTALL_DIR"

# Try to locate installer
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

log "Done"
