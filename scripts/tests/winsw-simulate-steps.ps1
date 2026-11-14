#Requires -Version 7.0
<#
.SYNOPSIS
    Isolated WinSW simulation harness for the Moddex Windows installer
    (Forgejo issues #564 foundation, #198 exitcode contract, #200 staged
    upgrade flow).

.DESCRIPTION
    Verifies the Windows installer's native WinSW step handling WITHOUT
    touching any real Windows service, SCM or productive data:

      1. Parse check of every *.ps1 under scripts/windows and scripts/tests
         via the PowerShell language parser (pattern taken from the source
         repository's scripts/ci/lint-powershell.ps1 at f0898ffa; parse-only,
         no PSScriptAnalyzer download in this harness).
      2. Well-formedness check of packaging/windows/moddex-backend.xml.template
         plus a placeholder cross-check against the substitutions table in
         install.ps1 (drift between installer and template fails here, before
         any simulated run).
      3. Contract extraction (issues #198 and #200): every native WinSW call in
         install.ps1 and uninstall.ps1 must go through the Invoke-ServiceStep
         wrapper. No direct `& $ServiceExe ...` invocation may remain, the
         wrapper must reference $LASTEXITCODE and abort via Die, and the
         ordered step list per script must match the audited contract:
         the MAIN-FLOW call sites of install.ps1 must remain
         stop, uninstall, install, start (uninstall.ps1: stop, uninstall) and
         the only function that may carry wrapper call sites is the #200
         rollback function Invoke-UpgradeRollback with uninstall, install,
         start - the service restoration steps of the #200 case matrix
         (remove a fresh-install registration, re-register the previous
         service when the old registration was uninstalled and no new one
         exists, start the previous service; a registration this run created
         is reused without a duplicate install). When later issues change
         these scripts, the assertions fail until the harness is
         re-validated against the new contract - by design.
      4. Runtime simulation of the #198 behaviour: the verbatim function
         bodies extracted from the real scripts (Write-Log, Die,
         Invoke-ServiceStep) run in an isolated child pwsh process against a
         generated stub executable (moddex-backend.exe) that logs every
         invocation and returns a configurable exit code per step.
           - Stub exit code 0: the step must succeed (child exit 0).
           - Nonzero stub exit code: the real wrapper must abort (child exit
             nonzero) with the guided message naming the step, the exit code
             and the concrete wrapper log location. A child that continues on
             a nonzero code is a contract violation (silent swallow), as is a
             child that fails without the guided message.
         The harness reports a verified abort as the expected observable of a
         failing scenario and still exits nonzero (the simulated installer run
         aborted); exit 0 is reserved for a fully successful chain, exit 1 for
         aborted or violating runs, which the driver test tells apart via its
         grep assertions.
      5. Flow simulation of the #200 staged upgrade (-FlowSimBundle): the REAL
         param block, main statements and helper functions of install.ps1 are
         extracted verbatim into a generated variant inside the simulation
         bundle; only the platform-bound entry points are simulation shims
         (Assert-Admin, Resolve-WinSw, Get-Service) and the file cmdlets
         Copy-Item/Move-Item/Remove-Item run as journaling shims that delegate
         to the real cmdlets and can fail once on demand
         (MODDEX_SIM_FAILSPEC "<op>:<ordinal>") to exercise the #200 rollback.
         The native WinSW steps run against the generated stub, whose calls
         share one journal file with the file operations so the driver can
         assert the real ordering: staging before the service stop,
         rename-aside before rename-in, rollback before the guided abort.
         Pass 4 does not run in flow mode (the driver covers it with its own
         success scenario).

    The harness runs on Linux/macOS pwsh only. It never installs, stops or
    removes a real Windows service and never touches anything outside its
    fixture directory.

.PARAMETER RepoRoot
    Repository root holding scripts/windows and packaging/windows.

.PARAMETER FixtureDir
    Directory for the generated stub, its log, the generated child executor
    and the captured child output. Created if missing. A caller-provided
    fixture is left in place so the caller cleans it up and can inspect the
    stub log; the auto-generated temp fixture is removed after the run unless
    -KeepFixture is passed.

.PARAMETER ExitCodes
    Optional stub control file with lines "step=code" (for example
    "install=3"). Steps without an entry exit 0. "step=code:N" fails the first
    N invocations of that step and succeeds afterwards (used by the #200 flow
    simulation to fail the new service start once and let the rollback's start
    succeed). "step=code:>N" succeeds for the first N invocations and fails
    with that code from invocation N+1 on - used to model real WinSW
    semantics that are not normalized, e.g. a second install on an
    already-registered service id fails with ERROR_SERVICE_EXISTS (1073),
    which pins that the #200 rollback does not re-register a registration
    this run just created. A nonzero code is the documented way to exercise
    the #198 controlled-abort contract; the run must then abort at that step
    with the guided message and exit nonzero.

.PARAMETER FlowSimBundle
    Enables the #200 flow simulation (pass 5) and points at the simulation
    bundle laid out by the driver: backend/, frontend/, VERSION and
    packaging/windows/moddex-backend.xml.template (Join-Path normalizes the
    backslash literals of install.ps1 to this directory on Linux). The
    generated variant is written to
    <bundle>/scripts/windows/install.ps1 so the script-relative bundle
    resolution ($BundleRoot, $PackagingWin) resolves inside the fixture. The
    driver also provides MODDEX_SIM_SERVICE_EXISTS (0|1) and
    MODDEX_SIM_FAILSPEC in the environment and redirects
    $env:ProgramFiles/$env:ProgramData/$env:TEMP into the fixture.

.PARAMETER FlowStubDest
    Flow simulation only: where to place a copy of the generated WinSW stub
    (the ServiceExe of the simulated previous installation), so the stub
    content stays single-sourced in this harness.

.PARAMETER FlowInstallMode
    Flow simulation only: passed to the generated variant as its -Mode
    parameter. A fresh-install scenario (no existing service definition to
    inherit from) must supply it, or Resolve-Config aborts before staging.

.PARAMETER KeepFixture
    Keep the fixture directory for manual inspection (only honored for the
    default temp fixture; the caller-owned -FixtureDir is never removed).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $RepoRoot,

    [string] $FixtureDir,

    [string] $ExitCodes,

    [string] $FlowSimBundle,

    [string] $FlowStubDest,

    [string] $FlowInstallMode,

    [switch] $KeepFixture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The stub is a POSIX shell script masquerading as the WinSW wrapper binary
# (moddex-backend.exe). PowerShell's `&` invocation honours the shebang on
# Unix, so the simulated calls keep the native-call shape of install.ps1.
# Exitcode control file syntax: "step=code" always fails with that code;
# "step=code:N" fails the first N invocations of the step and exits 0
# afterwards; "step=code:>N" succeeds for the first N invocations and fails
# with that code from invocation N+1 on (counts taken from this stub's own
# exact log lines). ">N" models real WinSW semantics that are not normalized:
# a second install on an already-registered service id fails with
# ERROR_SERVICE_EXISTS (1073) - used by the #200 flow simulation to pin that
# the rollback does NOT re-register a registration this run just created.
$StubScript = @'
#!/bin/sh
# Generated WinSW test stub (Moddex issues #564/#198/#200 simulation). Not a
# real Windows service; runs only inside an isolated test fixture directory.
log_path="${MODDEX_WINSW_STUB_LOG:-}"
conf_path="${MODDEX_WINSW_STUB_EXITCODES:-}"
if [ -z "$log_path" ]; then
  printf 'winsw stub: MODDEX_WINSW_STUB_LOG is not set\n' >&2
  exit 90
fi
printf '%s\n' "$*" >> "$log_path"
step="${1:-}"
code=0
if [ -n "$conf_path" ] && [ -f "$conf_path" ]; then
  line="$(grep -m1 "^${step}=" "$conf_path" 2>/dev/null || true)"
  if [ -n "$line" ]; then
    raw="${line#*=}"
    limit=""
    fail_from=0
    case "$raw" in
      *:*)
        limit="${raw##*:}"
        raw="${raw%:*}"
        ;;
    esac
    case "$limit" in
      ">"*)
        fail_from=1
        limit="${limit#\>}"
        ;;
    esac
    case "$raw" in
      ''|*[!0-9]*) code=0 ;;
      *) code="$raw" ;;
    esac
    if [ -n "$limit" ]; then
      case "$limit" in
        ''|*[!0-9]*) limit="" ;;
      esac
    fi
    if [ -n "$limit" ]; then
      seen="$(grep -cx "$step" "$log_path" 2>/dev/null || true)"
      seen="${seen:-0}"
      case "$seen" in
        *[!0-9]*) seen=0 ;;
      esac
      if [ "$fail_from" -eq 1 ]; then
        if [ "$seen" -gt "$limit" ]; then
          code="$raw"
        else
          code=0
        fi
      else
        if [ "$seen" -le "$limit" ]; then
          code="$raw"
        else
          code=0
        fi
      fi
    fi
  fi
fi
exit "$code"
'@

# Generated child executor: parses one real installer script, extracts the
# verbatim function bodies the wrapper depends on (Write-Log, Die) plus the
# wrapper itself, and runs ONE wrapper call against the stub. Running each
# step in its own child process lets the harness observe the real abort
# behaviour (Die -> terminating error -> nonzero process exit) without ever
# executing the scripts' main bodies, which would touch real services.
$ChildScript = @'
# Generated child executor for the WinSW simulation harness (Moddex Forgejo
# issues #564/#198). Runs only inside the harness fixture against a generated
# stub executable; it never touches a real Windows service.
param(
    [Parameter(Mandatory = $true)] [string] $SourceScript,
    [Parameter(Mandatory = $true)] [string] $StubPath,
    [Parameter(Mandatory = $true)] [string] $Step,
    [Parameter(Mandatory = $true)] [string] $LogDir
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $SourceScript, [ref] $tokens, [ref] $parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    throw "Simulation child: parse errors in $SourceScript; nothing was executed."
}

# Reproduce the script-scope helpers the wrapper depends on and the wrapper
# itself - all verbatim from the real script, so the stub invocation and the
# $LASTEXITCODE handling are the real code, not a re-implementation.
foreach ($name in @('Write-Log', 'Die', 'Invoke-ServiceStep')) {
    $fn = $ast.FindAll(
        { param($node) ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $name) },
        $true) | Select-Object -First 1
    if (-not $fn) {
        throw "Simulation child: function '$name' not found in $SourceScript."
    }
    Invoke-Expression $fn.Extent.Text
}

# Run the real wrapper body against the stub. A nonzero stub exit code must
# produce the script's own guided abort, which terminates this child nonzero.
Invoke-ServiceStep -Executable $StubPath -Step $Step -LogDir $LogDir
exit 0
'@

function Write-Sim([string] $Message) { Write-Host "[winsw-sim] $Message" }
function Fail([string] $Message) {
    Write-Host "[winsw-sim] FAIL: $Message" -ForegroundColor Red
    exit 1
}

# Simulation preamble of the generated #200 flow variant (see pass 5): the
# platform-bound entry points become shims, the file cmdlets become journaling
# shims that delegate to the real cmdlets (module-qualified invocation) and
# can fail once on demand. Everything else in the variant is the real script.
$FlowPreamble = @'
# >>> Moddex #200 flow-simulation preamble (generated; not part of the real installer) >>>
Set-StrictMode -Version Latest

$script:SimOpCounts = @{}

function Add-SimJournal([string] $Line) {
    Add-Content -LiteralPath $env:MODDEX_SIM_FILE_JOURNAL -Value $Line
}

function Assert-Admin { }

function Resolve-WinSw {
    param([string] $RequestedPath)
    Add-SimJournal "simop resolve-winsw requested=[$RequestedPath]"
    return $env:MODDEX_SIM_WINSW_EXE
}

function Get-Service {
    [CmdletBinding()] param([string] $Name)
    if ($env:MODDEX_SIM_SERVICE_EXISTS -eq '1') {
        return [pscustomobject]@{ Name = $Name; Status = 'Running' }
    }
    return $null
}

function Invoke-SimFileOp {
    param([string] $Op, [object[]] $CallArgs)
    if (-not $script:SimOpCounts.ContainsKey($Op)) { $script:SimOpCounts[$Op] = 0 }
    $script:SimOpCounts[$Op] = $script:SimOpCounts[$Op] + 1
    $ordinal = $script:SimOpCounts[$Op]
    $argText = ($CallArgs | ForEach-Object { "$_" }) -join ' '
    Add-SimJournal ("simop {0}#{1} {2}" -f $Op, $ordinal, $argText)
    $failSpec = "$env:MODDEX_SIM_FAILSPEC"
    if ($failSpec -eq ("{0}:{1}" -f $Op, $ordinal)) {
        Add-SimJournal ("simop-fail {0}#{1}" -f $Op, $ordinal)
        Write-Error "Simulated $Op failure (fail-once spec '$failSpec'); the real cmdlet was not invoked."
        return
    }
    switch ($Op) {
        'copy'   { Microsoft.PowerShell.Management\Copy-Item @CallArgs }
        'move'   { Microsoft.PowerShell.Management\Move-Item @CallArgs }
        'remove' { Microsoft.PowerShell.Management\Remove-Item @CallArgs }
    }
}

function Copy-Item { Invoke-SimFileOp -Op 'copy' -CallArgs $args }
function Move-Item { Invoke-SimFileOp -Op 'move' -CallArgs $args }
function Remove-Item { Invoke-SimFileOp -Op 'remove' -CallArgs $args }
# <<< Moddex #200 flow-simulation preamble <<<
'@

# --- environment guards ------------------------------------------------------
if (-not ($IsLinux -or $IsMacOS)) {
    Fail 'This simulation harness runs on Linux/macOS pwsh only (it executes a POSIX shell stub). Windows itself needs the real installer flow, not this simulation.'
}
$repoRootResolved = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
$installPath  = Join-Path $repoRootResolved 'scripts/windows/install.ps1'
$uninstallPath = Join-Path $repoRootResolved 'scripts/windows/uninstall.ps1'
$templatePath = Join-Path $repoRootResolved 'packaging/windows/moddex-backend.xml.template'
foreach ($required in @($installPath, $uninstallPath, $templatePath)) {
    if (-not (Test-Path -LiteralPath $required)) {
        Fail "Required Windows installer source not found: $required"
    }
}

# --- fixture -----------------------------------------------------------------
$fixtureOwned = $false
if (-not $FixtureDir) {
    $FixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ("winsw-sim-" + [guid]::NewGuid().ToString('N'))
    $fixtureOwned = $true
}
if (-not (Test-Path -LiteralPath $FixtureDir)) {
    New-Item -ItemType Directory -Force -Path $FixtureDir | Out-Null
}
$fixtureResolved = (Resolve-Path -LiteralPath $FixtureDir).Path

function Remove-Fixture {
    if (-not $fixtureOwned) { return }   # caller-owned fixture is the caller's cleanup
    if ($KeepFixture) { Write-Sim "Fixture kept: $fixtureResolved"; return }
    Remove-Item -LiteralPath $fixtureResolved -Recurse -Force -ErrorAction SilentlyContinue
}

# --- pass 1: parse check (no execution) --------------------------------------
$parseTargets = @()
foreach ($dir in @((Join-Path $repoRootResolved 'scripts/windows'), (Split-Path -Parent $PSCommandPath))) {
    $parseTargets += @(Get-ChildItem -LiteralPath $dir -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
}
if ($parseTargets.Count -eq 0) { Fail 'No .ps1 files found for the parse check.' }

foreach ($file in $parseTargets) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref] $tokens, [ref] $parseErrors) | Out-Null
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        foreach ($e in $parseErrors) {
            Write-Host ("[winsw-sim] PARSE {0}:{1}: {2}" -f $file.Name, $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red
        }
        Fail "Parse errors in $($file.Name) (see PARSE lines above); nothing was executed."
    }
}

# --- pass 2: template well-formedness and placeholder cross-check ------------
$templateSource = Get-Content -LiteralPath $templatePath -Raw
try {
    [xml] $null = $templateSource
} catch {
    Fail "Service template is not well-formed XML: $($_.Exception.Message)"
}
$installSource = Get-Content -LiteralPath $installPath -Raw

$substituted = @([regex]::Matches($installSource, "'@@([A-Z_]+)@@'\s*=") |
    ForEach-Object { $_.Groups[1].Value } |
    Sort-Object -Unique)
$xmlWithoutComments = [regex]::Replace($templateSource, '(?s)<!--.*?-->', '')
$templatePlaceholders = @([regex]::Matches($xmlWithoutComments, '@@([A-Z_]+)@@') |
    ForEach-Object { $_.Groups[1].Value } |
    Sort-Object -Unique)

if (Compare-Object $substituted $templatePlaceholders -SyncWindow 0) {
    Fail ("Placeholder drift between install.ps1 substitutions and the service template. Installer: {0}. Template: {1}." -f ($substituted -join ', '), ($templatePlaceholders -join ', '))
}

# --- pass 3: #198 contract via AST -------------------------------------------
# Since the #198 fix, install.ps1 and uninstall.ps1 drive their native WinSW
# steps through the Invoke-ServiceStep wrapper, which evaluates $LASTEXITCODE
# and aborts via Die on a nonzero code. The contract asserted here:
#   - no direct `& $ServiceExe ...` invocation remains anywhere;
#   - each script defines Invoke-ServiceStep with exactly one native
#     invocation (`& $Executable <Step> ...`), a $LASTEXITCODE reference and a
#     Die call;
#   - every wrapper call site passes -Executable $ServiceExe, a literal -Step
#     and -LogDir, and the ordered step list matches the audited contract.
$scriptAsts = @{}
function Get-ParsedAst {
    param([string] $Path)
    if (-not $scriptAsts.ContainsKey($Path)) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref] $tokens, [ref] $parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            Fail "Unexpected parse errors in $Path during contract extraction."
        }
        $scriptAsts[$Path] = $ast
    }
    return $scriptAsts[$Path]
}

function Get-FunctionDefinition {
    param([string] $Path, [string] $Name)
    return (Get-ParsedAst -Path $Path).FindAll(
        { param($node) ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $Name) },
        $true) | Select-Object -First 1
}

# Audited step contract (audit M101 / Forgejo #198 plus the #200 rollback
# contract, source stand f0898ffa): the ordered MAIN-FLOW wrapper call sites
# per script, plus the wrapper call sites of the #200 rollback function
# Invoke-UpgradeRollback - the service restoration steps of the #200 case
# matrix: uninstall (fresh-install rollback removes the registration this run
# created), install (re-register the previous service after the old one was
# uninstalled and no new registration came into existence) and start (bring
# the previous service back up; a registration this run created is reused
# without a duplicate install, which would fail with WinSW 1073). No other
# function may carry wrapper call sites. A change to the scripts fails this
# guard BY DESIGN until scripts/tests/winsw-simulate-steps.ps1 is
# re-validated against the new contract - for example the #200 staging change
# turned the bare "stop, uninstall, install, start" list into the main-flow +
# rollback split asserted here.
$ExpectedSteps = @{
    'install.ps1' = @{
        Main      = @('stop', 'uninstall', 'install', 'start')
        Functions = @{ 'Invoke-UpgradeRollback' = @('uninstall', 'install', 'start') }
    }
    'uninstall.ps1' = @{
        Main      = @('stop', 'uninstall')
        Functions = @{}
    }
}

function Get-ContainingFunction {
    # Innermost FunctionDefinitionAst whose extent contains the given node,
    # or $null when the node belongs to the script's main flow.
    param($Node, $FunctionDefs)
    $innermost = $null
    foreach ($fn in $FunctionDefs) {
        if (($fn.Extent.StartOffset -le $Node.Extent.StartOffset) -and
            ($Node.Extent.EndOffset -le $fn.Extent.EndOffset)) {
            if (-not $innermost -or
                (($fn.Extent.EndOffset - $fn.Extent.StartOffset) -lt
                    ($innermost.Extent.EndOffset - $innermost.Extent.StartOffset))) {
                $innermost = $fn
            }
        }
    }
    return $innermost
}

$contracts = @{}
foreach ($entry in $ExpectedSteps.GetEnumerator()) {
    $fileName = $entry.Key
    $scriptPath = Join-Path $repoRootResolved ("scripts/windows/" + $fileName)
    $ast = Get-ParsedAst -Path $scriptPath

    # 1. No direct native WinSW invocation may remain.
    $direct = @($ast.FindAll({
        param($node)
        ($node -is [System.Management.Automation.Language.CommandAst]) -and
        ($node.CommandElements.Count -ge 1) -and
        ($node.CommandElements[0] -is [System.Management.Automation.Language.VariableExpressionAst]) -and
        ($node.CommandElements[0].VariablePath.UserPath -eq 'ServiceExe')
    }, $true))
    if ($direct.Count -gt 0) {
        Fail ("{0}: direct native WinSW invocation(s) remain at line(s) {1}; since the #198 fix every step must go through Invoke-ServiceStep." -f $fileName, (($direct | ForEach-Object { $_.Extent.StartLineNumber }) -join ', '))
    }

    # 2. The wrapper must exist and carry the exitcode/abort contract.
    $wrapper = Get-FunctionDefinition -Path $scriptPath -Name 'Invoke-ServiceStep'
    if (-not $wrapper) {
        Fail "${fileName}: the Invoke-ServiceStep wrapper is missing; the #198 contract requires every native WinSW call to go through it."
    }
    $wrapperBody = $wrapper.Body
    $native = @($wrapperBody.FindAll({
        param($node)
        ($node -is [System.Management.Automation.Language.CommandAst]) -and
        ($node.CommandElements.Count -ge 2) -and
        ($node.CommandElements[0] -is [System.Management.Automation.Language.VariableExpressionAst]) -and
        ($node.CommandElements[0].VariablePath.UserPath -eq 'Executable')
    }, $true))
    if ($native.Count -ne 1) {
        Fail ("{0}: Invoke-ServiceStep must contain exactly one native invocation of the -Executable parameter; found {1}." -f $fileName, $native.Count)
    }
    $stepElement = $native[0].CommandElements[1]
    if (-not ($stepElement -is [System.Management.Automation.Language.VariableExpressionAst]) -or $stepElement.VariablePath.UserPath -ne 'Step') {
        Fail "${fileName}: the wrapper's native invocation must use the -Step parameter as its argument."
    }
    $lastExitRefs = @($wrapperBody.FindAll({
        param($node)
        ($node -is [System.Management.Automation.Language.VariableExpressionAst]) -and
        ($node.VariablePath.UserPath -eq 'LASTEXITCODE')
    }, $true))
    if ($lastExitRefs.Count -lt 1) {
        Fail "${fileName}: Invoke-ServiceStep does not reference `$LASTEXITCODE; the #198 exitcode evaluation is missing."
    }
    $dieCalls = @($wrapperBody.FindAll({
        param($node)
        ($node -is [System.Management.Automation.Language.CommandAst]) -and
        ($node.GetCommandName() -eq 'Die')
    }, $true))
    if ($dieCalls.Count -lt 1) {
        Fail "${fileName}: Invoke-ServiceStep does not abort via Die on a nonzero exit code."
    }
    foreach ($helper in @('Write-Log', 'Die')) {
        if (-not (Get-FunctionDefinition -Path $scriptPath -Name $helper)) {
            Fail "${fileName}: helper function $helper is missing (the runtime simulation needs it verbatim)."
        }
    }

    # 3. Every call site must be a wrapper call with the audited shape.
    $sites = @()
    $callAsts = @($ast.FindAll({
        param($node)
        ($node -is [System.Management.Automation.Language.CommandAst]) -and
        ($node.GetCommandName() -eq 'Invoke-ServiceStep')
    }, $true))
    if ($callAsts.Count -eq 0) {
        Fail "${fileName}: no Invoke-ServiceStep call site found; the native WinSW steps are not wired to the wrapper."
    }
    foreach ($call in $callAsts) {
        $named = @{}
        $i = 1
        while ($i -lt $call.CommandElements.Count) {
            $element = $call.CommandElements[$i]
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                Fail "${fileName}: unexpected positional argument in the Invoke-ServiceStep call at line $($call.Extent.StartLineNumber)."
            }
            $paramName = $element.ParameterName
            if (($i + 1) -ge $call.CommandElements.Count) {
                Fail "${fileName}: parameter $paramName of the Invoke-ServiceStep call at line $($call.Extent.StartLineNumber) has no value."
            }
            $named[$paramName] = $call.CommandElements[$i + 1]
            $i += 2
        }
        foreach ($required in @('Executable', 'Step', 'LogDir')) {
            if (-not $named.ContainsKey($required)) {
                Fail "${fileName}: the Invoke-ServiceStep call at line $($call.Extent.StartLineNumber) is missing -$required."
            }
        }
        $exeElement = $named['Executable']
        if (-not ($exeElement -is [System.Management.Automation.Language.VariableExpressionAst]) -or $exeElement.VariablePath.UserPath -ne 'ServiceExe') {
            Fail "${fileName}: the Invoke-ServiceStep call at line $($call.Extent.StartLineNumber) must pass -Executable `$ServiceExe."
        }
        $stepValue = $named['Step']
        if (-not ($stepValue -is [System.Management.Automation.Language.StringConstantExpressionAst])) {
            Fail "${fileName}: the -Step argument at line $($call.Extent.StartLineNumber) must be a literal step name."
        }
        $sites += [pscustomobject] @{
            Step = [string] $stepValue.Value
            Line = $call.Extent.StartLineNumber
            Node = $call
        }
    }

    # 4. Ordered step list must match the audited contract: the MAIN-FLOW call
    #    sites (not contained in any function) plus, separately, the wrapper
    #    call sites of the allowed functions (#200 rollback contract).
    $functionDefs = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true))
    $mainSites = @()
    $fnSitesByFunction = @{}
    foreach ($site in $sites) {
        $owner = Get-ContainingFunction -Node $site.Node -FunctionDefs $functionDefs
        if ($owner) {
            if (-not $fnSitesByFunction.ContainsKey($owner.Name)) {
                $fnSitesByFunction[$owner.Name] = @()
            }
            $fnSitesByFunction[$owner.Name] += $site
        } else {
            $mainSites += $site
        }
    }
    $mainVerbs = @($mainSites | ForEach-Object { $_.Step })
    if (($mainVerbs -join ',') -ne ($entry.Value.Main -join ',')) {
        Fail ("{0}: the WinSW step contract changed. Expected main-flow steps (in order): {1}. Found: {2}. Re-validate scripts/tests/winsw-simulate-steps.ps1 against the new contract (main flow and #200 rollback function) before relying on the simulation." -f $fileName, ($entry.Value.Main -join ', '), ($mainVerbs -join ', '))
    }
    $foundFns = @($fnSitesByFunction.Keys | Sort-Object)
    $expectedFns = @($entry.Value.Functions.Keys | Sort-Object)
    if (($foundFns -join ',') -ne ($expectedFns -join ',')) {
        Fail ("{0}: the WinSW step contract changed. Expected wrapper call sites in exactly these functions: {1}. Found: {2}. Re-validate scripts/tests/winsw-simulate-steps.ps1 against the new contract (main flow and #200 rollback function) before relying on the simulation." -f $fileName, (($expectedFns -join ', ') -replace '^$', '(none)'), (($foundFns -join ', ') -replace '^$', '(none)'))
    }
    foreach ($fnName in $expectedFns) {
        $fnVerbs = @($fnSitesByFunction[$fnName] | ForEach-Object { $_.Step })
        if (($fnVerbs -join ',') -ne ($entry.Value.Functions[$fnName] -join ',')) {
            Fail ("{0}: the WinSW step contract changed. Expected steps (in order) in function {1}: {2}. Found: {3}. Re-validate scripts/tests/winsw-simulate-steps.ps1 against the new contract (main flow and #200 rollback function) before relying on the simulation." -f $fileName, $fnName, ($entry.Value.Functions[$fnName] -join ', '), ($fnVerbs -join ', '))
        }
    }
    # Pass 4 (and the flow simulation order note) walk the main chain first,
    # then the rollback continuation steps, matching the contract lists above.
    $orderedSites = @($mainSites)
    foreach ($fnName in $entry.Value.Functions.Keys) {
        $orderedSites += @($fnSitesByFunction[$fnName])
    }
    $contracts[$fileName] = $orderedSites
}

# The current pwsh executable, used for the child processes of pass 4 and the
# flow simulation (no dependence on a differently-versioned pwsh earlier in
# PATH).
$pwshExe = try { (Get-Process -Id $PID).Path } catch { 'pwsh' }
if (-not $pwshExe -or -not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }

# --- pass 5: #200 flow simulation of the staged upgrade -----------------------
# Runs the REAL main flow of install.ps1 (param block, main statements and
# helper functions extracted verbatim; only the platform-bound entry points
# are shims - see $FlowPreamble) against the generated WinSW stub inside the
# simulation bundle laid out by the driver. The file cmdlets journal to the
# same file as the stub calls, so the driver can assert the real ordering of
# staging, service stop, rename-aside/rename-in, rollback and cleanup. The
# harness mirrors the simulated run's exit code: 0 for a successful upgrade,
# nonzero for a guided abort (the expected observable of a failing scenario,
# told apart from harness failures by the driver's greps). Pass 4 does not
# run in flow mode.
if ($FlowSimBundle) {
    if ($null -eq $env:MODDEX_SIM_SERVICE_EXISTS -or $null -eq $env:MODDEX_SIM_FAILSPEC) {
        Fail 'The flow simulation requires MODDEX_SIM_SERVICE_EXISTS (0|1) and MODDEX_SIM_FAILSPEC ("<op>:<ordinal>" or empty) in the driver environment.'
    }
    $bundleResolved = (Resolve-Path -LiteralPath $FlowSimBundle -ErrorAction Stop).Path
    $templateSimPath = Join-Path $bundleResolved 'packaging\windows\moddex-backend.xml.template'
    foreach ($required in @(
            (Join-Path $bundleResolved 'backend'),
            (Join-Path $bundleResolved 'frontend'),
            (Join-Path $bundleResolved 'VERSION'),
            $templateSimPath)) {
        if (-not (Test-Path -LiteralPath $required)) {
            Fail ("Flow simulation bundle is missing {0}; the driver must lay out backend/, frontend/, VERSION and the service template under packaging/windows (Join-Path normalizes the backslash literals of install.ps1 to this directory on Linux)." -f $required)
        }
    }

    # Stub for the native WinSW calls of the simulated run; a copy goes to
    # -FlowStubDest so the simulated previous installation's ServiceExe is the
    # same single-sourced stub.
    if (-not $FlowStubDest) {
        Fail 'The flow simulation requires -FlowStubDest (the ServiceExe path of the simulated previous installation).'
    }
    $stubDir = Join-Path $fixtureResolved 'winsw-stub'
    New-Item -ItemType Directory -Force -Path $stubDir | Out-Null
    $flowStubPath = Join-Path $stubDir 'moddex-backend.exe'
    Set-Content -LiteralPath $flowStubPath -Value $StubScript -Encoding utf8NoBOM
    & chmod '+x' $flowStubPath
    $stubDestParent = Split-Path -Parent $FlowStubDest
    if (-not (Test-Path -LiteralPath $stubDestParent)) {
        Fail "The -FlowStubDest parent directory does not exist: $stubDestParent"
    }
    Copy-Item -LiteralPath $flowStubPath -Destination $FlowStubDest -Force
    & chmod '+x' $FlowStubDest

    # Generated variant: the REAL param block, main statements and helper
    # functions of install.ps1; only Assert-Admin, Resolve-WinSw, Get-Service
    # and the file cmdlets are simulation shims ($FlowPreamble).
    $variantDir = Join-Path $bundleResolved 'scripts/windows'
    New-Item -ItemType Directory -Force -Path $variantDir | Out-Null
    $variantPath = Join-Path $variantDir 'install.ps1'
    $srcAst = Get-ParsedAst -Path $installPath
    if (-not $srcAst.ParamBlock) {
        Fail 'install.ps1 has no param block; the flow simulation expects one.'
    }
    $mainStatements = @($srcAst.EndBlock.Statements |
        Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] })
    if ($mainStatements.Count -eq 0) {
        Fail 'install.ps1 main statements could not be extracted for the flow simulation.'
    }
    $verbatimTexts = @()
    foreach ($fnName in @('Write-Log', 'Die', 'Invoke-ServiceStep', 'Invoke-UpgradeRollback', 'Get-ExistingEnv', 'Get-UnmanagedEnv', 'Resolve-Config', 'Resolve-JavaExe')) {
        $fnNode = Get-FunctionDefinition -Path $installPath -Name $fnName
        if (-not $fnNode) {
            Fail "install.ps1 function '$fnName' is missing; the flow simulation needs it verbatim."
        }
        $verbatimTexts += $fnNode.Extent.Text
    }
    $variantText = @(
        '# <Generated flow-simulation variant (scripts/tests/winsw-simulate-steps.ps1, Forgejo #200).>'
        '# Runs the REAL main statements of scripts/windows/install.ps1 against generated'
        '# stubs inside an isolated test fixture. It never touches a real Windows service:'
        '# Assert-Admin (Windows identity), Resolve-WinSw (pinned download) and Get-Service'
        '# (SCM) are simulation shims; Copy-Item, Move-Item and Remove-Item are journaling'
        '# shims that delegate to the real cmdlets and can fail once on demand'
        '# (MODDEX_SIM_FAILSPEC "<op>:<ordinal>") to exercise the #200 rollback.'
        $srcAst.ParamBlock.Extent.Text
        $FlowPreamble
        ($verbatimTexts -join "`n`n")
        (($mainStatements | ForEach-Object { $_.Extent.Text }) -join "`n")
    ) -join "`n"
    Set-Content -LiteralPath $variantPath -Value $variantText -Encoding utf8NoBOM

    # Parse-check the generated variant before running it: a generation bug
    # must fail loudly, not masquerade as an installer abort.
    $variantTokens = $null
    $variantErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $variantPath, [ref] $variantTokens, [ref] $variantErrors) | Out-Null
    if ($variantErrors -and $variantErrors.Count -gt 0) {
        foreach ($e in $variantErrors) {
            Write-Host ("[winsw-sim] VARIANT PARSE {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red
        }
        Fail 'The generated flow variant has parse errors; nothing was executed.'
    }

    # Unified journal: the file-operation shims and the WinSW stub append to
    # the same file in chronological order.
    $journalPath = Join-Path $fixtureResolved 'flow-journal.log'
    New-Item -ItemType File -Force -Path $journalPath | Out-Null

    $prevStubLog = $env:MODDEX_WINSW_STUB_LOG
    $prevStubCodes = $env:MODDEX_WINSW_STUB_EXITCODES
    $prevJournal = $env:MODDEX_SIM_FILE_JOURNAL
    $prevSimExe = $env:MODDEX_SIM_WINSW_EXE
    $prevPath = $env:PATH
    $childOut = Join-Path $fixtureResolved 'flow-child.out'
    $childErr = Join-Path $fixtureResolved 'flow-child.err'
    try {
        $env:MODDEX_WINSW_STUB_LOG = $journalPath
        $env:MODDEX_WINSW_STUB_EXITCODES = if ($ExitCodes) { (Resolve-Path -LiteralPath $ExitCodes).Path } else { '' }
        $env:MODDEX_SIM_FILE_JOURNAL = $journalPath
        $env:MODDEX_SIM_WINSW_EXE = $flowStubPath
        # The driver may place a stub java.exe here (Resolve-JavaExe is real
        # code and needs a Java 17+ candidate).
        $binDir = Join-Path $fixtureResolved 'bin'
        if (Test-Path -LiteralPath $binDir) {
            $env:PATH = "$binDir" + [System.IO.Path]::PathSeparator + $env:PATH
        }

        $variantArgs = @(
            '-NoProfile', '-NonInteractive', '-File', $variantPath,
            '-BackendJar', (Join-Path (Join-Path $bundleResolved 'backend') 'Moddex-Backend.jar'),
            '-FrontendDir', (Join-Path $bundleResolved 'frontend')
        )
        if ($FlowInstallMode) {
            $variantArgs += @('-Mode', $FlowInstallMode)
        }
        $proc = Start-Process -FilePath $pwshExe `
            -ArgumentList $variantArgs `
            -RedirectStandardOutput $childOut `
            -RedirectStandardError $childErr `
            -NoNewWindow -Wait -PassThru
        $childExit = $proc.ExitCode
    } finally {
        $env:MODDEX_WINSW_STUB_LOG = $prevStubLog
        $env:MODDEX_WINSW_STUB_EXITCODES = $prevStubCodes
        $env:MODDEX_SIM_FILE_JOURNAL = $prevJournal
        $env:MODDEX_SIM_WINSW_EXE = $prevSimExe
        $env:PATH = $prevPath
    }

    $childText = @(
        (Get-Content -LiteralPath $childOut -ErrorAction SilentlyContinue)
        (Get-Content -LiteralPath $childErr -ErrorAction SilentlyContinue)
    ) -join "`n"
    # pwsh renders terminating errors with ANSI escapes even into a redirected
    # file; strip them so the driver's fragment checks stay greppable.
    $childText = [regex]::Replace($childText, "$([char]27)\[[0-9;?=]*[a-zA-Z]", '')
    # The concise error view wraps the rendered message at the console width
    # and continues each line with "| "; unwrap those continuations so the
    # driver's guided-message fragments match regardless of wrap position.
    $childText = [regex]::Replace($childText, "(?m)\r?\n\s*\| ", ' ')
    Write-Sim ("flow simulation of install.ps1 finished with exit code {0}" -f $childExit)
    Write-Host "[winsw-flow] simulated installer output:" -ForegroundColor Yellow
    foreach ($line in @($childText -split "`n" | Where-Object { $_.Trim().Length -gt 0 })) {
        Write-Host "  $line"
    }

    if ($childExit -eq 0) {
        Write-Sim 'PASS: the simulated #200 upgrade run completed (staging before the service stop, rename-aside/rename-in replace, service steps, work directory removed).'
        exit 0
    }
    Write-Host "[winsw-flow] CONTROLLED EXIT (expected observable for a failing scenario): the simulated upgrade run exited with code $childExit; the driver asserts the guided message, the restored file state and the journal." -ForegroundColor Yellow
    exit $childExit
}

# --- pass 4: runtime simulation of the #198 behaviour ------------------------
# Parses the stub's exitcode control file so the harness knows which code the
# stub will return per step and can tell a silent swallow (child continued
# although the stub failed) from a controlled abort. "step=code:N" fails the
# first N invocations; the code before the colon is what pass 4 expects.
$stubCodes = @{}
if ($ExitCodes) {
    if (-not (Test-Path -LiteralPath $ExitCodes)) {
        Fail "ExitCodes control file not found: $ExitCodes"
    }
    foreach ($line in @(Get-Content -LiteralPath (Resolve-Path -LiteralPath $ExitCodes) -ErrorAction Stop)) {
        if ($line -match '^\s*([A-Za-z]+)\s*=\s*(\d+)(?::\d+)?\s*$') {
            $stubCodes[$Matches[1]] = [int] $Matches[2]
        }
    }
}

$stubPath = Join-Path $fixtureResolved 'moddex-backend.exe'
$stubLog  = Join-Path $fixtureResolved 'winsw-calls.log'
Set-Content -LiteralPath $stubPath -Value $StubScript -Encoding utf8NoBOM
& chmod '+x' $stubPath
if (-not (Test-Path -LiteralPath $stubPath)) { Fail "Stub was not created at $stubPath" }
$childPath = Join-Path $fixtureResolved 'Invoke-ExtractedStep.ps1'
Set-Content -LiteralPath $childPath -Value $ChildScript -Encoding utf8NoBOM

$env:MODDEX_WINSW_STUB_LOG = $stubLog
$env:MODDEX_WINSW_STUB_EXITCODES = if ($ExitCodes) { (Resolve-Path -LiteralPath $ExitCodes).Path } else { '' }

$totalSteps = 0
$executedSequence = @()   # steps whose stub call was actually made, in order
$aborts = New-Object System.Collections.Generic.List[string]
$violations = New-Object System.Collections.Generic.List[string]

function New-ChildPaths {
    param([string] $Entry, [string] $Step)
    $base = Join-Path $fixtureResolved ("child-" + $Entry.Replace('.ps1', '') + "-" + $Step)
    return @{
        Out = "$base.out"
        Err = "$base.err"
    }
}

function Test-ChildText {
    # Verifies the guided-abort message (step, code, concrete log location,
    # next action). Returns $true when every fragment is present. The message
    # wording is the wrapper's: "The WinSW '<step>' step failed with exit
    # code <code> ..." / "Check the WinSW wrapper log in <logdir> ... rerun".
    param([string] $Text, [string] $Step, [int] $Code, [string] $LogDir)

    foreach ($fragment in @(
            "'$Step' step failed",
            "exit code $Code",
            'wrapper log',
            'rerun',
            [regex]::Escape($LogDir)
        )) {
        if ($Text -notmatch $fragment) { return $false }
    }
    return $true
}

try {
    foreach ($entry in @('install.ps1', 'uninstall.ps1')) {
        foreach ($site in $contracts[$entry]) {
            $step = $site.Step
            $expectedCode = if ($stubCodes.ContainsKey($step)) { $stubCodes[$step] } else { 0 }
            $totalSteps++
            $executedSequence += $step

            $childPaths = New-ChildPaths -Entry $entry -Step $step
            $proc = Start-Process -FilePath $pwshExe `
                -ArgumentList @(
                    '-NoProfile', '-NonInteractive', '-File', $childPath,
                    '-SourceScript', (Join-Path $repoRootResolved ("scripts/windows/" + $entry)),
                    '-StubPath', $stubPath, '-Step', $step, '-LogDir', $fixtureResolved
                ) `
                -RedirectStandardOutput $childPaths.Out `
                -RedirectStandardError $childPaths.Err `
                -NoNewWindow -Wait -PassThru
            $childExit = $proc.ExitCode
            $childText = @(
                (Get-Content -LiteralPath $childPaths.Out -ErrorAction SilentlyContinue)
                (Get-Content -LiteralPath $childPaths.Err -ErrorAction SilentlyContinue)
            ) -join "`n"
            # pwsh renders terminating errors with ANSI escapes even into a
            # redirected file; strip them so the fragment checks and the
            # echoed guided message stay greppable.
            $childText = [regex]::Replace($childText, "$([char]27)\[[0-9;?=]*[a-zA-Z]", '')

            Write-Sim ("run {0} step '{1}' (stub exit code {2}) -> child exit {3}" -f $entry, $step, $expectedCode, $childExit)

            if ($childExit -eq 0) {
                if ($expectedCode -ne 0) {
                    $violations.Add(("{0}: simulated WinSW step '{1}' returned exit code {2} but the run continued silently; the #198 contract requires a controlled abort." -f $entry, $step, $expectedCode))
                    break   # the real script would have continued here - stop this chain
                }
                continue    # success path
            }

            # Nonzero child exit: must be the script's own guided abort.
            if ($expectedCode -eq 0) {
                $violations.Add(("{0}: simulated step '{1}' failed (child exit {2}) although the stub exited 0. Child output:`n{3}" -f $entry, $step, $childExit, $childText))
                break
            }
            if (-not (Test-ChildText -Text $childText -Step $step -Code $expectedCode -LogDir $fixtureResolved)) {
                $violations.Add(("{0}: the abort at step '{1}' (exit code {2}) did not carry the guided message (step, code, wrapper log location, next action). Child output:`n{3}" -f $entry, $step, $expectedCode, $childText))
                break
            }
            $aborts.Add(("{0} aborted at step '{1}' with WinSW exit code {2}; guided message verified." -f $entry, $step, $expectedCode))
            Write-Host "[winsw-sim] guided abort message (child output):" -ForegroundColor Yellow
            foreach ($line in @($childText -split "`n" | Where-Object { $_.Trim().Length -gt 0 })) {
                Write-Host "  $line" -ForegroundColor Yellow
            }
            break   # the real script stops at the failing step
        }
    }
} finally {
    Remove-Item Env:MODDEX_WINSW_STUB_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:MODDEX_WINSW_STUB_EXITCODES -ErrorAction SilentlyContinue
}

# The stub log proves the generated wrapper actually ran for every executed
# step (an exec/shebang failure would surface here instead of passing silently).
$executed = @(Get-Content -LiteralPath $stubLog -ErrorAction SilentlyContinue)
if (($executedSequence -join ',') -ne ($executed -join ',')) {
    $violations.Add(("Stub call log does not match the executed steps. Expected: {0}. Logged: {1}." -f ($executedSequence -join ', '), ($executed -join ', ')))
}

Remove-Fixture

if ($violations.Count -gt 0) {
    foreach ($violation in $violations) {
        Write-Host "[winsw-sim] CONTRACT VIOLATION: $violation" -ForegroundColor Red
    }
    exit 1
}

if ($aborts.Count -gt 0) {
    # A failing-code scenario: the simulated installer run(s) aborted in the
    # controlled way the #198 contract demands. Nonzero exit mirrors the
    # aborted run - the driver test asserts this observable via its greps.
    foreach ($abort in $aborts) {
        Write-Host "[winsw-sim] CONTROLLED ABORT (expected observable for a nonzero WinSW exit code): $abort" -ForegroundColor Yellow
    }
    exit 1
}

Write-Sim ("PASS: {0} .ps1 parsed, template placeholders consistent ({1}), #198/#200 contract asserted (no direct WinSW call; Invoke-ServiceStep wrapper evaluated; install.ps1: {2}; rollback Invoke-UpgradeRollback: {3}; uninstall.ps1: {4}), {5} simulated steps executed as the real extracted wrapper code, all exit codes 0, stub log verified." -f `
    $parseTargets.Count, ($templatePlaceholders -join ', '),
    ($ExpectedSteps['install.ps1'].Main -join ', '),
    ($ExpectedSteps['install.ps1'].Functions['Invoke-UpgradeRollback'] -join ', '),
    ($ExpectedSteps['uninstall.ps1'].Main -join ', '), $totalSteps)
exit 0
