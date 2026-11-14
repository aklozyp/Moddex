#!/usr/bin/env bash
set -Eeuo pipefail

OWNER="${OWNER:-aklozyp}"
REPO="${REPO:-Moddex}"
VERSION="${VERSION:-latest}"
ASSET_SUFFIX="${ASSET_SUFFIX:-linux-amd64.tar.gz}"

log() { printf '[download] %s\n' "$1"; }
die() { printf '[ERROR] %s\n' "$1" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# True when the name has ".." as an actual path component. Every component is
# checked on its own, so names that merely contain ".." as a substring of a
# component (for example "a..b" or "..hidden") are not flagged.
entry_has_parent_component() {
  local entry="$1"
  [[ "$entry" == ".." || "$entry" == ../* || "$entry" == */../* || "$entry" == */.. ]]
}

# Lexically resolves an already relative, parent-free entry against the
# extraction root and aborts if any step would leave the bundle root. Merely
# stripping ".." sequences is not a safe containment check, so parent
# components are resolved properly and crossing the root is refused. Prints the
# normalized root-relative name.
resolve_entry_within_root() {
  local entry="$1" part resolved=""
  while [[ -n "$entry" ]]; do
    part="${entry%%/*}"
    case "$entry" in
      */*) entry="${entry#*/}" ;;
      *) entry="" ;;
    esac
    case "$part" in
      "" | ".") ;;
      "..")
        if [[ -z "$resolved" ]]; then
          die "Bundle archive validation failed: an archive entry would resolve outside the bundle directory. Download a complete matching release bundle again and retry; nothing was unpacked."
        fi
        resolved="${resolved%/*}"
        ;;
      *) resolved+="/$part" ;;
    esac
  done
  printf '%s' "${resolved#/}"
}

# Link targets are only interpreted from the tail of verbose listing lines
# (" -> " for symlinks, " link to " for hard links); the entry-name part of
# those lines is tar-format specific. GNU tar prints both target forms;
# bsdtar 3.5.3 does as well, but this marker output is not standardized, so a
# tar that omits link targets in its listing makes this gate ineffective for
# those entries. A target is rejected when it is empty, absolute or contains
# a parent component, regardless of where the link itself is placed, so a
# link can never resolve outside the extraction directory.
require_safe_link_target() {
  local target="$1"
  if [[ -z "$target" || "$target" == /* ]] || entry_has_parent_component "$target"; then
    die "Bundle archive validation failed: an archive link entry points outside the bundle directory. Download a complete matching release bundle again and retry; nothing was unpacked."
  fi
}

# Validates the downloaded archive's contents BEFORE anything is unpacked. The
# published checksum proves integrity, not that the archive is a safe
# installation bundle. Archive-controlled names are never echoed into output;
# violations are reported by category with a safe next action.
validate_bundle_archive() {
  local archive="$1" listing verbose_listing entry line required
  local bundle_entries=""

  if ! listing="$(tar -tzf "$archive" 2>/dev/null)"; then
    die "Bundle archive validation failed: the archive contents cannot be listed. Download a complete matching release bundle again and retry; nothing was unpacked."
  fi
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if [[ "$entry" == /* ]]; then
      die "Bundle archive validation failed: an archive entry uses an absolute path. Download a complete matching release bundle again and retry; nothing was unpacked."
    fi
    if entry_has_parent_component "$entry"; then
      die "Bundle archive validation failed: an archive entry contains a parent-directory path component. Download a complete matching release bundle again and retry; nothing was unpacked."
    fi
    # Names with embedded newlines cannot be listed reliably; a listed line
    # that does not correspond to a stored component boundary can only make
    # this validation stricter, never weaker (safe direction).
    bundle_entries+="$(resolve_entry_within_root "$entry")"$'\n'
  done <<< "$listing"

  # The archive must carry the core installation-bundle entries before it is
  # unpacked; the deeper per-file checks follow after extraction.
  for required in \
    VERSION \
    backend/Moddex-Backend.jar \
    frontend/index.html \
    scripts/install.sh \
    packaging/systemd/moddex-backend.service; do
    if ! grep -Fxq -- "$required" <<< "$bundle_entries"; then
      die "Bundle archive validation failed: the archive is not a complete Moddex installation bundle (required entry $required is missing). Download a complete release bundle and retry; nothing was unpacked."
    fi
  done

  if ! verbose_listing="$(tar -tvzf "$archive" 2>/dev/null)"; then
    die "Bundle archive validation failed: the archive contents cannot be listed. Download a complete matching release bundle again and retry; nothing was unpacked."
  fi
  while IFS= read -r line; do
    case "$line" in
      *" -> "*)
        # The marker can also appear inside archive-controlled names, so both
        # split candidates are checked; a false positive only tightens the
        # gate while a missed ".." in the real target would loosen it.
        require_safe_link_target "${line#* -> }"
        require_safe_link_target "${line##* -> }"
        ;;
      *" link to "*)
        require_safe_link_target "${line#* link to }"
        require_safe_link_target "${line##* link to }"
        ;;
    esac
  done <<< "$verbose_listing"
}

usage() {
  cat <<'USAGE'
Usage: download.sh [options]

Fetches the packaged Moddex bundle from GitHub Releases and runs the installer.

Options:
  --version <tag>   Release tag to download (default: latest)
  --owner <owner>   GitHub owner or organization (default: aklozyp)
  --repo <repo>     GitHub repository name (default: Moddex)
  --stage-only <dir>
                    Download the release, verify the published checksum, and
                    extract it into <dir>/bundle without installing anything.
                    The caller owns <dir> and its cleanup.
  --install-staged <dir>
                    Run the bundled installer from a bundle previously staged
                    with --stage-only, without any network access.
  -h, --help        Show this help and exit

Environment overrides:
  OWNER, REPO, VERSION, ASSET_SUFFIX
USAGE
}

STAGE_MODE=""
STAGE_DIR=""

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
    --stage-only)
      [[ $# -ge 2 ]] || die "Missing value for --stage-only. Provide an existing staging directory, then retry."
      [[ -z "$STAGE_MODE" ]] || die "Use either --stage-only or --install-staged, not both. Choose one mode, then retry."
      STAGE_MODE="stage"
      STAGE_DIR="$2"
      shift 2
      ;;
    --install-staged)
      [[ $# -ge 2 ]] || die "Missing value for --install-staged. Provide the directory used with --stage-only, then retry."
      [[ -z "$STAGE_MODE" ]] || die "Use either --stage-only or --install-staged, not both. Choose one mode, then retry."
      STAGE_MODE="install-staged"
      STAGE_DIR="$2"
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

# Verify the completeness of an extracted release bundle against the expected
# tag. The recovery hints describe how to obtain a complete bundle again and
# differ between the download flow and the staged flow.
verify_bundle_contents() {
  local extract_dir="$1" bundle_tag="$2" recovery="$3" recovery_mismatch="$4"
  local backend_jar="$extract_dir/backend/Moddex-Backend.jar"
  local frontend_dir="$extract_dir/frontend"
  local installer="$extract_dir/scripts/install.sh"
  local systemd_unit="$extract_dir/packaging/systemd/moddex-backend.service"
  local bundle_version

  [[ -f "$backend_jar" ]] || die "Backend JAR not found in bundle"
  [[ -d "$frontend_dir" ]] || die "Frontend directory missing in bundle"
  [[ -f "$extract_dir/VERSION" ]] || die "VERSION missing in release bundle. $recovery"
  if ! bundle_version=$(cat "$extract_dir/VERSION" 2>/dev/null); then
    die "Cannot read bundle VERSION. $recovery"
  fi
  [[ "$bundle_version" == "$bundle_tag" ]] ||
    die "Bundle VERSION does not match the resolved release tag. $recovery_mismatch"

  [[ -f "$installer" ]] || die "Installer script missing in release bundle (scripts/install.sh). $recovery"
  [[ -f "$systemd_unit" ]] || die "Systemd unit missing in release bundle (packaging/systemd/moddex-backend.service). $recovery"
  # A verified (staged) bundle carries an executable installer, so the
  # installation phase can run it without further preparation.
  chmod +x "$installer"
}

run_bundled_installer() {
  local extract_dir="$1" bundle_tag="$2"
  shift 2
  local installer="$extract_dir/scripts/install.sh"

  log "Running bundled installer"
  # Keep the bundle available until the installer exits; the EXIT trap of this
  # script or the calling updater removes the staging directory afterwards.
  "$installer" --backend-jar "$extract_dir/backend/Moddex-Backend.jar" \
    --frontend-dir "$extract_dir/frontend" "$@" --version "$bundle_tag"
}

install_from_stage() {
  local staged_root="$1/bundle" staged_version
  shift

  [[ -f "$staged_root/VERSION" ]] ||
    die "Staged bundle is missing VERSION. Stage the release again with --stage-only; nothing was installed."
  if ! staged_version=$(cat "$staged_root/VERSION" 2>/dev/null); then
    die "Cannot read the staged bundle VERSION. Stage the release again with --stage-only; nothing was installed."
  fi
  if [[ "$VERSION" != "latest" ]]; then
    [[ "$staged_version" == "$VERSION" ]] ||
      die "Staged bundle VERSION does not match the requested release $VERSION. Stage the requested release again with --stage-only; nothing was installed."
    tag_name="$VERSION"
  else
    tag_name="$staged_version"
  fi
  [[ "$tag_name" =~ ^[A-Za-z0-9._-]+$ && "$tag_name" != latest ]] ||
    die "Staged bundle VERSION is not a concrete release tag. Stage a complete release again with --stage-only; nothing was installed."

  verify_bundle_contents "$staged_root" "$tag_name" \
    "Stage the complete release again with --stage-only; nothing was installed." \
    "Stage the requested release again with --stage-only; nothing was installed."
  run_bundled_installer "$staged_root" "$tag_name" "$@"
}

if [[ -n "$STAGE_MODE" ]]; then
  [[ -d "$STAGE_DIR" ]] ||
    die "Staging directory '$STAGE_DIR' does not exist or is not a directory. Create it (for example with 'mktemp -d'), then retry."
  STAGE_DIR="$(cd "$STAGE_DIR" && pwd -P)" ||
    die "Cannot access the staging directory '$STAGE_DIR'. Fix its permissions, then retry."
fi

if [[ "$STAGE_MODE" == "install-staged" ]]; then
  # No network access in this mode: the release was already downloaded,
  # checksum-verified and extracted by a prior --stage-only run.
  install_from_stage "$STAGE_DIR" "$@"
  exit 0
fi

need_cmd curl
need_cmd jq
need_cmd tar
need_cmd grep
need_cmd sha256sum

api_url="https://api.github.com/repos/${OWNER}/${REPO}/releases"
if [[ "$VERSION" == "latest" ]]; then
  api_url+="/latest"
else
  api_url+="/tags/${VERSION}"
fi

log "Fetching release metadata from ${api_url}"
release_json=$(curl -fsSL "$api_url" 2>/dev/null) ||
  die "Failed to fetch release metadata. Check network connectivity and the selected release, then retry."
if ! tag_name=$(jq -ers 'select(length == 1) | .[0].tag_name | strings | select(test("\\A[A-Za-z0-9._-]+\\z") and . != "latest")' <<< "$release_json" 2>/dev/null); then
  die "Release metadata is missing a valid concrete tag_name. Retry with --version <release-tag> or a complete published release."
fi

if ! asset_name=$(jq -er --arg suffix "$ASSET_SUFFIX" '
  .assets | arrays | map(select(.name? | strings | endswith($suffix))) |
  select(length == 1) | .[0].name |
  select(test("\\A[A-Za-z0-9][A-Za-z0-9._-]*\\z"))
' <<< "$release_json" 2>/dev/null); then
  die "Release metadata must identify exactly one bundle asset with a valid filename. Select a complete published release and retry."
fi
if ! asset_url=$(jq -er --arg name "$asset_name" '
  .assets[] | select(.name == $name) | .browser_download_url | strings |
  select(test("\\Ahttps://[^[:space:]]+\\z"))
' <<< "$release_json" 2>/dev/null); then
  die "Release bundle download URL is missing or invalid. Select a complete published release and retry."
fi

if ! sha_asset_url=$(jq -er --arg name "$asset_name.sha256" '
  .assets | map(select(.name == $name)) | select(length == 1) |
  .[0].browser_download_url | strings | select(test("\\Ahttps://[^[:space:]]+\\z"))
' <<< "$release_json" 2>/dev/null); then
  die "Required release checksum asset (.sha256) is missing, ambiguous or has an invalid download URL. Select a complete published release and retry; installation was not started."
fi

if [[ "$STAGE_MODE" == "stage" ]]; then
  # The caller owns the staging directory and its cleanup; nothing is removed here.
  temp_dir="$STAGE_DIR"
  log "Staging verified release into $temp_dir"
else
  temp_dir=$(mktemp -d -t moddex-bundle.XXXXXX)
  trap 'rm -rf "$temp_dir"' EXIT
  log "Using temporary directory $temp_dir"
fi

bundle_path="$temp_dir/$asset_name"
log "Downloading bundle $asset_name"
curl -fsSL "$asset_url" -o "$bundle_path" 2>/dev/null ||
  die "Failed to download the release bundle. Check network connectivity and retry; installation was not started."

log "Downloading release checksum"
curl -fsSL "$sha_asset_url" -o "$bundle_path.sha256" 2>/dev/null ||
  die "Failed to download the required release checksum. Check network connectivity and retry; installation was not started."
# The per-bundle asset must contain one sha256sum record for this exact archive,
# not a valid checksum for some other file.
if ! jq -Rers --arg name "$asset_name" '
  capture("\\A[0-9A-Fa-f]{64} [ *](?<filename>[^\\r\\n]+)\\n?\\z") |
  .filename == $name
' "$bundle_path.sha256" >/dev/null 2>&1; then
  die "Invalid release checksum: expected one SHA-256 record for the selected bundle. Select a complete published release and retry; installation was not started."
fi
if ! (cd "$temp_dir" && sha256sum -c "$asset_name.sha256" >/dev/null 2>&1); then
  die "Release bundle checksum verification failed. Do not run this archive; download a complete matching release again or contact the release maintainer. Installation was not started."
fi
log "Release bundle checksum verified"

# The extraction target is only created after the archive contents passed
# validation, so a rejected bundle never produces a partially unpacked tree.
validate_bundle_archive "$bundle_path"
log "Bundle archive contents validated"

extract_dir="$temp_dir/bundle"
mkdir -p "$extract_dir"
# --no-same-owner keeps the archive from assigning arbitrary ownership (it is
# supported by GNU tar and bsdtar, the tar implementations this downloader
# targets). Absolute-name and ".." members were already rejected above.
tar --no-same-owner -C "$extract_dir" -xzf "$bundle_path"

if [[ "$STAGE_MODE" == "stage" ]]; then
  verify_bundle_contents "$extract_dir" "$tag_name" \
    "Stage the complete release again with --stage-only; nothing was installed." \
    "Stage the requested release again with --stage-only; nothing was installed."
  log "Release staged and verified; installation is up to the caller"
  exit 0
fi

verify_bundle_contents "$extract_dir" "$tag_name" \
  "Download a complete release bundle and retry." \
  "Download a matching release bundle and retry."
run_bundled_installer "$extract_dir" "$tag_name" "$@"
