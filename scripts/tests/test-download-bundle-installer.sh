#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DIR="$PROJECT_ROOT/.download-bundle-installer-test.$$"
BASH_BIN="$(command -v bash)"
RM_BIN="$(command -v rm)"
CHMOD_BIN="$(command -v chmod)"
SED_BIN="$(command -v sed)"
MKDIR_BIN="$(command -v mkdir)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ ! -e "$TEST_DIR" ]] || fail "Test directory already exists: $TEST_DIR"
mkdir "$TEST_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir "$TEST_DIR/bin"

for command in jq tar sha256sum; do
  command -v "$command" >/dev/null 2>&1 || fail "Missing test dependency: $command"
done
TAR_BIN="$(command -v tar)"
# A closed PATH prevents the production installer from reaching host commands.
for command in bash jq gzip sha256sum cat cp dirname basename grep; do
  ln -s "$(command -v "$command")" "$TEST_DIR/bin/$command"
done

# The host lock (issue #108) is acquired before the installer's package
# steps: the closed fixture PATH needs flock (real where available, otherwise
# a perl stub with the same kernel-lock semantics) and the metadata timestamp.
if command -v flock >/dev/null 2>&1; then
  ln -s "$(command -v flock)" "$TEST_DIR/bin/flock"
else
  cat > "$TEST_DIR/bin/flock" <<'PERL'
#!/usr/bin/perl
use strict;
use warnings;
use Fcntl qw(:flock);
my $op = '';
my $fd;
foreach my $arg (@ARGV) {
  if ($arg eq '-n' || $arg eq '-u' || $arg eq '-s' || $arg eq '-x') { $op ||= $arg; }
  elsif ($arg =~ /^\d+$/) { $fd = $arg; }
  else { exit 91; }
}
exit 91 unless defined $fd;
open(my $fh, '+<&=', $fd) or exit 1;
if ($op eq '-u') { flock($fh, LOCK_UN) or exit 1; exit 0; }
exit 0 if flock($fh, LOCK_EX | LOCK_NB);
exit 1;
PERL
  chmod +x "$TEST_DIR/bin/flock"
fi
ln -s "$(command -v date)" "$TEST_DIR/bin/date"

cat > "$TEST_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
url=""
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -fsSL) shift ;;
    -o) output="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) printf 'Unexpected curl argument: %s\n' "$1" >&2; exit 90 ;;
  esac
done

printf '%s\n' "$url" >> "$TEST_CASE_DIR/curl.log"
case "$url" in
  "$TEST_API_URL")
    [[ -z "$output" ]]
    if [[ "$TEST_DOWNLOAD_VARIANT" == metadata-download ]]; then
      printf 'unexpected-token-secret\n' >&2
      printf '{"token":"unexpected-token-secret",'
      exit 22
    fi
    cat "$TEST_CASE_DIR/release.json"
    ;;
  "https://releases.invalid/$TEST_RELEASE_TAG/$TEST_ASSET_NAME")
    [[ -n "$output" ]]
    if [[ "$TEST_DOWNLOAD_VARIANT" == bundle-download ]]; then
      printf 'partial bundle\n' > "$output"
      printf 'unexpected-token-secret\n' >&2
      exit 22
    fi
    cp "$TEST_CASE_DIR/$TEST_ASSET_NAME" "$output"
    ;;
  "https://releases.invalid/$TEST_RELEASE_TAG/$TEST_ASSET_NAME.sha256")
    [[ -n "$output" ]]
    if [[ "$TEST_DOWNLOAD_VARIANT" == checksum-download ]]; then
      printf 'partial checksum\n' > "$output"
      printf 'unexpected-token-secret\n' >&2
      exit 22
    fi
    cp "$TEST_CASE_DIR/$TEST_ASSET_NAME.sha256" "$output"
    case "$TEST_DOWNLOAD_VARIANT" in
      checksum-wrong-filename|checksum-extra-record)
        cp "$TEST_CASE_DIR/unrelated.txt" "${output%/*}/unrelated.txt"
        ;;
    esac
    ;;
  *)
    printf 'Unexpected URL; network access is disabled: %s\n' "$url" >&2
    exit 90
    ;;
esac
SH

# Confine the downloader's scratch space to this test's project-local directory.
# The stub creates the scratch root with the real mkdir so the recorded
# destination log below only carries the downloader's own directory creations.
cat > "$TEST_DIR/bin/mktemp" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" -eq 3 && "$1" == "-d" && "$2" == "-t" && "$3" == "moddex-bundle.XXXXXX" ]]
[[ -n "${TEST_MKDIR_BIN:-}" ]] || exit 90
"$TEST_MKDIR_BIN" "$TEST_CASE_DIR/extracted bundle"
printf '%s\n' "$TEST_CASE_DIR/extracted bundle"
SH

# Record the downloader's directory creations outside the EXIT-cleaned scratch
# directory, so the pre-extraction abort can be proven against actual mkdir
# calls instead of post-run directory state (the EXIT trap removes both).
cat > "$TEST_DIR/bin/mkdir" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'mkdir %s\n' "$*" >> "$TEST_CASE_DIR/destination.mkdirs"
[[ "$*" == "-p $TEST_CASE_DIR/extracted bundle/bundle" ]] || exit 91
exec "$TEST_MKDIR_BIN" "$@"
SH

# Keep evidence outside the downloader's EXIT-cleaned scratch directory while
# executing the real tar against only this case's archive, its read-only
# validation listings and the isolated extraction path.
cat > "$TEST_DIR/bin/tar" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
archive="$TEST_CASE_DIR/extracted bundle/$TEST_ASSET_NAME"
case "$1" in
  -tzf|-tvzf)
    [[ "$#" -eq 2 && "$2" == "$archive" ]] || exit 91
    printf '%s\n' "$1" >> "$TEST_CASE_DIR/validation.listings"
    exec "$TEST_TAR_BIN" "$@"
    ;;
  --no-same-owner)
    [[ "$#" -eq 5 && "$2" == -C &&
      "$3" == "$TEST_CASE_DIR/extracted bundle/bundle" && "$4" == -xzf &&
      "$5" == "$archive" ]] || exit 91
    printf 'attempt\n' >> "$TEST_CASE_DIR/extraction.attempted"
    printf '%s\n' "$@" >> "$TEST_CASE_DIR/extraction.args"
    "$TEST_TAR_BIN" "$@"
    printf 'completed\n' >> "$TEST_CASE_DIR/extraction.completed"
    ;;
  *) exit 91 ;;
esac
SH
chmod +x "$TEST_DIR/bin/curl" "$TEST_DIR/bin/mktemp" "$TEST_DIR/bin/tar" "$TEST_DIR/bin/mkdir"

cat > "$TEST_DIR/bin/install" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'install %s\n' "$*" >> "$TEST_CASE_DIR/host-commands"
directory=no
mode=""
while [[ "$1" == -* ]]; do
  case "$1" in
    -d) directory=yes; shift ;;
    -m) mode="$2"; shift 2 ;;
    -o|-g) [[ "$2" == moddex ]]; shift 2 ;;
    *) exit 91 ;;
  esac
done
if [[ "$directory" == yes ]]; then
  [[ "$#" -eq 1 && "$1" == "$TEST_CASE_DIR/host/"* ]] || exit 91
  "$TEST_MKDIR_BIN" -p "$1"
  target="$1"
else
  [[ "$#" -eq 2 && "$1" == "$TEST_CASE_DIR/extracted bundle/bundle/"* &&
    "$2" == "$TEST_CASE_DIR/host/"* ]] || exit 91
  cp "$1" "$2"
  target="$2"
fi
"$TEST_CHMOD_BIN" "$mode" "$target"
SH

cat > "$TEST_DIR/bin/host-command" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
command="${0##*/}"
printf '%s %s\n' "$command" "$*" >> "$TEST_CASE_DIR/host-commands"
case "$command:$*" in
  'apt-get:update -y'|'apt-get:install -y --no-install-recommends openjdk-17-jre-headless rsync') ;;
  'id:-u moddex') printf '1234\n' ;;
  'systemctl:daemon-reload') ;;
  'systemctl:enable --now moddex-backend.service') exit "$TEST_INSTALLER_STATUS" ;;
  'systemctl:is-active moddex-backend')
    if [[ "${TEST_CLI_SERVICE_STATUS:-0}" -eq 0 ]]; then
      printf 'active\n'
    else
      printf 'inactive\n'
      exit "$TEST_CLI_SERVICE_STATUS"
    fi
    ;;
  'ufw:allow 18080/tcp') ;;
  "chown:moddex:moddex $TEST_CASE_DIR/host/opt/moddex/app.jar") ;;
  "rsync:-a --delete --chown=moddex:moddex $TEST_CASE_DIR/extracted bundle/bundle/frontend/ $TEST_CASE_DIR/host/var/lib/moddex/ui/") ;;
  "sed:-i s/^Environment=SERVER_ADDRESS=.*/Environment=SERVER_ADDRESS=0.0.0.0/ $TEST_CASE_DIR/host/etc/systemd/system/moddex-backend.service"|\
  "sed:-i s/^Environment=SERVER_PORT=.*/Environment=SERVER_PORT=18080/ $TEST_CASE_DIR/host/etc/systemd/system/moddex-backend.service")
    # BSD sed has no portable -i; redirect like test-install-tls.sh does.
    "$TEST_SED_BIN" "$2" "$3" > "$3.sed-fixture"
    cat "$3.sed-fixture" > "$3"
    "$TEST_RM_BIN" -f -- "$3.sed-fixture" ;;
  *) printf 'Unexpected host command blocked.\n' >&2; exit 91 ;;
esac
SH
for command in apt-get id systemctl ufw chown rsync sed java sudo useradd git; do
  ln -s host-command "$TEST_DIR/bin/$command"
done

cat > "$TEST_DIR/bin/rm" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" -eq 2 && "$1" == -rf && "$2" == "$TEST_CASE_DIR/extracted bundle" ]] || exit 91
exec "$TEST_RM_BIN" "$@"
SH

cat > "$TEST_DIR/bin/chmod" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" -eq 2 ]] || exit 91
case "$*" in
  "+x $TEST_CASE_DIR/extracted bundle/bundle/scripts/install.sh"|\
  "0644 $TEST_CASE_DIR/host/opt/moddex/VERSION") exec "$TEST_CHMOD_BIN" "$@" ;;
  *) exit 91 ;;
esac
SH
chmod +x "$TEST_DIR/bin/install" "$TEST_DIR/bin/host-command" "$TEST_DIR/bin/rm" "$TEST_DIR/bin/chmod"

mkdir "$TEST_DIR/build-bin"
for command in bash sh tar gzip mkdir find cp sha256sum dirname head; do
  ln -s "$(command -v "$command")" "$TEST_DIR/build-bin/$command"
done
cat > "$TEST_DIR/build-bin/rm" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" -eq 2 && "$1" == -rf ]] || exit 91
if [[ "$2" != "$TEST_CASE_DIR/release/build" &&
  !( "$PWD" == "$TEST_CASE_DIR/release/frontend" && "$2" == dist ) ]]; then
  printf 'Unexpected build deletion blocked.\n' >&2
  exit 91
fi
exec "$TEST_RM_BIN" "$@"
SH
cat > "$TEST_DIR/build-bin/npm" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$PWD" == "$TEST_CASE_DIR/release/frontend" ]] || exit 91
printf 'npm %s\n' "$*" >> "$TEST_CASE_DIR/build-commands"
case "$*" in
  ci) ;;
  'run build -- --configuration production')
    mkdir -p dist/moddex-frontend/browser
    printf 'frontend:%s\n' "$TEST_RELEASE_TAG" > dist/moddex-frontend/browser/index.html
    ;;
  *) printf 'Unexpected npm command blocked.\n' >&2; exit 91 ;;
esac
SH
cat > "$TEST_DIR/build-bin/no-runtime" <<'SH'
#!/usr/bin/env bash
printf 'Unexpected runtime invocation blocked.\n' >&2
exit 91
SH
ln -s no-runtime "$TEST_DIR/build-bin/java"
ln -s no-runtime "$TEST_DIR/build-bin/node"
chmod +x "$TEST_DIR/build-bin/rm" "$TEST_DIR/build-bin/npm" "$TEST_DIR/build-bin/no-runtime"

build_release() {
  local case_dir="$1" tag="$2" asset_name="$3" required
  cp "$PROJECT_ROOT/scripts/build-bundle.sh" "$case_dir/release/scripts/build-bundle.sh"
  cp "$PROJECT_ROOT/scripts/download.sh" "$case_dir/release/scripts/download.sh"
  printf '<project/>\n' > "$case_dir/release/backend/pom.xml"
  printf '{}\n' > "$case_dir/release/frontend/package.json"
  printf '{}\n' > "$case_dir/release/frontend/package-lock.json"
  printf '0.0.0-source-checkout\n' > "$case_dir/release/VERSION"
  printf 'not-the-built-backend\n' > "$case_dir/release/backend/Moddex-Backend.jar"
  printf 'not-the-built-frontend\n' > "$case_dir/release/frontend/index.html"
  cat > "$case_dir/release/backend/mvnw" <<'SH'
#!/bin/sh
set -eu
[ "$PWD" = "$TEST_CASE_DIR/release/backend" ] || exit 91
[ "$*" = '-B -ntp -Pprod -DskipTests clean package' ] || exit 91
printf 'mvnw %s\n' "$*" >> "$TEST_CASE_DIR/build-commands"
mkdir -p target
printf 'backend:%s\n' "$TEST_RELEASE_TAG" > target/Moddex-Backend-fixture.jar
SH
  if ! (
    cd "$case_dir/caller"
    PATH="$TEST_DIR/build-bin" VERSION="$tag" TEST_RELEASE_TAG="$tag" \
      TEST_CASE_DIR="$case_dir" TEST_RM_BIN="$RM_BIN" \
      "$BASH_BIN" "$case_dir/release/scripts/build-bundle.sh"
  ) > "$case_dir/build-output" 2>&1; then
    cat "$case_dir/build-output" >&2
    fail "Real bundle builder failed for $tag"
  fi
  grep -Fxq 'mvnw -B -ntp -Pprod -DskipTests clean package' "$case_dir/build-commands" ||
    fail "Bundle builder did not run the mocked Maven build"
  grep -Fxq 'npm ci' "$case_dir/build-commands" ||
    fail "Bundle builder did not install frontend fixture dependencies"
  grep -Fxq 'npm run build -- --configuration production' "$case_dir/build-commands" ||
    fail "Bundle builder did not build the frontend fixture"
  cp "$case_dir/release/build/$asset_name" "$case_dir/$asset_name"
  cp "$case_dir/release/build/$asset_name.sha256" "$case_dir/$asset_name.sha256"
  (cd "$case_dir" && sha256sum -c "$asset_name.sha256") > "$case_dir/build-checksum"
  tar -tzf "$case_dir/$asset_name" > "$case_dir/archive-files"
  for required in backend/Moddex-Backend.jar backend/bin/moddex frontend/index.html \
    scripts/install.sh scripts/download.sh packaging/systemd/moddex-backend.service VERSION; do
    grep -Fxq "./$required" "$case_dir/archive-files" ||
      fail "Built archive is missing $required"
  done
  [[ "$(tar -xOzf "$case_dir/$asset_name" ./VERSION)" == "$tag" ]] ||
    fail "Built archive VERSION does not match the release tag"
  [[ "$(tar -xOzf "$case_dir/$asset_name" ./backend/Moddex-Backend.jar)" == "backend:$tag" ]] ||
    fail "Built archive does not contain the Maven-produced backend"
  [[ "$(tar -xOzf "$case_dir/$asset_name" ./frontend/index.html)" == "frontend:$tag" ]] ||
    fail "Built archive does not contain the npm-produced frontend"
  tar -xOzf "$case_dir/$asset_name" ./backend/bin/moddex > "$case_dir/archive-cli"
  cmp "$case_dir/release/backend/bin/moddex" "$case_dir/archive-cli" ||
    fail "Built archive contains the wrong CLI helper"
}

# Builds archives that mimic the core installation-bundle layout plus one
# malicious entry. GNU tar sanitizes member names at create time
# (safer_name_suffix strips leading ".." components and, without -P, leading
# slashes), so the traversal and absolute fixtures pass -P to store their
# names verbatim; bsdtar stores them as typed either way (verified). Link
# targets are stored as given by both. The core entries keep the structure
# check quiet, so each case exercises the specific security rejection. The
# real checksum is computed afterwards so the case exercises the archive
# validation gate, not the checksum gate.
build_malicious_archive() {
  local case_dir="$1" asset_name="$2" variant="$3"
  local malcontent="$case_dir/malcontent"
  local payload="$malcontent/payload"
  mkdir -p "$payload/backend" "$payload/frontend" "$payload/scripts" \
    "$payload/packaging/systemd"
  printf 'fixture-version\n' > "$payload/VERSION"
  printf 'fixture-jar\n' > "$payload/backend/Moddex-Backend.jar"
  printf 'fixture-frontend\n' > "$payload/frontend/index.html"
  printf '#!/usr/bin/env bash\n' > "$payload/scripts/install.sh"
  printf 'fixture-unit\n' > "$payload/packaging/systemd/moddex-backend.service"
  printf 'outside the extraction root\n' > "$case_dir/escape-target"
  case "$variant" in
    absolute-entry)
      printf 'absolute entry payload\n' > "$malcontent/absolute-marker"
      tar -P -C "$payload" -czf "$case_dir/$asset_name" . \
        "$malcontent/absolute-marker"
      ;;
    traversal-entry)
      printf 'traversal payload\n' > "$malcontent/escape-target"
      tar -P -C "$payload" -czf "$case_dir/$asset_name" . ../escape-target
      ;;
    escaping-link-absolute)
      ln -s /etc/moddex/moddex.env "$payload/escaping-link"
      tar -C "$payload" -czf "$case_dir/$asset_name" .
      ;;
    escaping-link-relative)
      ln -s ../escape-target "$payload/escaping-link"
      tar -C "$payload" -czf "$case_dir/$asset_name" .
      ;;
    *) fail "Unknown malicious archive variant: $variant" ;;
  esac
}

check_case() {
  local name="$1" requested_version="$2" tag="$3" missing="$4" installer_status="$5"
  local neighbor="${6:-no}" kind="${7:-stub}" case_dir asset_name api_url expected_status status cli_path
  local verification="${8:-valid}" verification_failure=no expected_error expected_requests
  local malware="${9:-none}" pre_extract_abort=no
  local -a runner
  case_dir="$TEST_DIR/$name"
  asset_name="moddex-$tag-linux-amd64.tar.gz"
  api_url="https://api.github.com/repos/fixture-owner/fixture-repo/releases"
  if [[ "$requested_version" == latest ]]; then
    api_url+="/latest"
  else
    api_url+="/tags/$requested_version"
  fi

  mkdir -p "$case_dir/caller" "$case_dir/release/backend" "$case_dir/release/frontend" \
    "$case_dir/release/scripts" "$case_dir/release/packaging/systemd"
  cp "$PROJECT_ROOT/scripts/download.sh" "$case_dir/caller/download.sh"
  printf 'backend:%s\n' "$tag" > "$case_dir/release/backend/Moddex-Backend.jar"
  printf 'frontend:%s\n' "$tag" > "$case_dir/release/frontend/index.html"
  printf 'unit:%s\n' "$tag" > "$case_dir/release/packaging/systemd/moddex-backend.service"
  printf '%s\n' "$tag" > "$case_dir/release/VERSION"
  printf 'v9.9.9-caller-checkout\n' > "$case_dir/caller/VERSION"

  if [[ "$kind" != stub ]]; then
    # Track installer entry, bypass privilege gating/Bash 3's missing lowercase
    # operator, and redirect host paths. Version writer and CLI logic are unchanged.
    TEST_CASE_DIR="$case_dir" awk '
      $0 == "if [[ \"${EUID:-$(id -u)}\" -ne 0 ]]; then" {
        print ": > \"$TEST_CASE_DIR/installer.entered\""
        print "if false; then"
        root_replaced = 1
        next
      }
      $0 == "MODE=\"${MODE,,}\"" {
        print "MODE=\"${MODE}\""
        mode_replaced = 1
        next
      }
      {
        gsub("/opt/moddex", ENVIRON["TEST_CASE_DIR"] "/host/opt/moddex")
        gsub("/var/lib/moddex", ENVIRON["TEST_CASE_DIR"] "/host/var/lib/moddex")
        gsub("/etc/moddex", ENVIRON["TEST_CASE_DIR"] "/host/etc/moddex")
        gsub("/etc/systemd/system", ENVIRON["TEST_CASE_DIR"] "/host/etc/systemd/system")
        gsub("/run/systemd/system", ENVIRON["TEST_CASE_DIR"] "/host/run/systemd/system")
        gsub("/usr/local/bin", ENVIRON["TEST_CASE_DIR"] "/host/usr/local/bin")
        print
      }
      END { if (!root_replaced || !mode_replaced) exit 1 }
    ' "$PROJECT_ROOT/scripts/install.sh" > "$case_dir/release/scripts/install.sh"
    # The systemd runtime marker must exist so the installer's preflight
    # accepts this fixture as a systemd host.
    mkdir -p "$case_dir/release/backend/bin" "$case_dir/host/etc/systemd/system" \
      "$case_dir/host/run/systemd/system"
    # CLI logic is unchanged; only host paths (version file, TLS environment
    # file, systemd unit) are redirected into this case's fixture host.
    TEST_CASE_DIR="$case_dir" awk '
      { gsub("/opt/moddex", ENVIRON["TEST_CASE_DIR"] "/host/opt/moddex")
        gsub("/etc/moddex", ENVIRON["TEST_CASE_DIR"] "/host/etc/moddex")
        gsub("/etc/systemd/system", ENVIRON["TEST_CASE_DIR"] "/host/etc/systemd/system")
        print }
    ' "$PROJECT_ROOT/backend/bin/moddex" > "$case_dir/release/backend/bin/moddex"
    cp "$PROJECT_ROOT/packaging/systemd/moddex-backend.service" \
      "$case_dir/release/packaging/systemd/moddex-backend.service"
  else
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nrelease_tag=%q\n' "$tag" \
      > "$case_dir/release/scripts/install.sh"
    cat >> "$case_dir/release/scripts/install.sh" <<'SH'
: > "$TEST_CASE_DIR/installer.entered"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bundle_root="$(cd "$script_dir/.." && pwd)"
printf '%s\n' "$@" > "$TEST_CASE_DIR/installer.args"
printf '%s\n' "$bundle_root" > "$TEST_CASE_DIR/installer.root"
printf '%s\n' "$release_tag" > "$TEST_CASE_DIR/installer.identity"

[[ "$release_tag" == "$TEST_RELEASE_TAG" ]]
[[ "$(cat "$bundle_root/VERSION")" == "$release_tag" ]]
[[ "$(cat "$bundle_root/backend/Moddex-Backend.jar")" == "backend:$release_tag" ]]
[[ "$(cat "$bundle_root/frontend/index.html")" == "frontend:$release_tag" ]]
[[ "$(cat "$bundle_root/packaging/systemd/moddex-backend.service")" == "unit:$release_tag" ]]
exit "$TEST_INSTALLER_STATUS"
SH
  fi
  chmod 0644 "$case_dir/release/scripts/install.sh"

  case "$kind" in
    manual-explicit) printf 'dev\n' > "$case_dir/release/VERSION" ;;
    manual-fail-missing) rm "$case_dir/release/VERSION" ;;
    manual-fail-invalid) printf 'unexpected-token-secret/invalid\n' > "$case_dir/release/VERSION" ;;
    production-fail-write) mkdir -p "$case_dir/host/opt/moddex/VERSION" ;;
  esac
  case "$missing" in
    installer) rm "$case_dir/release/scripts/install.sh" ;;
    unit) rm "$case_dir/release/packaging/systemd/moddex-backend.service" ;;
    version) rm "$case_dir/release/VERSION" ;;
    mismatched-version) printf 'v9.9.9-wrong-bundle\n' > "$case_dir/release/VERSION" ;;
    empty-version) : > "$case_dir/release/VERSION" ;;
    tag-*) ;;
    none) ;;
    *) fail "Unknown fixture variant: $missing" ;;
  esac
  if [[ "$malware" == internal-link ]]; then
    # A link that stays inside the bundle root is legitimate and must survive
    # the archive validation.
    ln -s backend/Moddex-Backend.jar "$case_dir/release/internal-link"
  fi
  if [[ "$kind" == built ]]; then
    build_release "$case_dir" "$tag" "$asset_name"
  elif [[ "$malware" != none && "$malware" != internal-link ]]; then
    build_malicious_archive "$case_dir" "$asset_name" "$malware"
    (cd "$case_dir" && sha256sum "$asset_name" > "$asset_name.sha256")
  else
    tar -C "$case_dir/release" -czf "$case_dir/$asset_name" .
    (cd "$case_dir" && sha256sum "$asset_name" > "$asset_name.sha256")
  fi
  cat > "$case_dir/release.json" <<JSON
{
  "tag_name": "$tag",
  "assets": [
    {
      "name": "$asset_name",
      "browser_download_url": "https://releases.invalid/$tag/$asset_name"
    },
    {
      "name": "$asset_name.sha256",
      "browser_download_url": "https://releases.invalid/$tag/$asset_name.sha256"
    }
  ]
}
JSON

  case "$missing" in
    tag-missing) jq 'del(.tag_name)' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    tag-empty) jq '.tag_name = ""' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    tag-null) jq '.tag_name = null' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    tag-number) jq '.tag_name = 123' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    tag-object) jq '.tag_name = {"token": "unexpected-token-secret"}' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    tag-array) jq '.tag_name = ["v0.1.2"]' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    tag-invalid) jq '.tag_name = "unexpected-token-secret/invalid tag\n"' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    tag-newline) jq '.tag_name += "\n"' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    tag-multiple) cat "$case_dir/release.json" "$case_dir/release.json" > "$case_dir/changed.json" ;;
    tag-latest) jq '.tag_name = "latest"' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    tag-malformed) printf '{"tag_name":"unexpected-token-secret",' > "$case_dir/changed.json" ;;
  esac
  case "$verification" in
    bundle-metadata-missing) jq 'del(.assets)' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    bundle-asset-missing) jq '.assets |= .[1:]' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    bundle-asset-duplicate) jq '.assets += [.assets[0]]' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    bundle-url-missing) jq 'del(.assets[0].browser_download_url)' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    bundle-url-null) jq '.assets[0].browser_download_url = null' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    bundle-url-empty) jq '.assets[0].browser_download_url = ""' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    bundle-url-number) jq '.assets[0].browser_download_url = 123' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    bundle-url-invalid) jq '.assets[0].browser_download_url = "file:///unexpected-token-secret"' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    checksum-asset-missing) jq '.assets |= .[:1]' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    checksum-asset-duplicate) jq '.assets += [.assets[1]]' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    checksum-asset-unrelated) jq '.assets[1].name = "unrelated.tar.gz.sha256"' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    checksum-url-missing) jq 'del(.assets[1].browser_download_url)' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    checksum-url-null) jq '.assets[1].browser_download_url = null' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    checksum-url-empty) jq '.assets[1].browser_download_url = ""' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    checksum-url-number) jq '.assets[1].browser_download_url = 123' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    checksum-url-invalid) jq '.assets[1].browser_download_url = "file:///unexpected-token-secret"' "$case_dir/release.json" > "$case_dir/changed.json" ;;
    checksum-empty) : > "$case_dir/$asset_name.sha256" ;;
    checksum-whitespace) printf ' \n' > "$case_dir/$asset_name.sha256" ;;
    checksum-malformed) printf 'unexpected-token-secret\n' > "$case_dir/$asset_name.sha256" ;;
    checksum-short) printf '%063d  %s\n' 0 "$asset_name" > "$case_dir/$asset_name.sha256" ;;
    checksum-long) printf '%065d  %s\n' 0 "$asset_name" > "$case_dir/$asset_name.sha256" ;;
    checksum-nonhex) printf '%064d  %s\n' 0 "$asset_name" | tr 0 G > "$case_dir/$asset_name.sha256" ;;
    checksum-digest-only) (cd "$case_dir" && sha256sum "$asset_name") | cut -d ' ' -f1 > "$case_dir/$asset_name.sha256" ;;
    checksum-wrong-digest) printf '%064d  %s\n' 0 "$asset_name" > "$case_dir/$asset_name.sha256" ;;
    checksum-duplicate-record)
      cat "$case_dir/$asset_name.sha256" "$case_dir/$asset_name.sha256" > "$case_dir/duplicate.sha256"
      mv "$case_dir/duplicate.sha256" "$case_dir/$asset_name.sha256"
      (cd "$case_dir" && sha256sum -c "$asset_name.sha256") > "$case_dir/duplicate-checksum"
      ;;
    checksum-wrong-filename|checksum-extra-record)
      printf 'unrelated independently checked content\n' > "$case_dir/unrelated.txt"
      if [[ "$verification" == checksum-wrong-filename ]]; then
        (cd "$case_dir" && sha256sum unrelated.txt > "$asset_name.sha256")
      else
        (cd "$case_dir" && sha256sum unrelated.txt >> "$asset_name.sha256")
      fi
      # Prove a plain sha256sum -c would accept these records, including the
      # unrelated file staged by the checksum-download fixture.
      (cd "$case_dir" && sha256sum -c "$asset_name.sha256") > "$case_dir/unrelated-checksum"
      ;;
    tampered-bundle) printf 'changed after publication\n' >> "$case_dir/$asset_name" ;;
    binary) (cd "$case_dir" && sha256sum --binary "$asset_name" > "$asset_name.sha256") ;;
    no-newline)
      printf '%s' "$(cat "$case_dir/$asset_name.sha256")" > "$case_dir/$asset_name.sha256"
      ;;
    uppercase) tr 'a-f' 'A-F' < "$case_dir/$asset_name.sha256" > "$case_dir/uppercase.sha256"
      # Only the digest is case-insensitive; preserve the bundle's filename.
      printf '%s  %s\n' "$(cut -c1-64 "$case_dir/uppercase.sha256")" "$asset_name" > "$case_dir/$asset_name.sha256"
      ;;
    valid|metadata-download|bundle-download|checksum-download) ;;
    *) fail "Unknown verification variant: $verification" ;;
  esac
  if [[ -f "$case_dir/changed.json" ]]; then
    mv "$case_dir/changed.json" "$case_dir/release.json"
  fi

  if [[ "$neighbor" == yes ]]; then
    cat > "$case_dir/caller/install.sh" <<'SH'
#!/usr/bin/env bash
printf 'Adjacent installer must not run.\n' > "$TEST_CASE_DIR/neighbor-invoked"
exit 92
SH
    chmod +x "$case_dir/caller/install.sh"
  fi

  expected_status="$installer_status"
  [[ "$missing" == none ]] || expected_status=1
  case "$verification" in
    valid|binary|no-newline|uppercase) ;;
    *) expected_status=1; verification_failure=yes ;;
  esac
  case "$malware" in
    none|internal-link) ;;
    *) expected_status=1; pre_extract_abort=yes ;;
  esac
  case "$missing" in
    none|mismatched-version|empty-version) ;;
    # Invalid release metadata aborts before the download; archives missing a
    # required bundle entry must be rejected by the pre-extraction validation.
    tag-*|installer|unit|version) pre_extract_abort=yes ;;
    *) fail "Unknown fixture variant: $missing" ;;
  esac
  runner=("$BASH_BIN" ./download.sh --owner fixture-owner --repo fixture-repo
    --version "$requested_version" --mode lan --port 18080 --version v9.9.9-caller-override)
  if [[ "$kind" == manual-* ]]; then
    mkdir -p "$case_dir/extracted bundle/bundle"
    tar -C "$case_dir/extracted bundle/bundle" -xzf "$case_dir/$asset_name"
    runner=("$BASH_BIN" "$case_dir/extracted bundle/bundle/scripts/install.sh" --mode lan --port 18080)
    case "$kind" in
      manual-explicit) runner+=(--version "$tag") ;;
      manual-fail-empty) runner+=(--version "") ;;
      manual-fail-alias) runner+=(--version latest) ;;
    esac
  fi
  if (
    cd "$case_dir/caller"
    PATH="$TEST_DIR/bin" VERSION=dev INSTALL_VERSION=v9.9.9-environment ASSET_SUFFIX=linux-amd64.tar.gz \
      TEST_CASE_DIR="$case_dir" TEST_API_URL="$api_url" TEST_RELEASE_TAG="$tag" \
      TEST_ASSET_NAME="$asset_name" TEST_INSTALLER_STATUS="$installer_status" \
      TEST_DOWNLOAD_VARIANT="$verification" \
      MODDEX_LOCK_FILE="$case_dir/host/run/moddex/install.lock" \
      TEST_RM_BIN="$RM_BIN" TEST_CHMOD_BIN="$CHMOD_BIN" TEST_TAR_BIN="$TAR_BIN" \
      TEST_SED_BIN="$SED_BIN" TEST_MKDIR_BIN="$MKDIR_BIN" \
      "${runner[@]}"
  ) > "$case_dir/output" 2>&1; then
    status=0
  else
    status=$?
  fi
  if [[ "$kind" == manual-* ]]; then
    rm -rf "$case_dir/extracted bundle"
    [[ ! -e "$case_dir/curl.log" ]] || fail "$name: manual installation accessed the network"
  fi

  if [[ "$status" -ne "$expected_status" ]]; then
    cat "$case_dir/output" >&2
    fail "$name: expected exit $expected_status, got $status"
  fi
  [[ ! -e "$case_dir/extracted bundle" ]] || fail "$name: extracted bundle was not cleaned up"
  [[ ! -e "$case_dir/neighbor-invoked" ]] || fail "$name: adjacent installer was executed"
  if grep -Fq 'unexpected-token-secret' "$case_dir/output"; then
    fail "$name: error exposed untrusted release metadata"
  fi

  if [[ "$verification_failure" == yes || "$pre_extract_abort" == yes ]]; then
    [[ ! -e "$case_dir/extraction.attempted" ]] ||
      fail "$name: unverified bundle was extracted"
    if [[ -f "$case_dir/destination.mkdirs" ]] &&
      grep -Fxq "mkdir -p $case_dir/extracted bundle/bundle" "$case_dir/destination.mkdirs"; then
      fail "$name: extraction destination was created despite the pre-extraction abort"
    fi
  elif [[ "$kind" == manual-* ]]; then
    [[ ! -e "$case_dir/extraction.attempted" ]] ||
      fail "$name: manual installer unexpectedly extracted an archive"
  else
    [[ -f "$case_dir/extraction.attempted" && -f "$case_dir/extraction.completed" ]] ||
      fail "$name: verified bundle was not extracted with real tar"
    [[ "$(cat "$case_dir/extraction.attempted")" == attempt &&
      "$(cat "$case_dir/extraction.completed")" == completed ]] ||
      fail "$name: verified bundle was not extracted exactly once"
    printf '%s\n' --no-same-owner -C "$case_dir/extracted bundle/bundle" -xzf \
      "$case_dir/extracted bundle/$asset_name" > "$case_dir/expected-extraction.args"
    cmp "$case_dir/expected-extraction.args" "$case_dir/extraction.args" ||
      fail "$name: extraction did not use the verified archive and isolated destination"
  fi

  if [[ "$verification_failure" == yes ]]; then
    [[ ! -e "$case_dir/installer.entered" && ! -e "$case_dir/installer.root" &&
      ! -e "$case_dir/host-commands" && ! -e "$case_dir/host/opt/moddex" &&
      ! -e "$case_dir/host/usr/local/bin/moddex" ]] ||
      fail "$name: unverified bundle executed an installer or caused install/CLI side effects"
    case "$verification" in
      metadata-download) expected_error='Failed to fetch release metadata'; expected_requests=1 ;;
      bundle-metadata-*|bundle-asset-*) expected_error='exactly one bundle asset'; expected_requests=1 ;;
      bundle-url-*) expected_error='Release bundle download URL is missing or invalid'; expected_requests=1 ;;
      checksum-asset-*|checksum-url-*) expected_error='Required release checksum asset'; expected_requests=1 ;;
      bundle-download) expected_error='Failed to download the release bundle'; expected_requests=2 ;;
      checksum-download) expected_error='Failed to download the required release checksum'; expected_requests=3 ;;
      checksum-wrong-digest|tampered-bundle) expected_error='Release bundle checksum verification failed'; expected_requests=3 ;;
      checksum-*) expected_error='Invalid release checksum'; expected_requests=3 ;;
      *) fail "$name: missing verification failure assertions" ;;
    esac
    grep -Fq "$expected_error" "$case_dir/output" ||
      fail "$name: missing actionable verification error"
    grep -Eiq 'retry|download a complete matching release again' "$case_dir/output" ||
      fail "$name: verification error did not explain how to recover"
    [[ "$(wc -l < "$case_dir/curl.log")" -eq "$expected_requests" ]] ||
      fail "$name: downloader continued after a verification prerequisite failed"
    if grep -Fq 'Release bundle checksum verified' "$case_dir/output"; then
      fail "$name: unverified bundle was reported as verified"
    fi
  elif [[ "$kind" == production-fail-write ]]; then
    # Since #119 the install path preflight rejects a directory sitting at
    # the VERSION target before any host change; the version-write failure
    # branch behind it stays as defense in depth for non-static failures.
    [[ -d "$case_dir/host/opt/moddex/VERSION" ]] ||
      fail "$name: tampered VERSION fixture was changed"
    grep -Fq 'exists but is not a regular file' "$case_dir/output" ||
      fail "$name: tampered VERSION target was not rejected by the path preflight"
    grep -Fq 'then rerun the installer' "$case_dir/output" ||
      fail "$name: rejection did not explain how to recover"
    if [[ -e "$case_dir/host-commands" ]] &&
      grep -Evq '^id -u moddex$' "$case_dir/host-commands"; then
      fail "$name: tampered VERSION target reached a mutation/privilege command"
    fi
    if grep -q '^systemctl ' "$case_dir/host-commands"; then
      fail "$name: service was started despite a tampered VERSION target"
    fi
  elif [[ "$kind" == manual-fail-* ]]; then
    [[ ! -e "$case_dir/host-commands" && ! -e "$case_dir/host/opt/moddex/VERSION" ]] ||
      fail "$name: invalid version caused host mutations"
    grep -Eiq 'version' "$case_dir/output" || fail "$name: version failure was not explained"
  elif [[ "$malware" != none && "$malware" != internal-link ]]; then
    # The rejected archive must never reach the installer or the host commands,
    # and the validation must have inspected the namelist before aborting.
    [[ ! -e "$case_dir/installer.entered" && ! -e "$case_dir/installer.root" &&
      ! -e "$case_dir/host-commands" ]] ||
      fail "$name: rejected archive ran the installer or host commands"
    [[ -f "$case_dir/validation.listings" ]] ||
      fail "$name: archive was not listed before the rejection"
    grep -Fq 'Bundle archive validation failed' "$case_dir/output" ||
      fail "$name: rejection did not report the archive validation failure"
    case "$malware" in
      absolute-entry) expected_error='an archive entry uses an absolute path' ;;
      traversal-entry) expected_error='an archive entry contains a parent-directory path component' ;;
      escaping-link-absolute|escaping-link-relative)
        expected_error='an archive link entry points outside the bundle directory' ;;
      *) fail "$name: missing rejection assertions" ;;
    esac
    grep -Fq "$expected_error" "$case_dir/output" ||
      fail "$name: rejection did not identify the violation"
    grep -Eq 'Download a complete matching release bundle again and retry; nothing was unpacked\.' \
      "$case_dir/output" ||
      fail "$name: rejection did not explain the safe next action"
  elif [[ "$missing" == none && "$kind" != stub ]]; then
    [[ "$(cat "$case_dir/host/opt/moddex/VERSION")" == "$tag" ]] ||
      fail "$name: installed VERSION is not the resolved release tag"
    [[ "$(cat "$case_dir/host/opt/moddex/app.jar")" == "backend:$tag" ]] ||
      fail "$name: installed version does not identify the downloaded backend"
    cli_path="$case_dir/host/usr/local/bin:$TEST_DIR/bin"
    [[ -x "$case_dir/host/usr/local/bin/moddex" ]] || fail "$name: installed CLI is not executable"
    [[ "$(PATH="$cli_path" command -v moddex)" == "$case_dir/host/usr/local/bin/moddex" ]] ||
      fail "$name: installed CLI is not discoverable on PATH"
    PATH="$cli_path" moddex version \
      > "$case_dir/cli-version" 2> "$case_dir/cli-error"
    [[ "$(cat "$case_dir/cli-version")" == "$tag" && ! -s "$case_dir/cli-error" ]] ||
      fail "$name: installed CLI does not report the downloaded release tag"
  elif [[ "$missing" == none ]]; then
    [[ -f "$case_dir/installer.root" ]] || fail "$name: bundled installer did not run"
    [[ "$(cat "$case_dir/installer.root")" == "$case_dir/extracted bundle/bundle" ]] ||
      fail "$name: installer did not run from the extracted bundle"
    [[ "$(cat "$case_dir/installer.identity")" == "$tag" ]] ||
      fail "$name: wrong release's installer was executed"
    printf '%s\n' --backend-jar "$case_dir/extracted bundle/bundle/backend/Moddex-Backend.jar" \
      --frontend-dir "$case_dir/extracted bundle/bundle/frontend" --mode lan --port 18080 \
      --version v9.9.9-caller-override --version "$tag" \
      > "$case_dir/expected.args"
    cmp "$case_dir/expected.args" "$case_dir/installer.args" ||
      fail "$name: installer arguments were not preserved"
  else
    [[ ! -e "$case_dir/installer.root" && ! -e "$case_dir/installer.entered" ]] ||
      fail "$name: incomplete bundle's installer ran"
    case "$missing" in
      installer)
        grep -Fq 'scripts/install.sh' "$case_dir/output" ||
          fail "$name: error did not identify the missing installer"
        ;;
      unit)
        grep -Fq 'packaging/systemd/moddex-backend.service' "$case_dir/output" ||
          fail "$name: error did not identify the missing unit"
        ;;
      version|empty-version|mismatched-version)
        grep -Fq 'VERSION' "$case_dir/output" ||
          fail "$name: error did not identify invalid bundle version metadata"
        ;;
      tag-*)
        grep -Fq 'valid concrete tag_name' "$case_dir/output" ||
          fail "$name: error did not identify invalid release tag metadata"
        grep -Fq -- '--version <release-tag>' "$case_dir/output" ||
          fail "$name: invalid tag error did not explain how to recover"
        [[ "$(wc -l < "$case_dir/curl.log")" -eq 1 ]] ||
          fail "$name: assets were downloaded despite invalid release metadata"
        ;;
    esac
    if [[ "$missing" != tag-* ]]; then
      grep -Eq 'Download a (complete|matching) release bundle and retry.' "$case_dir/output" ||
        fail "$name: invalid bundle error did not explain how to recover"
    fi
  fi
  if [[ "$missing" == none && "$verification_failure" == no && "$kind" != manual-* ]]; then
    grep -Fq 'Release bundle checksum verified' "$case_dir/output" ||
      fail "$name: independent release checksum verification was not reported"
    [[ "$(wc -l < "$case_dir/curl.log")" -eq 3 ]] ||
      fail "$name: bundle and independent checksum were not both downloaded"
  fi
  printf 'PASS: %s\n' "$name"
}

check_case standalone-latest latest v0.1.2-fixture none 0
check_case standalone-pinned v0.1.1-fixture v0.1.1-fixture none 0
check_case adjacent-installer-ignored latest v0.1.2-fixture none 0 yes
check_case missing-installer latest v0.1.2-fixture installer 0
check_case missing-unit latest v0.1.2-fixture unit 0
check_case installer-failure latest v0.1.2-fixture none 37
check_case installed-latest latest v0.1.2-fixture none 0 no production
check_case installed-pinned v0.1.1-fixture v0.1.1-fixture none 0 no production
check_case installed-service-failure latest v0.1.2-fixture none 37 no production
check_case installed-version-write-failure latest v0.1.2-fixture none 1 no production-fail-write
check_case built-latest latest v0.1.2-built none 0 no built
check_case built-pinned v0.1.1-built v0.1.1-built none 0 no built
check_case manual-bundle-version latest v0.1.2-fixture none 0 no manual-bundle
check_case local-checkout-version latest 0.1.2 none 0 no manual-bundle
check_case local-dev-version latest dev none 0 no manual-bundle
check_case manual-explicit-version latest v0.1.2-manual none 0 no manual-explicit
check_case manual-missing-version latest v0.1.2-fixture none 1 no manual-fail-missing
check_case manual-invalid-version latest v0.1.2-fixture none 1 no manual-fail-invalid
check_case manual-empty-explicit-version latest v0.1.2-fixture none 1 no manual-fail-empty
check_case manual-alias-version latest v0.1.2-fixture none 1 no manual-fail-alias
check_case missing-bundle-version latest v0.1.2-fixture version 0
check_case mismatched-bundle-version latest v0.1.2-fixture mismatched-version 0
check_case empty-bundle-version latest v0.1.2-fixture empty-version 0
for fault in missing empty null number object array invalid newline multiple latest malformed; do
  check_case "invalid-release-tag-$fault" latest v0.1.2-fixture "tag-$fault" 0
done

# The archive validation gate: a link that stays inside the bundle root passes,
# absolute paths, parent traversal and escaping link targets abort before the
# extraction destination is even created.
check_case archive-internal-link latest v0.1.2-fixture none 0 no stub valid internal-link
check_case archive-absolute-entry latest v0.1.2-fixture none 0 no stub valid absolute-entry
check_case archive-traversal-entry latest v0.1.2-fixture none 0 no stub valid traversal-entry
check_case archive-escaping-link-absolute latest v0.1.2-fixture none 0 no stub valid escaping-link-absolute
check_case archive-escaping-link-relative latest v0.1.2-fixture none 0 no stub valid escaping-link-relative

for format in binary no-newline uppercase; do
  check_case "valid-checksum-$format" latest v0.1.2-fixture none 0 no production "$format"
done
for fault in metadata-download bundle-metadata-missing bundle-asset-missing bundle-asset-duplicate \
  bundle-url-missing bundle-url-null bundle-url-empty bundle-url-number bundle-url-invalid \
  checksum-asset-missing checksum-asset-duplicate checksum-asset-unrelated checksum-url-missing checksum-url-null \
  checksum-url-empty checksum-url-number checksum-url-invalid bundle-download checksum-download \
  checksum-empty checksum-whitespace checksum-malformed checksum-short checksum-long checksum-nonhex \
  checksum-digest-only checksum-wrong-digest checksum-wrong-filename checksum-extra-record \
  checksum-duplicate-record tampered-bundle; do
  check_case "verification-$fault" latest v0.1.2-fixture none 0 no production "$fault"
done

cli_case="$TEST_DIR/installed-latest"
cli_path="$cli_case/host/usr/local/bin:$TEST_DIR/bin"
command_count="$(wc -l < "$cli_case/host-commands")"
PATH="$cli_path" moddex help > "$cli_case/cli-help" 2> "$cli_case/cli-error"
grep -Fq 'Moddex CLI' "$cli_case/cli-help" || fail "Installed CLI help did not display usage"
[[ ! -s "$cli_case/cli-error" && "$(wc -l < "$cli_case/host-commands")" -eq "$command_count" ]] ||
  fail "Installed CLI help invoked a host command or emitted an error"
printf 'PASS: cli-help\n'

# The TLS-aware status query derives the URL from the fixture unit
# (SERVER_PORT=18080, no TLS environment file) and calls the API over plain
# HTTP. The CLI gets its own sed/curl fixture so the installer's host-command
# stub, which blocks sed, cannot observe the CLI's read-only usage.
mkdir "$TEST_DIR/cli-bin"
ln -s "$(command -v sed)" "$TEST_DIR/cli-bin/sed"
cat > "$TEST_DIR/cli-bin/curl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --silent|--fail) shift ;;
    --max-time) [[ "$2" =~ ^[0-9]+$ ]] || exit 90; shift 2 ;;
    http://*) url="$1"; shift ;;
    *) printf 'Unexpected CLI curl argument: %s\n' "$1" >&2; exit 90 ;;
  esac
done
[[ -n "$url" ]] || exit 90
printf '%s\n' "$url" >> "$TEST_CASE_DIR/cli-curl.log"
printf '{"setupRequired": false}\n'
SH
chmod +x "$TEST_DIR/cli-bin/curl"
status_cli_path="$cli_case/host/usr/local/bin:$TEST_DIR/cli-bin:$TEST_DIR/bin"

for service_status in 0 3; do
  : > "$cli_case/cli-curl.log"
  PATH="$status_cli_path" TEST_CASE_DIR="$cli_case" TEST_CLI_SERVICE_STATUS="$service_status" \
    moddex status > "$cli_case/cli-status" 2> "$cli_case/cli-error"
  expected_state=active
  [[ "$service_status" -eq 0 ]] || expected_state=inactive
  grep -Fq "Backend service (moddex-backend.service): $expected_state" "$cli_case/cli-status" ||
    fail "Installed CLI status did not preserve the mocked $expected_state service result"
  grep -Fq 'Backend URL: http://127.0.0.1:18080' "$cli_case/cli-status" ||
    fail "Installed CLI status did not derive the plain HTTP URL from the unit port"
  grep -Fq 'Backend API: reachable (setup not required)' "$cli_case/cli-status" ||
    fail "Installed CLI status did not verify the API via the derived URL"
  [[ ! -s "$cli_case/cli-error" ]] ||
    fail "Installed CLI status emitted an error"
  [[ "$(wc -l < "$cli_case/host-commands")" -eq $((command_count + 1)) ]] ||
    fail "Installed CLI status did not use exactly one mocked host command"
  tail -n 1 "$cli_case/host-commands" | grep -Fxq 'systemctl is-active moddex-backend' ||
    fail "Installed CLI status did not call the mocked systemctl"
  [[ "$(wc -l < "$cli_case/cli-curl.log")" -eq 1 ]] ||
    fail "Installed CLI status did not use exactly one API request"
  grep -Fxq 'http://127.0.0.1:18080/api/v1/setup/status' "$cli_case/cli-curl.log" ||
    fail "Installed CLI status queried an unexpected API URL"
  command_count=$((command_count + 1))
  printf 'PASS: cli-status-%s\n' "$expected_state"
done

status=0
PATH="$cli_path" moddex not-a-command > "$cli_case/cli-unknown" 2> "$cli_case/cli-error" || status=$?
[[ "$status" -eq 2 && ! -s "$cli_case/cli-unknown" ]] ||
  fail "Installed CLI unknown-command exit status changed"
grep -Fq 'Unknown command: not-a-command' "$cli_case/cli-error" ||
  fail "Installed CLI unknown command did not explain the error"
grep -Fq "Run 'moddex help' for usage." "$cli_case/cli-error" ||
  fail "Installed CLI unknown command did not explain how to recover"
[[ "$(wc -l < "$cli_case/host-commands")" -eq "$command_count" ]] ||
  fail "Installed CLI unknown command invoked a host command"
printf 'PASS: cli-unknown-command\n'

for fault in missing empty invalid latest; do
  case "$fault" in
    missing) rm "$cli_case/host/opt/moddex/VERSION" ;;
    empty) : > "$cli_case/host/opt/moddex/VERSION" ;;
    invalid) printf 'unexpected-token-secret/invalid\n' > "$cli_case/host/opt/moddex/VERSION" ;;
    latest) printf 'latest\n' > "$cli_case/host/opt/moddex/VERSION" ;;
  esac
  status=0
  PATH="$cli_path" moddex version \
    > "$cli_case/cli-version" 2> "$cli_case/cli-error" || status=$?
  [[ "$status" -eq 1 && ! -s "$cli_case/cli-version" ]] ||
    fail "CLI $fault version did not fail without a fabricated version"
  grep -Fq 'Reinstall a complete Moddex bundle.' "$cli_case/cli-error" ||
    fail "CLI $fault version did not explain how to recover"
  if grep -Fq 'unexpected-token-secret' "$cli_case/cli-error"; then
    fail "CLI $fault version exposed invalid version file contents"
  fi
  printf 'PASS: cli-version-%s\n' "$fault"
done

printf 'Downloader bundle-installer checks passed (offline fixtures; no host installation).\n'
