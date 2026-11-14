#Requires -Version 5.1
<#
.SYNOPSIS
    Installs (or upgrades) Moddex as a Windows service.

.DESCRIPTION
    The Windows counterpart of scripts/install.sh. It lays out a consistent path
    layout, installs the backend JAR and the built frontend assets, registers the
    backend as a Windows service via WinSW, and starts it.

    Path layout:
      App      : %ProgramFiles%\Moddex          (app.jar, frontend, service wrapper)
      Data     : %ProgramData%\Moddex\data      (MODDEX_ROOT - instances, backups, settings)
      Config   : %ProgramData%\Moddex\config
      Logs     : %ProgramData%\Moddex\logs

    The installer is idempotent: re-running it upgrades the application artifacts
    without touching instance data, and preserves the machine-local mode/port from
    the existing service definition unless -Mode/-Port is passed explicitly. The
    upgrade is staged before the service is stopped and rolled back as a whole
    when any replace or service step fails (Forgejo issue #200).

.PARAMETER Mode
    Deployment mode: local (loopback only), lan, or public.
.PARAMETER Port
    TCP port to expose the backend on (default: 8080).
.PARAMETER BackendJar
    Path to the backend JAR. Defaults to <bundle>\backend\Moddex-Backend.jar.
.PARAMETER FrontendDir
    Path to the built frontend assets. Defaults to <bundle>\frontend.
.PARAMETER WinSwPath
    Path to a WinSW executable to bundle. If omitted, a bundled copy
    (packaging\windows\WinSW.exe) is used, else the pinned release is downloaded.

.NOTES
    Provenance: this file was transferred verbatim from the release repository's
    develop branch at commit f0898ffa9bc1adcb2a62216143f2a9c0a1fa04fd
    (https://github.com/aklozyp/Moddex, PRs #26/#40/#44/#50/#57/#59/#61), which
    audit issues M101 (#198) and M103 (#200) name as the reviewed source stand.
    Only this .NOTES section was added during the transfer (Forgejo issue #564);
    no code, message or parameter was changed at that point. The two documented
    deviations below (the #198 exitcode wrapper and the #200 staged upgrade with
    rollback) are this repository's changes on top of the transferred stand.
    Issue references in comments such
    as "Moddex#59" or "Moddex-Backend#50" refer to the GitHub repositories at
    that source commit, NOT to Forgejo issues of this repository.

    The verbatim transfer ends with the Forgejo issue #198 fix (audit M101): the
    four native WinSW calls (stop, uninstall, install, start) no longer run as
    bare `& $ServiceExe <step> ... | Out-Null` statements that swallow both
    output and $LASTEXITCODE. They now go through the Invoke-ServiceStep wrapper
    below, which evaluates $LASTEXITCODE and aborts with a guided message on a
    nonzero code. That wrapper, the four replaced call sites and this paragraph
    are this repository's changes on top of f0898ffa; no other line was touched.

    Forgejo issue #200 (audit M103) is the second deviation from the source
    stand. At f0898ffa the upgrade path stopped the service and then overwrote
    app.jar, deleted the existing ui directory and copied the new frontend
    BEFORE the service definition was rendered, placeholder-checked and the
    service re-registered, so any later failure left the previous installation
    destroyed. The main flow now stages the complete new application image
    (app.jar, UI, VERSION, rendered service definition with preserved operator
    <env> entries, WinSW executable) inside
    %ProgramFiles%\Moddex\.upgrade-<id>\staging while the old version keeps
    running, then stops the service, renames the existing managed files aside
    (.upgrade-<id>\aside) instead of deleting them, renames the staged files
    into place and re-registers the service. Any failure in the replace or
    service phase triggers Invoke-UpgradeRollback, which restores the previous
    application files and brings the previous service registration back up;
    %ProgramData%\Moddex (instance data, operator config) is never part of the
    replace set. That flow, the Invoke-UpgradeRollback function and this
    paragraph are this repository's changes; the rest of the file still matches
    f0898ffa apart from the #198 wrapper.

    Support status: this is the Windows installer source foundation. It has NOT
    been executed on a real Windows host by this repository's checks (CI runs
    Linux only); syntax and the simulated WinSW step chain are verified by
    scripts/tests/test-windows-installer-foundation.sh (pwsh). Do not claim
    supported Windows operation until it has been verified on Windows.
#>
[CmdletBinding()]
param(
    [ValidateSet('local', 'lan', 'public')]
    [string]$Mode,
    [int]$Port,
    [string]$BackendJar,
    [string]$FrontendDir,
    [string]$WinSwPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Which parameters the caller actually supplied, captured HERE and nowhere else.
# Inside a function $PSBoundParameters describes that function's own parameters,
# so a function asking `$PSBoundParameters.ContainsKey('Mode')` always got $false
# and an explicit -Mode/-Port was silently discarded (#57). Explicitness is a
# property of the script invocation; it is determined once, at script scope, and
# passed down.
$ModeExplicit = $PSBoundParameters.ContainsKey('Mode')
$PortExplicit = $PSBoundParameters.ContainsKey('Port')

# --- constants ---------------------------------------------------------------
$ServiceId   = 'moddex-backend'
$AppDir      = Join-Path $env:ProgramFiles 'Moddex'
# Built web UI, served by the backend on the same port as the API (Moddex#59).
# Mirrors the Linux layout (/opt/moddex/ui): it lives with the application, not
# with the instance data, because an upgrade replaces it wholesale.
$UiDir       = Join-Path $AppDir 'ui'
$DataRoot    = Join-Path $env:ProgramData 'Moddex'
$DataDir     = Join-Path $DataRoot 'data'
$ConfigDir   = Join-Path $DataRoot 'config'
$LogDir      = Join-Path $DataRoot 'logs'
$ServiceXml  = Join-Path $AppDir 'moddex-backend.xml'
$ServiceExe  = Join-Path $AppDir 'moddex-backend.exe'
$MinJava     = 17

# Pinned WinSW (Windows Service Wrapper). The hash gates the downloaded binary so
# a compromised mirror cannot inject a different executable (defense in depth,
# matching the backend's SecureArtifactDownloader policy).
$WinSwVersion = 'v2.12.0'
$WinSwUrl     = "https://github.com/winsw/winsw/releases/download/$WinSwVersion/WinSW-x64.exe"
$WinSwSha256  = '05b82d46ad331cc16bdc00de5c6332c1ef818df8ceefcd49c726553209b3a0da'

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$BundleRoot  = Split-Path -Parent (Split-Path -Parent $ScriptDir)   # <bundle>\scripts\windows -> <bundle>
$PackagingWin = Join-Path $BundleRoot 'packaging\windows'

function Write-Log([string]$Message) { Write-Host "[moddex-install] $Message" }
function Die([string]$Message) { Write-Error $Message; exit 1 }

# --- preflight ---------------------------------------------------------------
function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Die 'This installer must run from an elevated (Administrator) PowerShell session.'
    }
}

function Resolve-JavaExe {
    $candidates = @()
    $cmd = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    if ($env:JAVA_HOME) { $candidates += (Join-Path $env:JAVA_HOME 'bin\java.exe') }
    foreach ($java in $candidates) {
        if (-not (Test-Path $java)) { continue }
        $verLine = (& $java -version 2>&1 | Select-Object -First 1)
        if ($verLine -match '"(\d+)(\.(\d+))?') {
            $major = [int]$Matches[1]
            if ($major -eq 1 -and $Matches[3]) { $major = [int]$Matches[3] }  # 1.8 style
            if ($major -ge $MinJava) { return $java }
            Die "Found Java $major but Moddex requires Java $MinJava or newer."
        }
    }
    Die "Java $MinJava+ not found. Install a JRE/JDK $MinJava or set JAVA_HOME."
}

# --- WinSW acquisition -------------------------------------------------------
# Takes the operator-supplied path as a parameter instead of reading it from the
# enclosing scope. The scope-visibility shortcut is what made #57 possible; the
# same pattern is not left in place here.
function Resolve-WinSw {
    param([string] $RequestedPath)

    $bundled = if ($RequestedPath) { $RequestedPath } else { Join-Path $PackagingWin 'WinSW.exe' }
    if (Test-Path $bundled) {
        Write-Log "Using bundled WinSW: $bundled"
        return $bundled
    }
    if ($RequestedPath) {
        Die "WinSW not found at the path given via -WinSwPath: $RequestedPath"
    }
    # Not bundled: download the pinned release and verify its hash.
    $tmp = Join-Path $env:TEMP "WinSW-$WinSwVersion.exe"
    Write-Log "Downloading WinSW $WinSwVersion ..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $WinSwUrl -OutFile $tmp -UseBasicParsing
    $actual = (Get-FileHash -Algorithm SHA256 -Path $tmp).Hash.ToLowerInvariant()
    if ($actual -ne $WinSwSha256) {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Die "WinSW checksum mismatch (expected $WinSwSha256, got $actual)."
    }
    return $tmp
}

# --- config resolution -------------------------------------------------------
# Env names the template renders from -Mode/-Port; everything else in an existing
# service definition was added by the operator and must survive an upgrade.
$ManagedEnv = @(
    'MODDEX_ROOT', 'MODDEX_CONFIG_DIR', 'MODDEX_LOG_DIR', 'MODDEX_UI_DIR',
    'MODDEX_MODE', 'MODDEX_SECURITY_MODE', 'SERVER_ADDRESS', 'SERVER_PORT'
)

function Get-ExistingEnv([string]$Name) {
    if (-not (Test-Path $ServiceXml)) { return $null }
    [xml]$xml = Get-Content -Path $ServiceXml -Raw
    $node = $xml.service.env | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if ($node) { return $node.value } else { return $null }
}

# Operator-added <env> entries (anything not in $ManagedEnv) from the existing
# service definition, so a re-install/upgrade preserves them instead of dropping
# them when the XML is re-rendered (parity with install.sh's upsert_env_key,
# e.g. MODDEX_CORS_ALLOWED_ORIGINS).
function Get-UnmanagedEnv {
    if (-not (Test-Path $ServiceXml)) { return @() }
    [xml]$existing = Get-Content -Path $ServiceXml -Raw
    $kept = @()
    foreach ($node in @($existing.service.env)) {
        if ($node -and $node.name -and ($ManagedEnv -notcontains $node.name)) {
            $kept += [pscustomobject]@{ Name = [string]$node.name; Value = [string]$node.value }
        }
    }
    return $kept
}

# Resolves the effective mode/port. Explicitness is passed in rather than
# inferred, because it cannot be observed from here (see the note at the top of
# the script). An explicitly supplied value always wins over an inherited one;
# only an omitted parameter falls back to the existing installation, and only
# then to the default.
function Resolve-Config {
    param(
        [string] $RequestedMode,
        [int]    $RequestedPort,
        [bool]   $ModeWasGiven,
        [bool]   $PortWasGiven
    )

    if ($ModeWasGiven) {
        $resolvedMode = $RequestedMode
    } else {
        $existingMode = Get-ExistingEnv 'MODDEX_MODE'
        if ($existingMode) {
            $resolvedMode = $existingMode
        } elseif ($RequestedMode) {
            $resolvedMode = $RequestedMode
        } else {
            Die 'No -Mode given and no existing install to inherit from. Pass -Mode local|lan|public.'
        }
    }

    if ($PortWasGiven) {
        $resolvedPort = $RequestedPort
    } else {
        $existingPort = Get-ExistingEnv 'SERVER_PORT'
        if ($existingPort) { $resolvedPort = [int]$existingPort } else { $resolvedPort = 8080 }
    }
    if ($resolvedPort -lt 1 -or $resolvedPort -gt 65535) { Die "Invalid -Port: $resolvedPort" }

    $address = if ($resolvedMode -eq 'local') { '127.0.0.1' } else { '0.0.0.0' }
    return [pscustomobject]@{ Mode = $resolvedMode; Port = $resolvedPort; Address = $address }
}

# --- native WinSW step execution (Forgejo issue #198) ------------------------
# Every native WinSW call in this script goes through this wrapper: the exit
# code is evaluated instead of being swallowed by `| Out-Null` (audit M101).
#
# No exit code is tolerated here. The pinned WinSW v2.12.0 already normalizes
# the "already done" situations to exit 0 itself (checked against its source
# at tag v2.12.0, Program.cs): `stop` on an already-stopped service reports
# ERROR_SERVICE_NOT_ACTIVE internally but treats it as success, `uninstall`
# treats a missing or marked-for-delete service as success, `start` treats an
# already-running service as success. A nonzero code is therefore always a
# real failure (Win32 error code, or -1 for an unhandled WinSW exception) and
# must abort the install before the artifacts are replaced or the service is
# left half-registered. WinSW logs every CLI operation - including the fatal
# ones - to the wrapper log in <logpath> (see the service template:
# @@LOG_DIR@@), so the guided message can point there without exposing
# anything beyond the paths the installer already prints at the end.
function Invoke-ServiceStep {
    param(
        [Parameter(Mandatory = $true)] [string] $Executable,
        [Parameter(Mandatory = $true)] [string] $Step,
        [Parameter(Mandatory = $true)] [string] $LogDir
    )

    & $Executable $Step 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Die @"
The WinSW '$Step' step failed with exit code $LASTEXITCODE (a Win32 error code, or -1 for an unhandled WinSW exception).
Check the WinSW wrapper log in $LogDir, correct the cause, and rerun this installer script.
"@
    }
}

# --- upgrade rollback (Forgejo issue #200) ------------------------------------
# Reverses a failed upgrade after the existing files were already touched:
# restores the recorded managed files in reverse order (a partially or fully
# installed new copy is removed first, then the renamed-aside previous copy is
# moved back) and brings the previous service back up according to the
# registration case matrix below. Called from the catch handlers of the
# replace and service phases; the caller reports the outcome and decides
# whether the upgrade work directory is kept for manual recovery.
#
# The SCM registration points at the ServiceExe path, not at a file version:
# a registration that still exists runs the restored previous application
# again once the files are back, because the wrapper executable reads the
# restored previous XML next to it. WinSW v2.12.0 normalizes stop/uninstall/
# start "already done" situations to exit 0, but its Program.cs Install()
# fails with ERROR_SERVICE_EXISTS (1073) when the service id is already
# registered - that error is NOT normalized. Re-registering an existing
# registration is therefore never done; $InstalledNew flags whether THIS run
# created the registration now in place (review correction for #200).
#
# Registration case matrix when the rollback runs:
#   ServiceExisted RanUninstall InstalledNew  registration state       service steps
#   true           false        false         old, stopped (replace    start - the existing
#                                            phase failed before      registration runs the
#                                            the uninstall)           restored previous files
#   true           true         false         none (old uninstalled,   install + start -
#                                            new install failed)      re-register the previous
#                                                                     service from the restored
#                                                                     previous definition
#   true           true         true          new (created by this     start only - NO install:
#                                            run, pointing at the     an install would fail with
#                                            ServiceExe path)         1073; the restored files
#                                                                     make the existing
#                                                                     registration the previous
#                                                                     application again
#   false          false        true          new (fresh install,      uninstall - BEFORE the
#                                            previous state had no    file restoration, because
#                                            service and no files)    the WinSW uninstall runs
#                                                                     through the wrapper
#                                                                     executable that the
#                                                                     restoration would remove;
#                                                                     the restoration then
#                                                                     leaves no application
#                                                                     files behind
# RanUninstall and InstalledNew both imply StoppedOld (the service is stopped before either runs),
# so the start runs whenever a previous registration existed. $RollbackFilesRestored marks the point
# after which a failure leaves the previous files restored in place rather than in the aside; the
# callers use it to report the actual end state.
function Invoke-UpgradeRollback {
    Write-Log 'Rolling back to the previous application files ...'

    if (-not $ServiceExisted -and $InstalledNew) {
        # Fresh install: the previous state has no service, so the registration
        # this run created must be removed - and before the file restoration
        # deletes the wrapper executable the uninstall runs through.
        Write-Log 'Removing the service registration created by this run ...'
        try {
            Invoke-ServiceStep -Executable $ServiceExe -Step 'uninstall' -LogDir $LogDir
        } catch {
            Die @"
The upgrade failed and the service registration created by this run could not be removed: $($_.Exception.Message)
The application files of this run are still in place at $AppDir and the service remains registered (stopped).
Check the WinSW wrapper log in $LogDir, remove the service manually if needed, and rerun this installer script.
"@
        }
    }

    for ($i = $ReplacedEntries.Count - 1; $i -ge 0; $i--) {
        $entry = $ReplacedEntries[$i]
        if ($entry.NewInstalled -and (Test-Path -LiteralPath $entry.Target)) {
            Remove-Item -LiteralPath $entry.Target -Recurse -Force
        }
        if ($entry.AsidePath -and (Test-Path -LiteralPath $entry.AsidePath)) {
            Move-Item -LiteralPath $entry.AsidePath -Destination $entry.Target -Force
        }
    }
    $script:RollbackFilesRestored = $true

    if ($ServiceExisted) {
        if ($RanUninstall -and -not $InstalledNew) {
            # The old registration was removed and the new one never came into
            # existence: re-register the previous service from the restored
            # previous definition.
            Write-Log 'Re-registering the previous service ...'
            Start-Sleep -Seconds 1
            try {
                Invoke-ServiceStep -Executable $ServiceExe -Step 'install' -LogDir $LogDir
            } catch {
                Die @"
The previous application files are restored in place, but the previous service could not be re-registered: $($_.Exception.Message)
The service is currently not registered. Check the WinSW wrapper log in $LogDir, correct the cause, then register and start the service manually or rerun this installer script.
"@
            }
        }
        if ($StoppedOld) {
            # The registration still exists (this run re-created it, or never
            # uninstalled it) and, after the file restoration, points at the
            # previous application again. No install here: the service id is
            # already registered and WinSW would fail with 1073.
            Write-Log 'Starting the previous service ...'
            try {
                Invoke-ServiceStep -Executable $ServiceExe -Step 'start' -LogDir $LogDir
            } catch {
                Die @"
The previous application files are restored in place, but the previous service could not be started: $($_.Exception.Message)
The service is registered but stopped. Check the WinSW wrapper log in $LogDir, correct the cause, then start the service manually or rerun this installer script.
"@
            }
        }
    }
}

# --- main --------------------------------------------------------------------
Assert-Admin
$javaExe = Resolve-JavaExe
Write-Log "Using Java: $javaExe"

if (-not $BackendJar)  { $BackendJar  = Join-Path $BundleRoot 'backend\Moddex-Backend.jar' }
if (-not $FrontendDir) { $FrontendDir = Join-Path $BundleRoot 'frontend' }
if (-not (Test-Path $BackendJar))  { Die "Backend JAR not found: $BackendJar" }
if (-not (Test-Path $FrontendDir)) { Die "Frontend assets not found: $FrontendDir" }

# Checked here, before anything is stopped or deleted. The backend serves
# index.html straight out of MODDEX_UI_DIR, so a directory without one at its
# root is unusable - and validating it later would mean tearing down a working
# installation first and then reporting success over the wreckage. Matches the
# Linux installer's check (Moddex#59/#61).
if (-not (Test-Path (Join-Path $FrontendDir 'index.html'))) {
    Die @"
Frontend directory has no index.html at its root: $FrontendDir
This is not a built Angular app. Point -FrontendDir at the browser output
(the directory containing index.html), not at the dist\ root.
"@
}

$cfg = Resolve-Config -RequestedMode $Mode -RequestedPort $Port `
    -ModeWasGiven $ModeExplicit -PortWasGiven $PortExplicit
Write-Log "Mode=$($cfg.Mode) Address=$($cfg.Address) Port=$($cfg.Port)"

# Public mode serves plain HTTP unless the operator sets up TLS (reverse proxy
# or the backend's native MODDEX_TLS_*): warn loudly and, when a human newly
# chooses public, require confirmation (Moddex-Backend#50). Upgrades that
# inherit an existing public mode, and automation (MODDEX_INSTALL_ASSUME_YES=1
# or a non-interactive session), only get the warning.
if ($cfg.Mode -eq 'public') {
    Write-Log 'WARNING: public mode serves the admin login and ALL API traffic over plain HTTP.'
    Write-Log '         Passwords and session tokens are readable on the network until you terminate TLS'
    Write-Log '         in a reverse proxy (then set MODDEX_TLS_TERMINATED=true) or enable native HTTPS'
    Write-Log '         via MODDEX_TLS_ENABLED/MODDEX_TLS_CERT/MODDEX_TLS_KEY.'
    $existingMode = Get-ExistingEnv 'MODDEX_MODE'
    if ($existingMode -ne 'public' -and [Environment]::UserInteractive -and -not $env:MODDEX_INSTALL_ASSUME_YES) {
        $tlsAnswer = Read-Host 'Continue with public mode over plain HTTP? [y/N]'
        if ($tlsAnswer -notmatch '^(?i)y(es)?$') {
            Die 'Aborted. Re-run with -Mode lan/local, or set up TLS first (see README).'
        }
    }
}

foreach ($dir in @($AppDir, $DataDir, $ConfigDir, $LogDir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

# --- staged upgrade with rollback (Forgejo issue #200) ------------------------
# The source script stopped the service and then overwrote app.jar, deleted the
# existing ui directory and copied the new frontend BEFORE the service
# definition was rendered, placeholder-checked and the service re-registered,
# so any later failure left the previous installation destroyed (audit M103).
# This block replaces that sequence:
#
#   1. Staging - the complete new application image (app.jar, UI, VERSION,
#      rendered service definition with the preserved operator <env> entries,
#      WinSW executable) is prepared and verified in the staging directory
#      while the installed version keeps running. Nothing existing is touched,
#      so a failure here costs neither downtime nor files.
#   2. Stop - the first mutation is the exit-code-checked service stop.
#   3. Replace - the existing managed files are renamed aside (not deleted)
#      and the staged files are renamed into place. Every managed file lives
#      in $AppDir, so the work directory is placed inside $AppDir as well:
#      all renames stay on one volume and never leave partial copies, which a
#      delete-then-copy sequence could.
#   4. Service - uninstall/install/start through the exit-code wrapper.
#
# Any failure in phases 3 and 4 triggers Invoke-UpgradeRollback above, which
# re-establishes the previous application image and service state.
# %ProgramData%\Moddex (instance data, operator configuration) is never part
# of the replace set. The work directory is removed in finally; only a
# rollback that could not complete keeps its aside and says so, with the
# manual recovery path. A hard kill (power loss) mid-replace can still leave
# the work directory behind; the guided next action is to rerun this
# installer, and a leftover aside may then still hold the previous files for
# manual recovery.
$upgradeId = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff') + '-' + $PID + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$UpgradeDir = Join-Path $AppDir ('.upgrade-' + $upgradeId)
$StagingDir = Join-Path $UpgradeDir 'staging'
$AsideDir   = Join-Path $UpgradeDir 'aside'
New-Item -ItemType Directory -Force -Path $UpgradeDir, $StagingDir, $AsideDir | Out-Null

# Upgrade run state: what was already mutated, so the rollback restores
# exactly the previous state and nothing else. $InstalledNew flags that THIS
# run created the service registration now in place (the rollback case matrix
# above decides between start-only, re-register+start and uninstall).
$ServiceExisted = $false
$StoppedOld = $false
$RanUninstall = $false
$InstalledNew = $false
$ReplacedEntries = @()
$RollbackIncomplete = $false
$RollbackFilesRestored = $false

try {
    # Phase 1: stage the complete new application image. A failure here has
    # touched nothing: the installed files are intact and the service was not
    # stopped.
    try {
        Write-Log 'Staging the new application artifacts ...'
        Copy-Item -Path $BackendJar -Destination (Join-Path $StagingDir 'app.jar') -Force
        Copy-Item -Path $FrontendDir -Destination (Join-Path $StagingDir 'ui') -Recurse -Force

        # Record the staged version for parity with Linux (/opt/moddex/VERSION) so
        # operators can verify an upgrade (Get-Content "$env:ProgramFiles\Moddex\VERSION").
        $stagedVersion = Join-Path $StagingDir 'VERSION'
        $bundleVersion = Join-Path $BundleRoot 'VERSION'
        if (Test-Path $bundleVersion) {
            Copy-Item -Path $bundleVersion -Destination $stagedVersion -Force
        } else {
            # No bundle metadata (e.g. custom -BackendJar/-FrontendDir): never leave a
            # stale VERSION from a previous install. Match install.sh's 'dev' fallback.
            Set-Content -Path $stagedVersion -Value 'dev' -Encoding ASCII -NoNewline
        }

        # Render the WinSW service definition into staging. The unresolved-
        # placeholder check runs here, before the service is stopped - a broken
        # template can no longer cost the running installation.
        $stagedServiceXml = Join-Path $StagingDir 'moddex-backend.xml'
        $templatePath = Join-Path $PackagingWin 'moddex-backend.xml.template'
        if (-not (Test-Path $templatePath)) { Die "Service template not found: $templatePath" }
        $xml = Get-Content -Path $templatePath -Raw

        # Placeholder table rather than a chained .Replace(): adding a placeholder is one
        # line, and the substitutions are visible as data instead of buried in a chain.
        $substitutions = [ordered]@{
            '@@JAVA_EXE@@'       = $javaExe
            '@@APP_DIR@@'        = $AppDir
            '@@DATA_DIR@@'       = $DataDir
            '@@CONFIG_DIR@@'     = $ConfigDir
            '@@LOG_DIR@@'        = $LogDir
            '@@UI_DIR@@'         = $UiDir
            '@@MODE@@'           = $cfg.Mode
            '@@SERVER_ADDRESS@@' = $cfg.Address
            '@@SERVER_PORT@@'    = [string]$cfg.Port
        }
        foreach ($placeholder in $substitutions.Keys) {
            $xml = $xml.Replace($placeholder, $substitutions[$placeholder])
        }

        # An unresolved placeholder would be written into the service definition and only
        # fail when the service refuses to start, so catch it here. The check runs over
        # the XML with comments stripped: the template's own header comment describes the
        # mechanism using the literal "@@PLACEHOLDERS@@", which is documentation, not a
        # substitution site.
        $xmlWithoutComments = [regex]::Replace($xml, '(?s)<!--.*?-->', '')
        if ($xmlWithoutComments -match '@@[A-Z_]+@@') {
            Die "Service template still contains an unresolved placeholder: $($Matches[0])"
        }

        # The rendered definition is complete: carry over any operator-added <env>
        # entries from the previous definition (read while the old XML is still in
        # place - the replace phase has not run yet). Managed keys keep coming from
        # the template above. The @() wrapper is load-bearing: the function returns
        # an empty pipeline when there is no previous definition (fresh install) or
        # no operator entries, which assigns $null, and $null.Count throws under
        # Set-StrictMode.
        $preservedEnv = @(Get-UnmanagedEnv)
        if ($preservedEnv.Count -gt 0) {
            [xml]$doc = $xml
            foreach ($extra in $preservedEnv) {
                $node = $doc.CreateElement('env')
                $node.SetAttribute('name', $extra.Name)
                $node.SetAttribute('value', $extra.Value)
                $doc.DocumentElement.AppendChild($node) | Out-Null
                Write-Log "Preserving operator-added env entry: $($extra.Name)"
            }
            $doc.Save($stagedServiceXml)
        } else {
            Set-Content -Path $stagedServiceXml -Value $xml -Encoding UTF8
        }

        # Place the WinSW executable in staging (WinSW derives the config from its
        # own file name: moddex-backend.exe -> moddex-backend.xml; the replace
        # phase below keeps that name).
        $stagedServiceExe = Join-Path $StagingDir 'moddex-backend.exe'
        Copy-Item -Path (Resolve-WinSw -RequestedPath $WinSwPath) -Destination $stagedServiceExe -Force
    } catch {
        Die @"
Staging the new application files failed: $($_.Exception.Message)
Nothing was changed: the installed application files were not touched and the service was not stopped.
Fix the cause (for example free disk space or write permissions for $AppDir), then rerun this installer script.
"@
    }

    # Phase 2: stop the running service (the file lock would block the JAR
    # replace). This is the first mutation of the existing installation.
    $ServiceExisted = $null -ne (Get-Service -Name $ServiceId -ErrorAction SilentlyContinue)
    if ($ServiceExisted) {
        Write-Log 'Stopping existing service for upgrade ...'
        Invoke-ServiceStep -Executable $ServiceExe -Step 'stop' -LogDir $LogDir
        $StoppedOld = $true
    }

    # Phase 3: replace the managed application files by rename-aside and
    # rename-in. Each entry records what was moved so the rollback can undo
    # exactly the completed steps, in reverse order.
    try {
        $legacyFrontend = Join-Path $AppDir 'frontend'
        $managedItems = @(
            @{ Name = 'app.jar';            Staged = (Join-Path $StagingDir 'app.jar') },
            @{ Name = 'ui';                 Staged = (Join-Path $StagingDir 'ui') },
            @{ Name = 'VERSION';            Staged = (Join-Path $StagingDir 'VERSION') },
            @{ Name = 'moddex-backend.xml'; Staged = (Join-Path $StagingDir 'moddex-backend.xml') },
            @{ Name = 'moddex-backend.exe'; Staged = (Join-Path $StagingDir 'moddex-backend.exe') }
        )
        foreach ($item in $managedItems) {
            $target = Join-Path $AppDir $item.Name
            $entry = [pscustomobject]@{ Target = $target; AsidePath = $null; NewInstalled = $false }
            if (Test-Path -LiteralPath $target) {
                $asidePath = Join-Path $AsideDir $item.Name
                Move-Item -LiteralPath $target -Destination $asidePath -Force
                $entry.AsidePath = $asidePath
            }
            $ReplacedEntries += $entry
            Move-Item -LiteralPath $item.Staged -Destination $target -Force
            $entry.NewInstalled = $true
        }

        # One-time migration: earlier installs put the assets in <AppDir>\frontend,
        # where nothing served them. It moves aside with the rest, so an aborted
        # upgrade restores it too; a successful upgrade removes it with the work
        # directory in finally.
        if (Test-Path -LiteralPath $legacyFrontend) {
            $legacyAside = Join-Path $AsideDir 'legacy-frontend'
            Move-Item -LiteralPath $legacyFrontend -Destination $legacyAside -Force
            $ReplacedEntries += [pscustomobject]@{ Target = $legacyFrontend; AsidePath = $legacyAside; NewInstalled = $false }
            Write-Log "Moved the obsolete UI directory at $legacyFrontend aside (removed after a successful upgrade)"
        }
    } catch {
        $rollbackError = $null
        try { Invoke-UpgradeRollback } catch { $rollbackError = $_ }
        if ($rollbackError) {
            $RollbackIncomplete = $true
            if ($RollbackFilesRestored) {
                # The files are back; the rollback died on a service step and
                # has already named the exact end state and next action.
                Die @"
The upgrade failed while installing the new application files: $($_.Exception.Message)
$($rollbackError.Exception.Message)
"@
            }
            elseif ($ServiceExisted) {
                Die @"
The upgrade failed while installing the new application files: $($_.Exception.Message)
The automatic rollback could not complete: $($rollbackError.Exception.Message)
The previous application files are preserved in the upgrade aside at $AsideDir.
Move them back into $AppDir by hand, fix the cause, and rerun this installer script.
"@
            }
            else {
                Die @"
The upgrade failed while installing the new application files: $($_.Exception.Message)
The automatic rollback could not complete: $($rollbackError.Exception.Message)
No previous application files existed: the application files of this run remain in $AppDir.
Remove them by hand, fix the cause, and rerun this installer script.
"@
            }
        }
        Die @"
The upgrade failed while installing the new application files: $($_.Exception.Message)
The application files and the service state from before the upgrade were re-established.
Fix the cause, then rerun this installer script.
"@
    }

    # Phase 4: (re)install and start the service with the new files. A failure
    # here also rolls back; whether the rollback re-registers the previous
    # service or reuses the registration this run just created follows the
    # case matrix on Invoke-UpgradeRollback.
    try {
        if (Get-Service -Name $ServiceId -ErrorAction SilentlyContinue) {
            Write-Log 'Updating service registration ...'
            Invoke-ServiceStep -Executable $ServiceExe -Step 'uninstall' -LogDir $LogDir
            $RanUninstall = $true
            Start-Sleep -Seconds 1
        }
        Write-Log 'Registering Windows service ...'
        Invoke-ServiceStep -Executable $ServiceExe -Step 'install' -LogDir $LogDir
        $InstalledNew = $true
        Write-Log 'Starting the Moddex service ...'
        Invoke-ServiceStep -Executable $ServiceExe -Step 'start' -LogDir $LogDir
    } catch {
        $rollbackError = $null
        try { Invoke-UpgradeRollback } catch { $rollbackError = $_ }
        if ($rollbackError) {
            $RollbackIncomplete = $true
            if ($RollbackFilesRestored) {
                # The files are back; the rollback died on a service step and
                # has already named the exact end state and next action.
                Die @"
The upgrade failed while bringing the service up: $($_.Exception.Message)
$($rollbackError.Exception.Message)
"@
            }
            elseif ($ServiceExisted) {
                Die @"
The upgrade failed while bringing the service up: $($_.Exception.Message)
The automatic rollback could not complete: $($rollbackError.Exception.Message)
The previous application files are preserved in the upgrade aside at $AsideDir.
Move them back into $AppDir by hand, fix the cause, and rerun this installer script.
"@
            }
            else {
                Die @"
The upgrade failed while bringing the service up: $($_.Exception.Message)
The automatic rollback could not complete: $($rollbackError.Exception.Message)
No previous application files existed: the application files of this run remain in $AppDir.
Remove them by hand, fix the cause, and rerun this installer script.
"@
            }
        }
        Die @"
The upgrade failed while bringing the service up: $($_.Exception.Message)
The application files and the service state from before the upgrade were re-established.
Check the WinSW wrapper log in $LogDir, fix the cause, then rerun this installer script.
"@
    }

    Write-Log "Moddex installed. Service '$ServiceId' is running on $($cfg.Address):$($cfg.Port)."
    Write-Log "Data: $DataDir   Config: $ConfigDir   Logs: $LogDir"
    if ($cfg.Mode -ne 'local') {
        Write-Log 'Reminder: open the firewall for the chosen port and complete first-run setup in the web UI.'
    }
} finally {
    # The staging and the aside are transient upgrade state: a completed run
    # (success or successful rollback) removes them; only a rollback that could
    # not complete keeps the aside with the previous files and points at it in
    # the guided message above.
    if ($RollbackIncomplete) {
        Write-Log "Upgrade aside kept for manual recovery: $AsideDir (inside $UpgradeDir)"
    } else {
        Remove-Item -LiteralPath $UpgradeDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
