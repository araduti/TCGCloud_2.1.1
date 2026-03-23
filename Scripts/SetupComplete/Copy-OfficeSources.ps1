# Copy-OfficeSources.ps1 for SetupComplete
# This script runs in the full Windows environment during first boot.
# Delegates to the shared Copy-OfficeSourcesToLocal function.

Start-Transcript -Path "$env:WINDIR\Logs\OfficeCopy-SetupComplete.log" -Force

# Dot-source the shared implementation
$sharedScript = Join-Path $PSScriptRoot "..\Shared\Copy-OfficeSources.ps1"
if (-not (Test-Path $sharedScript)) {
    # Fallback: try the Scripts\Shared path relative to the repo root
    $sharedScript = Join-Path $PSScriptRoot "..\..\Scripts\Shared\Copy-OfficeSources.ps1"
}

if (Test-Path $sharedScript) {
    . $sharedScript
    $result = Copy-OfficeSourcesToLocal -DestinationPath "C:\Windows\Temp\OfficeSources"
    if ($result) {
        Write-Host "Office source files copied successfully." -ForegroundColor Green
    }
    else {
        Write-Host "Office source copy did not complete." -ForegroundColor Yellow
    }
}
else {
    Write-Host "Shared Copy-OfficeSources.ps1 not found at: $sharedScript" -ForegroundColor Red
}

Stop-Transcript