#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
OWNER="aklozyp"
REPO="Moddex"
ASSET_SUFFIX="-linux-amd64.tar.gz"

# Optional pin: export VERSION=v0.1.0 before running this script.
VERSION="${VERSION:-}"

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "Missing required tool: $1"; }
need curl
need tar

api_latest_asset_url() {
  # Return browser_download_url for the tarball asset of the latest release
  local api="https://api.github.com/repos/${OWNER}/${REPO}/releases/latest"
  curl -fsSL -H 'Accept: application/vnd.github+json' "$api" \
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

echo "[bootstrap] Downloading: $TARBALL_URL"
WORKDIR="$(mktemp -d)"
TARBALL="${WORKDIR}/bundle.tar.gz"
SUMS="${WORKDIR}/SHA256SUMS"
curl -fsSL "$TARBALL_URL" -o "$TARBALL"

# Optional checksum verification (if sha256sum exists and sums file is present)
if command -v sha256sum >/dev/null; then
  if curl -fsSL "$SUMS_URL" -o "$SUMS"; then
    echo "[bootstrap] Verifying checksum..."
    (cd "$WORKDIR" && sha256sum --check --status <(grep "$(basename "$TARBALL")" "$SUMS" || true)) \
      || die "Checksum verification failed"
    echo "[bootstrap] Checksum OK."
  else
    echo "[bootstrap] No checksum at $SUMS_URL (skipping verification)."
  fi
fi

echo "[bootstrap] Extracting..."
EXTRACT_DIR="${WORKDIR}/bundle"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$TARBALL" -C "$EXTRACT_DIR"

INSTALLER="${EXTRACT_DIR}/scripts/install.sh"
[[ -x "$INSTALLER" ]] || chmod +x "$INSTALLER"

echo "[bootstrap] Starting interactive installer..."
sudo "$INSTALLER"
echo "[bootstrap] Done."
