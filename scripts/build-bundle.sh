#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PROJECT_ROOT}/.." && pwd)"

BACKEND_DIR="${REPO_ROOT}/Moddex-Backend"
FRONTEND_DIR="${REPO_ROOT}/Moddex-Frontend"

VERSION="${VERSION:-dev}"
BUILD_DIR="${PROJECT_ROOT}/build"
BUNDLE_DIR="${BUILD_DIR}/bundle"
BACKEND_BUILD_DIR="${BUNDLE_DIR}/backend"
FRONTEND_BUILD_DIR="${BUNDLE_DIR}/frontend"

log() { printf '[build] %s
' "$*"; }
die() { printf '[ERROR] %s
' "$1" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

need_cmd tar
need_cmd mkdir
need_cmd rm
need_cmd find
need_cmd cp
need_cmd npm
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

rm -rf "${BUILD_DIR}"
mkdir -p "${BACKEND_BUILD_DIR}" "${FRONTEND_BUILD_DIR}"

# -----------------------------------------------------------------------------
# Build backend JAR
# -----------------------------------------------------------------------------
if [[ ! -f "${BACKEND_DIR}/pom.xml" ]]; then
  die "Backend project not found at ${BACKEND_DIR}"
fi

log "Building backend artifact"
chmod +x "${BACKEND_DIR}/mvnw"
"${BACKEND_DIR}/mvnw" -f "${BACKEND_DIR}/pom.xml" -B -Pprod -DskipTests clean package

BACKEND_JAR="$(find "${BACKEND_DIR}/target" -maxdepth 1 -name 'Moddex-Backend-*.jar' | head -n1)"
[[ -n "${BACKEND_JAR}" ]] || die "Backend JAR not found in ${BACKEND_DIR}/target"
cp "${BACKEND_JAR}" "${BACKEND_BUILD_DIR}/Moddex-Backend.jar"

# -----------------------------------------------------------------------------
# Build frontend assets
# -----------------------------------------------------------------------------
if [[ ! -f "${FRONTEND_DIR}/package.json" ]]; then
  die "Frontend project not found at ${FRONTEND_DIR}"
fi

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
copy_dir "${FRONTEND_DIST}" "${FRONTEND_BUILD_DIR}"

# -----------------------------------------------------------------------------
# Copy scripts and packaging resources
# -----------------------------------------------------------------------------
log "Copying installer resources"
copy_dir "${PROJECT_ROOT}/scripts" "${BUNDLE_DIR}/scripts"
copy_dir "${PROJECT_ROOT}/packaging" "${BUNDLE_DIR}/packaging"

if [[ -d "${PROJECT_ROOT}/config/defaults" ]]; then
  copy_dir "${PROJECT_ROOT}/config/defaults" "${BUNDLE_DIR}/config/defaults"
fi

printf '%s
' "${VERSION}" > "${BUNDLE_DIR}/VERSION"

# -----------------------------------------------------------------------------
# Archive bundle
# -----------------------------------------------------------------------------
ARTIFACT_NAME="moddex-${VERSION}-linux-amd64.tar.gz"
log "Creating archive ${ARTIFACT_NAME}"

tar -C "${BUNDLE_DIR}" -czf "${BUILD_DIR}/${ARTIFACT_NAME}" .
(
  cd "${BUILD_DIR}"
  sha256sum "${ARTIFACT_NAME}" > "${ARTIFACT_NAME}.sha256"
)

log "Bundle created at ${BUILD_DIR}/${ARTIFACT_NAME}"
