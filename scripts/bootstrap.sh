#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
OWNER="aklozyp"
REPO="Moddex"
ASSET_SUFFIX="-linux-amd64.tar.gz"

# Optional pin: export VERSION=v0.1.0 before running this script.
VERSION="${VERSION:-}"

# --- Utils ---
die() { echo "ERROR: $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Missing required tool: $1"; }

need_any() {
  for bin in "$@"; do
    if command -v "$bin" >/dev/null 2>&1; then return 0; fi
  done
  return 1
}

is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

try_pkg_install() {
  # Try to install the given package name(s) with a best-effort approach.
  # Usage: try_pkg_install "curl" || try_pkg_install "wget"
  local pkg="$1"
  echo "[bootstrap] Attempting to install '$pkg' (best effort)..."

  if command -v apt-get >/dev/null 2>&1; then
    (set -x; sudo apt-get update -y && sudo apt-get install -y "$pkg") || return 1
  elif command -v apt >/dev/null 2>&1; then
    (set -x; sudo apt update -y && sudo apt install -y "$pkg") || return 1
  elif command -v dnf >/dev/null 2>&1; then
    (set -x; sudo dnf install -y "$pkg") || return 1
  elif command -v yum >/dev/null 2>&1; then
    (set -x; sudo yum install -y "$pkg") || return 1
  elif command -v zypper >/dev/null 2>&1; then
    (set -x; sudo zypper --non-interactive install "$pkg") || return 1
  elif command -v pacman >/dev/null 2>&1; then
    (set -x; sudo pacman -Sy --noconfirm "$pkg") || return 1
  elif command -v apk >/dev/null 2>&1; then
    (set -x; sudo apk add --no-cache "$pkg") || return 1
  else
    echo "[bootstrap] No supported package manager found to install '$pkg'." >&2
    return 1
  fi
}

# Ensure we have either curl or wget; try to install if missing
if ! need_any curl wget; then
  try_pkg_install "curl" || try_pkg_install "wget" || die "Neither curl nor wget is installed and automatic installation failed."
fi

# After attempted install, pick the downloader
if command -v curl >/dev/null 2>&1; then
  DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
  DOWNLOADER="wget"
else
  die "Neither curl nor wget available."
fi

# Download helpers that abstract curl/wget differences
http_get_stdout() {
  # Print URL to stdout
  local url="$1"
  case "$DOWNLOADER" in
    curl) curl -fsSL "$url" ;;
    wget) wget -qO- "$url" ;;
  esac
}

download_to_file() {
  # download_to_file URL OUTFILE
  local url="$1" out="$2"
  case "$DOWNLOADER" in
    curl) curl -fsSL "$url" -o "$out" ;;
    wget) wget -q "$url" -O "$out" ;;
  esac
}

# Other required base tools
need tar
# grep/sed are assumed present on all typical distros; bail out early if not:
need grep
need sed

api_latest_asset_url() {
  # Return browser_download_url for the tarball asset of the latest release
  local api="https://api.github.com/repos/${OWNER}/${REPO}/releases/latest"
  http_get_stdout "$api" \
  | grep -Eo '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*'"$ASSET_SUFFIX"'"' \
  | sed -E 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
  | head -n1
}

asset_url_for_version() {
  # Our artifact naming: moddex-<tag>-linux-amd64.tar.gz
  echo "https://github.com/${OWNER}/${REPO}/releases/download/${VERSION}/moddex-${VERSION}${ASSET_SUFFIX}"
}

checksum_url_for_version() {
  echo "https://github.com/${OWNER}/${REPO}/releases/download/${VERSION}/moddex-${VERSION}-SHA256SUMS"
}

# --- Resolve URLs ---
if [[ -n "$VERSION" ]]; then
  TARBALL_URL="$(asset_url_for_version)"
  SUMS_URL="$(checksum_url_for_version)"
else
  TARBALL_URL="$(api_latest_asset_url)"
  [[ -n "${TARBALL_URL:-}" ]] || die "Could not determine tarball URL (no release asset found)."
  TAG_FROM_URL="$(basename "$TARBALL_URL" | sed -E 's/^moddex-(v[^-]+)-linux-amd64\.tar\.gz$/\1/')"
  SUMS_URL="https://github.com/${OWNER}/${REPO}/releases/download/${TAG_FROM_URL}/moddex-${TAG_FROM_URL}-SHA256SUMS"
fi

echo "[bootstrap] Using downloader: $DOWNLOADER"
echo "[bootstrap] Downloading: $TARBALL_URL"

WORKDIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

TARBALL="${WORKDIR}/$(basename "$TARBALL_URL")"
SUMS="${WORKDIR}/SHA256SUMS"

download_to_file "$TARBALL_URL" "$TARBALL"

# Optional checksum verification (if sha256sum exists and sums file is present)
if command -v sha256sum >/dev/null 2>&1; then
  if download_to_file "$SUMS_URL" "$SUMS"; then
    echo "[bootstrap] Verifying checksum..."
    (
      cd "$WORKDIR"
      # Extract expected line for our tarball filename (if present)
      grep -F "$(basename "$TARBALL")" "$SUMS" | sha256sum --check --status
    ) || die "Checksum verification failed"
    echo "[bootstrap] Checksum OK."
  else
    echo "[bootstrap] No checksum at $SUMS_URL (skipping verification)."
  fi
else
  echo "[bootstrap] sha256sum not found (skipping verification)."
fi

echo "[bootstrap] Extracting..."
EXTRACT_DIR="${WORKDIR}/bundle"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$TARBALL" -C "$EXTRACT_DIR"

INSTALLER="${EXTRACT_DIR}/scripts/install.sh"
if [[ ! -x "$INSTALLER" ]]; then
  chmod +x "$INSTALLER" || true
fi
[[ -f "$INSTALLER" ]] || die "Installer not found at $INSTALLER"

echo "[bootstrap] Starting interactive installer..."
if is_root; then
  "$INSTALLER"
elif command -v sudo >/dev/null 2>&1; then
  sudo "$INSTALLER"
else
  echo "[bootstrap] 'sudo' not found. Attempting to run installer directly (may fail if privileges are required)..."
  "$INSTALLER"
fi

echo "[bootstrap] Done."
