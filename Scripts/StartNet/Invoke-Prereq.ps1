# Import utility functions
. "$PSScriptRoot\Utils.ps1"

Start-Transcript -Path "X:\OSDCloud\Logs\Prereq-Transcript.log" -Force
try {
    Write-Host "Status: Checking Autopilot status"
    $SerialNumber = (Get-WmiObject -Class Win32_BIOS).SerialNumber
    Write-Host "Status: Device serial number: $SerialNumber"
    
    $Token = Get-GraphToken
    if ($Token) {
        Write-Host "Status: Successfully got Graph token, checking Autopilot status"
        $AutopilotStatus = Test-AutopilotStatus -SerialNumber $SerialNumber -Token $Token
        
        # Debug output
        Write-Host "Status: Autopilot check results: Success=$($AutopilotStatus.Success), IsRegistered=$($AutopilotStatus.IsRegistered)"
        
        if ($AutopilotStatus.Success -and $AutopilotStatus.IsRegistered) {
            Write-Host "FINAL_RESULT: Registered in Autopilot"
            Stop-Transcript
            exit 0
        }
        else {
            Write-Host "FINAL_RESULT: Not registered in Autopilot"
            Stop-Transcript
            # IMPORTANT: Exit code 2 means device not registered
            exit 2
        }
    }
    else {
        Write-Host "Status: Failed to get Graph token"
        Write-Host "FINAL_RESULT: Could not get Graph token"
        Stop-Transcript
        exit 1
    }
        
}
catch {
    Write-Error "Unexpected error: $_"
    Write-Host "FINAL_RESULT: Error: $($_.Exception.Message)"
    Stop-Transcript
    exit 99
}