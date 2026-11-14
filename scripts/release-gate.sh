#!/usr/bin/env bash
# Release-Gate (Issue #186): runs against the FINAL release bundle before it is
# published. Called from .github/workflows/release.yml on the same fresh
# GitHub-hosted runner (a VM with systemd) that built the bundle:
#
#   1. Digest verification: every published main artifact (bundle tar.gz, zip,
#      download.sh) must match its published per-asset .sha256 record and the
#      SHA256SUMS summary, and the match (published == computed) is printed as
#      evidence per artifact.
#   2. Staging: the archive is validated as an installation bundle (relative
#      entries, required core files, safe link targets — the same check as the
#      published downloader, which --install-staged deliberately skips) and
#      unpacked into a gate-owned staging directory; the staged VERSION must
#      equal the release tag.
#   3. Installation: the PUBLISHED downloader (release/download.sh) runs in
#      --install-staged mode, so the bundled installer is invoked exactly like
#      in the documented user path. On a fresh runner host this performs a real
#      installation with the native systemd service. All paths (release
#      directory, downloader, stage root) are resolved absolutely at startup,
#      so the invocation is independent of the working directory. Before the
#      installation the gate pins the gate host's UNIT java (/usr/bin/java,
#      what 'ExecStart=/usr/bin/env java' resolves under systemd's default
#      service PATH) to a Java 17 (or newer) runtime: GitHub runner images
#      preselect older javas via update-alternatives AND put a toolcache java
#      first in the shell PATH (runs 43509195319/43512932003 started the
#      service on Java 11 and crashed it with UnsupportedClassVersionError,
#      while the shell saw Java 21), so the gate must probe and pin
#      /usr/bin/java, never the shell's java. A clean host whose
#      /usr/bin/java already reports >= 17 skips the correction entirely.
#   4. Evidence: the moddex-backend systemd service must become active and the
#      backend must answer /api/v1/setup/status on the installed address with
#      setupRequired=true (fresh host, no administrator configured yet).
#
# A gate failure aborts the release workflow BEFORE the publish step. All
# error messages state the problem and a safe next action and never contain
# secrets (the gate uses no tokens; it only touches the local release files).
#
# Usage: release-gate.sh <release-dir> <tag>
#   <release-dir>  Directory with the artifacts exactly as they are published
#                  (moddex-<tag>-linux-amd64.tar.gz[.sha256], .zip[.sha256],
#                  download.sh[.sha256], SHA256SUMS).
#   <tag>          Release tag (vX.Y.Z) the bundle was built for.
#
# Trusted environment overrides (test seams; production defaults in brackets):
#   MODDEX_GATE_STAGE_ROOT      staging root owned by the caller [temporary
#                               directory created and removed by the gate]
#   MODDEX_GATE_INSTALL_SCRIPT  downloader invoked for the installation
#                               [<release-dir>/download.sh]
#   MODDEX_GATE_UNIT_JAVA       unit java binary probed and pinned
#                               [/usr/bin/java]
#   MODDEX_GATE_UNIT_FILE       installed systemd unit read for the backend
#                               address and port [/etc/systemd/system/moddex-backend.service]
#   MODDEX_GATE_SERVICE_TIMEOUT seconds to wait for an active, reachable
#                               backend [180]
set -Eeuo pipefail

RELEASE_DIR="${1:-}"
GATE_TAG="${2:-}"

log() { printf '[release-gate] %s\n' "$*"; }
die() { printf '[ERROR] release-gate: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1. Install it on the gate host, then re-run the gate."; }
# One diagnostic line with a stable prefix, so a failing probe can be read
# directly from the workflow log without host access.
diag() { printf '[release-gate] diag: %s\n' "$*"; }

# The archive entry name is data from the artifact; it is never echoed in
# error output. Violations are reported by category with a safe next action,
# mirroring the downloader's bundle validation.
entry_has_parent_component() {
  local entry="$1"
  [[ "$entry" == ".." || "$entry" == ../* || "$entry" == */../* || "$entry" == */.. ]]
}

# A link target is rejected when it is empty, absolute or contains a parent
# component, regardless of where the link itself is placed. As in the
# downloader, the message is category-style and never echoes
# archive-controlled names.
require_safe_link_target() {
  local target="$1"
  if [[ -z "$target" || "$target" == /* ]] || entry_has_parent_component "$target"; then
    die "Bundle archive validation failed: an archive link entry points outside the bundle directory. Do not publish this release. Rebuild the bundle with 'scripts/build-bundle.sh' and re-run the workflow; nothing was unpacked."
  fi
}

# Prints the sha256 record's digest for exactly <name> ("<digest>  <name>", one
# record, binary-marker "*" tolerated). Records for other files or additional
# records for the same file are rejected: the published checksum must name
# exactly this archive.
read_published_digest() {
  local file="$1" name="$2" record record_name expected=""
  while IFS= read -r record || [[ -n "$record" ]]; do
    record="${record%$'\r'}"
    case "$record" in
      "" | "#"*) continue ;;
      [0-9A-Fa-f]*)
        record_name="${record#* }"      # digest is separated by spaces
        record_name="${record_name#* }" # second space of the standard separator
        record_name="${record_name#\*}" # binary-marker variant "*<name>"
        if [[ "$record_name" == "$name" ]]; then
          [[ -z "$expected" ]] || return 1
          expected="${record%% *}"
        fi
        ;;
    esac
  done < "$file"
  [[ -n "$expected" ]] || return 1
  printf '%s\n' "$expected"
}

verify_published_digests() {
  local release_dir="$1" tag="$2" bundle artifact checksum_file published computed summary_output
  bundle="moddex-${tag}-linux-amd64"

  need_cmd sha256sum
  # The summary checksum file lists tar.gz, zip and download.sh with the names
  # they have in the published release; verifying it proves the gate checks
  # exactly the published files.
  if summary_output="$(cd "$release_dir" && sha256sum -c SHA256SUMS 2>&1)"; then
    log "SHA256SUMS verification passed (bundle tar.gz, zip and download.sh match the published checksums)."
  else
    printf '%s\n' "$summary_output" >&2
    die "Published checksum verification failed: the file named above does not match its recorded digest in SHA256SUMS. Do not publish this release. Rebuild the bundle with 'scripts/build-bundle.sh', re-prepare the release artifacts and re-run the workflow."
  fi

  # Every published main artifact is re-verified against exactly its published
  # per-asset checksum, so the evidence covers the bundle archive, the zip and
  # the downloader symmetrically (published == computed, printed per artifact).
  for artifact in "${bundle}.tar.gz" "${bundle}.zip" "download.sh"; do
    checksum_file="$release_dir/$artifact.sha256"
    if ! published="$(read_published_digest "$checksum_file" "$artifact")"; then
      die "Published checksum file $checksum_file does not contain exactly one SHA-256 record for $artifact. Do not publish this release. Re-prepare the release artifacts (each per-asset .sha256 must name exactly its artifact) and re-run the workflow."
    fi
    computed="$(sha256sum "$release_dir/$artifact")"
    computed="${computed%% *}"
    if [[ "$computed" != "$published" ]]; then
      die "Digest mismatch for $artifact: computed $computed, published $published. Do not publish this release. The artifact changed after its checksum was written: rebuild the bundle with 'scripts/build-bundle.sh', re-prepare the release artifacts and re-run the workflow."
    fi
    log "Digest verified for $artifact: published == computed == $published"
  done
}

stage_bundle() {
  local archive="$1" extract_dir="$2" listing verbose_listing entry norm required entries="" line

  need_cmd tar
  if ! listing="$(tar -tzf "$archive" 2>/dev/null)"; then
    die "Bundle archive validation failed: the archive contents cannot be listed even though the digest matched. Do not publish this release. Inspect the archive locally ('tar -tzf <archive>') and re-run the workflow."
  fi
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    norm="${entry#./}"
    case "$norm" in
      "" | ".") continue ;;
      /*)
        die "Bundle archive validation failed: an archive entry uses an absolute path. Do not publish this release. Rebuild the bundle with 'scripts/build-bundle.sh' (entries must be relative to the bundle root) and re-run the workflow."
        ;;
      ..)
        die "Bundle archive validation failed: an archive entry contains a parent-directory path component. Do not publish this release. Rebuild the bundle with 'scripts/build-bundle.sh' and re-run the workflow; nothing was unpacked."
        ;;
    esac
    if entry_has_parent_component "$norm"; then
      die "Bundle archive validation failed: an archive entry contains a parent-directory path component. Do not publish this release. Rebuild the bundle with 'scripts/build-bundle.sh' and re-run the workflow; nothing was unpacked."
    fi
    entries+="$norm"$'\n'
  done <<< "$listing"

  for required in \
    VERSION \
    backend/Moddex-Backend.jar \
    frontend/index.html \
    scripts/install.sh \
    packaging/systemd/moddex-backend.service; do
    if ! grep -Fxq -- "$required" <<< "$entries"; then
      die "Bundle archive validation failed: the archive is not a complete Moddex installation bundle (required entry $required is missing). Do not publish this release. Rebuild the bundle with 'scripts/build-bundle.sh' and re-run the workflow; nothing was unpacked."
    fi
  done
  log "Bundle archive entries validated (relative entries, complete installation bundle)."

  # Same check as the published downloader's archive validation
  # (--install-staged deliberately skips it): link targets are interpreted
  # from the tail of verbose listing lines (" -> " for symlinks, " link to "
  # for hard links); the entry-name part of those lines is tar-format
  # specific. GNU tar prints both target forms; bsdtar 3.5.3 does as well,
  # but this marker output is not standardized, so a tar that omits link
  # targets in its listing makes this check ineffective for those entries. A
  # target is rejected when it is empty, absolute or contains a parent
  # component, regardless of where the link itself is placed, so a link can
  # never resolve outside the extraction directory.
  if ! verbose_listing="$(tar -tvzf "$archive" 2>/dev/null)"; then
    die "Bundle archive validation failed: the archive contents cannot be listed even though the digest matched. Do not publish this release. Inspect the archive locally ('tar -tvzf <archive>') and re-run the workflow."
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
  log "Bundle archive link targets validated (no escaping links)."

  mkdir -p "$extract_dir"
  # --no-same-owner keeps the archive from assigning arbitrary ownership; the
  # digest and structure of the archive were verified above.
  tar --no-same-owner -C "$extract_dir" -xzf "$archive"
}

# Reports the major version of the UNIT java: the binary the systemd unit
# executes. GitHub runner images put a toolcache java FIRST in the shell PATH
# (run 43512932003: shell saw Java 21) while the unit's
# 'ExecStart=/usr/bin/env java' resolves under systemd's default service PATH
# to /usr/bin/java (run 43509195319: Java 11, UnsupportedClassVersionError
# crash loop) — shell PATH and unit PATH are different selectors, so every
# probe and assertion targets /usr/bin/java verbatim, never the shell's java.
# MODDEX_GATE_UNIT_JAVA relocates that binary for the regression stubs only;
# production resolves the exact binary the unit runs.
unit_java_version() {
  local unit_java="${MODDEX_GATE_UNIT_JAVA:-/usr/bin/java}"
  printf '%s' "$("$unit_java" -version 2>&1 | sed -n '1s/.*version "\([0-9][0-9]*\).*/\1/p' || true)"
}

# Gate-host preparation (GitHub-runner-specific): pins the UNIT java
# (/usr/bin/java) to Java 17 (or newer) BEFORE the installer starts the
# service. Runner images preconfigure several update-alternatives javas and
# select them independently of the shell PATH; a fresh install then
# crash-looped the backend with UnsupportedClassVersionError (Java 11 runtime
# for Java 17 classes) while systemd kept reporting 'activating'. The bundled
# installer's own apt install cannot fix the selection, and verifying the
# runtime version is issue #621, not the gate's scope. A clean host whose
# /usr/bin/java already reports >= 17 is left completely untouched (no apt, no
# alternatives change). The alternatives change needs root: GitHub runners
# provide passwordless 'sudo -n'. Runs after digest verification and staging,
# so a broken artifact never triggers a host change.
prepare_gate_host_java() {
  local unit_java="${MODDEX_GATE_UNIT_JAVA:-/usr/bin/java}"
  local version_line candidate

  version_line="$(unit_java_version)"
  if [[ "$version_line" =~ ^[0-9]+$ && "$version_line" -ge 17 ]]; then
    log "Gate host unit java ($unit_java) is already version $version_line; no preparation needed."
    return 0
  fi

  log "Gate host unit java ($unit_java) reports version ${version_line:-nothing usable}; pinning a Java 17 runtime for the installation."
  need_cmd sudo

  # (a) Ensure a Java 17 runtime exists (the bundled installer installs the
  # same package again; doing it here makes a java-17 alternative available
  # for the selection below). A failing install aborts with a guided action.
  if command -v apt-get >/dev/null 2>&1; then
    if ! sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends openjdk-17-jre-headless; then
      die "The gate host java preparation could not install openjdk-17-jre-headless. Do not publish this release. Install a Java 17 (or newer) JRE on the gate host manually, point $unit_java at it with 'update-alternatives --set java <candidate>', verify with '$unit_java -version', and re-run the workflow."
    fi
  fi

  # (b) Select the registered java-17 alternative when one exists. On a real
  # host the apt package above registers /usr/lib/jvm/java-17-openjdk-*/bin/java
  # and update-alternatives re-points /usr/bin/java, the unit's binary.
  if command -v update-alternatives >/dev/null 2>&1; then
    candidate=""
    while IFS= read -r line; do
      if [[ -z "$candidate" && "$line" == *java-17* ]]; then
        candidate="$line"
      fi
    done < <(update-alternatives --list java 2>/dev/null)
    if [[ -n "$candidate" ]]; then
      log "Selecting the Java 17 alternative for the service: $candidate"
      if ! sudo -n update-alternatives --set java "$candidate"; then
        die "The gate host java preparation could not select the Java 17 alternative. Do not publish this release. Run 'sudo update-alternatives --set java <java-17-candidate>' on the gate host, verify with '$unit_java -version', and re-run the workflow."
      fi
    else
      log "No java-17 alternative is registered on the gate host; relying on the installed runtime."
    fi
  fi

  # (c) Version assert after the correction, against the unit java: class-file
  # compatibility cannot be probed without running the backend, so the major
  # version is parsed.
  version_line="$(unit_java_version)"
  if ! [[ "$version_line" =~ ^[0-9]+$ && "$version_line" -ge 17 ]]; then
    die "The gate host java preparation could not select a Java 17 (or newer) runtime for $unit_java: it reports ${version_line:-nothing usable}. Do not publish this release. Install a Java 17 JRE on the gate host, point $unit_java at it with 'update-alternatives --set java <candidate>', verify with '$unit_java -version', and re-run the workflow."
  fi
  log "Gate host java preparation completed: $unit_java reports version $version_line."
}

run_install() {
  local install_script="${MODDEX_GATE_INSTALL_SCRIPT:-$RELEASE_DIR/download.sh}"

  need_cmd bash
  [[ -f "$install_script" ]] ||
    die "The installation entry point ($install_script) is missing. The published release must contain download.sh; re-prepare the release artifacts and re-run the workflow."
  # VERSION pins the release tag: the staged bundle VERSION must match, which
  # the downloader enforces before the bundled installer runs. --mode local
  # binds the backend to 127.0.0.1 for the reachability check below. The
  # installer re-executes with sudo by itself when it is not run as root.
  # Release directory, downloader path and stage root are absolute (resolved
  # once at startup), so this call is independent of the working directory;
  # the gate never changes directories here (a previous version resolved the
  # relative downloader path after cd-ing into the release directory and
  # failed: "bash: release/download.sh: No such file or directory").
  if ! VERSION="$GATE_TAG" bash "$install_script" \
      --install-staged "$GATE_STAGE_ROOT" --mode local; then
    die "The bundled installer failed on the fresh gate host. Do not publish this release. Read the installer output above for the failing step, fix the bundle or the host condition (for example a missing package or an occupied installation path) and re-run the workflow."
  fi
  log "Bundled installer completed (mode local, systemd service enabled)."
}

# Dumps the diagnosis sources of a failed backend probe into the workflow log:
# service state, installed unit, environment file keys, TCP listeners, the
# service's log files, the journal, and one verbose probe attempt. Every
# source is best-effort and bounded: a failing or unavailable source is
# reported as such and never aborts the gate, so the dump always completes
# before the error message is printed. Sources contain no secrets (see the
# allow-list below), so the dump is safe for the workflow log.
dump_backend_diagnosis() {
  local address="$1" port="$2" url="$3" line capture

  diag "--- backend diagnosis for http://${address}:${port} ---"

  need_cmd systemctl
  diag "service state: $(systemctl is-active moddex-backend.service 2>&1)"
  if ! capture="$(systemctl status moddex-backend.service --no-pager 2>&1)"; then
    : # the status text is dumped either way; a failing call is still evidence
  fi
  if [[ -z "$capture" ]]; then
    diag "status: unavailable on this host"
  fi
  while IFS= read -r line; do diag "status: $line"; done <<< "$capture"

  if ! capture="$(systemctl cat moddex-backend.service 2>&1)"; then
    :
  fi
  if [[ -z "$capture" ]]; then
    diag "unit: unavailable on this host"
  fi
  while IFS= read -r line; do diag "unit: $line"; done <<< "$capture"

  # The installer's environment file carries only TLS flags, TLS file paths,
  # and TLS metadata. Only allow-listed non-secret keys are echoed with their
  # values; MODDEX_TLS_KEYSTORE_PASSWORD and any unrecognized key are reduced
  # to the key name, so a secret can never reach the workflow log.
  local env_file="/etc/moddex/moddex.env"
  if [[ -f "$env_file" ]]; then
    while IFS= read -r line; do
      case "$line" in
        MODDEX_TLS_ENABLED=* | SERVER_ADDRESS=* | SERVER_PORT=* | \
        MODDEX_TLS_CERT_FILE=* | MODDEX_TLS_KEY_FILE=* | MODDEX_TLS_KEYSTORE=* | \
        MODDEX_TLS_KEYSTORE_TYPE=*) diag "env: $line" ;;
        *"="*) diag "env: ${line%%=*}=<value redacted>" ;;
        "") ;;
        *) diag "env: (unparsable line)" ;;
      esac
    done < "$env_file"
  else
    diag "env: $env_file not present (plain HTTP installation)"
  fi

  if command -v ss >/dev/null 2>&1; then
    if capture="$(ss -ltnp 2>/dev/null | grep -F ":${port} ")"; then
      while IFS= read -r line; do diag "listener: $line"; done <<< "$capture"
    else
      diag "listener: nothing listening on port ${port}; all TCP listeners follow"
      if ! capture="$(ss -ltnp 2>/dev/null)"; then
        capture=""
      fi
      if [[ -z "$capture" ]]; then
        diag "listener(all): ss returned no listeners"
      fi
      while IFS= read -r line; do diag "listener(all): $line"; done <<< "$capture"
    fi
  else
    diag "listener: ss unavailable on this host"
  fi

  local log_source
  for log_source in /var/lib/moddex/logs/backend.err.log /var/lib/moddex/logs/backend.out.log; do
    if [[ -f "$log_source" ]]; then
      diag "--- $log_source (last 50 lines) ---"
      if ! capture="$(tail -n 50 "$log_source" 2>/dev/null)"; then
        capture=""
      fi
      if [[ -z "$capture" ]]; then
        diag "log: (empty or unreadable)"
      fi
      while IFS= read -r line; do diag "log: $line"; done <<< "$capture"
    else
      diag "$log_source not present"
    fi
  done

  if command -v journalctl >/dev/null 2>&1; then
    if ! capture="$(journalctl -u moddex-backend.service --no-pager -n 100 2>&1)"; then
      : # journalctl's own error text is dumped as evidence either way
    fi
    if [[ -z "$capture" ]]; then
      diag "journal: no entries"
    fi
    while IFS= read -r line; do diag "journal: $line"; done <<< "$capture"
  else
    diag "journal: journalctl unavailable on this host"
  fi

  diag "last probe attempt:"
  if ! capture="$(curl -v --max-time 10 "$url" 2>&1)"; then
    : # curl's verdict (refused, timeout, HTTP status) is the evidence
  fi
  if [[ -z "$capture" ]]; then
    diag "curl: no output"
  fi
  while IFS= read -r line; do diag "curl: $line"; done <<< "$capture"
  diag "--- end of backend diagnosis ---"
}

verify_service() {
  local unit_file="${MODDEX_GATE_UNIT_FILE:-/etc/systemd/system/moddex-backend.service}"
  local timeout="${MODDEX_GATE_SERVICE_TIMEOUT:-180}" line port="" address="" url body deadline

  [[ -f "$unit_file" ]] ||
    die "The installed systemd unit ($unit_file) was not found after the installation. Do not publish this release. Check the installer output above for the unit installation step and re-run the workflow."
  while IFS= read -r line; do
    case "$line" in
      Environment=SERVER_PORT=*) port="${line#Environment=SERVER_PORT=}" ;;
      Environment=SERVER_ADDRESS=*) address="${line#Environment=SERVER_ADDRESS=}" ;;
    esac
  done < "$unit_file"
  [[ "$port" =~ ^[0-9]+$ ]] ||
    die "The installed systemd unit does not declare a numeric SERVER_PORT, so the backend address cannot be determined. Do not publish this release. Compare the unit with packaging/systemd/moddex-backend.service and re-run the workflow."
  # With --mode local the installer binds 127.0.0.1; a 0.0.0.0 address is
  # probed on the loopback interface of the same host.
  address="${address:-127.0.0.1}"
  if [[ "$address" == "0.0.0.0" ]]; then
    address="127.0.0.1"
  fi
  url="http://${address}:${port}/api/v1/setup/status"

  need_cmd systemctl
  need_cmd curl
  need_cmd sleep
  log "Waiting for the moddex-backend service (timeout ${timeout}s) ..."
  deadline=$(( SECONDS + timeout ))
  while :; do
    if systemctl is-active moddex-backend.service >/dev/null 2>&1; then
      log "Service moddex-backend.service is active."
      break
    fi
    if (( SECONDS >= deadline )); then
      dump_backend_diagnosis "$address" "$port" "$url"
      die "The moddex-backend service did not become active within ${timeout}s on the fresh gate host. Do not publish this release. The diagnosis above shows the service state, unit, listeners, log files, journal and probe verdict. Fix the bundle or unit and re-run the workflow."
    fi
    sleep 5
  done

  deadline=$(( SECONDS + timeout ))
  body=""
  while :; do
    if body="$(curl -fsS --max-time 10 "$url" 2>/dev/null)"; then
      break
    fi
    if (( SECONDS >= deadline )); then
      dump_backend_diagnosis "$address" "$port" "$url"
      die "The backend did not answer on $url within ${timeout}s on the fresh gate host. Do not publish this release. The diagnosis above shows the service state, unit, listeners, log files, journal and probe verdict (for example whether the port is already occupied). Fix the bundle and re-run the workflow."
    fi
    sleep 5
  done
  if ! printf '%s' "$body" | grep -q '"setupRequired"[[:space:]]*:[[:space:]]*true'; then
    die "The backend answered on $url with $body - setupRequired must be true on a fresh installation. Do not publish this release. Investigate why the fresh host already reports a configured administrator (configuration directories or data directory not empty) and re-run the workflow."
  fi
  log "Backend reachable at $url (setup status: $body)."
}

# --- Argument and artifact checks -------------------------------------------

if [[ -z "$RELEASE_DIR" || -z "$GATE_TAG" ]]; then
  die "Usage: release-gate.sh <release-dir> <tag>. Provide the release artifact directory and the release tag, then re-run the gate."
fi
[[ "$GATE_TAG" =~ ^[A-Za-z0-9._-]+$ && "$GATE_TAG" != latest ]] ||
  die "Invalid release tag '$GATE_TAG'. Use a concrete tag (vX.Y.Z) and re-run the gate."
[[ -d "$RELEASE_DIR" ]] ||
  die "Release directory '$RELEASE_DIR' does not exist or is not a directory. Run the release artifact preparation step first, then re-run the gate."

# The release workflow passes the release directory relative to the repository
# root ('release'). Resolve it once and absolutely, so every later use — most
# importantly the downloader invocation after staging and installation changed
# their directory contexts — is independent of the working directory. Without
# this, a relative downloader path was resolved after a cd into the release
# directory and the installer step failed on the fresh runner host.
if ! RELEASE_DIR="$(cd "$RELEASE_DIR" && pwd -P)"; then
  die "Cannot access the release directory to resolve it as an absolute path. Run the gate from a location where the release artifacts are readable, then re-run the workflow."
fi

archive_name="moddex-${GATE_TAG}-linux-amd64.tar.gz"
archive="$RELEASE_DIR/$archive_name"
for required in \
  "$archive" \
  "$RELEASE_DIR/$archive_name.sha256" \
  "$RELEASE_DIR/moddex-${GATE_TAG}-linux-amd64.zip" \
  "$RELEASE_DIR/moddex-${GATE_TAG}-linux-amd64.zip.sha256" \
  "$RELEASE_DIR/download.sh" \
  "$RELEASE_DIR/download.sh.sha256" \
  "$RELEASE_DIR/SHA256SUMS"; do
  [[ -f "$required" ]] ||
    die "Release artifact missing: $required. The gate runs against exactly the artifact set that gets published; re-prepare the release artifacts and re-run the workflow."
done

# --- Staging root: caller-owned when provided, otherwise gate-owned ---------
GATE_STAGE_ROOT="${MODDEX_GATE_STAGE_ROOT:-}"
GATE_OWNS_STAGE_ROOT=0
if [[ -z "$GATE_STAGE_ROOT" ]]; then
  need_cmd mktemp
  GATE_STAGE_ROOT="$(mktemp -d -t moddex-release-gate.XXXXXX)"
  GATE_OWNS_STAGE_ROOT=1
else
  # A caller-provided stage root may be relative and may not exist yet; both
  # must not depend on the working directory of the later install step (and
  # of the EXIT-trap cleanup).
  if ! mkdir -p "$GATE_STAGE_ROOT"; then
    die "Cannot create the staging root '$GATE_STAGE_ROOT'. Provide a writable staging directory and re-run the workflow."
  fi
  if ! GATE_STAGE_ROOT="$(cd "$GATE_STAGE_ROOT" && pwd -P)"; then
    die "Cannot access the staging root to resolve it as an absolute path. Provide a writable staging directory and re-run the workflow."
  fi
fi
cleanup() {
  if [[ "$GATE_OWNS_STAGE_ROOT" -eq 1 && -d "$GATE_STAGE_ROOT" && ! -L "$GATE_STAGE_ROOT" ]]; then
    rm -rf -- "$GATE_STAGE_ROOT"
  fi
}
trap cleanup EXIT

log "Release gate started for $GATE_TAG (release directory: $RELEASE_DIR)"
verify_published_digests "$RELEASE_DIR" "$GATE_TAG"

extract_dir="$GATE_STAGE_ROOT/bundle"
stage_bundle "$archive" "$extract_dir"
staged_version="$(cat "$extract_dir/VERSION" 2>/dev/null)" ||
  die "Cannot read the staged bundle VERSION after extraction. Do not publish this release. Inspect the archive ('tar -tzf $archive_name') and re-run the workflow."
[[ "$staged_version" == "$GATE_TAG" ]] ||
  die "Staged bundle VERSION ($staged_version) does not match the release tag ($GATE_TAG). Do not publish this release. Rebuild the bundle with 'scripts/build-bundle.sh' and re-run the workflow."
log "Staged bundle VERSION matches the release tag ($staged_version)."

prepare_gate_host_java
run_install
verify_service

log "Release gate passed: published digests verified, bundle installed on a fresh host, backend active and reachable with setup pending."
