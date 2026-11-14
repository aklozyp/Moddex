#!/usr/bin/env bash
set -Eeuo pipefail

on_error() {
  local exit_code="$1" line="$2"
  if [[ "$exit_code" -ne 0 ]]; then
    printf '[ERROR] Installation aborted (exit %s at line %s)\n' "$exit_code" "$line" >&2
  fi
}
trap 'on_error $? $LINENO' ERR

umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYSTEMD_DIR="$PROJECT_ROOT/packaging/systemd"

MODE="${MODE:-${MODDEX_MODE:-}}"
BACKEND_JAR="${BACKEND_JAR:-${MODDEX_BACKEND_JAR:-}}"
FRONTEND_DIR="${FRONTEND_DIR:-${MODDEX_FRONTEND_DIR:-}}"
SERVER_PORT="${PORT-${MODDEX_PORT-8080}}"
TLS_CERT_FILE="${MODDEX_TLS_CERT_FILE:-}"
TLS_KEY_FILE="${MODDEX_TLS_KEY_FILE:-}"
TLS_KEYSTORE="${MODDEX_TLS_KEYSTORE:-}"
TLS_DISABLE=0
PORT_EXPLICIT=0
MODDEX_ENV_FILE=/etc/moddex/moddex.env
# Host lock against parallel installations and updates (issue #108). The
# default lives in a root-writable runtime directory; MODDEX_LOCK_FILE
# relocates it for isolated test fixtures. Like the other installer
# environment overrides, it is trusted: only root or a sudo-capable
# administrator reaches the code that uses it.
MODDEX_LOCK_FILE="${MODDEX_LOCK_FILE:-/run/moddex/install.lock}"
INSTALL_LOCK_ACQUIRED=0
INSTALL_VERSION=""
INSTALL_COMMAND=("$0" "$@")

log() { printf '[moddex-install] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

require_readable_file() {
  local label="$1" path="$2"
  [[ -n "$path" ]] || die "Native TLS: $label requires a file path. Set the path, then rerun the installer."
  [[ -f "$path" ]] || die "Native TLS: $label points to '$path', which is not a file. Set the correct path, then rerun the installer."
  [[ -r "$path" ]] || die "Native TLS: $label points to '$path', which is not readable. Fix the file permissions for the service account, then rerun the installer."
}

# Rejects backend JAR paths that are missing, empty, or unreadable before
# the installer deploys anything, so a broken path cannot surface only at
# the deployment step after the host has already been changed.
require_valid_backend_jar() {
  local path="$1"
  [[ -n "$path" ]] || die "Backend JAR path is empty. Provide the built backend JAR with --backend-jar, then rerun the installer."
  [[ -f "$path" ]] || die "Backend JAR points to '$path', which does not exist or is not a regular file. Correct the --backend-jar path, then rerun the installer."
  [[ -s "$path" ]] || die "Backend JAR points to '$path', which is empty (0 bytes). Provide the built backend JAR, then rerun the installer."
  [[ -r "$path" ]] || die "Backend JAR points to '$path', which is not readable. Fix the file permissions so the installer can read the JAR, then rerun the installer."
}

# systemd must be the running service manager, not merely installed:
# `command -v systemctl` also succeeds in containers and WSL without
# systemd, where the installation would only fail at the later
# `systemctl daemon-reload`, after packages, the service account, and
# directories have already been changed. /run/systemd/system is the
# canonical runtime marker of a booted systemd system (it exists on
# WSL2 with systemd enabled and is absent in containers and WSL without
# systemd); PID 1 being systemd independently corroborates it whenever
# ps is available, which also rejects stale markers in images that are
# not booted with systemd. If ps cannot determine PID 1, the marker
# above stays decisive so minimal systems are not falsely rejected.
require_running_systemd() {
  command -v systemctl >/dev/null 2>&1 ||
    die "systemctl is not available. Moddex installs as a native systemd service; run this installer on a systemd-based host, then rerun the installer."
  [[ -d /run/systemd/system ]] ||
    die "systemd is not running as this system's service manager (missing /run/systemd/system). Moddex installs as a native systemd service: run this installer on a systemd-based host; in containers or WSL without systemd, run the bundled backend JAR directly instead."
  if command -v ps >/dev/null 2>&1; then
    local pid1_comm
    if ! pid1_comm="$(ps -p 1 -o comm= 2>/dev/null)"; then
      pid1_comm=""
    fi
    if [[ -n "$pid1_comm" && "$pid1_comm" != "systemd" ]]; then
      die "PID 1 is '$pid1_comm', not systemd, although /run/systemd/system exists. Moddex installs as a native systemd service; run this installer on a host where systemd is the running service manager, then rerun the installer."
    fi
  fi
  log "Systemd is running as the service manager; installing the native systemd service."
}

# --- Install path preflight (issue #119) -----------------------------------
#
# The installer writes fixed systemwide targets: the app directory with its
# JAR and VERSION file, the data directory with the frontend assets and
# logs, the configuration directory with the TLS environment file, the
# systemd unit path, and the CLI deployment path. Those writes follow
# symlinks, so a planted symlink or an unexpected owner on any of the
# targets could redirect the installation outside the managed layout (for
# example the service account relinking app.jar before a reinstall). Before
# the first host change, the checks below verify every existing component
# of those targets:
#   - symlinks must resolve inside the Moddex layout roots
#     (/opt/moddex, /var/lib/moddex, /etc/moddex) or inside a destination
#     explicitly allowed with MODDEX_ALLOWED_INSTALL_ROOTS (colon-separated
#     absolute paths, for documented relocations such as a dedicated mount);
#   - owners must be root, the invoking user, or - for the Moddex layout -
#     the moddex service account.
# The distribution-owned parents (/opt, /var/lib, /etc, /usr/local) are
# trusted anchors: tampering with them requires privileges the service
# account does not have, and the walk below starts at the layout roots
# themselves.
MODDEX_LAYOUT_ROOTS=(/opt/moddex /var/lib/moddex /etc/moddex)

# Prints the numeric owner uid of an existing path (GNU and BSD stat).
install_path_owner_uid() {
  local uid
  if uid="$(stat -c '%u' "$1" 2>/dev/null)"; then
    printf '%s\n' "$uid"
    return 0
  fi
  if uid="$(stat -f '%u' "$1" 2>/dev/null)"; then
    printf '%s\n' "$uid"
    return 0
  fi
  return 1
}

# True when the fully resolved path stays inside one of the allowed roots.
install_path_in_allowed_roots() {
  local resolved="$1" root
  for root in "${INSTALL_PATH_ALLOWED_ROOTS[@]}"; do
    if [[ "$resolved" == "$root" || "$resolved" == "$root"/* ]]; then
      return 0
    fi
  done
  return 1
}

install_path_check_ownership() {
  local path="$1" mode="$2" allowed_uids uid
  [[ "$INSTALL_PATH_OWNERSHIP_CHECK" == available ]] || return 0
  if ! uid="$(install_path_owner_uid "$path")"; then
    die "Cannot determine the owner of $path because stat failed. Verify the ownership of the installation paths manually, then rerun the installer."
  fi
  if [[ "$mode" == moddex ]]; then
    allowed_uids="$INSTALL_PATH_UIDS_MODDEX"
  else
    allowed_uids="$INSTALL_PATH_UIDS_SYSTEM"
  fi
  if [[ "$allowed_uids" == *":${uid}:"* ]]; then
    return 0
  fi
  if [[ "$mode" == moddex ]]; then
    die "Install path $path is owned by uid $uid, which is neither root, nor the invoking user, nor the moddex service account. Restore the expected ownership of the installation paths, then rerun the installer."
  fi
  die "Install path $path is owned by uid $uid, which is neither root nor the invoking user. Restore the expected ownership of the installation paths, then rerun the installer."
}

# Verifies one written installation target. The trusted parent <base> (a
# Moddex layout root or one of the two system directories) starts the walk;
# every component from <base> down to <target> is verified when it exists.
# <ownership> selects the allowed-owner set (moddex layout or system
# directory) and <expect> the required final type (dir or file).
require_safe_install_path() {
  local target="$1" base="$2" ownership="$3" expect="$4"
  local rest comp prefix is_last resolved

  rest="${target#"$base"}"
  prefix="$base"
  while :; do
    is_last=0
    if [[ -z "$rest" ]]; then
      is_last=1
    else
      rest="${rest#/}"
      comp="${rest%%/*}"
      if [[ -z "$comp" ]]; then
        die "Install path preflight failed: empty path component below $prefix. Report this as a bug, then rerun the installer."
      fi
      prefix="$prefix/$comp"
      rest="${rest#"$comp"}"
      if [[ -z "$rest" ]]; then
        is_last=1
      fi
    fi

    if [[ ! -e "$prefix" && ! -L "$prefix" ]]; then
      # Nothing exists at this component or below it; the installer creates
      # it fresh inside the already verified parent.
      return 0
    fi

    if [[ -L "$prefix" ]]; then
      if ! command -v readlink >/dev/null 2>&1; then
        die "Cannot verify the symlink target of $prefix because readlink is unavailable. Install coreutils (readlink) or replace the symlink with a real file or directory, then rerun the installer."
      fi
      if ! resolved="$(readlink -f "$prefix" 2>/dev/null)"; then
        die "Cannot resolve the symlink target of $prefix. Replace the symlink with a real file or directory, then rerun the installer."
      fi
      if ! install_path_in_allowed_roots "$resolved"; then
        die "Install path $prefix is a symlink to $resolved, which is outside the Moddex installation layout. Remove the symlink or replace it with a real directory, or allow the destination explicitly with MODDEX_ALLOWED_INSTALL_ROOTS, then rerun the installer."
      fi
      if [[ "$is_last" == 1 ]]; then
        if [[ "$expect" == dir && ! -d "$prefix" ]]; then
          die "Install path $prefix is a symlink to $resolved, which is not a directory. Point the symlink at a directory or replace it, then rerun the installer."
        fi
        if [[ "$expect" == file && -d "$prefix" ]]; then
          die "Install path $prefix is a symlink to the directory $resolved, but the installer writes a file there. Replace the symlink, then rerun the installer."
        fi
      elif [[ ! -d "$prefix" ]]; then
        die "Install path $prefix is a symlink to $resolved, which is not a directory. Point the symlink at a directory or replace it, then rerun the installer."
      fi
    else
      if [[ "$is_last" == 1 && "$expect" == file ]]; then
        if [[ ! -f "$prefix" ]]; then
          die "Install path $prefix exists but is not a regular file. Remove or replace it, then rerun the installer."
        fi
      elif [[ ! -d "$prefix" ]]; then
        die "Install path $prefix exists but is not a directory. Remove or replace it, then rerun the installer."
      fi
    fi

    install_path_check_ownership "$prefix" "$ownership"

    if [[ "$is_last" == 1 ]]; then
      return 0
    fi
  done
}

require_safe_install_paths() {
  local root resolved extra entry moddex_uid_probe="" saved_ifs
  INSTALL_PATH_ALLOWED_ROOTS=()
  for root in "${MODDEX_LAYOUT_ROOTS[@]}"; do
    INSTALL_PATH_ALLOWED_ROOTS+=("$root")
    # A real, non-link root also allows its physically resolved form, so a
    # symlinked prefix above it (for example a linked test checkout) cannot
    # hide a relocated destination. The resolved form of a root that is
    # itself a symlink deliberately stays out: a planted relocation must be
    # allowed explicitly via MODDEX_ALLOWED_INSTALL_ROOTS.
    if [[ -d "$root" && ! -L "$root" ]] && command -v readlink >/dev/null 2>&1 &&
      resolved="$(readlink -f "$root" 2>/dev/null)"; then
      INSTALL_PATH_ALLOWED_ROOTS+=("$resolved")
    fi
  done
  extra="${MODDEX_ALLOWED_INSTALL_ROOTS:-}"
  if [[ -n "$extra" ]]; then
    saved_ifs="$IFS"
    local IFS=":"
    # shellcheck disable=SC2086
    for entry in $extra; do
      if [[ "$entry" != /* ]]; then
        die "MODDEX_ALLOWED_INSTALL_ROOTS contains an entry that is empty or not an absolute path. Use absolute directory paths separated by colons, then rerun the installer."
      fi
      INSTALL_PATH_ALLOWED_ROOTS+=("$entry")
      if command -v readlink >/dev/null 2>&1 && resolved="$(readlink -f "$entry" 2>/dev/null)"; then
        INSTALL_PATH_ALLOWED_ROOTS+=("$resolved")
      fi
    done
    IFS="$saved_ifs"
  fi

  INSTALL_PATH_OWNERSHIP_CHECK=unavailable
  if command -v stat >/dev/null 2>&1; then
    INSTALL_PATH_OWNERSHIP_CHECK=available
  else
    log "Skipping installation path ownership verification: stat is unavailable on this host."
  fi
  if moddex_uid_probe="$(id -u moddex 2>/dev/null)" && [[ "$moddex_uid_probe" =~ ^[0-9]+$ ]]; then
    INSTALL_PATH_UIDS_MODDEX=":0:${EUID}:${moddex_uid_probe}:"
  else
    INSTALL_PATH_UIDS_MODDEX=":0:${EUID}:"
  fi
  INSTALL_PATH_UIDS_SYSTEM=":0:${EUID}:"

  # App directory and its contents.
  require_safe_install_path /opt/moddex /opt/moddex moddex dir
  require_safe_install_path /opt/moddex/app.jar /opt/moddex moddex file
  require_safe_install_path /opt/moddex/VERSION /opt/moddex moddex file
  # Data directory, frontend assets, and logs.
  require_safe_install_path /var/lib/moddex /var/lib/moddex moddex dir
  require_safe_install_path /var/lib/moddex/ui /var/lib/moddex moddex dir
  require_safe_install_path /var/lib/moddex/logs /var/lib/moddex moddex dir
  # Configuration directory and TLS environment file.
  require_safe_install_path /etc/moddex /etc/moddex moddex dir
  require_safe_install_path /etc/moddex/moddex.env /etc/moddex moddex file
  # systemd unit directory and unit file.
  require_safe_install_path /etc/systemd/system /etc/systemd/system system dir
  require_safe_install_path /etc/systemd/system/moddex-backend.service /etc/systemd/system system file
  # CLI deployment directory and helper.
  require_safe_install_path /usr/local/bin /usr/local/bin system dir
  require_safe_install_path /usr/local/bin/moddex /usr/local/bin system file

  log "Install path preflight passed: symlink targets and ownership of the systemwide installation paths verified."
}

# --- Host lock against parallel installations and updates (issue #108) ------
#
# Several invocations could otherwise change the same artifacts, environment
# files, systemd unit, and service at the same time. install.sh and update.sh
# hold a host-wide advisory lock (flock) on MODDEX_LOCK_FILE for their
# mutating phases. The default /run/moddex/install.lock lives in a
# root-owned 0755 runtime directory the installer creates before the first
# host change; MODDEX_LOCK_FILE relocates it (documented override, same trust
# level as the other installer environment: only root or a sudo-capable
# administrator reaches this code). The kernel releases the lock when the
# holding process ends, including on SIGKILL, and no child still carries the
# inherited lock descriptor (for example a still-running apt-get; that
# deliberately keeps a parallel run from racing a live mutator), so a crashed
# run never leaves a permanent lock; the file itself stays in place as the
# lock target and carries only diagnostic metadata (holder PID, UTC start
# time, operation type) for the error messages. Lock validity comes from the
# kernel lock alone, never from the file content. update.sh holds the lock
# across the service stop and the staged installation and passes its PID in
# MODDEX_LOCK_PID, so the bundled installer it runs reenters the same
# operation instead of failing against its own update; every other holder
# fails fast without waiting.

# Prints "pid start" from the lock file's metadata line
# ("pid=<pid> start=<utc> op=<operation>"); both fields are empty when the
# file is unreadable or its content is not a metadata line.
install_lock_holder_fields() {
  local line="" pid="" start=""
  IFS= read -r line < "$MODDEX_LOCK_FILE" 2>/dev/null || line=""
  case "$line" in
    pid=[0-9]*\ *)
      pid="${line#pid=}"
      pid="${pid%% *}"
      start="${line#*start=}"
      start="${start%% *}"
      printf '%s %s\n' "$pid" "$start"
      ;;
  esac
}

release_install_lock() {
  if [[ "${INSTALL_LOCK_ACQUIRED:-0}" -eq 1 ]]; then
    INSTALL_LOCK_ACQUIRED=0
    flock -u 9 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
  fi
}

acquire_install_lock() {
  local lock_dir holder holder_pid="" holder_start=""
  command -v flock >/dev/null 2>&1 ||
    die "flock is unavailable, but Moddex serializes concurrent installation and update runs with it. Install the util-linux package (or your distribution's flock provider), then rerun the installer; nothing was changed."
  [[ "$MODDEX_LOCK_FILE" == /* ]] ||
    die "MODDEX_LOCK_FILE must be an absolute file path (received: $MODDEX_LOCK_FILE). Set an absolute lock file path, then rerun the installer; nothing was changed."
  if [[ -e "$MODDEX_LOCK_FILE" && ! -f "$MODDEX_LOCK_FILE" ]]; then
    die "The Moddex lock path $MODDEX_LOCK_FILE exists but is not a regular file. Remove or replace it, then rerun the installer; nothing was changed."
  fi
  lock_dir="${MODDEX_LOCK_FILE%/*}"
  if ! install -d -m 0755 "$lock_dir"; then
    die "Cannot create the Moddex lock directory $lock_dir. Create it as root (install -d -m 0755 <directory>), then rerun the installer; nothing was changed."
  fi
  if ! { : >> "$MODDEX_LOCK_FILE"; } 2>/dev/null; then
    die "Cannot write the Moddex lock file $MODDEX_LOCK_FILE. Make the lock directory writable for root, then rerun the installer; nothing was changed."
  fi
  exec 9>> "$MODDEX_LOCK_FILE"
  if flock -n 9; then
    INSTALL_LOCK_ACQUIRED=1
    : > "$MODDEX_LOCK_FILE"
    printf 'pid=%s start=%s op=%s\n' "$$" "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)" "install" >&9
    log "Acquired the Moddex host lock at $MODDEX_LOCK_FILE (operation PID $$)."
    return 0
  fi
  # The lock is held by another process. Only the top-level update operation
  # may pass: it holds the lock while this installer runs as its staged
  # installation step and identifies itself by the PID it recorded in
  # MODDEX_LOCK_PID matching the lock metadata. Every other holder fails fast.
  holder="$(install_lock_holder_fields)" || holder=""
  holder_pid="${holder%% *}"
  if [[ "$holder" == *" "* ]]; then
    holder_start="${holder#* }"
  fi
  if [[ -n "${MODDEX_LOCK_PID:-}" && "$MODDEX_LOCK_PID" =~ ^[0-9]+$ &&
        "$holder_pid" == "$MODDEX_LOCK_PID" ]] &&
    kill -0 "$MODDEX_LOCK_PID" 2>/dev/null; then
    log "The running update (operation PID $MODDEX_LOCK_PID) already holds the Moddex host lock; continuing the staged installation inside it."
    return 0
  fi
  if [[ -z "$holder_pid" ]]; then
    die "Another Moddex installation or update is currently running and holds the host lock ($MODDEX_LOCK_FILE); its operation ID could not be read. Wait for the running installation or update to finish, then rerun this installer; nothing was changed by this run."
  fi
  if kill -0 "$holder_pid" 2>/dev/null; then
    die "Another Moddex installation or update is currently running (operation PID $holder_pid, started ${holder_start:-unknown}). Wait for it to finish, then rerun this installer; nothing was changed by this run."
  fi
  die "The Moddex host lock ($MODDEX_LOCK_FILE) could not be acquired; it is recorded for PID $holder_pid (started ${holder_start:-unknown}), which is not running anymore. The lock is held by another local process that did not record itself: check for other Moddex installation or update activity, then rerun this installer; nothing was changed by this run."
}

# systemd EnvironmentFile values are double quoted; quotes and backslashes
# would corrupt the line or be reinterpreted as C escapes.
require_systemd_safe_value() {
  local label="$1" value="$2"
  [[ "$value" != *[\"\\]* && "$value" != *$'\n'* ]] ||
    die "Native TLS: $label contains a double quote, backslash, or newline, which the systemd environment file cannot carry safely. Choose a path or password without these characters, then rerun the installer."
}

# Writes the native TLS settings the systemd unit and the backend read.
# The temp file is created with mode 0600 before any content is written, so
# secrets are never world readable and a killed run leaves no readable rest.
write_tls_env() {
  local pair name value tmp_file="$MODDEX_ENV_FILE.tmp"
  # The directory must exist before the temp file is created; on a fresh
  # installation nothing else has created it yet.
  install -d -m 0755 -o moddex -g moddex /etc/moddex
  rm -f -- "$tmp_file"
  (umask 077 && : > "$tmp_file")
  printf '# Managed by install.sh - native TLS settings for the Moddex backend.\n' > "$tmp_file"
  for pair in "$@"; do
    name="${pair%%=*}"
    value="${pair#*=}"
    printf '%s="%s"\n' "$name" "$value" >> "$tmp_file"
  done
  mv -f -- "$tmp_file" "$MODDEX_ENV_FILE"
  chmod 0600 "$MODDEX_ENV_FILE"
  log "Wrote TLS settings to $MODDEX_ENV_FILE (mode 0600). Ensure the service account can read the referenced certificate, key, and keystore files."
}

validate_port() {
  local port="$SERVER_PORT"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  # Strip zero padding before bounding decimal arithmetic, avoiding octal and overflow.
  port="${port#"${port%%[!0]*}"}"
  [[ -n "$port" && ${#port} -le 5 ]] || return 1
  (( 10#$port <= 65535 )) || return 1
  SERVER_PORT="$port"
}

usage() {
  cat <<'USAGE'
Usage: install.sh [options]

Options:
  --mode MODE           Deployment mode: local, lan, public
  --backend-jar PATH    Path to the backend JAR to install
  --frontend-dir PATH   Path to the directory with built frontend assets
  --port NUMBER         Decimal TCP port, 1..65535 (default: 8080; preserved
                        from an existing installation when omitted)
  --tls-cert PATH       PEM certificate chain for native HTTPS
  --tls-key PATH        PEM private key matching --tls-cert
  --tls-keystore PATH   PKCS12 keystore instead of PEM files (other types
                        via MODDEX_TLS_KEYSTORE_TYPE, e.g. JKS)
  --no-tls              Remove a preserved TLS configuration (plain HTTP)
  --version TAG         Installed version (default: the bundle's VERSION file)
  -h, --help            Show this help and exit

Environment overrides:
  MODDEX_MODE, MODDEX_BACKEND_JAR, MODDEX_FRONTEND_DIR
  MODDEX_ALLOWED_INSTALL_ROOTS: colon-separated absolute directories that
  symlinked installation targets may additionally point to.
  MODDEX_LOCK_FILE: absolute path of the host lock that serializes
  concurrent installations and updates (default /run/moddex/install.lock).
  Port precedence: --port, PORT, MODDEX_PORT, then the port of an existing
  installation, then 8080 (unset overrides only).
  TLS: MODDEX_TLS_CERT_FILE, MODDEX_TLS_KEY_FILE, MODDEX_TLS_KEYSTORE,
  MODDEX_TLS_KEYSTORE_PASSWORD, MODDEX_TLS_KEYSTORE_TYPE.

Native TLS contract: activating TLS (PEM pair or keystore) writes the
MODDEX_TLS_* settings to /etc/moddex/moddex.env, which the systemd unit reads.
The backend then serves HTTPS on SERVER_PORT. Missing or unreadable key
material aborts the installation with a safe instruction instead of silently
falling back to HTTP. Reinstalling without TLS options preserves an existing
configuration; --no-tls removes it.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) [[ $# -ge 2 ]] || die "Missing value for --mode"; MODE="$2"; shift 2 ;;
    --backend-jar) [[ $# -ge 2 ]] || die "Missing value for --backend-jar"; BACKEND_JAR="$2"; shift 2 ;;
    --frontend-dir) [[ $# -ge 2 ]] || die "Missing value for --frontend-dir"; FRONTEND_DIR="$2"; shift 2 ;;
    --port) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "Missing value for --port. Use a decimal integer from 1 to 65535."; SERVER_PORT="$2"; PORT_EXPLICIT=1; shift 2 ;;
    --tls-cert) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "Missing value for --tls-cert. Use the path to the PEM certificate chain."; TLS_CERT_FILE="$2"; shift 2 ;;
    --tls-key) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "Missing value for --tls-key. Use the path to the matching PEM private key."; TLS_KEY_FILE="$2"; shift 2 ;;
    --tls-keystore) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "Missing value for --tls-keystore. Use the path to the keystore file."; TLS_KEYSTORE="$2"; shift 2 ;;
    --no-tls) TLS_DISABLE=1; shift ;;
    --version) [[ $# -ge 2 && -n "$2" ]] || die "Missing value for --version"; INSTALL_VERSION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

validate_port || die "Invalid backend port. Use a decimal integer from 1 to 65535 (--port, PORT or MODDEX_PORT)."

if [[ "$TLS_DISABLE" -eq 1 && -n "$TLS_CERT_FILE$TLS_KEY_FILE$TLS_KEYSTORE" ]]; then
  die "--no-tls cannot be combined with the TLS options. Use either --no-tls or the TLS options, then rerun the installer."
fi

# Validate requested TLS key material before anything is deployed, so an
# invalid configuration cannot leave a half-updated installation behind.
if [[ -n "$TLS_CERT_FILE" && -n "$TLS_KEYSTORE" ]]; then
  die "Native TLS accepts either the PEM pair (--tls-cert and --tls-key) or a keystore (--tls-keystore), not both. Choose one variant, then rerun the installer."
fi
if [[ -n "$TLS_CERT_FILE" || -n "$TLS_KEY_FILE" ]]; then
  [[ -n "$TLS_CERT_FILE" && -n "$TLS_KEY_FILE" ]] ||
    die "Native TLS needs both the certificate chain and its private key (--tls-cert and --tls-key), or use --tls-keystore instead. Provide both files, then rerun the installer."
  require_systemd_safe_value "--tls-cert" "$TLS_CERT_FILE"
  require_systemd_safe_value "--tls-key" "$TLS_KEY_FILE"
  require_readable_file "--tls-cert" "$TLS_CERT_FILE"
  require_readable_file "--tls-key" "$TLS_KEY_FILE"
elif [[ -n "$TLS_KEYSTORE" ]]; then
  require_systemd_safe_value "--tls-keystore" "$TLS_KEYSTORE"
  require_systemd_safe_value "MODDEX_TLS_KEYSTORE_PASSWORD" "${MODDEX_TLS_KEYSTORE_PASSWORD:-}"
  require_systemd_safe_value "MODDEX_TLS_KEYSTORE_TYPE" "${MODDEX_TLS_KEYSTORE_TYPE:-}"
  require_readable_file "--tls-keystore" "$TLS_KEYSTORE"
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  if [[ -z "${MODDEX_INSTALL_REEXEC:-}" ]] && command -v sudo >/dev/null 2>&1; then
    export MODDEX_INSTALL_REEXEC=1
    exec sudo -E "${INSTALL_COMMAND[@]}"
  fi
  echo "This installer must run with root privileges." >&2
  exit 1
fi
unset MODDEX_INSTALL_REEXEC

if [[ -z "$INSTALL_VERSION" ]]; then
  [[ -f "$PROJECT_ROOT/VERSION" ]] || die "Installation version missing. Use a complete bundle or provide --version <tag>."
  if ! INSTALL_VERSION="$(cat "$PROJECT_ROOT/VERSION" 2>/dev/null)"; then
    die "Cannot read installation VERSION. Use a complete bundle or provide --version <tag>."
  fi
fi
[[ "$INSTALL_VERSION" =~ ^[A-Za-z0-9._-]+$ && "$INSTALL_VERSION" != latest ]] ||
  die "Invalid installation version. Use a concrete tag with letters, digits, dots, underscores or hyphens."
CLI_SOURCE="$PROJECT_ROOT/backend/bin/moddex"
[[ -f "$CLI_SOURCE" ]] || die "CLI helper missing (backend/bin/moddex). Use a complete bundle or checkout."

if [[ -z "$MODE" ]]; then
  log "In which mode do you want to operate Moddex?"
  select mode_option in "lan (recommended)" "local (dev only)" "public"; do
    case "$mode_option" in
      "lan (recommended)") MODE="lan"; break ;;
      "local (dev only)") MODE="local"; break ;;
      "public") MODE="public"; break ;;
      *) echo "Invalid option. Please try again." ;;
    esac
  done
fi

MODE="${MODE,,}"
case "$MODE" in
  local|lan|public) ;;
  *) die "Invalid --mode value: $MODE (expected local, lan, or public)" ;;
esac

if [[ -z "$BACKEND_JAR" ]]; then
  DEFAULT_JAR="$PROJECT_ROOT/backend/Moddex-Backend.jar"
  [[ -f "$DEFAULT_JAR" ]] || die "Backend JAR not found. Provide --backend-jar."
  BACKEND_JAR="$DEFAULT_JAR"
fi

# The first host change happens with the package installation below; an
# invalid backend JAR must abort before that point instead of failing at
# the deployment step.
require_valid_backend_jar "$BACKEND_JAR"

if [[ -z "$FRONTEND_DIR" ]]; then
  DEFAULT_FRONTEND="$PROJECT_ROOT/frontend"
  if [[ -d "$DEFAULT_FRONTEND" && -f "$DEFAULT_FRONTEND/index.html" ]]; then
    FRONTEND_DIR="$DEFAULT_FRONTEND"
  else
    FRONTEND_DIR=""
  fi
fi

if [[ -n "$FRONTEND_DIR" ]]; then
  [[ -d "$FRONTEND_DIR" && -f "$FRONTEND_DIR/index.html" ]] || die "Frontend directory invalid. Use --frontend-dir."
fi

# The package installation below is the first host change; an environment
# without a running systemd must abort before packages, the service account,
# directories, or the unit are touched. `command -v systemctl` alone cannot
# decide this: containers and WSL without systemd pass it and only fail at
# the later `systemctl daemon-reload`.
require_running_systemd

# The package installation below is the first host change; a tampered
# installation path must abort before that point as well (issue #119).
require_safe_install_paths

# From here on the installer mutates the host: packages, service account,
# directories, artifacts, environment files, unit, and service. The host lock
# (issue #108) serializes this window against every other installation or
# update run; it is released when this process ends.
trap release_install_lock EXIT
acquire_install_lock

log "Ensuring required packages are installed"
if command -v apt-get >/dev/null 2>&1; then
  if DEBIAN_FRONTEND=noninteractive apt-get update -y; then
    :
  else
    apt_status=$?
    die "apt-get update failed (exit $apt_status); check network connectivity and repository configuration, then rerun the installer."
  fi

  if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openjdk-17-jre-headless rsync; then
    :
  else
    apt_status=$?
    die "apt-get install failed (exit $apt_status) while installing OpenJDK 17 and rsync; resolve the package manager error, then rerun the installer."
  fi
fi

if ! command -v rsync >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    die "rsync is still unavailable after apt-get install; check the package manager output and rerun the installer."
  fi
  die "rsync is required but was not found. Install it with your platform's package manager, then rerun the installer."
fi
need_cmd install
need_cmd systemctl
need_cmd java

log "Creating moddex user and directories"
if ! id -u moddex >/dev/null 2>&1; then
  useradd -r -M -s /usr/sbin/nologin -d /opt/moddex moddex
fi

install -d -m 0755 -o moddex -g moddex /opt/moddex
install -d -m 0755 -o moddex -g moddex /var/lib/moddex
install -d -m 0755 -o moddex -g moddex /var/lib/moddex/ui
install -d -m 0755 -o moddex -g moddex /var/lib/moddex/logs

log "Deploying backend artifact"
install -m 0644 "$BACKEND_JAR" /opt/moddex/app.jar
chown moddex:moddex /opt/moddex/app.jar

if [[ -n "$FRONTEND_DIR" ]]; then
  log "Deploying frontend assets from $FRONTEND_DIR"
  rsync -a --delete --chown=moddex:moddex "$FRONTEND_DIR/" /var/lib/moddex/ui/
else
  log "Skipping frontend asset deployment (no build directory provided)"
fi

log "Installing CLI helper and recording version $INSTALL_VERSION"
install -d -m 0755 /usr/local/bin
install -m 0755 "$CLI_SOURCE" /usr/local/bin/moddex
if ! printf '%s\n' "$INSTALL_VERSION" > /opt/moddex/VERSION; then
  die "Could not write /opt/moddex/VERSION. Check installation directory permissions, then rerun the installer."
fi
chmod 0644 /opt/moddex/VERSION

case "$MODE" in
  local)
    SERVER_ADDRESS="127.0.0.1"
    ;;
  lan|public)
    SERVER_ADDRESS="0.0.0.0"
    ;;
esac

SERVICE_FILE=/etc/systemd/system/moddex-backend.service

# A reinstall without an explicit port keeps the effective port of the
# existing installation instead of resetting it to the default.
if [[ "$PORT_EXPLICIT" -eq 0 && -z "${PORT:-}" && -z "${MODDEX_PORT:-}" && -r "$SERVICE_FILE" ]]; then
  existing_port=""
  while IFS= read -r service_line; do
    case "$service_line" in
      "Environment=SERVER_PORT="*)
        existing_port="${service_line#Environment=SERVER_PORT=}"
        break
        ;;
    esac
  done < "$SERVICE_FILE"
  if [[ "$existing_port" =~ ^[0-9]+$ && $((10#$existing_port)) -ge 1 && $((10#$existing_port)) -le 65535 ]]; then
    SERVER_PORT="$existing_port"
    log "Preserving the existing backend port $SERVER_PORT."
  fi
fi

log "Writing systemd service to $SERVICE_FILE"
install -m 0644 "$SYSTEMD_DIR/moddex-backend.service" "$SERVICE_FILE"
sed -i "s/^Environment=SERVER_ADDRESS=.*/Environment=SERVER_ADDRESS=$SERVER_ADDRESS/" "$SERVICE_FILE"
sed -i "s/^Environment=SERVER_PORT=.*/Environment=SERVER_PORT=$SERVER_PORT/" "$SERVICE_FILE"

log "Configuring native TLS settings"
TLS_ACTIVE=0
if [[ "$TLS_DISABLE" -eq 1 ]]; then
  if [[ -f "$MODDEX_ENV_FILE" ]]; then
    rm -f -- "$MODDEX_ENV_FILE"
    log "Removed the existing TLS configuration; the backend serves plain HTTP on port $SERVER_PORT."
  else
    log "No TLS configuration present; the backend serves plain HTTP on port $SERVER_PORT."
  fi
elif [[ -n "$TLS_CERT_FILE$TLS_KEY_FILE$TLS_KEYSTORE" ]]; then
  # Key material was already validated before the deployment started.
  if [[ -n "$TLS_KEYSTORE" ]]; then
    tls_lines=("MODDEX_TLS_ENABLED=true" "MODDEX_TLS_KEYSTORE=$TLS_KEYSTORE")
    if [[ -n "${MODDEX_TLS_KEYSTORE_PASSWORD:-}" ]]; then
      tls_lines+=("MODDEX_TLS_KEYSTORE_PASSWORD=$MODDEX_TLS_KEYSTORE_PASSWORD")
    fi
    tls_lines+=("MODDEX_TLS_KEYSTORE_TYPE=${MODDEX_TLS_KEYSTORE_TYPE:-PKCS12}")
    write_tls_env "${tls_lines[@]}"
  else
    write_tls_env \
      "MODDEX_TLS_ENABLED=true" \
      "MODDEX_TLS_CERT_FILE=$TLS_CERT_FILE" \
      "MODDEX_TLS_KEY_FILE=$TLS_KEY_FILE"
  fi
  TLS_ACTIVE=1
elif [[ -f "$MODDEX_ENV_FILE" ]]; then
  log "Preserving the existing TLS configuration in $MODDEX_ENV_FILE."
  TLS_ACTIVE=1
else
  log "No TLS configuration requested; the backend serves plain HTTP on port $SERVER_PORT."
fi

log "Reloading systemd and starting backend"
systemctl daemon-reload
systemctl enable --now moddex-backend.service

if [[ "$MODE" != "local" ]]; then
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "$SERVER_PORT"/tcp || true
  elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$SERVER_PORT"/tcp || true
    firewall-cmd --reload || true
  else
    log "Firewall not detected. Ensure TCP $SERVER_PORT is reachable if needed."
  fi
fi

log "Installation complete"
if [[ "$TLS_ACTIVE" -eq 1 ]]; then
  TLS_PROTOCOL="https"
else
  TLS_PROTOCOL="http"
fi
case "$MODE" in
  local)
    printf 'Backend API reachable at: %s://127.0.0.1:%s\n' "$TLS_PROTOCOL" "$SERVER_PORT"
    ;;
  lan)
    printf 'Backend API reachable at: %s://<server-ip>:%s\n' "$TLS_PROTOCOL" "$SERVER_PORT"
    ;;
  public)
    printf 'Backend API reachable at: %s://<public-host>:%s\n' "$TLS_PROTOCOL" "$SERVER_PORT"
    ;;
esac
printf 'Systemd unit: moddex-backend.service\n'
if [[ -n "$FRONTEND_DIR" ]]; then
  printf 'Static frontend copied to /var/lib/moddex/ui (serve separately).\n'
fi
printf 'Authentication is disabled. Protect the service via network policies if exposed.\n'

exit 0
