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

.NOTES
    Provenance: transferred verbatim from the release repository's develop
    branch at commit f0898ffa9bc1adcb2a62216143f2a9c0a1fa04fd
    (https://github.com/aklozyp/Moddex); only this .NOTES section was added
    during the transfer (Forgejo issue #564). Windows execution has not been
    verified by this repository; see the install.ps1 notes and
    docs/windows-installer.md for the support status.

    The verbatim transfer ends with the Forgejo issue #198 fix (audit M101):
    the two native WinSW calls (stop, uninstall) run through the
    Invoke-ServiceStep wrapper, which evaluates $LASTEXITCODE and aborts with
    a guided message on a nonzero code; the $LogDir constant and this paragraph
    are part of that change. No other line was touched.
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
# WinSW writes its wrapper log to <logpath> from the service template
# (%ProgramData%\Moddex\logs); named in the Invoke-ServiceStep failure message.
$LogDir     = Join-Path $DataRoot 'logs'

function Write-Log([string]$Message) { Write-Host "[moddex-uninstall] $Message" }
function Die([string]$Message) { Write-Error $Message; exit 1 }

# --- native WinSW step execution (Forgejo issue #198) ------------------------
# Every native WinSW call in this script goes through this wrapper: the exit
# code is evaluated instead of being swallowed by `2>$null | Out-Null`
# (audit M101). No exit code is tolerated here: the pinned WinSW v2.12.0
# already treats the "already done" situations as success (stop on an
# already-stopped service, uninstall of a missing or marked-for-delete
# service), so a nonzero code is always a real failure (Win32 error code, or
# -1 for an unhandled WinSW exception). Unlike the installer, the uninstaller
# removes files afterwards, so a half-finished service teardown must stop the
# run instead of silently deleting the application directory. WinSW logs every
# CLI operation to the wrapper log in <logpath>, so the guided message can
# point there without exposing anything beyond the paths this script already
# prints. See install.ps1 for the full rationale.
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
Check the WinSW wrapper log in $LogDir, correct the cause, and rerun this uninstaller script.
"@
    }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die 'This uninstaller must run from an elevated (Administrator) PowerShell session.'
}

if (Get-Service -Name $ServiceId -ErrorAction SilentlyContinue) {
    Write-Log 'Stopping and removing the service ...'
    if (Test-Path $ServiceExe) {
        Invoke-ServiceStep -Executable $ServiceExe -Step 'stop' -LogDir $LogDir
        Invoke-ServiceStep -Executable $ServiceExe -Step 'uninstall' -LogDir $LogDir
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
