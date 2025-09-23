#!/usr/bin/env bash
set -Eeuo pipefail

OWNER="aklozyp"
REPO="Moddex"
ASSET_SUFFIX="-linux-amd64.tar.gz"

SCRIPT_OWNER="${MODDEX_SCRIPT_OWNER:-aklozyp}"
SCRIPT_REPO="${MODDEX_SCRIPT_REPO:-Moddex-build}"
SCRIPT_SHA_URL_DEFAULT="https://github.com/${SCRIPT_OWNER}/${SCRIPT_REPO}/releases/latest/download/download.sh.sha256"
SCRIPT_SHA_URL="${MODDEX_DOWNLOAD_SHA_URL:-$SCRIPT_SHA_URL_DEFAULT}"

VERSION="${VERSION:-}"
AUTO_RUN=0
INSTALL_DIR="${MODDEX_INSTALL_DIR:-}"

usage() {
  cat <<'USAGE'
Usage: download.sh [options]

Fetch the Moddex release bundle and prepare the installer locally. Set VERSION=vX.Y.Z
before invoking the script to pin a specific release; otherwise the latest release is used.

Options:
  --run                 Execute the installer after download (requires privileges)
  --install-dir PATH    Extract the bundle into PATH (default: ./moddex-<release>-bundle)
  -h, --help            Show this help message
USAGE
}

log() { printf '[moddex-download] %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      AUTO_RUN=1
      shift
      ;;
    --install-dir)
      [[ $# -ge 2 ]] || die "Missing value for --install-dir"
      INSTALL_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

if command -v curl >/dev/null 2>&1; then
  DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
  DOWNLOADER="wget"
else
  die "Required tool not found: install curl or wget"
fi

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

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

resolve_script_path() {
  local source="${BASH_SOURCE[0]}"
  if [[ -z "$source" || "$source" == "-" || "$source" == "bash" ]]; then
    if [[ -n "${MODDEX_DOWNLOAD_SCRIPT:-}" && -f "${MODDEX_DOWNLOAD_SCRIPT}" ]]; then
      if command -v realpath >/dev/null 2>&1; then
        realpath "${MODDEX_DOWNLOAD_SCRIPT}"
      elif command -v readlink >/dev/null 2>&1; then
        readlink -f "${MODDEX_DOWNLOAD_SCRIPT}"
      else
        printf '%s\n' "${MODDEX_DOWNLOAD_SCRIPT}"
      fi
      return 0
    fi
    return 1
  fi
  if command -v realpath >/dev/null 2>&1; then
    realpath "$source"
  elif command -v readlink >/dev/null 2>&1; then
    readlink -f "$source"
  else
    printf '%s\n' "$source"
  fi
}

verify_self_checksum() {
  if ! command -v sha256sum >/dev/null 2>&1; then
    log "sha256sum not available - skipping download.sh verification"
    return
  fi
  local script_path checksum_source expected actual
  if ! script_path="$(resolve_script_path)" || [[ -z "$script_path" ]]; then
    log "Unable to determine script path for checksum verification; skipping"
    return
  fi

  if [[ -n "${MODDEX_DOWNLOAD_CHECKSUM:-}" && -f "${MODDEX_DOWNLOAD_CHECKSUM}" ]]; then
    checksum_source="${MODDEX_DOWNLOAD_CHECKSUM}"
    expected="$(awk '{print $1; exit}' "$checksum_source")"
  else
    local local_sha_file="${script_path}.sha256"
    if [[ -f "$local_sha_file" ]]; then
      checksum_source="$local_sha_file"
      expected="$(awk '{print $1; exit}' "$checksum_source")"
    elif [[ -n "$SCRIPT_SHA_URL" ]]; then
      checksum_source="$SCRIPT_SHA_URL"
      expected="$(http_get_stdout "$SCRIPT_SHA_URL" 2>/dev/null | awk 'NF {print $1; exit}')"
    fi
  fi

  if [[ -z "${expected:-}" ]]; then
    log "No checksum source available - skipping download.sh verification"
    return
  fi

  actual="$(sha256sum "$script_path" | awk '{print $1}')"
  if [[ "$expected" != "$actual" ]]; then
    die "download.sh checksum mismatch (expected $expected, got $actual)"
  fi
  log "download.sh checksum verification passed"
}

require_cmd tar
require_cmd grep
require_cmd sed
require_cmd head
require_cmd find
require_cmd awk
require_cmd mktemp
require_cmd basename

verify_self_checksum

api_latest_asset_url() {
  local api="https://api.github.com/repos/${OWNER}/${REPO}/releases/latest"
  http_get_stdout "$api" \
    | grep -Eo '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*'"$ASSET_SUFFIX"'"' \
    | sed -E 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
    | head -n 1
}

asset_url_for_version() {
  local tag="$1"
  printf 'https://github.com/%s/%s/releases/download/%s/moddex-%s%s\n' "$OWNER" "$REPO" "$tag" "$tag" "$ASSET_SUFFIX"
}

checksum_url_for_version() {
  local tag="$1"
  printf 'https://github.com/%s/%s/releases/download/%s/moddex-%s-SHA256SUMS\n' "$OWNER" "$REPO" "$tag" "$tag"
}

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

if [[ -n "$VERSION" ]]; then
  TARBALL_URL="$(asset_url_for_version "$VERSION")"
  SUMS_URL="$(checksum_url_for_version "$VERSION")"
  TAG="$VERSION"
else
  TARBALL_URL="$(api_latest_asset_url)"
  [[ -n "${TARBALL_URL:-}" ]] || die "Could not determine release asset URL"
  TAG="$(basename "$TARBALL_URL" | sed -E 's/^moddex-(v[^-]+)-linux-amd64\.tar\.gz$/\1/')"
  [[ -n "$TAG" ]] || die "Could not parse release tag from asset name"
  SUMS_URL="https://github.com/${OWNER}/${REPO}/releases/download/${TAG}/moddex-${TAG}-SHA256SUMS"
fi

if [[ -z "$INSTALL_DIR" ]]; then
  INSTALL_DIR="moddex-${TAG}-bundle"
fi

[[ -e "$INSTALL_DIR" ]] && die "Target directory '$INSTALL_DIR' already exists"
mkdir -p "$INSTALL_DIR"

log "Downloading release: $TARBALL_URL"
TARBALL="$TMPDIR/moddex.tar.gz"
download_to_file "$TARBALL_URL" "$TARBALL"

if command -v sha256sum >/dev/null 2>&1; then
  SUMS_FILE="$TMPDIR/SHA256SUMS"
  if download_to_file "$SUMS_URL" "$SUMS_FILE"; then
    log "Verifying bundle checksum"
    (
      cd "$TMPDIR"
      grep -F "$(basename "$TARBALL")" "$SUMS_FILE" | sha256sum --check --status
    ) || die "Checksum verification failed"
  else
    log "Checksum list not available at $SUMS_URL (skipping verification)"
  fi
else
  log "sha256sum not available - skipping bundle verification"
fi

log "Extracting bundle into $INSTALL_DIR"
tar -xzf "$TARBALL" -C "$INSTALL_DIR"

INSTALLER="$INSTALL_DIR/scripts/install.sh"
if [[ ! -f "$INSTALLER" ]]; then
  INSTALLER="$(find "$INSTALL_DIR" -maxdepth 3 -path '*/scripts/install.sh' -type f | head -n 1)"
fi
[[ -n "$INSTALLER" && -f "$INSTALLER" ]] || die "Installer script not found inside bundle"
chmod +x "$INSTALLER" || true
BUNDLE_ROOT="$(cd "$(dirname "$INSTALLER")/.." && pwd)"

cat <<INFO

Bundle ready at: $BUNDLE_ROOT
Next steps:
  cd "$BUNDLE_ROOT"
  sudo ./scripts/install.sh

Set VERSION=vX.Y.Z before running this script to pin a specific release.
INFO

if (( AUTO_RUN )); then
  printf '\nRun the installer now? [y/N] '
  read -r reply
  reply="${reply:-}"
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
