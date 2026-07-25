#!/usr/bin/env bash
#
# Moddex build pipeline — single source of truth.
#
# The same script runs locally and inside GitHub Actions. The workflows only
# provide a checkout and a runner; every build, test and verification step lives
# here. That way a green local run and a green CI run mean the same thing, and a
# broken pipeline can be reproduced on a workstation without pushing a commit.
#
# Usage:
#   scripts/ci/pipeline.sh [options] [stage ...]
#
# Stages (run in this order when none are named):
#   tools      Verify the toolchain required by the selected stages.
#   lint       shellcheck over the shell scripts, PSScriptAnalyzer over PowerShell.
#   backend    Backend unit tests (clean) and the production JAR.
#   frontend   Frontend install, headless unit tests and the production build.
#   bundle     Assemble the installable Linux bundle.
#   verify     Check the assembled bundle: structure, file modes, no stray sources.
#
# Options:
#   --repo-root DIR        Directory holding the three repo checkouts.
#                          Default: the parent of this repository.
#   --backend-dir DIR      Override the backend checkout location.
#   --frontend-dir DIR     Override the frontend checkout location.
#   --version VERSION      Version label baked into the bundle. Default: $VERSION or "dev".
#   --allow-missing-tools  Downgrade absent optional tools to warnings instead of
#                          failing. Intended for workstations; CI never passes it,
#                          so a missing linter can never silently skip a check.
#   --list                 List the available stages and exit.
#   -h, --help             Show this help and exit.
#
# Environment:
#   MODDEX_BACKEND_DIR, MODDEX_FRONTEND_DIR, VERSION, CHROME_BIN
#
# Exit code is non-zero if any selected stage fails.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ALL_STAGES=(tools lint backend frontend bundle verify)

REPO_ROOT=""
BACKEND_DIR="${MODDEX_BACKEND_DIR:-}"
FRONTEND_DIR="${MODDEX_FRONTEND_DIR:-}"
VERSION="${VERSION:-dev}"
ALLOW_MISSING_TOOLS=0
REQUESTED_STAGES=()

# Artefacts handed from the build stages to the bundle stage. Empty when those
# stages were not selected, in which case the bundle builder builds from source.
BUILT_BACKEND_JAR=""
BUILT_FRONTEND_DIST=""

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi

log()  { printf '%s[pipeline]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

stage_banner() {
  printf '\n%s=== %s ===%s\n' "$C_BOLD" "$*" "$C_RESET"
}

usage() { grep '^#' "$0" | sed '1d;s/^# \{0,1\}//'; }

# Records one result row per stage for the closing summary.
SUMMARY_NAMES=()
SUMMARY_STATES=()
SUMMARY_NOTES=()

record() {
  SUMMARY_NAMES+=("$1")
  SUMMARY_STATES+=("$2")
  SUMMARY_NOTES+=("${3:-}")
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)   [[ $# -ge 2 ]] || die "Missing value for --repo-root";   REPO_ROOT="$2"; shift 2 ;;
    --backend-dir) [[ $# -ge 2 ]] || die "Missing value for --backend-dir"; BACKEND_DIR="$2"; shift 2 ;;
    --frontend-dir)[[ $# -ge 2 ]] || die "Missing value for --frontend-dir";FRONTEND_DIR="$2"; shift 2 ;;
    --version)     [[ $# -ge 2 ]] || die "Missing value for --version";     VERSION="$2"; shift 2 ;;
    --allow-missing-tools) ALLOW_MISSING_TOOLS=1; shift ;;
    --list)        printf '%s\n' "${ALL_STAGES[@]}"; exit 0 ;;
    -h|--help)     usage; exit 0 ;;
    -*)            die "Unknown option: $1" ;;
    *)
      # shellcheck disable=SC2076
      [[ " ${ALL_STAGES[*]} " == *" $1 "* ]] || die "Unknown stage: $1 (see --list)"
      REQUESTED_STAGES+=("$1"); shift ;;
  esac
done

if [[ ${#REQUESTED_STAGES[@]} -eq 0 ]]; then
  REQUESTED_STAGES=("${ALL_STAGES[@]}")
fi

# The toolchain check is never optional. Naming stages explicitly
# (`pipeline.sh lint`) must not be a way around the missing-tool policy —
# otherwise a machine without shellcheck would run that command, skip the
# linting, and exit 0.
# shellcheck disable=SC2076
if [[ " ${REQUESTED_STAGES[*]} " != *" tools "* ]]; then
  REQUESTED_STAGES=(tools "${REQUESTED_STAGES[@]}")
fi

wants_stage() {
  # shellcheck disable=SC2076
  [[ " ${REQUESTED_STAGES[*]} " == *" $1 "* ]]
}

# -----------------------------------------------------------------------------
# Locate the sibling checkouts
# -----------------------------------------------------------------------------
[[ -n "$REPO_ROOT" ]] || REPO_ROOT="$(cd "${PROJECT_ROOT}/.." && pwd)"
[[ -n "$BACKEND_DIR" ]]  || BACKEND_DIR="${REPO_ROOT}/Moddex-Backend"
[[ -n "$FRONTEND_DIR" ]] || FRONTEND_DIR="${REPO_ROOT}/Moddex-Frontend"

BUILD_DIR="${PROJECT_ROOT}/build"
BUNDLE_DIR="${BUILD_DIR}/bundle"

# Scratch directories for the backend tests. Booting the full application
# context makes the backend persist its JWT secret and settings; pointed at the
# real defaults (/etc/moddex) that fails on any machine where the tester is not
# root — which is every CI runner (Moddex-Backend#55).
TEST_STATE_DIR="${BUILD_DIR}/test-state"

# -----------------------------------------------------------------------------
# Tool handling
#
# A tool is either required for a selected stage (absence fails) or optional.
# --allow-missing-tools turns a required-tool failure into a warning so a
# workstation without, say, PowerShell can still run the rest. CI must never
# pass that flag: a linter that is silently skipped is worse than no linter.
# -----------------------------------------------------------------------------
MISSING_TOOLS=()

have() { command -v "$1" >/dev/null 2>&1; }

# Returns non-zero only when the absence should fail the run. Under
# --allow-missing-tools it records the gap, warns, and reports success so the
# caller continues — returning 1 there would make the flag do nothing.
require_tool() {
  local tool="$1" reason="$2"
  if have "$tool"; then
    return 0
  fi
  MISSING_TOOLS+=("$tool ($reason)")
  if [[ "$ALLOW_MISSING_TOOLS" -eq 1 ]]; then
    warn "missing tool: $tool — $reason (continuing because --allow-missing-tools)"
    return 0
  fi
  return 1
}

# Angular's karma builder needs a Chrome binary. Resolve one so a workstation
# does not have to export CHROME_BIN by hand.
# A candidate counts only if it actually starts. A Chrome build whose shared
# libraries are missing is present on PATH and executable, but every test run
# against it dies with a linker error that looks nothing like a browser problem.
chrome_runs() {
  "$1" --version >/dev/null 2>&1
}

resolve_chrome() {
  if [[ -n "${CHROME_BIN:-}" && -x "${CHROME_BIN}" ]] && chrome_runs "${CHROME_BIN}"; then
    return 0
  fi
  local candidate resolved
  for candidate in chromium chromium-browser google-chrome google-chrome-stable; do
    if have "$candidate"; then
      resolved="$(command -v "$candidate")"
      if chrome_runs "$resolved"; then
        CHROME_BIN="$resolved"
        export CHROME_BIN
        return 0
      fi
      warn "found $candidate at $resolved but it does not run (missing libraries?)"
    fi
  done
  return 1
}

stage_tools() {
  stage_banner "tools"
  local failed=0

  # Always needed to do anything useful.
  have bash || die "bash is required"
  for tool in git tar sha256sum find; do
    require_tool "$tool" "core pipeline plumbing" || failed=1
  done

  if wants_stage backend || wants_stage bundle; then
    require_tool java "backend build (JDK 21)" || failed=1
  fi
  if wants_stage frontend || wants_stage bundle; then
    require_tool node "frontend build" || failed=1
    require_tool npm "frontend build" || failed=1
  fi
  if wants_stage frontend; then
    if resolve_chrome; then
      log "Chrome for headless tests: ${CHROME_BIN}"
    else
      MISSING_TOOLS+=("chromium (headless frontend unit tests)")
      if [[ "$ALLOW_MISSING_TOOLS" -eq 1 ]]; then
        warn "no Chrome/Chromium found — frontend unit tests will be skipped"
      else
        failed=1
      fi
    fi
  fi
  if wants_stage lint; then
    require_tool shellcheck "shell script linting" || failed=1
    require_tool pwsh "PowerShell script analysis" || failed=1
  fi

  if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    printf '\n%sMissing tools:%s\n' "$C_BOLD" "$C_RESET" >&2
    printf '  - %s\n' "${MISSING_TOOLS[@]}" >&2
    cat >&2 <<'HINT'

  Debian/Ubuntu:  sudo apt-get install -y shellcheck chromium
  PowerShell:     https://github.com/PowerShell/PowerShell/releases (linux-x64 tarball)
HINT
  fi

  if [[ "$failed" -ne 0 ]]; then
    cat >&2 <<'HINT'

Install the tools above, or re-run with --allow-missing-tools to continue with
reduced coverage. Never pass --allow-missing-tools in CI: a skipped check that
reports success is indistinguishable from a passing one.
HINT
    return 1
  fi

  # Report the versions actually used, so a failing run can be reproduced.
  have java && log "java:  $(java -version 2>&1 | head -n1)"
  have node && log "node:  $(node -v)"
  have npm  && log "npm:   $(npm -v)"
  have shellcheck && log "shellcheck: $(shellcheck --version | awk '/^version:/{print $2}')"
  have pwsh && log "pwsh:  $(pwsh --version)"

  if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    record tools partial "${#MISSING_TOOLS[@]} tool(s) missing, coverage reduced"
  else
    record tools ok
  fi
  return 0
}

# -----------------------------------------------------------------------------
# lint
# -----------------------------------------------------------------------------
stage_lint() {
  stage_banner "lint"
  local rc=0

  # Collect shell scripts by shebang rather than by extension: the CLI entry
  # point `scripts/moddex` has no .sh suffix but is very much a shell script.
  local shell_files=() file
  while IFS= read -r file; do
    case "$file" in
      *.sh) shell_files+=("$file") ;;
      *)
        if head -n1 "$file" 2>/dev/null | grep -qE '^#!.*\b(ba)?sh\b'; then
          shell_files+=("$file")
        fi ;;
    esac
  done < <(find "${PROJECT_ROOT}/scripts" -type f | sort)

  if [[ ${#shell_files[@]} -eq 0 ]]; then
    warn "no shell scripts found under scripts/"
  else
    log "Checking ${#shell_files[@]} shell scripts"

    # bash -n first: a syntax error makes shellcheck output far less readable.
    for file in "${shell_files[@]}"; do
      bash -n "$file" || { warn "syntax error: $file"; rc=1; }
    done

    if have shellcheck; then
      # -x follows `source`d files. External SC directives stay in the scripts.
      shellcheck -x -S warning "${shell_files[@]}" || rc=1
    else
      warn "shellcheck unavailable — shell linting skipped"
    fi
  fi

  # Executable bits: the installer and CLI are executed straight from the
  # bundle, so a lost +x turns into a runtime failure on the operator's machine.
  local not_exec=()
  for file in "${shell_files[@]}"; do
    [[ -x "$file" ]] || not_exec+=("${file#"${PROJECT_ROOT}/"}")
  done
  if [[ ${#not_exec[@]} -gt 0 ]]; then
    warn "shell scripts without the executable bit:"
    printf '  - %s\n' "${not_exec[@]}" >&2
    rc=1
  fi

  # PowerShell: parse check plus PSScriptAnalyzer when it is installed.
  local ps_dir="${PROJECT_ROOT}/scripts/windows"
  if [[ -d "$ps_dir" ]] && have pwsh; then
    log "Analysing PowerShell scripts in ${ps_dir#"${PROJECT_ROOT}/"}"
    # The analyzer module is fetched on demand. If that fails the helper exits
    # non-zero unless reduced coverage was explicitly accepted here too.
    local ps_args=(-Path "$ps_dir")
    [[ "$ALLOW_MISSING_TOOLS" -eq 1 ]] && ps_args+=(-AllowMissingAnalyzer)
    pwsh -NoProfile -NonInteractive -File "${SCRIPT_DIR}/lint-powershell.ps1" "${ps_args[@]}" || rc=1
  elif [[ -d "$ps_dir" ]]; then
    warn "pwsh unavailable — PowerShell analysis skipped"
  fi

  if [[ "$rc" -eq 0 ]]; then record lint ok; else record lint failed; fi
  return "$rc"
}

# -----------------------------------------------------------------------------
# backend
# -----------------------------------------------------------------------------
stage_backend() {
  stage_banner "backend"
  [[ -f "${BACKEND_DIR}/pom.xml" ]] || die "Backend project not found at ${BACKEND_DIR}"

  # Every stage runs as the condition of an `if`, which disables errexit inside
  # it, so setup that must succeed is checked explicitly. A silently failed
  # scratch-directory reset would let the tests run against stale state and
  # still report success.
  chmod +x "${BACKEND_DIR}/mvnw" || {
    record backend failed "mvnw not executable"; return 1
  }

  # Point every writable path at a scratch directory. Without this the context
  # test writes to /etc/moddex and /var/log/moddex.
  rm -rf "${TEST_STATE_DIR}" || {
    record backend failed "could not clear ${TEST_STATE_DIR}"; return 1
  }
  mkdir -p "${TEST_STATE_DIR}"/{data,config,logs} || {
    record backend failed "could not create ${TEST_STATE_DIR}"; return 1
  }

  # `clean` is not optional. A previous build leaves compiled test classes in
  # target/, and surefire happily runs classes whose sources no longer exist —
  # producing failures for tests that are not in the tree and, worse, green runs
  # for tests that were deleted.
  log "Running backend unit tests (clean)"
  (
    cd "${BACKEND_DIR}"
    MODDEX_ROOT="${TEST_STATE_DIR}/data" \
    MODDEX_CONFIG_DIR="${TEST_STATE_DIR}/config" \
    MODDEX_LOG_DIR="${TEST_STATE_DIR}/logs" \
      ./mvnw -B -Pci clean test
  ) || { record backend failed "unit tests"; return 1; }

  log "Packaging production JAR"
  (
    cd "${BACKEND_DIR}"
    ./mvnw -B -Pprod -DskipTests package
  ) || { record backend failed "package"; return 1; }

  local jar
  jar="$(find "${BACKEND_DIR}/target" -maxdepth 1 -name 'Moddex-Backend-*.jar' ! -name '*-sources.jar' | head -n1)"
  [[ -n "$jar" ]] || { record backend failed "no JAR produced"; die "Backend JAR not found in ${BACKEND_DIR}/target"; }
  log "Backend JAR: ${jar#"${REPO_ROOT}/"} ($(du -h "$jar" | cut -f1))"

  # Handed to the bundle stage so it packages exactly the artefact that was just
  # tested, rather than compiling the project a second time.
  BUILT_BACKEND_JAR="$jar"

  record backend ok
  return 0
}

# -----------------------------------------------------------------------------
# frontend
# -----------------------------------------------------------------------------
stage_frontend() {
  stage_banner "frontend"
  [[ -f "${FRONTEND_DIR}/package.json" ]] || die "Frontend project not found at ${FRONTEND_DIR}"

  log "Installing dependencies"
  (
    cd "${FRONTEND_DIR}"
    if [[ -f package-lock.json ]]; then
      # `ci` is reproducible and fails on a lockfile that drifted from
      # package.json — exactly what a pipeline wants.
      npm ci
    else
      warn "no package-lock.json — falling back to npm install (not reproducible)"
      npm install
    fi
  ) || { record frontend failed "install"; return 1; }

  if resolve_chrome; then
    log "Running unit tests headless (${CHROME_BIN})"
    (
      cd "${FRONTEND_DIR}"
      CHROME_BIN="${CHROME_BIN}" npm run test -- --watch=false --browsers=ChromeHeadless
    ) || { record frontend failed "unit tests"; return 1; }
  else
    warn "no Chrome/Chromium — unit tests skipped"
    record frontend partial "tests skipped (no Chrome)"
  fi

  log "Production build"
  (
    cd "${FRONTEND_DIR}"
    npm run build -- --configuration production
  ) || { record frontend failed "production build"; return 1; }

  local index
  index="$(resolve_frontend_index)" || {
    record frontend failed "no index.html in dist"
    die "Frontend build produced no index.html under ${FRONTEND_DIR}/dist"
  }
  BUILT_FRONTEND_DIST="${index%/index.html}"
  log "Frontend output: ${BUILT_FRONTEND_DIST}"

  # Only record success when the tests actually ran.
  if [[ "${SUMMARY_NAMES[*]: -1}" != "frontend" ]]; then
    record frontend ok
  fi
  return 0
}

# Resolves the directory Angular actually emitted the browser build into and
# echoes the path to its index.html.
#
# `@angular/build:application` writes to dist/<project>/browser/ by default, and
# the project name is not something the packaging repo should have to guess. Any
# consumer that assumes dist/index.html silently ships an empty UI (Moddex#61),
# so the location is resolved from the artefact itself.
resolve_frontend_index() {
  local dist="${FRONTEND_DIR}/dist"
  [[ -d "$dist" ]] || return 1
  local found
  found="$(find "$dist" -maxdepth 4 -name index.html -type f \
    -not -path '*/node_modules/*' -not -path '*/server/*' | sort | head -n1)"
  [[ -n "$found" ]] || return 1
  printf '%s' "$found"
}

# -----------------------------------------------------------------------------
# bundle
# -----------------------------------------------------------------------------
stage_bundle() {
  stage_banner "bundle"
  local builder="${PROJECT_ROOT}/scripts/build-bundle.sh"
  [[ -f "$builder" ]] || die "Bundle builder not found at $builder"

  # Checked explicitly: errexit does not apply inside a stage (see stage_backend).
  chmod +x "$builder" || { record bundle failed "builder not executable"; return 1; }

  # Reuse what the earlier stages produced. Packaging the exact artefacts that
  # were just tested is both faster and more honest than rebuilding them: a
  # second compile could, in principle, produce something the tests never saw.
  local args=()
  if [[ -n "${BUILT_BACKEND_JAR:-}" ]]; then
    args+=(--backend-jar "${BUILT_BACKEND_JAR}")
  fi
  if [[ -n "${BUILT_FRONTEND_DIST:-}" ]]; then
    args+=(--frontend-dist "${BUILT_FRONTEND_DIST}")
  fi

  if [[ ${#args[@]} -gt 0 ]]; then
    log "Assembling bundle (version ${VERSION}, reusing built artefacts)"
  else
    log "Assembling bundle (version ${VERSION}, building from source)"
  fi

  # The builder resolves the checkouts itself when it has to build from source,
  # so the pipeline's --repo-root/--backend-dir/--frontend-dir overrides have to
  # reach it. Without this it would silently fall back to the repos next to the
  # packaging checkout and build something other than what was asked for.
  VERSION="${VERSION}" \
  MODDEX_BACKEND_DIR="${BACKEND_DIR}" \
  MODDEX_FRONTEND_DIR="${FRONTEND_DIR}" \
    "$builder" "${args[@]+"${args[@]}"}" || { record bundle failed; return 1; }

  record bundle ok
  return 0
}

# -----------------------------------------------------------------------------
# verify
#
# Checks the assembled artefact rather than the sources. Every check here failed
# silently at some point in this project's history: a bundle with no UI still
# installed "successfully", and scripts that lost their executable bit only
# surfaced on the operator's machine.
# -----------------------------------------------------------------------------
# Checks run as functions taking real arguments rather than as interpolated
# `bash -c` strings: a path or version label containing a quote would otherwise
# produce malformed shell and fail a perfectly good bundle.
no_typescript_sources() {
  ! find "$1" -name '*.ts' -not -name '*.d.ts' -print -quit | grep -q .
}

checksum_verifies() {
  ( cd "$1" && sha256sum -c "$2" )
}

stage_verify() {
  stage_banner "verify"
  local rc=0

  [[ -d "$BUNDLE_DIR" ]] || { record verify failed "no bundle"; die "No bundle at $BUNDLE_DIR — run the bundle stage first"; }

  check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
      printf '  %sPASS%s %s\n' "$C_GREEN" "$C_RESET" "$label"
    else
      printf '  %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$label"
      rc=1
    fi
  }

  # --- Structure ---
  check "backend JAR present"        test -f "${BUNDLE_DIR}/backend/Moddex-Backend.jar"
  check "frontend index.html at the bundle root" test -f "${BUNDLE_DIR}/frontend/index.html"
  check "installer present"          test -f "${BUNDLE_DIR}/scripts/install.sh"
  check "systemd unit present"       test -f "${BUNDLE_DIR}/packaging/systemd/moddex-backend.service"
  check "VERSION file present"       test -f "${BUNDLE_DIR}/VERSION"

  # --- Executability: these are run directly out of the extracted bundle ---
  local script
  for script in install.sh uninstall.sh update.sh download.sh moddex; do
    if [[ -e "${BUNDLE_DIR}/scripts/${script}" ]]; then
      check "scripts/${script} is executable" test -x "${BUNDLE_DIR}/scripts/${script}"
    fi
  done

  # --- The frontend must be a built artefact, not a source tree ---
  check "no node_modules in the bundle" test ! -d "${BUNDLE_DIR}/frontend/node_modules"
  check "no TypeScript sources in the bundle" no_typescript_sources "${BUNDLE_DIR}/frontend"

  # --- Archive + checksum ---
  local archive="${BUILD_DIR}/moddex-${VERSION}-linux-amd64.tar.gz"
  check "archive produced" test -f "$archive"
  if [[ -f "${archive}.sha256" ]]; then
    check "checksum verifies" checksum_verifies "${BUILD_DIR}" "$(basename "${archive}.sha256")"
  else
    printf '  %sFAIL%s checksum file present\n' "$C_RED" "$C_RESET"
    rc=1
  fi

  if [[ "$rc" -eq 0 ]]; then record verify ok; else record verify failed; fi
  return "$rc"
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
print_summary() {
  local overall="$1"
  printf '\n%s=== summary ===%s\n' "$C_BOLD" "$C_RESET"
  local i state colour
  for i in "${!SUMMARY_NAMES[@]}"; do
    state="${SUMMARY_STATES[$i]}"
    case "$state" in
      ok)      colour="$C_GREEN" ;;
      partial) colour="$C_YELLOW" ;;
      *)       colour="$C_RED" ;;
    esac
    printf '  %-10s %s%-8s%s %s\n' \
      "${SUMMARY_NAMES[$i]}" "$colour" "$state" "$C_RESET" "${SUMMARY_NOTES[$i]}"
  done

  # GitHub renders this in the job summary, so a failed run is readable without
  # scrolling through the raw log.
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### Pipeline"
      echo
      echo "| Stage | Result | Note |"
      echo "|-------|--------|------|"
      for i in "${!SUMMARY_NAMES[@]}"; do
        echo "| ${SUMMARY_NAMES[$i]} | ${SUMMARY_STATES[$i]} | ${SUMMARY_NOTES[$i]:-—} |"
      done
      echo
      echo "Version: \`${VERSION}\`"
    } >> "$GITHUB_STEP_SUMMARY"
  fi

  if [[ "$overall" -eq 0 ]]; then
    printf '\n%sPipeline passed.%s\n' "$C_GREEN" "$C_RESET"
  else
    printf '\n%sPipeline failed.%s\n' "$C_RED" "$C_RESET"
  fi
}

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------
log "Packaging repo: ${PROJECT_ROOT}"
log "Backend:        ${BACKEND_DIR}"
log "Frontend:       ${FRONTEND_DIR}"
log "Version:        ${VERSION}"
log "Stages:         ${REQUESTED_STAGES[*]}"

OVERALL=0
for stage in "${ALL_STAGES[@]}"; do
  wants_stage "$stage" || continue
  # `set -e` must not abort the loop: every stage should report, and the summary
  # is more useful than a run that stops at the first problem. `tools` is the
  # exception — building without a verified toolchain only produces noise.
  if ! "stage_${stage}"; then
    OVERALL=1
    if [[ "$stage" == "tools" ]]; then
      record tools failed "toolchain incomplete"
      print_summary "$OVERALL"
      exit 1
    fi
  fi
done

print_summary "$OVERALL"
exit "$OVERALL"
