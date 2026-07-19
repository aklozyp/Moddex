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
    the existing service definition unless -Mode/-Port is passed explicitly.

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

# --- constants ---------------------------------------------------------------
$ServiceId   = 'moddex-backend'
$AppDir      = Join-Path $env:ProgramFiles 'Moddex'
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
function Resolve-WinSw {
    $bundled = if ($WinSwPath) { $WinSwPath } else { Join-Path $PackagingWin 'WinSW.exe' }
    if (Test-Path $bundled) {
        Write-Log "Using bundled WinSW: $bundled"
        return $bundled
    }
    # Not bundled: download the pinned release and verify its hash.
    $tmp = Join-Path $env:TEMP "WinSW-$WinSwVersion.exe"
    Write-Log "Downloading WinSW $WinSwVersion …"
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
    'MODDEX_ROOT', 'MODDEX_CONFIG_DIR', 'MODDEX_LOG_DIR',
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

function Resolve-Config {
    $modeExplicit = $PSBoundParameters.ContainsKey('Mode')
    $portExplicit = $PSBoundParameters.ContainsKey('Port')

    $resolvedMode = $Mode
    if (-not $modeExplicit) {
        $existingMode = Get-ExistingEnv 'MODDEX_MODE'
        if ($existingMode) { $resolvedMode = $existingMode }
        elseif (-not $resolvedMode) {
            Die 'No -Mode given and no existing install to inherit from. Pass -Mode local|lan|public.'
        }
    }

    $resolvedPort = $Port
    if (-not $portExplicit) {
        $existingPort = Get-ExistingEnv 'SERVER_PORT'
        if ($existingPort) { $resolvedPort = [int]$existingPort } else { $resolvedPort = 8080 }
    }
    if ($resolvedPort -lt 1 -or $resolvedPort -gt 65535) { Die "Invalid -Port: $resolvedPort" }

    $address = if ($resolvedMode -eq 'local') { '127.0.0.1' } else { '0.0.0.0' }
    return [pscustomobject]@{ Mode = $resolvedMode; Port = $resolvedPort; Address = $address }
}

# --- main --------------------------------------------------------------------
Assert-Admin
$javaExe = Resolve-JavaExe
Write-Log "Using Java: $javaExe"

if (-not $BackendJar)  { $BackendJar  = Join-Path $BundleRoot 'backend\Moddex-Backend.jar' }
if (-not $FrontendDir) { $FrontendDir = Join-Path $BundleRoot 'frontend' }
if (-not (Test-Path $BackendJar))  { Die "Backend JAR not found: $BackendJar" }
if (-not (Test-Path $FrontendDir)) { Die "Frontend assets not found: $FrontendDir" }

$cfg = Resolve-Config
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

# Stop the service before replacing the JAR so the file is not locked.
if (Get-Service -Name $ServiceId -ErrorAction SilentlyContinue) {
    Write-Log 'Stopping existing service for upgrade …'
    & $ServiceExe stop  2>$null | Out-Null
}

Write-Log 'Installing application artifacts …'
Copy-Item -Path $BackendJar -Destination (Join-Path $AppDir 'app.jar') -Force
$frontendTarget = Join-Path $AppDir 'frontend'
if (Test-Path $frontendTarget) { Remove-Item -Recurse -Force $frontendTarget }
Copy-Item -Path $FrontendDir -Destination $frontendTarget -Recurse -Force

# Record the installed version for parity with Linux (/opt/moddex/VERSION) so
# operators can verify an upgrade (Get-Content "$env:ProgramFiles\Moddex\VERSION").
$bundleVersion = Join-Path $BundleRoot 'VERSION'
$versionTarget = Join-Path $AppDir 'VERSION'
if (Test-Path $bundleVersion) {
    Copy-Item -Path $bundleVersion -Destination $versionTarget -Force
} else {
    # No bundle metadata (e.g. custom -BackendJar/-FrontendDir): never leave a
    # stale VERSION from a previous install. Match install.sh's 'dev' fallback.
    Set-Content -Path $versionTarget -Value 'dev' -Encoding ASCII -NoNewline
}

# Render the WinSW service definition from the template.
$templatePath = Join-Path $PackagingWin 'moddex-backend.xml.template'
if (-not (Test-Path $templatePath)) { Die "Service template not found: $templatePath" }
$xml = Get-Content -Path $templatePath -Raw
$xml = $xml.Replace('@@JAVA_EXE@@', $javaExe).
            Replace('@@APP_DIR@@', $AppDir).
            Replace('@@DATA_DIR@@', $DataDir).
            Replace('@@CONFIG_DIR@@', $ConfigDir).
            Replace('@@LOG_DIR@@', $LogDir).
            Replace('@@MODE@@', $cfg.Mode).
            Replace('@@SERVER_ADDRESS@@', $cfg.Address).
            Replace('@@SERVER_PORT@@', [string]$cfg.Port)

# Re-render replaces the whole file, so carry over any operator-added <env>
# entries from the previous definition before writing (read while the old XML is
# still on disk). Managed keys keep coming from the template above.
$preservedEnv = Get-UnmanagedEnv
if ($preservedEnv.Count -gt 0) {
    [xml]$doc = $xml
    foreach ($extra in $preservedEnv) {
        $node = $doc.CreateElement('env')
        $node.SetAttribute('name', $extra.Name)
        $node.SetAttribute('value', $extra.Value)
        $doc.DocumentElement.AppendChild($node) | Out-Null
        Write-Log "Preserving operator-added env entry: $($extra.Name)"
    }
    $doc.Save($ServiceXml)
} else {
    Set-Content -Path $ServiceXml -Value $xml -Encoding UTF8
}

# Place the WinSW executable next to its XML (WinSW derives the config from its
# own file name: moddex-backend.exe -> moddex-backend.xml).
Copy-Item -Path (Resolve-WinSw) -Destination $ServiceExe -Force

# (Re)install and start the service.
if (Get-Service -Name $ServiceId -ErrorAction SilentlyContinue) {
    Write-Log 'Updating service registration …'
    & $ServiceExe uninstall | Out-Null
    Start-Sleep -Seconds 1
}
Write-Log 'Registering Windows service …'
& $ServiceExe install | Out-Null
& $ServiceExe start   | Out-Null

Write-Log "Moddex installed. Service '$ServiceId' is running on $($cfg.Address):$($cfg.Port)."
Write-Log "Data: $DataDir   Config: $ConfigDir   Logs: $LogDir"
if ($cfg.Mode -ne 'local') {
    Write-Log 'Reminder: open the firewall for the chosen port and complete first-run setup in the web UI.'
}
