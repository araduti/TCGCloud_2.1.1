# Logging Module for OSDCloud — Compatibility Wrapper
# This module delegates to TCGLogging.psm1, the canonical logging module.
# Kept for backward-compatibility with scripts that import Logging.psm1 directly.

# Import the canonical logging module
$tcgLoggingPath = Join-Path (Split-Path $PSScriptRoot) "Custom\TCGLogging.psm1"
if (-not (Test-Path $tcgLoggingPath)) {
    # Fallback: look next to this file (e.g. when scripts are packaged flat)
    $tcgLoggingPath = Join-Path $PSScriptRoot "..\Custom\TCGLogging.psm1"
}
if (Test-Path $tcgLoggingPath) {
    Import-Module $tcgLoggingPath -Force -DisableNameChecking
}

# ─── Module-level state ──────────────────────────────────────────────────────
$script:LogFile        = "X:\OSDCloud\Logs\OSDCloud.log"
$script:TranscriptFile = "X:\OSDCloud\Logs\OSDCloud-Transcript.log"
$script:ErrorFile      = "X:\OSDCloud\Logs\OSDCloud-Errors.log"
$script:LogLevels      = @{ DEBUG = 0; INFO = 1; WARNING = 2; ERROR = 3; CRITICAL = 4 }
$script:CurrentLogLevel = 1  # INFO

# ─── Public wrappers (old API → TCGLogging) ──────────────────────────────────

function Initialize-Logging {
    param(
        [string]$LogPath  = "X:\OSDCloud\Logs",
        [string]$LogLevel = "INFO"
    )

    if (-not (Test-Path $LogPath)) {
        New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
    }

    $script:LogFile        = Join-Path $LogPath "OSDCloud.log"
    $script:TranscriptFile = Join-Path $LogPath "OSDCloud-Transcript.log"
    $script:ErrorFile      = Join-Path $LogPath "OSDCloud-Errors.log"
    $script:CurrentLogLevel = if ($script:LogLevels.ContainsKey($LogLevel.ToUpper())) {
        $script:LogLevels[$LogLevel.ToUpper()]
    } else { 1 }

    Start-Transcript -Path $script:TranscriptFile -Force -Append -ErrorAction SilentlyContinue
    Write-Log "INFO" "Logging initialized. Log level: $LogLevel"
}

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("DEBUG","INFO","WARNING","ERROR","CRITICAL")]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [object]$Exception = $null,
        [string]$Component = "Unknown"
    )

    if ($script:LogLevels[$Level] -lt $script:CurrentLogLevel) { return }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $logEntry  = "[$timestamp] [$Level] [$Component] $Message"
    if ($Exception) {
        $logEntry += "`nException: $($Exception.Exception.Message)"
        if ($Exception.Exception.StackTrace) {
            $logEntry += "`nStack Trace: $($Exception.Exception.StackTrace)"
        }
    }

    Add-Content -Path $script:LogFile -Value $logEntry -Force -ErrorAction SilentlyContinue
    if ($Level -in @("ERROR","CRITICAL")) {
        Add-Content -Path $script:ErrorFile -Value $logEntry -Force -ErrorAction SilentlyContinue
    }

    $colour = switch ($Level) {
        "DEBUG"    { "Gray"    }
        "INFO"     { "White"   }
        "WARNING"  { "Yellow"  }
        "ERROR"    { "Red"     }
        "CRITICAL" { "DarkRed" }
    }
    Write-Host $logEntry -ForegroundColor $colour
}

function Get-LogContent {
    param(
        [ValidateSet("Main","Transcript","Errors")]
        [string]$LogType = "Main",
        [int]$LastLines = 100
    )

    $file = switch ($LogType) {
        "Main"       { $script:LogFile }
        "Transcript" { $script:TranscriptFile }
        "Errors"     { $script:ErrorFile }
    }
    if (Test-Path $file) { Get-Content -Path $file -Tail $LastLines }
    else { return $null }
}

function Clear-Logs {
    param(
        [ValidateSet("Main","Transcript","Errors","All")]
        [string]$LogType = "All"
    )

    $files = switch ($LogType) {
        "Main"       { @($script:LogFile) }
        "Transcript" { @($script:TranscriptFile) }
        "Errors"     { @($script:ErrorFile) }
        "All"        { @($script:LogFile, $script:TranscriptFile, $script:ErrorFile) }
    }
    foreach ($f in $files) {
        if (Test-Path $f) { Clear-Content -Path $f -Force -ErrorAction SilentlyContinue }
    }
}

function Stop-Logging {
    Stop-Transcript -ErrorAction SilentlyContinue
    Write-Log "INFO" "Logging stopped"
}

# Export the same public surface as before
Export-ModuleMember -Function Initialize-Logging, Write-Log, Get-LogContent, Clear-Logs, Stop-Logging