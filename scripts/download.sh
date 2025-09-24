#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Configuration
# ==============================================================================
OWNER="${OWNER:-aklozyp}"
BACKEND_REPO="${BACKEND_REPO:-Moddex-Backend}"
FRONTEND_REPO="${FRONTEND_REPO:-Moddex-Frontend}"
VERSION="${VERSION:-latest}"

# ==============================================================================
# Helpers
# ==============================================================================
log() { printf '[INFO] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

usage() {
  cat <<'USAGE'
Usage: download.sh [options]

Downloads the latest Moddex backend and frontend artifacts and runs the installer.

Options:
  --version <tag>       Install a specific release tag (default: latest)
  --backend-repo <repo> Specify the backend repository (default: Moddex-Backend)
  --frontend-repo <repo> Specify the frontend repository (default: Moddex-Frontend)
  -h, --help            Show this help and exit

Environment overrides:
  OWNER, BACKEND_REPO, FRONTEND_REPO, VERSION
USAGE
}

# ==============================================================================
# Argument Parsing
# ==============================================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || die "Missing value for --version"
      VERSION="$2"
      shift 2
      ;;
    --backend-repo)
      [[ $# -ge 2 ]] || die "Missing value for --backend-repo"
      BACKEND_REPO="$2"
      shift 2
      ;;
    --frontend-repo)
      [[ $# -ge 2 ]] || die "Missing value for --frontend-repo"
      FRONTEND_REPO="$2"
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

# ==============================================================================
# Main Logic
# ==============================================================================
require_cmd curl
require_cmd jq
require_cmd unzip

# Prepare temporary directory
DOWNLOAD_DIR="$(mktemp -d -t moddex-download.XXXXXX)"
trap 'rm -rf "$DOWNLOAD_DIR"' EXIT
log "Using temporary download directory: $DOWNLOAD_DIR"

# --- Fetch Asset URLs from GitHub API ---
get_asset_url() {
  local repo="$1" asset_name_pattern="$2" version_tag="$3"
  local api_url
  if [[ "$version_tag" == "latest" ]]; then
    api_url="https://api.github.com/repos/${OWNER}/${repo}/releases/latest"
  else
    api_url="https://api.github.com/repos/${OWNER}/${repo}/releases/tags/${version_tag}"
  fi

  log "Fetching release info from $api_url"
  local response
  response=$(curl -fsSL "$api_url")
  if ! jq -e '.assets' >/dev/null 2>&1 <<< "$response"; then
      die "Failed to fetch release info for ${OWNER}/${repo} at version ${version_tag}. Response: $response"
  fi

  local asset_url
  asset_url=$(jq -r --arg pattern "$asset_name_pattern" '.assets[] | select(.name | test($pattern)) | .browser_download_url' <<< "$response")

  if [[ -z "$asset_url" ]]; then
    die "Could not find asset matching pattern '${asset_name_pattern}' in release ${version_tag} of ${OWNER}/${repo}"
  fi
  echo "$asset_url"
}

# --- Download Artifacts ---
BACKEND_ASSET_URL=$(get_asset_url "$BACKEND_REPO" "Moddex-Backend.*\.jar$" "$VERSION")
FRONTEND_ASSET_URL=$(get_asset_url "$FRONTEND_REPO" "Moddex-Frontend.*\.zip$" "$VERSION")

BACKEND_JAR_PATH="$DOWNLOAD_DIR/Moddex-Backend.jar"
FRONTEND_ZIP_PATH="$DOWNLOAD_DIR/Moddex-Frontend.zip"
FRONTEND_EXTRACT_PATH="$DOWNLOAD_DIR/frontend"

log "Downloading Backend: $BACKEND_ASSET_URL"
curl -L --output "$BACKEND_JAR_PATH" "$BACKEND_ASSET_URL"

log "Downloading Frontend: $FRONTEND_ASSET_URL"
curl -L --output "$FRONTEND_ZIP_PATH" "$FRONTEND_ASSET_URL"

# --- Prepare for Installation ---
log "Extracting frontend artifact"
mkdir -p "$FRONTEND_EXTRACT_PATH"
unzip -q "$FRONTEND_ZIP_PATH" -d "$FRONTEND_EXTRACT_PATH"

# Find the actual frontend build directory inside the unzipped folder
# It often is inside a subfolder like 'dist' or the repo name
if [[ -d "$FRONTEND_EXTRACT_PATH/dist/" ]]; then
    FRONTEND_DIR_FINAL="$FRONTEND_EXTRACT_PATH/dist"
elif [[ -d "$FRONTEND_EXTRACT_PATH/browser/" ]]; then
    FRONTEND_DIR_FINAL="$FRONTEND_EXTRACT_PATH/browser"
elif [[ -f "$FRONTEND_EXTRACT_PATH/index.html" ]]; then
    FRONTEND_DIR_FINAL="$FRONTEND_EXTRACT_PATH"
else
    # If not in a standard folder, find the index.html and use its directory
    INDEX_PATH=$(find "$FRONTEND_EXTRACT_PATH" -name "index.html" -print -quit)
    if [[ -n "$INDEX_PATH" ]]; then
        FRONTEND_DIR_FINAL=$(dirname "$INDEX_PATH")
    else
        die "Could not locate the frontend's index.html in the extracted archive."
    fi
fi

log "Located frontend assets at: $FRONTEND_DIR_FINAL"

# --- Run Installer ---
INSTALLER_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh"
if [[ ! -f "$INSTALLER_SCRIPT" ]]; then
  die "Installer script not found at: $INSTALLER_SCRIPT"
fi

log "Starting installer..."
chmod +x "$INSTALLER_SCRIPT"

# Execute installer with sudo, passing required artifact paths
# The installer itself handles sudo escalation if needed.
exec "$INSTALLER_SCRIPT" --backend-jar "$BACKEND_JAR_PATH" --frontend-dir "$FRONTEND_DIR_FINAL" "$@"