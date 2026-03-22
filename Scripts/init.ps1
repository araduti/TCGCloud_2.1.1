# OSDCloud init script
param()

# Default Windows version and build
$OSVersion = "Windows 11"
$OSBuild = "24H2"

# Function to show Windows version selection dialog with timeout
function Show-WindowsVersionDialog {
    [CmdletBinding()]
    param(
        [int]$TimeoutSeconds = 10
    )
    
    # Pre-defined options
    $options = @(
        @{ Name = "Windows 11 24H2 (Latest)"; Version = "Windows 11"; Build = "24H2" },
        @{ Name = "Windows 10 22H2"; Version = "Windows 10"; Build = "22H2" }
    )
    
    # Build the menu
    Clear-Host
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "            WINDOWS VERSION SELECTION           " -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Select a Windows version to install:" -ForegroundColor Yellow
    Write-Host "Default selection: $($options[0].Name)" -ForegroundColor Green
    Write-Host ""
    
    for ($i = 0; $i -lt $options.Count; $i++) {
        Write-Host "  $($i+1). $($options[$i].Name)"
    }
    
    Write-Host ""
    Write-Host "This menu will automatically select the default option in $TimeoutSeconds seconds..."
    Write-Host "================================================" -ForegroundColor Cyan
    
    # Start timer
    $startTime = Get-Date
    $selection = $null
    
    # Wait for input with timeout
    while ((Get-Date).Subtract($startTime).TotalSeconds -lt $TimeoutSeconds) {
        if ([Console]::KeyAvailable) {
            $keyInfo = [Console]::ReadKey($true)
            if ($keyInfo.Key -ge [ConsoleKey]::D1 -and $keyInfo.Key -le [ConsoleKey]::D5) {
                $index = [int]$keyInfo.Key - [int][ConsoleKey]::D1
                if ($index -lt $options.Count) {
                    $selection = $options[$index]
                    break
                }
            }
            elseif ($keyInfo.Key -ge [ConsoleKey]::NumPad1 -and $keyInfo.Key -le [ConsoleKey]::NumPad5) {
                $index = [int]$keyInfo.Key - [int][ConsoleKey]::NumPad1
                if ($index -lt $options.Count) {
                    $selection = $options[$index]
                    break
                }
            }
        }
        
        # Update countdown
        $remainingSeconds = $TimeoutSeconds - [Math]::Floor((Get-Date).Subtract($startTime).TotalSeconds)
        Write-Host "`rTime remaining: $remainingSeconds seconds...      " -NoNewline
        Start-Sleep -Milliseconds 250
    }
    
    # Clear the countdown line
    Write-Host "`r                                   " -NoNewline
    
    # If no selection was made, use default
    if ($null -eq $selection) {
        $selection = $options[0]
        Write-Host "`rUsing default: $($selection.Name)" -ForegroundColor Yellow
    }
    else {
        Write-Host "`rSelected: $($selection.Name)" -ForegroundColor Green
    }
    
    return $selection
}

# Main script execution
try {
    # Show Windows version selection dialog with 10-second timeout
    $selectedOS = Show-WindowsVersionDialog -TimeoutSeconds 10
    
    # Extract selected Windows version and build
    $OSVersion = $selectedOS.Version
    $OSBuild = $selectedOS.Build
    
    Write-Host "Selected Windows version: $OSVersion $OSBuild" -ForegroundColor Cyan
    
    # Start Show-OSDCloudOverlay with selected parameters
    . X:\OSDCloud\Config\Scripts\StartNet\Show-OSDCloudOverlay.ps1 -OSVersion $OSVersion -OSBuild $OSBuild
}
catch {
    Write-Host "Error: $_" -ForegroundColor Red
    # If an error occurs, fall back to defaults
    . X:\OSDCloud\Config\Scripts\StartNet\Show-OSDCloudOverlay.ps1 -OSVersion $OSVersion -OSBuild $OSBuild
} 