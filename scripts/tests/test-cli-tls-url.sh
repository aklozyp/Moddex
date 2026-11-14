#!/usr/bin/env bash
set -Eeuo pipefail

# Regression test for issue #163: the CLI derives its backend URL from the
# native TLS configuration (HTTPS plus the deployed certificate chain when
# MODDEX_TLS_ENABLED=true, plain HTTP otherwise) and never disables TLS
# verification.
#
# The fixture deliberately sticks to the minimal CI runner toolset (bash, curl,
# sed, grep) instead of starting a real API server: a strict curl fixture
# rejects any unexpected argument, URL, or endpoint, so every case proves the
# exact URL, TLS arguments, and request shape the CLI hands to curl, plus the
# mapping of curl exit codes to the safe CLI error messages. A real TLS
# handshake proof against an openssl s_server fixture runs when openssl is
# available; without openssl it is skipped with an explicit named message, and
# the case for an unreadable configuration is skipped by name when running as
# root (root bypasses file permissions). Nothing is skipped silently.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DIR="$PROJECT_ROOT/.cli-tls-url-test.$$"
CLI_SRC="$PROJECT_ROOT/backend/bin/moddex"

FIXTURE_PASSWORD="fixture-admin-password"
TRICKY_PASSWORD='fixture-admin-pa"ss\word'
WRONG_PASSWORD="fixture-wrong-password"
FIXTURE_TOKEN="fixture-jwt-token"
KS_PASSWORD_SECRET="fixture-ks-secret-value"
HTTP_PORT=18080
TLS_PORT=18443

# The exact JSON payload bytes the CLI must produce: JSON string escaping
# encodes the quote in TRICKY_PASSWORD as \" and its backslash as \\. The
# curl fixture answers 401 only for byte-exact matches and 400 for anything
# else, which proves the escaping round-trip. The bytes are built with printf
# instead of shell quoting so the expected encoding stays explicit.
FIXTURE_PAYLOAD="$(printf '{"password":"%s"}' "$FIXTURE_PASSWORD")"
WRONG_PAYLOAD="$(printf '{"password":"%s"}' "$WRONG_PASSWORD")"
TRICKY_PAYLOAD="$(printf '{"password":"%s"}' 'fixture-admin-pa\"ss\\word')"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

for tool in bash curl sed grep; do
  command -v "$tool" >/dev/null 2>&1 ||
    fail "Required tool '$tool' is not available; the CLI TLS/URL regression cannot run."
done

[[ ! -e "$TEST_DIR" ]] || fail "Test directory already exists: $TEST_DIR"
mkdir "$TEST_DIR"
SERVER_PID=""
cleanup() {
  if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; fi
  if [[ "$TEST_DIR" == "$PROJECT_ROOT"/.cli-tls-url-test.* &&
    -d "$TEST_DIR" && ! -L "$TEST_DIR" ]]; then
    rm -rf -- "$TEST_DIR"
  fi
}
trap cleanup EXIT

mkdir "$TEST_DIR/bin" "$TEST_DIR/tls" "$TEST_DIR/state" "$TEST_DIR/tmp"
mkdir "$TEST_DIR/etc" "$TEST_DIR/etc/moddex" "$TEST_DIR/etc/systemd"
mkdir "$TEST_DIR/etc/systemd/system"

BASH_BIN="$(command -v bash)"
# curl is NOT linked here: bin/curl is the strict fixture below, and a symlink
# would make the fixture write follow it to the real curl binary.
for command in bash sed grep; do
  ln -s "$(command -v "$command")" "$TEST_DIR/bin/$command"
done

# Closed-PATH systemctl stub for the CLI under test.
SYSTEMCTL_LOG="$TEST_DIR/state/systemctl.log"
cat > "$TEST_DIR/bin/systemctl" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "\$*" >> "$SYSTEMCTL_LOG"
printf 'active\n'
SH
chmod +x "$TEST_DIR/bin/systemctl"

CA_TRUSTED="$TEST_DIR/tls/server.crt"
CLI_CURL_LOG="$TEST_DIR/state/curl.log"
export CA_TRUSTED CLI_CURL_LOG FIXTURE_PAYLOAD TRICKY_PAYLOAD WRONG_PAYLOAD

# Strict fixture for the CLI's curl contract. HTTPS requests are answered only
# when curl received the deployed certificate chain as --cacert; any other CA
# file or no CA at all mirrors curl exit 60, exactly what a self-signed server
# produces against a wrong or the system trust store.
cat > "$TEST_DIR/bin/curl" <<SH
#!/usr/bin/env bash
set -Eeuo pipefail
cacert="none" data="no" config="no" url="" write_out="no"
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --cacert)
      [[ \$# -ge 2 ]] || { printf 'curl fixture: --cacert is missing its value\n' >&2; exit 90; }
      cacert="\$2"; shift 2 ;;
    --silent|--fail) shift ;;
    --max-time)
      [[ \$# -ge 2 && "\$2" =~ ^[0-9]+\$ ]] ||
        { printf 'curl fixture: unexpected --max-time value\n' >&2; exit 90; }
      shift 2 ;;
    --header)
      [[ \$# -ge 2 && "\$2" == 'Content-Type: application/json' ]] ||
        { printf 'curl fixture: unexpected --header value\n' >&2; exit 90; }
      shift 2 ;;
    --data-binary)
      [[ \$# -ge 2 && "\$2" == '@-' ]] ||
        { printf 'curl fixture: unexpected --data-binary value\n' >&2; exit 90; }
      data="yes"; shift 2 ;;
    --write-out)
      [[ \$# -ge 2 && "\$2" == '\n%{http_code}' ]] ||
        { printf 'curl fixture: unexpected --write-out value\n' >&2; exit 90; }
      write_out="yes"; shift 2 ;;
    --config)
      [[ \$# -ge 2 && "\$2" == '-' ]] ||
        { printf 'curl fixture: unexpected --config value\n' >&2; exit 90; }
      config="yes"; shift 2 ;;
    http://*|https://*) url="\$1"; shift ;;
    *) printf 'curl fixture: unexpected argument: %s\n' "\$1" >&2; exit 90 ;;
  esac
done
[[ -n "\$url" ]] || { printf 'curl fixture: no URL was passed\n' >&2; exit 90; }
printf 'cacert=%s data=%s config=%s url=%s\n' "\$cacert" "\$data" "\$config" "\$url" >> "\$CLI_CURL_LOG"
case "\$url" in
  https://*) [[ "\$cacert" == "\$CA_TRUSTED" ]] || exit 60 ;;
esac
if [[ "\$data" == "yes" && "\$config" == "yes" ]]; then
  printf 'curl fixture: --data-binary and --config cannot combine\n' >&2
  exit 90
fi
respond() {
  printf '%s' "\$1"
  if [[ "\$write_out" == "yes" ]]; then printf '\n%s' "\$2"; fi
}
if [[ "\$data" == "yes" ]]; then
  case "\$url" in
    */api/v1/auth/login) ;;
    *) printf 'curl fixture: unexpected sign-in URL\n' >&2; exit 90 ;;
  esac
  payload=""
  line=""
  while IFS= read -r line; do payload+="\$line"\$'\n'; done
  if [[ -n "\$line" ]]; then payload+="\$line"; fi
  if [[ "\$payload" == "\$FIXTURE_PAYLOAD" ]]; then
    respond '{"token":"fixture-jwt-token"}' 200
  elif [[ "\$payload" == "\$TRICKY_PAYLOAD" || "\$payload" == "\$WRONG_PAYLOAD" ]]; then
    respond '{"error":"Unauthorized"}' 401
  else
    respond '{"error":"Malformed request body"}' 400
  fi
elif [[ "\$config" == "yes" ]]; then
  case "\$url" in
    */api/v1/instance) ;;
    *) printf 'curl fixture: unexpected authenticated URL\n' >&2; exit 90 ;;
  esac
  header=""
  IFS= read -r header || true
  if [[ "\$header" == 'header = "Authorization: Bearer fixture-jwt-token"' ]]; then
    printf '[]'
  else
    exit 22
  fi
else
  case "\$url" in
    */api/v1/setup/status) printf '{"setupRequired": false}' ;;
    *) printf 'curl fixture: unexpected request URL\n' >&2; exit 90 ;;
  esac
fi
SH
chmod +x "$TEST_DIR/bin/curl"

# Certificate fixtures: real, verifiable material when openssl is available
# (for the s_server handshake proof), placeholders otherwise so the curl
# contract cases can still exercise the TLS configuration paths.
if command -v openssl >/dev/null 2>&1; then
  cat > "$TEST_DIR/tls/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = 127.0.0.1
[v3]
subjectAltName = IP:127.0.0.1,DNS:localhost
basicConstraints = critical,CA:FALSE
EOF
  cat > "$TEST_DIR/tls/other.cnf" <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = other.example.invalid
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TEST_DIR/tls/server.key" \
    -out "$TEST_DIR/tls/server.crt" -days 2 -config "$TEST_DIR/tls/openssl.cnf" \
    >/dev/null 2>&1 ||
    fail "Could not generate the fixture certificate."
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TEST_DIR/tls/other.key" \
    -out "$TEST_DIR/tls/other.crt" -days 2 -config "$TEST_DIR/tls/other.cnf" \
    >/dev/null 2>&1 ||
    fail "Could not generate the untrusted fixture certificate."
  CERT_FIXTURE_KIND="real"
else
  printf 'placeholder certificate fixture (openssl unavailable)\n' > "$TEST_DIR/tls/server.crt"
  printf 'placeholder key fixture\n' > "$TEST_DIR/tls/server.key"
  printf 'placeholder unrelated certificate fixture\n' > "$TEST_DIR/tls/other.crt"
  CERT_FIXTURE_KIND="placeholder"
  printf 'SKIP: the real TLS handshake proof is not exercised because openssl is not available on this runner. URL construction, TLS-argument passing, CA override handling, and failure mapping remain verified by the strict curl fixture cases.\n'
fi

# Runs the CLI with a closed PATH against the fixture configuration. Leading
# arguments of the form NAME=VALUE are exported for the CLI process.
run_cli() {
  local pairs=() pair
  while [[ "${1:-}" == *=* && "${1:-}" != -* ]]; do
    pairs+=("$1")
    shift
  done
  case_dir="$1"
  shift
  : > "$SYSTEMCTL_LOG"
  : > "$CLI_CURL_LOG"
  CLI_RC=0
  (
    export PATH="$TEST_DIR/bin"
    export TMPDIR="$TEST_DIR/tmp"
    unset MODDEX_ENV_FILE MODDEX_UNIT_FILE MODDEX_CLI_HOST MODDEX_CLI_PORT \
      MODDEX_CLI_CA_FILE MODDEX_ADMIN_PASSWORD
    export MODDEX_ENV_FILE="$TEST_DIR/etc/moddex/moddex.env"
    export MODDEX_UNIT_FILE="$TEST_DIR/etc/systemd/system/moddex-backend.service"
    export MODDEX_CLI_HOST="127.0.0.1"
    for pair in ${pairs[@]+"${pairs[@]}"}; do
      export "${pair%%=*}=${pair#*=}"
    done
    "$BASH_BIN" "$CLI_SRC" "$@" > "$case_dir/out" 2> "$case_dir/err"
  ) || CLI_RC=$?
}

write_env_fixture() {
  local line
  : > "$TEST_DIR/etc/moddex/moddex.env"
  printf '# Managed by install.sh - native TLS settings for the Moddex backend.\n' \
    > "$TEST_DIR/etc/moddex/moddex.env"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$TEST_DIR/etc/moddex/moddex.env"
  done
}

write_unit_fixture() {
  printf '[Unit]\nDescription=fixture unit\n\n[Service]\nEnvironment=SERVER_PORT=%s\n' "$1" \
    > "$TEST_DIR/etc/systemd/system/moddex-backend.service"
}

new_case() {
  case_dir="$TEST_DIR/case-$1"
  mkdir "$case_dir"
  case_count=$((case_count + 1))
}

expect_secret_absent() {
  local label="$1" secret="$2"
  if grep -Fq "$secret" "$case_dir/out" "$case_dir/err" "$SYSTEMCTL_LOG" "$CLI_CURL_LOG"; then
    fail "$label: the secret value appeared in CLI output or command logs."
  fi
}

expect_requests() {
  local label="$1" expected_count="$2" actual_count line
  shift 2
  actual_count="$(wc -l < "$CLI_CURL_LOG")"
  if [[ "$actual_count" -ne "$expected_count" ]]; then
    cat "$CLI_CURL_LOG" >&2
    fail "$label: expected $expected_count API request(s), got $actual_count."
  fi
  for line in "$@"; do
    if ! grep -Fxq "$line" "$CLI_CURL_LOG"; then
      cat "$CLI_CURL_LOG" >&2
      fail "$label: missing expected API request: $line"
    fi
  done
}

case_count=0

# --- Case 1: without a TLS environment file the CLI stays on plain HTTP ----
new_case "http-mode"
rm -f "$TEST_DIR/etc/moddex/moddex.env"
write_unit_fixture "$HTTP_PORT"
run_cli "$case_dir" status
[[ "$CLI_RC" -eq 0 ]] || fail "http-mode: status exited with $CLI_RC."
grep -Fq "Backend URL: http://127.0.0.1:$HTTP_PORT" "$case_dir/out" ||
  fail "http-mode: status did not build the plain HTTP URL from the unit port."
grep -Fq "Backend service (moddex-backend.service): active" "$case_dir/out" ||
  fail "http-mode: status did not report the systemd service state."
grep -Fq "Backend API: reachable (setup not required)" "$case_dir/out" ||
  fail "http-mode: status did not report API reachability via the setup endpoint."
if grep -Fq "https://" "$case_dir/out"; then
  fail "http-mode: status announced HTTPS although TLS is not configured."
fi
grep -Fq "is-active moddex-backend" "$SYSTEMCTL_LOG" ||
  fail "http-mode: status did not query the systemd service state."
expect_requests "http-mode status" 1 \
  "cacert=none data=no config=no url=http://127.0.0.1:$HTTP_PORT/api/v1/setup/status"

run_cli "MODDEX_ADMIN_PASSWORD=$FIXTURE_PASSWORD" "$case_dir" login
[[ "$CLI_RC" -eq 0 ]] || fail "http-mode: login exited with $CLI_RC."
grep -Fq "Authentication successful (authenticated API request to http://127.0.0.1:$HTTP_PORT/api/v1/instance succeeded)" \
  "$case_dir/out" ||
  fail "http-mode: login did not perform the authenticated API request."
expect_requests "http-mode login" 2 \
  "cacert=none data=yes config=no url=http://127.0.0.1:$HTTP_PORT/api/v1/auth/login" \
  "cacert=none data=no config=yes url=http://127.0.0.1:$HTTP_PORT/api/v1/instance"
expect_secret_absent "http-mode login" "$FIXTURE_PASSWORD"
expect_secret_absent "http-mode login" "$FIXTURE_TOKEN"

run_cli "MODDEX_ADMIN_PASSWORD=$WRONG_PASSWORD" "$case_dir" login
[[ "$CLI_RC" -eq 1 ]] || fail "http-mode: login with a wrong password exited with $CLI_RC."
grep -Fq "rejected the administrator password" "$case_dir/err" ||
  fail "http-mode: wrong-password login missed the safe error message."
expect_secret_absent "http-mode wrong-password login" "$WRONG_PASSWORD"

# --- Case 2: TLS active with the deployed certificate chain ----------------
new_case "tls-pem"
write_env_fixture \
  "MODDEX_TLS_ENABLED=\"true\"" \
  "MODDEX_TLS_CERT_FILE=\"$TEST_DIR/tls/server.crt\""
write_unit_fixture "$TLS_PORT"
run_cli "$case_dir" status
[[ "$CLI_RC" -eq 0 ]] || fail "tls-pem: status exited with $CLI_RC."
grep -Fq "Backend URL: https://127.0.0.1:$TLS_PORT" "$case_dir/out" ||
  fail "tls-pem: status did not build the HTTPS URL from the TLS configuration."
grep -Fq "Backend API: reachable (setup not required)" "$case_dir/out" ||
  fail "tls-pem: status did not reach the API over verified HTTPS."
expect_requests "tls-pem status" 1 \
  "cacert=$TEST_DIR/tls/server.crt data=no config=no url=https://127.0.0.1:$TLS_PORT/api/v1/setup/status"

run_cli "MODDEX_ADMIN_PASSWORD=$FIXTURE_PASSWORD" "$case_dir" login
[[ "$CLI_RC" -eq 0 ]] || fail "tls-pem: login exited with $CLI_RC."
grep -Fq "Authentication successful (authenticated API request to https://127.0.0.1:$TLS_PORT/api/v1/instance succeeded)" \
  "$case_dir/out" ||
  fail "tls-pem: login did not perform the authenticated request over HTTPS."
expect_secret_absent "tls-pem login" "$FIXTURE_PASSWORD"
expect_secret_absent "tls-pem login" "$FIXTURE_TOKEN"

# A password with JSON-relevant characters must survive the request encoding:
# only the byte-exact escaped payload is answered with 401 (unknown password);
# any other encoding would be answered with 400, and the CLI error message
# would differ.
run_cli "MODDEX_ADMIN_PASSWORD=$TRICKY_PASSWORD" "$case_dir" login
[[ "$CLI_RC" -eq 1 ]] || fail "tls-pem: login with the tricky password exited with $CLI_RC."
grep -Fq "rejected the administrator password" "$case_dir/err" ||
  fail "tls-pem: tricky-password login was not transmitted as valid JSON."
expect_secret_absent "tls-pem tricky-password login" "$TRICKY_PASSWORD"

# Verification must actually happen: curl received the CA override, and the
# fixture mirrors the verification failure with curl exit 60, which the CLI
# must map to the safe TLS message naming the override variable.
run_cli "MODDEX_CLI_CA_FILE=$TEST_DIR/tls/other.crt" "$case_dir" status
[[ "$CLI_RC" -eq 1 ]] ||
  fail "tls-pem: status succeeded despite an untrusted CA; verification would be bypassed."
grep -Fq "TLS verification of the backend at https://127.0.0.1:$TLS_PORT failed" "$case_dir/err" ||
  fail "tls-pem: untrusted CA did not produce the TLS verification message."
grep -Fq "MODDEX_CLI_CA_FILE" "$case_dir/err" ||
  fail "tls-pem: untrusted CA message misses the safe next action."
expect_requests "tls-pem untrusted CA status" 1 \
  "cacert=$TEST_DIR/tls/other.crt data=no config=no url=https://127.0.0.1:$TLS_PORT/api/v1/setup/status"
expect_secret_absent "tls-pem untrusted CA" "$FIXTURE_TOKEN"

# --- Case 3: TLS active but the configured CA file is missing --------------
new_case "tls-missing-ca"
write_env_fixture \
  "MODDEX_TLS_ENABLED=\"true\"" \
  "MODDEX_TLS_CERT_FILE=\"$TEST_DIR/tls/absent-cert.crt\""
write_unit_fixture "$TLS_PORT"
run_cli "$case_dir" status
[[ "$CLI_RC" -eq 1 ]] || fail "tls-missing-ca: status exited with $CLI_RC."
grep -Fq "MODDEX_TLS_CERT_FILE" "$case_dir/err" ||
  fail "tls-missing-ca: error message does not name the responsible variable."
grep -Fq "$TEST_DIR/tls/absent-cert.crt" "$case_dir/err" ||
  fail "tls-missing-ca: error message does not name the missing file."
grep -Fq "reinstall with install.sh --tls-cert/--tls-key" "$case_dir/err" ||
  fail "tls-missing-ca: error message misses the safe next action."
[[ ! -s "$CLI_CURL_LOG" ]] ||
  fail "tls-missing-ca: the CLI contacted the API before resolving the CA file."

# --- Case 4: keystore variant uses the system trust store and the CA -------
# --- override; the keystore password never appears anywhere ----------------
new_case "tls-keystore"
write_env_fixture \
  "MODDEX_TLS_ENABLED=\"true\"" \
  "MODDEX_TLS_KEYSTORE=\"$TEST_DIR/tls/server.p12\"" \
  "MODDEX_TLS_KEYSTORE_PASSWORD=\"$KS_PASSWORD_SECRET\"" \
  "MODDEX_TLS_KEYSTORE_TYPE=\"PKCS12\""
write_unit_fixture "$TLS_PORT"
run_cli "$case_dir" status
[[ "$CLI_RC" -eq 1 ]] ||
  fail "tls-keystore: status succeeded against a self-signed server without a CA override."
grep -Fq "TLS verification of the backend" "$case_dir/err" ||
  fail "tls-keystore: untrusted server did not produce the TLS verification message."
grep -Fq "MODDEX_CLI_CA_FILE" "$case_dir/err" ||
  fail "tls-keystore: verification message misses the CA override hint."
expect_requests "tls-keystore status" 1 \
  "cacert=none data=no config=no url=https://127.0.0.1:$TLS_PORT/api/v1/setup/status"
expect_secret_absent "tls-keystore status" "$KS_PASSWORD_SECRET"

run_cli "MODDEX_CLI_CA_FILE=$TEST_DIR/tls/server.crt" "$case_dir" status
[[ "$CLI_RC" -eq 0 ]] || fail "tls-keystore: status with the CA override exited with $CLI_RC."
grep -Fq "Backend URL: https://127.0.0.1:$TLS_PORT" "$case_dir/out" ||
  fail "tls-keystore: status with the CA override did not use HTTPS."
grep -Fq "Backend API: reachable (setup not required)" "$case_dir/out" ||
  fail "tls-keystore: status with the CA override did not reach the API."
expect_requests "tls-keystore status with CA override" 1 \
  "cacert=$TEST_DIR/tls/server.crt data=no config=no url=https://127.0.0.1:$TLS_PORT/api/v1/setup/status"

run_cli "MODDEX_CLI_CA_FILE=$TEST_DIR/tls/server.crt" \
  "MODDEX_ADMIN_PASSWORD=$FIXTURE_PASSWORD" "$case_dir" login
[[ "$CLI_RC" -eq 0 ]] || fail "tls-keystore: login with the CA override exited with $CLI_RC."
grep -Fq "Authentication successful" "$case_dir/out" ||
  fail "tls-keystore: login with the CA override did not report success."
expect_secret_absent "tls-keystore login" "$KS_PASSWORD_SECRET"
expect_secret_absent "tls-keystore login" "$FIXTURE_TOKEN"

# --- Case 5: an invalid MODDEX_TLS_ENABLED value fails like the backend ----
new_case "tls-invalid-enabled"
write_env_fixture \
  "MODDEX_TLS_ENABLED=\"maybe\"" \
  "MODDEX_TLS_CERT_FILE=\"$TEST_DIR/tls/server.crt\""
write_unit_fixture "$TLS_PORT"
run_cli "$case_dir" status
[[ "$CLI_RC" -eq 1 ]] || fail "tls-invalid-enabled: status exited with $CLI_RC."
grep -Fq "MODDEX_TLS_ENABLED in $TEST_DIR/etc/moddex/moddex.env must be true or false" \
  "$case_dir/err" ||
  fail "tls-invalid-enabled: error message misses the safe instruction."
[[ ! -s "$CLI_CURL_LOG" ]] ||
  fail "tls-invalid-enabled: the CLI contacted the API before validating the configuration."

# --- Case 6: an existing but unreadable TLS configuration fails safely -----
# Running as root bypasses file permissions (a chmod 000 file stays readable),
# so this case needs an unprivileged user and is skipped by name otherwise.
new_case "tls-unreadable-env"
if [[ "$EUID" -eq 0 ]]; then
  printf 'SKIP: tls-unreadable-env is not exercised because this runner runs as root, which bypasses file permissions, so the unreadable-configuration contract cannot be provoked here.\n'
else
  write_env_fixture \
    "MODDEX_TLS_ENABLED=\"true\"" \
    "MODDEX_TLS_CERT_FILE=\"$TEST_DIR/tls/server.crt\""
  write_unit_fixture "$TLS_PORT"
  chmod 000 "$TEST_DIR/etc/moddex/moddex.env"
  run_cli "$case_dir" status
  [[ "$CLI_RC" -eq 1 ]] || fail "tls-unreadable-env: status exited with $CLI_RC."
  grep -Fq "exists but is not readable by this user" "$case_dir/err" ||
    fail "tls-unreadable-env: error message does not describe the unreadable configuration."
  grep -Fq "via sudo" "$case_dir/err" ||
    fail "tls-unreadable-env: error message misses the safe next action."
  if grep -Fq "https://" "$case_dir/out" 2>/dev/null; then
    fail "tls-unreadable-env: the URL scheme must not be guessed when the configuration is unreadable."
  fi
  [[ ! -s "$CLI_CURL_LOG" ]] ||
    fail "tls-unreadable-env: the CLI contacted the API before reading the configuration."
fi

# --- Real TLS handshake proof ----------------------------------------------
# With openssl available this proves with real cryptography that the fixture
# chain verifies, that an unrelated CA and the system trust store are rejected
# with curl exit 60, and that the TLS fixture refuses plain HTTP.
port_free() {
  local port="$1"
  (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && return 1
  return 0
}

if [[ "$CERT_FIXTURE_KIND" == "real" ]]; then
  handshake_port="" handshake_pid="" handshake_rc=0
  for ((candidate = TLS_PORT; candidate < TLS_PORT + 60; candidate++)); do
    port_free "$candidate" || continue
    openssl s_server -accept "127.0.0.1:$candidate" \
      -cert "$TEST_DIR/tls/server.crt" -key "$TEST_DIR/tls/server.key" \
      -www >/dev/null 2>&1 &
    handshake_pid=$!
    # Keep the fixture out of the job table so the cleanup kill does not
    # leave a "Terminated" job message in the test output.
    disown "$handshake_pid"
    for ((attempt = 0; attempt < 50; attempt++)); do
      if curl -sS --max-time 2 --cacert "$TEST_DIR/tls/server.crt" \
        "https://127.0.0.1:$candidate/" >/dev/null 2>&1; then
        handshake_port="$candidate"
        break
      fi
      sleep 0.1
    done
    if [[ -n "$handshake_port" ]]; then break; fi
    kill "$handshake_pid" 2>/dev/null || true
    wait "$handshake_pid" 2>/dev/null || true
    handshake_pid=""
  done
  [[ -n "$handshake_port" ]] ||
    fail "The openssl s_server fixture did not become ready; the real TLS handshake proof could not run."
  SERVER_PID="$handshake_pid"

  curl -sS --max-time 5 --cacert "$TEST_DIR/tls/server.crt" \
    "https://127.0.0.1:$handshake_port/" >/dev/null 2>&1 ||
    fail "Real TLS handshake proof failed: curl rejected the deployed certificate chain."

  handshake_rc=0
  curl -sS --max-time 5 --cacert "$TEST_DIR/tls/other.crt" \
    "https://127.0.0.1:$handshake_port/" >/dev/null 2>&1 || handshake_rc=$?
  [[ "$handshake_rc" -eq 60 ]] ||
    fail "Real TLS handshake proof failed: curl exited with $handshake_rc for an unrelated CA; verification would be bypassed."

  handshake_rc=0
  curl -sS --max-time 5 "https://127.0.0.1:$handshake_port/" >/dev/null 2>&1 || handshake_rc=$?
  [[ "$handshake_rc" -eq 60 ]] ||
    fail "Real TLS handshake proof failed: curl exited with $handshake_rc without a CA override against a self-signed server."

  handshake_rc=0
  curl -sS --max-time 5 "http://127.0.0.1:$handshake_port/" >/dev/null 2>&1 || handshake_rc=$?
  [[ "$handshake_rc" -ne 0 ]] ||
    fail "Real TLS handshake proof failed: the TLS fixture accepted plain HTTP; the HTTPS cases would not prove TLS usage."

  printf 'PASS: real TLS handshake against openssl s_server: the deployed chain verifies, an unrelated CA and the system trust store are rejected with curl exit 60, and plain HTTP is refused.\n'
fi

if [[ "$CERT_FIXTURE_KIND" == "real" ]]; then
  printf 'CLI TLS/URL checks passed (%s cases plus the real TLS handshake proof; HTTP mode, verified HTTPS, missing CA, keystore variant, and safe failure paths covered).\n' \
    "$case_count"
else
  printf 'CLI TLS/URL checks passed (%s cases; the real TLS handshake proof was skipped because openssl is unavailable on this runner).\n' \
    "$case_count"
fi
