#!/usr/bin/env bash
#
# Assembles the installable Moddex Linux bundle from the three repositories.
#
# Layout produced under build/bundle:
#
#   backend/Moddex-Backend.jar   the packaged Spring Boot application
#   frontend/index.html          the built Angular app, flat at the root
#   scripts/                     installer, updater, CLI
#   packaging/                   systemd unit and friends
#   VERSION                      the version label baked into this bundle
#
# `scripts/install.sh` reads `frontend/index.html` to decide whether the bundle
# carries a usable UI, so the frontend must land flat at that path — not nested
# under Angular's dist/<project>/browser/ (Moddex#61).
#
# Usage:
#   scripts/build-bundle.sh [options]
#
# Options:
#   --backend-jar PATH     Use this prebuilt JAR instead of running the backend build.
#   --frontend-dist PATH   Use this prebuilt browser output instead of running
#                          the frontend build. Must contain index.html.
#   -h, --help             Show this help and exit.
#
# Environment:
#   VERSION                Version label for the artefact (default: dev)
#   MODDEX_BACKEND_JAR     Same as --backend-jar
#   MODDEX_FRONTEND_DIST   Same as --frontend-dist
#
# Passing prebuilt artefacts lets the pipeline reuse what it already built and
# tested instead of compiling the backend and frontend a second time.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PROJECT_ROOT}/.." && pwd)"

BACKEND_DIR="${MODDEX_BACKEND_DIR:-${REPO_ROOT}/Moddex-Backend}"
FRONTEND_DIR="${MODDEX_FRONTEND_DIR:-${REPO_ROOT}/Moddex-Frontend}"

VERSION="${VERSION:-dev}"
BUILD_DIR="${PROJECT_ROOT}/build"
BUNDLE_DIR="${BUILD_DIR}/bundle"
BACKEND_BUILD_DIR="${BUNDLE_DIR}/backend"
FRONTEND_BUILD_DIR="${BUNDLE_DIR}/frontend"

PREBUILT_JAR="${MODDEX_BACKEND_JAR:-}"
PREBUILT_DIST="${MODDEX_FRONTEND_DIST:-}"

log() { printf '[build] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$1" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

usage() { grep '^#' "$0" | sed '1d;s/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend-jar)   [[ $# -ge 2 ]] || die "Missing value for --backend-jar";   PREBUILT_JAR="$2"; shift 2 ;;
    --frontend-dist) [[ $# -ge 2 ]] || die "Missing value for --frontend-dist"; PREBUILT_DIST="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "Unknown argument: $1" ;;
  esac
done

need_cmd tar
need_cmd find
need_cmd cp
need_cmd sha256sum

copy_dir() {
  local src="$1" dest="$2"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "${src}/" "${dest}/"
  else
    mkdir -p "${dest}"
    cp -R "${src}/." "${dest}/"
  fi
}

# Validate and stage prebuilt inputs BEFORE the build directory is wiped. A
# caller may legitimately point at artefacts that live inside build/ — the
# output of a previous run, for instance — and clearing the directory first
# would delete the very inputs this run was asked to package.
STAGING_DIR=""

# An EXIT trap's status becomes the script's status, so this must never end on a
# failed test: with nothing to clean up, a `[[ ... ]] && rm` one-liner would turn
# every successful build into exit 1.
cleanup_staging() {
  if [[ -n "${STAGING_DIR}" && -d "${STAGING_DIR}" ]]; then
    rm -rf "${STAGING_DIR}"
  fi
  return 0
}
trap cleanup_staging EXIT

# Fully canonicalised path, symlinks included. Resolving only the parent would
# leave a symlink whose target sits inside build/ looking like an outside path,
# and the wipe below would delete it.
abs_path() {
  if readlink -f / >/dev/null 2>&1; then
    readlink -f "$1"
  else
    (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$1")")
  fi
}

is_inside_build_dir() {
  local resolved build_resolved
  resolved="$1"
  build_resolved="$(cd "$(dirname "${BUILD_DIR}")" && printf '%s/%s' "$(pwd -P)" "$(basename "${BUILD_DIR}")")"
  [[ "$resolved" == "$build_resolved" || "$resolved" == "$build_resolved"/* ]]
}

if [[ -n "${PREBUILT_JAR}" ]]; then
  [[ -f "${PREBUILT_JAR}" ]] || die "Prebuilt backend JAR not found: ${PREBUILT_JAR}"
  PREBUILT_JAR="$(abs_path "${PREBUILT_JAR}")"
fi
if [[ -n "${PREBUILT_DIST}" ]]; then
  [[ -d "${PREBUILT_DIST}" ]] || die "Prebuilt frontend directory not found: ${PREBUILT_DIST}"
  [[ -f "${PREBUILT_DIST}/index.html" ]] || \
    die "Prebuilt frontend directory has no index.html: ${PREBUILT_DIST}"
  PREBUILT_DIST="$(abs_path "${PREBUILT_DIST}")"
fi

# Move anything that would be destroyed out of harm's way first.
if [[ -n "${PREBUILT_JAR}" ]] && is_inside_build_dir "${PREBUILT_JAR}"; then
  STAGING_DIR="${STAGING_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/moddex-bundle.XXXXXX")}"
  log "Staging prebuilt JAR out of the build directory"
  cp "${PREBUILT_JAR}" "${STAGING_DIR}/Moddex-Backend.jar"
  PREBUILT_JAR="${STAGING_DIR}/Moddex-Backend.jar"
fi
if [[ -n "${PREBUILT_DIST}" ]] && is_inside_build_dir "${PREBUILT_DIST}"; then
  STAGING_DIR="${STAGING_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/moddex-bundle.XXXXXX")}"
  log "Staging prebuilt frontend out of the build directory"
  mkdir -p "${STAGING_DIR}/frontend"
  cp -R "${PREBUILT_DIST}/." "${STAGING_DIR}/frontend/"
  PREBUILT_DIST="${STAGING_DIR}/frontend"
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BACKEND_BUILD_DIR}" "${FRONTEND_BUILD_DIR}"

# -----------------------------------------------------------------------------
# Backend JAR
# -----------------------------------------------------------------------------
if [[ -n "${PREBUILT_JAR}" ]]; then
  # Validated (and staged if needed) before the build directory was cleared.
  log "Using prebuilt backend JAR: ${PREBUILT_JAR}"
  BACKEND_JAR="${PREBUILT_JAR}"
else
  [[ -f "${BACKEND_DIR}/pom.xml" ]] || die "Backend project not found at ${BACKEND_DIR}"
  need_cmd java

  log "Building backend artifact"
  chmod +x "${BACKEND_DIR}/mvnw"
  "${BACKEND_DIR}/mvnw" -f "${BACKEND_DIR}/pom.xml" -B -Pprod -DskipTests clean package

  # Exclude the sources/javadoc side artefacts; only the executable JAR ships.
  BACKEND_JAR="$(find "${BACKEND_DIR}/target" -maxdepth 1 -name 'Moddex-Backend-*.jar' \
    ! -name '*-sources.jar' ! -name '*-javadoc.jar' | head -n1)"
  [[ -n "${BACKEND_JAR}" ]] || die "Backend JAR not found in ${BACKEND_DIR}/target"
fi

cp "${BACKEND_JAR}" "${BACKEND_BUILD_DIR}/Moddex-Backend.jar"

# -----------------------------------------------------------------------------
# Frontend assets
#
# `@angular/build:application` emits to dist/<project>/browser/ by default. The
# project name is an Angular-side detail the packaging repo must not hardcode,
# and copying dist/ wholesale nests the app one or two levels too deep — which
# the installer then silently treats as "no frontend given" (Moddex#61).
# The browser output is therefore located by the artefact that defines it:
# the directory containing index.html.
# -----------------------------------------------------------------------------
resolve_browser_dir() {
  local dist="$1" found
  [[ -d "$dist" ]] || return 1

  # Shallowest index.html wins. `server/` holds the SSR build, which is not
  # what gets served as static assets. Depth is computed from the path itself
  # rather than via `find -printf`, which is GNU-only.
  found="$(find "$dist" -maxdepth 4 -name index.html -type f \
    -not -path '*/node_modules/*' -not -path '*/server/*' \
    | awk '{ n = gsub("/", "/"); print n, $0 }' | sort -n -k1,1 | head -n1 | cut -d' ' -f2-)"

  [[ -n "$found" ]] || return 1
  dirname "$found"
}

if [[ -n "${PREBUILT_DIST}" ]]; then
  # Existence and index.html were validated (and the directory staged if needed)
  # before the build directory was cleared.
  log "Using prebuilt frontend assets: ${PREBUILT_DIST}"
  BROWSER_DIR="${PREBUILT_DIST}"
else
  [[ -f "${FRONTEND_DIR}/package.json" ]] || die "Frontend project not found at ${FRONTEND_DIR}"
  need_cmd npm

  log "Building frontend assets"
  pushd "${FRONTEND_DIR}" >/dev/null
  if [[ -f package-lock.json ]]; then
    npm ci
  else
    npm install
  fi
  npm run build -- --configuration production
  popd >/dev/null

  FRONTEND_DIST="${FRONTEND_DIR}/dist"
  [[ -d "${FRONTEND_DIST}" ]] || die "Frontend dist directory not found at ${FRONTEND_DIST}"

  BROWSER_DIR="$(resolve_browser_dir "${FRONTEND_DIST}")" || \
    die "No index.html found under ${FRONTEND_DIST}. The frontend build produced no browser output."
fi

log "Frontend browser output: ${BROWSER_DIR}"
copy_dir "${BROWSER_DIR}" "${FRONTEND_BUILD_DIR}"

# The installer keys off exactly this path. Shipping a bundle without it means
# installing a product with no user interface, so fail here rather than there.
[[ -f "${FRONTEND_BUILD_DIR}/index.html" ]] || \
  die "Bundle assembly failed: frontend/index.html is missing from the bundle."

# -----------------------------------------------------------------------------
# Scripts and packaging resources
# -----------------------------------------------------------------------------
log "Copying installer resources"
copy_dir "${PROJECT_ROOT}/scripts" "${BUNDLE_DIR}/scripts"
copy_dir "${PROJECT_ROOT}/packaging" "${BUNDLE_DIR}/packaging"

if [[ -d "${PROJECT_ROOT}/config/defaults" ]]; then
  copy_dir "${PROJECT_ROOT}/config/defaults" "${BUNDLE_DIR}/config/defaults"
fi

printf '%s\n' "${VERSION}" > "${BUNDLE_DIR}/VERSION"

# -----------------------------------------------------------------------------
# Normalise permissions
#
# The bundle is extracted as root and its scripts are executed straight from the
# extracted tree. Modes must not depend on the umask of whoever ran this build,
# and an installer that lost its executable bit fails on the operator's machine
# rather than here.
# -----------------------------------------------------------------------------
log "Normalising file modes"
find "${BUNDLE_DIR}" -type d -exec chmod 0755 {} +
find "${BUNDLE_DIR}" -type f -exec chmod 0644 {} +

# Everything meant to be executed: shell scripts by extension, PowerShell
# scripts, and the extension-less CLI entry point.
while IFS= read -r -d '' file; do
  chmod 0755 "$file"
done < <(
  find "${BUNDLE_DIR}/scripts" -type f \
    \( -name '*.sh' -o -name '*.ps1' -o -name 'moddex' \) -print0
)

# Anything else carrying a shell shebang is executable too.
while IFS= read -r -d '' file; do
  if head -n1 "$file" 2>/dev/null | grep -qE '^#!.*\b(ba)?sh\b'; then
    chmod 0755 "$file"
  fi
done < <(find "${BUNDLE_DIR}/scripts" -type f -print0)

# -----------------------------------------------------------------------------
# Archive
# -----------------------------------------------------------------------------
ARTIFACT_NAME="moddex-${VERSION}-linux-amd64.tar.gz"
log "Creating archive ${ARTIFACT_NAME}"

# Reproducible archive: stable member order, no build-host ownership, and a
# fixed mtime so two builds of the same tree produce the same checksum. Falls
# back to a plain tar when the GNU-specific options are unavailable.
if tar --sort=name --owner=0 --group=0 --numeric-owner \
       --mtime='UTC 2020-01-01' -C "${BUNDLE_DIR}" -czf "${BUILD_DIR}/${ARTIFACT_NAME}" . 2>/dev/null; then
  log "Archive is reproducible (normalised order, ownership and timestamps)"
else
  log "Falling back to a non-reproducible archive (GNU tar options unavailable)"
  tar -C "${BUNDLE_DIR}" -czf "${BUILD_DIR}/${ARTIFACT_NAME}" .
fi

(
  cd "${BUILD_DIR}"
  sha256sum "${ARTIFACT_NAME}" > "${ARTIFACT_NAME}.sha256"
)

log "Bundle created at ${BUILD_DIR}/${ARTIFACT_NAME}"
log "SHA-256: $(cut -d' ' -f1 < "${BUILD_DIR}/${ARTIFACT_NAME}.sha256")"
