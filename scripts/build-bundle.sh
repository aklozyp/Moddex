#!/usr/bin/env bash
# Baut das Linux-Bundle (Backend-JAR + Frontend + Installer-Skripte) im Monorepo.
# Aufruf aus beliebigem Verzeichnis, z. B.:  VERSION=v0.1.3 scripts/build-bundle.sh
# Ergebnis: build/moddex-<VERSION>-linux-amd64.tar.gz (+ .sha256), Inhalt unter build/bundle/
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Monorepo: scripts/ liegt direkt unter der Repo-Wurzel; backend/ und frontend/ daneben.
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BACKEND_DIR="${PROJECT_ROOT}/backend"
FRONTEND_DIR="${PROJECT_ROOT}/frontend"

VERSION="${VERSION:-dev}"
BUILD_DIR="${PROJECT_ROOT}/build"
BUNDLE_DIR="${BUILD_DIR}/bundle"
BACKEND_BUILD_DIR="${BUNDLE_DIR}/backend"
FRONTEND_BUILD_DIR="${BUNDLE_DIR}/frontend"

log() { printf '[build] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$1" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

[[ "${VERSION}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Ungültige VERSION '${VERSION}' (erlaubt: Buchstaben, Ziffern, . _ -)"

need_cmd tar
need_cmd mkdir
need_cmd rm
need_cmd find
need_cmd cp
need_cmd java
need_cmd node
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
# mvnw ist im Repo nicht ausführbar markiert -> über sh starten (kein chmod, kein Git-Diff)
(cd "${BACKEND_DIR}" && sh ./mvnw -B -ntp -Pprod -DskipTests clean package)

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
rm -rf dist   # keine Altlasten, damit die Ausgabe eindeutig gefunden wird
if [[ -f package-lock.json ]]; then
  npm ci
else
  npm install
fi
npm run build -- --configuration production
popd >/dev/null

# Angular (application builder) schreibt nach dist/<projekt>/browser. Der Installer
# erwartet index.html direkt im Frontend-Verzeichnis des Bundles -> nur "browser" übernehmen.
FRONTEND_DIST="$(find "${FRONTEND_DIR}/dist" -mindepth 2 -maxdepth 2 -type d -name browser | head -n1)"
[[ -n "${FRONTEND_DIST}" ]] || die "Angular-Ausgabe dist/<projekt>/browser nicht gefunden in ${FRONTEND_DIR}/dist"
[[ -f "${FRONTEND_DIST}/index.html" ]] || die "index.html fehlt in ${FRONTEND_DIST}"
copy_dir "${FRONTEND_DIST}" "${FRONTEND_BUILD_DIR}"
# Lizenzhinweise der Frontend-Abhängigkeiten liegen eine Ebene über "browser"
if [[ -f "$(dirname "${FRONTEND_DIST}")/3rdpartylicenses.txt" ]]; then
  cp "$(dirname "${FRONTEND_DIST}")/3rdpartylicenses.txt" "${BUNDLE_DIR}/3rdpartylicenses-frontend.txt"
fi

# -----------------------------------------------------------------------------
# Copy scripts and packaging resources
# -----------------------------------------------------------------------------
log "Copying installer resources"
copy_dir "${PROJECT_ROOT}/scripts" "${BUNDLE_DIR}/scripts"
copy_dir "${PROJECT_ROOT}/packaging" "${BUNDLE_DIR}/packaging"
mkdir -p "${BACKEND_BUILD_DIR}/bin"
cp "${BACKEND_DIR}/bin/moddex" "${BACKEND_BUILD_DIR}/bin/moddex"

if [[ -d "${PROJECT_ROOT}/config/defaults" ]]; then
  copy_dir "${PROJECT_ROOT}/config/defaults" "${BUNDLE_DIR}/config/defaults"
fi

printf '%s\n' "${VERSION}" > "${BUNDLE_DIR}/VERSION"

# -----------------------------------------------------------------------------
# Struktur des Bundles prüfen (fängt z. B. eine falsche Angular-Ausgabeebene ab)
# -----------------------------------------------------------------------------
for required in \
  backend/Moddex-Backend.jar \
  backend/bin/moddex \
  frontend/index.html \
  scripts/install.sh \
  packaging/systemd/moddex-backend.service \
  VERSION; do
  [[ -f "${BUNDLE_DIR}/${required}" ]] || die "Bundle unvollständig: ${required} fehlt"
done

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
