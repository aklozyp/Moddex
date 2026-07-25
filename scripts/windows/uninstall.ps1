#Requires -Version 5.1
<#
.SYNOPSIS
    Removes the Moddex Windows service and application files.

.DESCRIPTION
    The Windows counterpart of scripts/uninstall.sh. By default it stops and
    removes the service and the application directory under %ProgramFiles%\Moddex
    but PRESERVES instance data and config under %ProgramData%\Moddex, mirroring
    the Linux installer's non-destructive default. Pass -Purge to also remove all
    data, config and logs.

.PARAMETER Purge
    Also delete %ProgramData%\Moddex (instances, backups, settings, logs).
#>
[CmdletBinding()]
param(
    [switch]$Purge
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ServiceId  = 'moddex-backend'
$AppDir     = Join-Path $env:ProgramFiles 'Moddex'
$DataRoot   = Join-Path $env:ProgramData 'Moddex'
$ServiceExe = Join-Path $AppDir 'moddex-backend.exe'

function Write-Log([string]$Message) { Write-Host "[moddex-uninstall] $Message" }
function Die([string]$Message) { Write-Error $Message; exit 1 }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die 'This uninstaller must run from an elevated (Administrator) PowerShell session.'
}

if (Get-Service -Name $ServiceId -ErrorAction SilentlyContinue) {
    Write-Log 'Stopping and removing the service ...'
    if (Test-Path $ServiceExe) {
        & $ServiceExe stop      2>$null | Out-Null
        & $ServiceExe uninstall 2>$null | Out-Null
    } else {
        # Fall back to SCM if the wrapper exe is already gone.
        Stop-Service -Name $ServiceId -Force -ErrorAction SilentlyContinue
        sc.exe delete $ServiceId | Out-Null
    }
    Start-Sleep -Seconds 1
}

if (Test-Path $AppDir) {
    Write-Log "Removing application directory $AppDir"
    Remove-Item -Recurse -Force $AppDir
}

if ($Purge) {
    if (Test-Path $DataRoot) {
        Write-Log "Purging data directory $DataRoot"
        Remove-Item -Recurse -Force $DataRoot
    }
} else {
    Write-Log "Instance data preserved at $DataRoot (pass -Purge to remove it)."
}

Write-Log 'Moddex uninstalled.'
