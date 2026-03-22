# TCGLogging.ps1
# Shared logging functions for TCG Cloud deployment scripts

# Ensure log directory exists
$script:LogDirectory = "X:\OSDCloud\Logs"
if (-not (Test-Path $script:LogDirectory)) {
    New-Item -Path $script:LogDirectory -ItemType Directory -Force | Out-Null
}

# Log levels (equivalent to enum in PS 5.0+)
$LogLevel = @{
    Debug = 0
    Info = 1
    Warning = 2
    Error = 3
    Fatal = 4
}

# Shared state tracking
$script:CurrentTranscript = $null
$script:ScriptName = $null

function Start-TCGLogging {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,
        
        [Parameter(Mandatory = $false)]
        [switch]$NoTranscript,
        
        [Parameter(Mandatory = $false)]
        [string]$LogPrefix = ""
    )
    
    $script:ScriptName = $ScriptName
    
    # Create timestamped log filename
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $logPrefix = if ($LogPrefix) { "$LogPrefix-" } else { "" }
    $logFile = Join-Path $script:LogDirectory "$($logPrefix)$($ScriptName)-$timestamp.log"
    
    # Start transcript if requested
    if (-not $NoTranscript) {
        $transcriptFile = Join-Path $script:LogDirectory "$($logPrefix)$($ScriptName)-Transcript-$timestamp.log"
        Start-Transcript -Path $transcriptFile -Force
        $script:CurrentTranscript = $transcriptFile
    }
    
    # Log start of script
    Write-TCGLog -Level $LogLevel.Info -Message "===== $ScriptName started at $(Get-Date) =====" -LogFile $logFile
    
    # Return the log file path
    return $logFile
}

function Stop-TCGLogging {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$LogFile,
        
        [Parameter(Mandatory = $false)]
        [int]$ExitCode = 0
    )
    
    # Log script completion
    Write-TCGLog -Level $LogLevel.Info -Message "===== $script:ScriptName completed at $(Get-Date) with exit code $ExitCode =====" -LogFile $LogFile
    
    # Stop transcript if it was started
    if ($script:CurrentTranscript -and (Get-Command -Name Stop-Transcript -ErrorAction SilentlyContinue)) {
        Stop-Transcript
        $script:CurrentTranscript = $null
    }
    
    return $ExitCode
}

function Write-TCGLog {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [int]$Level,
        
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $true)]
        [string]$LogFile,
        
        [Parameter(Mandatory = $false)]
        [switch]$NoConsole
    )
    
    # Format the log entry
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $levelName = switch ($Level) {
        $LogLevel.Debug { "Debug" }
        $LogLevel.Info { "Info" }
        $LogLevel.Warning { "Warning" }
        $LogLevel.Error { "Error" }
        $LogLevel.Fatal { "Fatal" }
        default { "Unknown" }
    }
    $logEntry = "[$timestamp][$levelName][$script:ScriptName] $Message"
    
    # Write to log file
    $logEntry | Out-File -FilePath $LogFile -Append -Encoding utf8
    
    # Write to console with appropriate color if requested
    if (-not $NoConsole) {
        $color = switch ($Level) {
            $LogLevel.Debug { "Gray" }
            $LogLevel.Info { "White" }
            $LogLevel.Warning { "Yellow" }
            $LogLevel.Error { "Red" }
            $LogLevel.Fatal { "Magenta" }
            default { "White" }
        }
        
        Write-Host $logEntry -ForegroundColor $color
    }
}

function Write-TCGDebug {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $true)]
        [string]$LogFile
    )
    
    Write-TCGLog -Level $LogLevel.Debug -Message $Message -LogFile $LogFile
}

function Write-TCGInfo {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $true)]
        [string]$LogFile
    )
    
    Write-TCGLog -Level $LogLevel.Info -Message $Message -LogFile $LogFile
}

function Write-TCGWarning {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $true)]
        [string]$LogFile
    )
    
    Write-TCGLog -Level $LogLevel.Warning -Message $Message -LogFile $LogFile
}

function Write-TCGError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $true)]
        [string]$LogFile,
        
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )
    
    $errorMessage = $Message
    if ($ErrorRecord) {
        $errorMessage += " | Exception: $($ErrorRecord.Exception.Message)"
        $errorMessage += " | Stack Trace: $($ErrorRecord.ScriptStackTrace)"
    }
    
    Write-TCGLog -Level $LogLevel.Error -Message $errorMessage -LogFile $LogFile
}

function Write-TCGFatal {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $true)]
        [string]$LogFile,
        
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )
    
    $errorMessage = $Message
    if ($ErrorRecord) {
        $errorMessage += " | Exception: $($ErrorRecord.Exception.Message)"
        $errorMessage += " | Stack Trace: $($ErrorRecord.ScriptStackTrace)"
    }
    
    Write-TCGLog -Level $LogLevel.Fatal -Message $errorMessage -LogFile $LogFile
}

# Invoke-TCGScript function to handle executing scripts with proper error handling
function Invoke-TCGScript {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        
        [Parameter(Mandatory = $false)]
        [string]$LogFile,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Parameters = @{},
        
        [Parameter(Mandatory = $false)]
        [switch]$ContinueOnError
    )
    
    $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($ScriptPath)
    
    if (-not $LogFile) {
        $LogFile = Join-Path $script:LogDirectory "Invoke-TCGScript.log"
    }
    
    Write-TCGInfo -Message "Invoking script: $ScriptPath" -LogFile $LogFile
    
    try {
        # Convert parameters hashtable to actual parameters
        $paramString = ""
        foreach ($key in $Parameters.Keys) {
            $value = $Parameters[$key]
            if ($value -is [switch]) {
                if ($value) {
                    $paramString += " -$key"
                }
            }
            elseif ($value -is [string]) {
                $paramString += " -$key '$value'"
            }
            else {
                $paramString += " -$key $value"
            }
        }
        
        Write-TCGDebug -Message "Script parameters: $paramString" -LogFile $LogFile
        
        # Execute the script
        $scriptBlock = [ScriptBlock]::Create("& '$ScriptPath' $paramString")
        $result = Invoke-Command -ScriptBlock $scriptBlock
        $exitCode = if ($LASTEXITCODE -ne $null) { $LASTEXITCODE } else { 0 }
        
        if ($exitCode -eq 0) {
            Write-TCGInfo -Message "Script completed successfully with exit code: $exitCode" -LogFile $LogFile
            return @{
                Success = $true
                ExitCode = $exitCode
                Output = $result
            }
        }
        else {
            $errorMessage = "Script failed with exit code: $exitCode"
            Write-TCGError -Message $errorMessage -LogFile $LogFile
            
            if ($ContinueOnError) {
                return @{
                    Success = $false
                    ExitCode = $exitCode
                    Output = $result
                    Error = $errorMessage
                }
            }
            else {
                throw $errorMessage
            }
        }
    }
    catch {
        Write-TCGError -Message "Error executing script $ScriptPath" -LogFile $LogFile -ErrorRecord $_
        
        if ($ContinueOnError) {
            return @{
                Success = $false
                ExitCode = 99
                Output = $null
                Error = $_.Exception.Message
            }
        }
        else {
            throw
        }
    }
} 