#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Configuration defaults (override with environment variables)
# ==============================================================================
OWNER="${OWNER:-aklozyp}"
REPO="${REPO:-Moddex}"
ASSET_SUFFIX="${ASSET_SUFFIX:--linux-amd64.tar.gz}"
VERSION="${VERSION:-}"
AUTO_RUN="${AUTO_RUN:-1}"
BUNDLE_DIR="${MODDEX_BUNDLE_DIR:-${MODDEX_INSTALL_DIR:-}}"

# ==============================================================================
# Helpers
# ==============================================================================
log() { printf '[INFO] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

usage() {
  cat <<'USAGE'
Usage: download.sh [options]

Options:
  --version <tag>       Install a specific release tag (default: latest)
  --asset-suffix <s>    Override asset suffix (default: -linux-amd64.tar.gz)
  --bundle-dir <path>   Extract bundle into path instead of a temp directory
  --run                 Force running the installer after download (default)
  --no-run              Download and extract only (skip installer)
  -h, --help            Show this help and exit

Environment overrides:
  OWNER, REPO, ASSET_SUFFIX, VERSION, AUTO_RUN, MODDEX_BUNDLE_DIR
USAGE
}

pick_downloader() {
  if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
  elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
  else
    die "Need either curl or wget"
  fi
}

http_get_stdout() {
  case "$DOWNLOADER" in
    curl) curl -fsSL "$1" ;;
    wget) wget -qO- "$1" ;;
  esac
}

http_get_headers() {
  case "$DOWNLOADER" in
    curl) curl -fsSLI "$1" ;;
    wget) wget -q --server-response --spider "$1" 2>&1 ;;
  esac
}

download_to_file() {
  local url="$1" out="$2"
  case "$DOWNLOADER" in
    curl) curl -fsSL "$url" -o "$out" ;;
    wget) wget -q "$url" -O "$out" ;;
  esac
}

resolve_version() {
  if [[ -n "$VERSION" ]]; then
    return
  fi
  local latest_url="https://github.com/${OWNER}/${REPO}/releases/latest"
  local redirect
  redirect="$(http_get_headers "$latest_url" | awk -F': ' 'tolower($1)=="location"{print $2}' | tail -n1 | tr -d '\r')"
  VERSION="${redirect##*/}"
  [[ -n "$VERSION" ]] || die "Unable to determine latest release tag"
}

prepare_bundle_dir() {
  if [[ -n "$BUNDLE_DIR" ]]; then
    mkdir -p "$BUNDLE_DIR"
    return
  fi
  local temp_root
  temp_root="$(mktemp -d -t moddex-download.XXXXXX)"
  BUNDLE_DIR="$temp_root/bundle"
  mkdir -p "$BUNDLE_DIR"
  CLEANUP_ROOT="$temp_root"
}

# Ensure cleanup even when AUTO_RUN succeeds
cleanup_tmp() {
  [[ -n "${CLEANUP_ROOT:-}" && -d "$CLEANUP_ROOT" ]] && rm -rf "$CLEANUP_ROOT"
}

# ==============================================================================
# Argument parsing
# ==============================================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || die "Missing value for --version"
      VERSION="$2"
      shift 2
      ;;
    --asset-suffix)
      [[ $# -ge 2 ]] || die "Missing value for --asset-suffix"
      ASSET_SUFFIX="$2"
      shift 2
      ;;
    --bundle-dir)
      [[ $# -ge 2 ]] || die "Missing value for --bundle-dir"
      BUNDLE_DIR="$2"
      shift 2
      ;;
    --run)
      AUTO_RUN=1
      shift
      ;;
    --no-run)
      AUTO_RUN=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

require_cmd tar
require_cmd sha256sum
pick_downloader
resolve_version
prepare_bundle_dir
log "Using release tag: $VERSION"

ASSET_DIR="$(mktemp -d -t moddex-assets.XXXXXX)"
trap 'cleanup_tmp; rm -rf "$ASSET_DIR"' EXIT

TARBALL_BASENAME="moddex-${VERSION}${ASSET_SUFFIX}"
TARBALL_URL="https://github.com/${OWNER}/${REPO}/releases/download/${VERSION}/${TARBALL_BASENAME}"
SHA_URL="${TARBALL_URL}.sha256"
TARBALL="$ASSET_DIR/$TARBALL_BASENAME"
SHA_FILE="$ASSET_DIR/${TARBALL_BASENAME}.sha256"

log "Downloading bundle from $TARBALL_URL"
download_to_file "$TARBALL_URL" "$TARBALL"
log "Downloading checksum from ${SHA_URL}"
download_to_file "$SHA_URL" "$SHA_FILE"

log "Verifying checksum"
(
  cd "$ASSET_DIR"
  sha256sum -c "$(basename "$SHA_FILE")"
)

log "Extracting bundle into $BUNDLE_DIR"
tar -xzf "$TARBALL" -C "$BUNDLE_DIR"

mapfile -t installers < <(find "$BUNDLE_DIR" -maxdepth 4 -type f -path '*/scripts/install.sh')
[[ ${#installers[@]} -gt 0 ]] || die "Installer script not found in extracted bundle"
INSTALLER="${installers[0]}"
chmod +x "$INSTALLER"
log "Resolved installer at $INSTALLER"

if [[ "$AUTO_RUN" == "1" ]]; then
  log "Running installer (sudo will be used if available)"
  if [[ "${EUID:-$(id -u)}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
    sudo "$INSTALLER"
  else
    "$INSTALLER"
  fi
  INSTALL_EXIT=$?
  cleanup_tmp
  rm -rf "$ASSET_DIR"
  exit "$INSTALL_EXIT"
else
  log "Skipping automatic execution (AUTO_RUN=0)."
  log "You can run the installer manually via: sudo '$INSTALLER'"
fi

cleanup_tmp
rm -rf "$ASSET_DIR"
