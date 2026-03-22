# Copy-OfficeSources.ps1 — Runs during OOBE before Office installation.
# Delegates to the shared Copy-OfficeSourcesToLocal function.

Start-Transcript -Path "C:\Windows\Logs\Copy-OfficeSources.log" -Force

# Dot-source the shared implementation
$sharedScript = Join-Path $PSScriptRoot "..\..\Shared\Copy-OfficeSources.ps1"
if (-not (Test-Path $sharedScript)) {
    $sharedScript = Join-Path $PSScriptRoot "..\..\..\Scripts\Shared\Copy-OfficeSources.ps1"
}

if (Test-Path $sharedScript) {
    . $sharedScript
    $result = Copy-OfficeSourcesToLocal -DestinationPath "C:\Windows\Temp\OfficeSources"
    if ($result) {
        Write-Host "Office sources prepared successfully for installation" -ForegroundColor Green
    }
    else {
        Write-Host "Failed to prepare Office sources" -ForegroundColor Yellow
    }
}
else {
    Write-Host "Shared Copy-OfficeSources.ps1 not found at: $sharedScript" -ForegroundColor Red
}

Stop-Transcript