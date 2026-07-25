#Requires -Version 7.0
<#
.SYNOPSIS
    Static analysis for the Windows installer scripts.

.DESCRIPTION
    Two passes over every *.ps1 under the given path:

      1. A parse check via the PowerShell language parser. This catches syntax
         errors without executing anything — running an installer to find out
         whether it parses is not an option.
      2. PSScriptAnalyzer, when the module is available. It is installed on
         demand for the current user if the PowerShell Gallery is reachable;
         when it is not, the parse check still runs and the script reports the
         reduced coverage instead of pretending everything was checked.

    Exit code 0 means every file passed the checks that actually ran.

.PARAMETER Path
    Directory to scan recursively for *.ps1 files.

.PARAMETER Severity
    Lowest PSScriptAnalyzer severity treated as a failure. Default: Warning.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Path,

    [ValidateSet('Information', 'Warning', 'Error')]
    [string] $Severity = 'Warning'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Error "Path not found: $Path"
    exit 2
}

$files = @(Get-ChildItem -LiteralPath $Path -Filter '*.ps1' -Recurse -File)
if ($files.Count -eq 0) {
    Write-Host "[ps-lint] No PowerShell scripts found under $Path"
    exit 0
}

Write-Host "[ps-lint] Checking $($files.Count) PowerShell script(s)"

$failed = $false

# --- Pass 1: parse ----------------------------------------------------------
foreach ($file in $files) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref] $tokens, [ref] $parseErrors) | Out-Null

    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $failed = $true
        foreach ($e in $parseErrors) {
            Write-Host ("  PARSE {0}:{1}: {2}" -f `
                $file.Name, $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red
        }
    }
}

# --- Pass 2: PSScriptAnalyzer ----------------------------------------------
$analyzer = Get-Module -ListAvailable -Name PSScriptAnalyzer | Select-Object -First 1

if (-not $analyzer) {
    Write-Host "[ps-lint] PSScriptAnalyzer not installed; attempting install for the current user"
    try {
        Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force `
            -AllowClobber -ErrorAction Stop
        $analyzer = Get-Module -ListAvailable -Name PSScriptAnalyzer | Select-Object -First 1
    } catch {
        Write-Host "[ps-lint] Could not install PSScriptAnalyzer: $($_.Exception.Message)" `
            -ForegroundColor Yellow
    }
}

if ($analyzer) {
    Import-Module PSScriptAnalyzer -ErrorAction Stop
    Write-Host "[ps-lint] PSScriptAnalyzer $($analyzer.Version)"

    $order = @{ 'Information' = 0; 'Warning' = 1; 'Error' = 2 }
    $threshold = $order[$Severity]

    # Rule configuration lives next to this script so a local run and CI apply
    # the same exclusions.
    $settingsPath = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
    $analyzerArgs = @{ Severity = @('Information', 'Warning', 'Error') }
    if (Test-Path -LiteralPath $settingsPath) {
        $analyzerArgs['Settings'] = $settingsPath
        Write-Host "[ps-lint] Settings: $(Split-Path -Leaf $settingsPath)"
    }

    foreach ($file in $files) {
        $results = @(Invoke-ScriptAnalyzer -Path $file.FullName @analyzerArgs)
        foreach ($r in $results) {
            $level = [string] $r.Severity
            $isFailure = $order.ContainsKey($level) -and $order[$level] -ge $threshold
            $colour = if ($isFailure) { 'Red' } else { 'DarkGray' }
            Write-Host ("  {0,-11} {1}:{2}: [{3}] {4}" -f `
                $level, $file.Name, $r.Line, $r.RuleName, $r.Message) -ForegroundColor $colour
            if ($isFailure) { $failed = $true }
        }
    }
} else {
    Write-Host "[ps-lint] Analysis skipped — parse check only (reduced coverage)" `
        -ForegroundColor Yellow
}

if ($failed) {
    Write-Host "[ps-lint] FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "[ps-lint] OK" -ForegroundColor Green
exit 0
