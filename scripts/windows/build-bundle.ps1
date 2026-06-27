#Requires -Version 5.1
<#
.SYNOPSIS
    Assembles the installable Moddex Windows artifact (zip + SHA256).

.DESCRIPTION
    The Windows counterpart of scripts/build-bundle.sh. Builds the backend JAR and
    the production frontend from the sibling Moddex-Backend / Moddex-Frontend
    repositories, bundles the Windows installer scripts and the verified WinSW
    service wrapper, and produces moddex-<version>-windows-x64.zip with a checksum.

.PARAMETER Version
    Version label embedded in the artifact name and VERSION file (default: dev).
#>
[CmdletBinding()]
param(
    [string]$Version = $(if ($env:VERSION) { $env:VERSION } else { 'dev' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)   # scripts\windows -> repo root
$RepoRoot    = Split-Path -Parent $ProjectRoot
$BackendDir  = Join-Path $RepoRoot 'Moddex-Backend'
$FrontendDir = Join-Path $RepoRoot 'Moddex-Frontend'

$BuildDir    = Join-Path $ProjectRoot 'build'
$BundleDir   = Join-Path $BuildDir 'bundle-windows'

# Keep the WinSW pin in sync with install.ps1.
$WinSwVersion = 'v2.12.0'
$WinSwUrl     = "https://github.com/winsw/winsw/releases/download/$WinSwVersion/WinSW-x64.exe"
$WinSwSha256  = '05b82d46ad331cc16bdc00de5c6332c1ef818df8ceefcd49c726553209b3a0da'

function Write-Log([string]$Message) { Write-Host "[build] $Message" }
function Die([string]$Message) { Write-Error $Message; exit 1 }

# Runs a native command (npm/mvnw) robustly. Tools like npm print warnings to
# stderr; under $ErrorActionPreference='Stop' Windows PowerShell would turn that
# into a terminating NativeCommandError even on a successful run. Drop to
# 'Continue' for the call (do NOT redirect stderr, which would wrap each line as
# an ErrorRecord) and decide success solely from the process exit code.
function Invoke-Native {
    param([Parameter(Mandatory)][scriptblock]$Cmd, [Parameter(Mandatory)][string]$What)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Cmd } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { Die "$What failed (exit $LASTEXITCODE)" }
}

if (Test-Path $BuildDir) { Remove-Item -Recurse -Force $BuildDir }
New-Item -ItemType Directory -Force -Path (Join-Path $BundleDir 'backend') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $BundleDir 'frontend') | Out-Null

# --- backend -----------------------------------------------------------------
if (-not (Test-Path (Join-Path $BackendDir 'pom.xml'))) { Die "Backend project not found at $BackendDir" }
Write-Log 'Building backend artifact'
$mvnw = Join-Path $BackendDir 'mvnw.cmd'
Invoke-Native { & $mvnw -f (Join-Path $BackendDir 'pom.xml') -B -Pprod -DskipTests clean package } 'Backend build'
$backendJar = Get-ChildItem -Path (Join-Path $BackendDir 'target') -Filter 'Moddex-Backend-*.jar' |
    Where-Object { $_.Name -notmatch 'sources|javadoc' } | Select-Object -First 1
if (-not $backendJar) { Die "Backend JAR not found in $BackendDir\target" }
Copy-Item $backendJar.FullName (Join-Path $BundleDir 'backend\Moddex-Backend.jar') -Force

# --- frontend ----------------------------------------------------------------
if (-not (Test-Path (Join-Path $FrontendDir 'package.json'))) { Die "Frontend project not found at $FrontendDir" }
Write-Log 'Building frontend assets'
Push-Location $FrontendDir
try {
    if (Test-Path (Join-Path $FrontendDir 'package-lock.json')) {
        Invoke-Native { npm ci } 'Frontend dependency install'
    } else {
        Invoke-Native { npm install } 'Frontend dependency install'
    }
    Invoke-Native { npm run build -- --configuration production } 'Frontend build'
} finally { Pop-Location }
$frontendDist = Join-Path $FrontendDir 'dist'
if (-not (Test-Path $frontendDist)) { Die "Frontend dist directory not found at $frontendDist" }
Copy-Item -Path (Join-Path $frontendDist '*') -Destination (Join-Path $BundleDir 'frontend') -Recurse -Force

# --- installer resources -----------------------------------------------------
Write-Log 'Copying Windows installer resources'
# Create the intermediate parents first: Copy-Item -Recurse does not reliably
# create missing parent directories of the destination across PowerShell versions.
New-Item -ItemType Directory -Force -Path (Join-Path $BundleDir 'scripts') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $BundleDir 'packaging') | Out-Null
Copy-Item -Path (Join-Path $ProjectRoot 'scripts\windows') -Destination (Join-Path $BundleDir 'scripts\windows') -Recurse -Force
Copy-Item -Path (Join-Path $ProjectRoot 'packaging\windows') -Destination (Join-Path $BundleDir 'packaging\windows') -Recurse -Force

# Bundle a checksum-verified WinSW so the install is offline-capable. A local copy
# can be supplied via MODDEX_WINSW_SOURCE (e.g. a CI cache); otherwise the pinned
# release is downloaded with a few retries to ride out transient network errors.
$winsw = Join-Path $BundleDir 'packaging\windows\WinSW.exe'
if ($env:MODDEX_WINSW_SOURCE -and (Test-Path $env:MODDEX_WINSW_SOURCE)) {
    Write-Log "Using local WinSW: $env:MODDEX_WINSW_SOURCE"
    Copy-Item -Path $env:MODDEX_WINSW_SOURCE -Destination $winsw -Force
} else {
    Write-Log "Fetching WinSW $WinSwVersion"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ok = $false
    for ($attempt = 1; $attempt -le 3 -and -not $ok; $attempt++) {
        try {
            Invoke-WebRequest -Uri $WinSwUrl -OutFile $winsw -UseBasicParsing -TimeoutSec 120
            $ok = $true
        } catch {
            Write-Log "WinSW download attempt $attempt failed: $($_.Exception.Message)"
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
    if (-not $ok) { Die "Failed to download WinSW from $WinSwUrl after 3 attempts" }
}
$actual = (Get-FileHash -Algorithm SHA256 -Path $winsw).Hash.ToLowerInvariant()
if ($actual -ne $WinSwSha256) { Die "WinSW checksum mismatch (expected $WinSwSha256, got $actual)" }

Set-Content -Path (Join-Path $BundleDir 'VERSION') -Value $Version -Encoding ASCII -NoNewline

# --- archive -----------------------------------------------------------------
$artifact = Join-Path $BuildDir "moddex-$Version-windows-x64.zip"
Write-Log "Creating archive $artifact"
Compress-Archive -Path (Join-Path $BundleDir '*') -DestinationPath $artifact -Force
$hash = (Get-FileHash -Algorithm SHA256 -Path $artifact).Hash.ToLowerInvariant()
"$hash *$(Split-Path -Leaf $artifact)" | Set-Content -Path "$artifact.sha256" -Encoding ASCII

Write-Log "Bundle created at $artifact"
