#!/usr/bin/env bash
set -Eeuo pipefail

OWNER="${OWNER:-aklozyp}"
REPO="${REPO:-Moddex}"
VERSION="${VERSION:-latest}"
ASSET_SUFFIX="${ASSET_SUFFIX:-linux-amd64.tar.gz}"

log() { printf '[download] %s\n' "$1"; }
die() { printf '[ERROR] %s\n' "$1" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

need_cmd curl
need_cmd jq
need_cmd tar
need_cmd sha256sum

usage() {
  cat <<'USAGE'
Usage: download.sh [options]

Fetches the packaged Moddex bundle from GitHub Releases and runs the installer.

Options:
  --version <tag>   Release tag to download (default: latest)
  --owner <owner>   GitHub owner or organization (default: aklozyp)
  --repo <repo>     GitHub repository name (default: Moddex)
  -h, --help        Show this help and exit

Environment overrides:
  OWNER, REPO, VERSION, ASSET_SUFFIX
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || die "Missing value for --version"
      VERSION="$2"
      shift 2
      ;;
    --owner)
      [[ $# -ge 2 ]] || die "Missing value for --owner"
      OWNER="$2"
      shift 2
      ;;
    --repo)
      [[ $# -ge 2 ]] || die "Missing value for --repo"
      REPO="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

api_url="https://api.github.com/repos/${OWNER}/${REPO}/releases"
if [[ "$VERSION" == "latest" ]]; then
  api_url+="/latest"
else
  api_url+="/tags/${VERSION}"
fi

log "Fetching release metadata from ${api_url}"
release_json=$(curl -fsSL "$api_url") || die "Failed to fetch release metadata"
tag_name=$(jq -r '.tag_name // ""' <<< "$release_json")
[[ -n "$tag_name" ]] || die "Release not found"

asset_name=$(jq -r --arg suffix "$ASSET_SUFFIX" '.assets[] | select(.name | endswith($suffix)) | .name' <<< "$release_json")
asset_url=$(jq -r --arg suffix "$ASSET_SUFFIX" '.assets[] | select(.name | endswith($suffix)) | .browser_download_url' <<< "$release_json")
[[ -n "$asset_url" ]] || die "No asset ending with $ASSET_SUFFIX found in release $tag_name"

sha_asset_url=$(jq -r --arg name "$asset_name.sha256" '.assets[] | select(.name == $name) | .browser_download_url' <<< "$release_json")

temp_dir=$(mktemp -d -t moddex-bundle.XXXXXX)
trap 'rm -rf "$temp_dir"' EXIT
log "Using temporary directory $temp_dir"

bundle_path="$temp_dir/$asset_name"
log "Downloading bundle $asset_name"
curl -fsSL "$asset_url" -o "$bundle_path"

if [[ -n "$sha_asset_url" && "$sha_asset_url" != "null" ]]; then
  log "Downloading checksum"
  curl -fsSL "$sha_asset_url" -o "$bundle_path.sha256"
  (cd "$temp_dir" && sha256sum -c "$(basename "$bundle_path").sha256")
else
  log "Checksum asset missing; computing locally"
  (cd "$temp_dir" && sha256sum "$(basename "$bundle_path")" > "$(basename "$bundle_path").sha256")
fi

extract_dir="$temp_dir/bundle"
mkdir -p "$extract_dir"
tar -C "$extract_dir" -xzf "$bundle_path"

backend_jar="$extract_dir/backend/Moddex-Backend.jar"
frontend_dir="$extract_dir/frontend"

[[ -f "$backend_jar" ]] || die "Backend JAR not found in bundle"
[[ -d "$frontend_dir" ]] || die "Frontend directory missing in bundle"

installer="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh"
[[ -f "$installer" ]] || die "Installer script not found at $installer"
chmod +x "$installer"

log "Running installer"
exec "$installer" --backend-jar "$backend_jar" --frontend-dir "$frontend_dir" "$@"
