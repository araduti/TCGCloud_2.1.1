# Logging Module for OSDCloud
# Provides consistent logging across all scripts

$script:LogLevels = @{
    DEBUG    = 0
    INFO     = 1
    WARNING  = 2
    ERROR    = 3
    CRITICAL = 4
}

$script:CurrentLogLevel = $script:LogLevels.INFO
$script:LogFile = "X:\OSDCloud\Logs\OSDCloud.log"
$script:TranscriptFile = "X:\OSDCloud\Logs\OSDCloud-Transcript.log"
$script:ErrorFile = "X:\OSDCloud\Logs\OSDCloud-Errors.log"

function Initialize-Logging {
    param(
        [string]$LogPath = "X:\OSDCloud\Logs",
        [string]$LogLevel = "INFO"
    )
    
    try {
        # Create log directory if it doesn't exist
        if (-not (Test-Path $LogPath)) {
            New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
        }

        # Set log file paths
        $script:LogFile = Join-Path $LogPath "OSDCloud.log"
        $script:TranscriptFile = Join-Path $LogPath "OSDCloud-Transcript.log"
        $script:ErrorFile = Join-Path $LogPath "OSDCloud-Errors.log"

        # Set log level
        $script:CurrentLogLevel = $script:LogLevels[$LogLevel.ToUpper()]
        if ($null -eq $script:CurrentLogLevel) {
            $script:CurrentLogLevel = $script:LogLevels.INFO
            Write-Log "WARNING" "Invalid log level specified: $LogLevel. Defaulting to INFO."
        }

        # Start transcript
        Start-Transcript -Path $script:TranscriptFile -Force -Append

        Write-Log "INFO" "Logging initialized. Log level: $LogLevel"
        Write-Log "INFO" "Log files:"
        Write-Log "INFO" "  - Main log: $($script:LogFile)"
        Write-Log "INFO" "  - Transcript: $($script:TranscriptFile)"
        Write-Log "INFO" "  - Errors: $($script:ErrorFile)"
    }
    catch {
        Write-Error "Failed to initialize logging: $_"
        throw
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL")]
        [string]$Level,
        
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [object]$Exception = $null,
        
        [Parameter(Mandatory = $false)]
        [string]$Component = "Unknown"
    )

    try {
        # Check if we should log this message based on current log level
        if ($script:LogLevels[$Level] -lt $script:CurrentLogLevel) {
            return
        }

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $logEntry = "[$timestamp] [$Level] [$Component] $Message"
        
        # Add exception details if provided
        if ($Exception) {
            $logEntry += "`nException: $($Exception.Exception.Message)"
            if ($Exception.Exception.StackTrace) {
                $logEntry += "`nStack Trace: $($Exception.Exception.StackTrace)"
            }
        }

        # Write to log file
        Add-Content -Path $script:LogFile -Value $logEntry -Force

        # Write to error file if level is ERROR or CRITICAL
        if ($Level -in @("ERROR", "CRITICAL")) {
            Add-Content -Path $script:ErrorFile -Value $logEntry -Force
        }

        # Write to console with appropriate color
        switch ($Level) {
            "DEBUG" { Write-Host $logEntry -ForegroundColor Gray }
            "INFO" { Write-Host $logEntry -ForegroundColor White }
            "WARNING" { Write-Host $logEntry -ForegroundColor Yellow }
            "ERROR" { Write-Host $logEntry -ForegroundColor Red }
            "CRITICAL" { Write-Host $logEntry -ForegroundColor DarkRed -BackgroundColor White }
        }
    }
    catch {
        Write-Error "Failed to write log entry: $_"
    }
}

function Get-LogContent {
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet("Main", "Transcript", "Errors")]
        [string]$LogType = "Main",
        
        [Parameter(Mandatory = $false)]
        [int]$LastLines = 100
    )

    try {
        $logFile = switch ($LogType) {
            "Main" { $script:LogFile }
            "Transcript" { $script:TranscriptFile }
            "Errors" { $script:ErrorFile }
        }

        if (Test-Path $logFile) {
            Get-Content -Path $logFile -Tail $LastLines
        }
        else {
            Write-Log "WARNING" "Log file not found: $logFile"
            return $null
        }
    }
    catch {
        Write-Log "ERROR" "Failed to get log content" -Exception $_
        return $null
    }
}

function Clear-Logs {
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet("Main", "Transcript", "Errors", "All")]
        [string]$LogType = "All"
    )

    try {
        $filesToClear = switch ($LogType) {
            "Main" { @($script:LogFile) }
            "Transcript" { @($script:TranscriptFile) }
            "Errors" { @($script:ErrorFile) }
            "All" { @($script:LogFile, $script:TranscriptFile, $script:ErrorFile) }
        }

        foreach ($file in $filesToClear) {
            if (Test-Path $file) {
                Clear-Content -Path $file -Force
                Write-Log "INFO" "Cleared log file: $file"
            }
        }
    }
    catch {
        Write-Log "ERROR" "Failed to clear logs" -Exception $_
    }
}

function Stop-Logging {
    try {
        Stop-Transcript
        Write-Log "INFO" "Logging stopped"
    }
    catch {
        Write-Error "Failed to stop logging: $_"
    }
}

# Export the functions
Export-ModuleMember -Function Initialize-Logging, Write-Log, Get-LogContent, Clear-Logs, Stop-Logging 