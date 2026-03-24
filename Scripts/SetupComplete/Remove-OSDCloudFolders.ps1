# Name: Remove-OSDCloudFolders.ps1

# Start transcript logging
Start-Transcript -Path "$env:SystemRoot\Temp\TCGCloud-Cleanup.log" -Force

try {
    Write-Host "Starting OSDCloud folders cleanup..."
    
    # List of OSDCloud folders to remove
    $foldersToRemove = @(
        "C:\OSDCloud",
        "C:\ProgramData\OSDCloud",
        "C:\Temp\OSDCloud"
    )
    
    foreach ($folder in $foldersToRemove) {
        if (Test-Path $folder) {
            Write-Host "Removing folder: $folder"
            Remove-Item -Path $folder -Recurse -Force -ErrorAction SilentlyContinue
            
            if (Test-Path $folder) {
                Write-Host "WARNING: Failed to completely remove $folder"
            }
            else {
                Write-Host "Successfully removed $folder"
            }
        }
        else {
            Write-Host "Folder not found: $folder"
        }
    }

    Write-Host "OSDCloud cleanup completed"
}
catch {
    Write-Host "Error during cleanup: $_"
}
finally {
    Stop-Transcript
}