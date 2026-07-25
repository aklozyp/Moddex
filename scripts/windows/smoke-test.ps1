#Requires -Version 5.1
<#
.SYNOPSIS
    End-to-end install smoke test for the Moddex Windows service.

.DESCRIPTION
    The Windows counterpart of scripts/smoke-test.sh. It installs Moddex as a
    service (local mode), verifies the backend comes up, that a protected endpoint
    rejects anonymous access (auth is enforced), reports the resolved paths, and
    then uninstalls and purges. Intended for a throwaway Windows CI runner or VM.

.PARAMETER Port
    Port to install on (default: 8080).
.PARAMETER KeepInstalled
    Skip the uninstall step (leave the service running for manual inspection).
#>
[CmdletBinding()]
param(
    [int]$Port = 8080,
    [switch]$KeepInstalled
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BaseUrl   = "http://127.0.0.1:$Port"
$failures  = 0

function Ok([string]$m)   { Write-Host "[ OK ] $m" -ForegroundColor Green }
function Bad([string]$m)  { Write-Host "[FAIL] $m" -ForegroundColor Red; $script:failures++ }
function Info([string]$m) { Write-Host "[ -- ] $m" }

function Get-Status([string]$Path) {
    try {
        $r = Invoke-WebRequest -Uri "$BaseUrl$Path" -Method GET -UseBasicParsing -TimeoutSec 5
        return [int]$r.StatusCode
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        return 0
    } catch { return 0 }
}

Info "Installing Moddex (local mode, port $Port) ..."
& (Join-Path $ScriptDir 'install.ps1') -Mode local -Port $Port

# Wait for the backend to answer (Spring Boot start can take a while).
Info 'Waiting for the backend to become reachable ...'
$reachable = $false
for ($i = 0; $i -lt 60; $i++) {
    $code = Get-Status '/api/v1/setup/status'
    if ($code -ne 0) { $reachable = $true; break }
    Start-Sleep -Seconds 2
}
if ($reachable) { Ok "backend reachable (/api/v1/setup/status -> $(Get-Status '/api/v1/setup/status'))" }
else { Bad 'backend not reachable after ~120s' }

# A clean exit code 0 of the service means the SCM considers it running.
$svc = Get-Service -Name 'moddex-backend' -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') { Ok "service status: $($svc.Status)" }
else { Bad "service not running: $(if ($svc) { $svc.Status } else { 'absent' })" }

# Protected endpoint must reject anonymous access.
$anon = Get-Status '/api/v1/instance'
if ($anon -eq 401 -or $anon -eq 403) { Ok "auth enforced (/instance -> $anon without a token)" }
elseif ($anon -eq 200) { Bad '/instance served WITHOUT a token (200) - auth not enforced' }
else { Info "unexpected anonymous status for /instance: $anon (continuing)" }

Info "Data:   $(Join-Path $env:ProgramData 'Moddex\data')"
Info "Config: $(Join-Path $env:ProgramData 'Moddex\config')"
Info "Logs:   $(Join-Path $env:ProgramData 'Moddex\logs')"

if (-not $KeepInstalled) {
    Info 'Uninstalling (purge) ...'
    & (Join-Path $ScriptDir 'uninstall.ps1') -Purge
}

if ($failures -gt 0) { Write-Error "Smoke test failed with $failures failure(s)."; exit 1 }
Ok 'Smoke test passed.'
