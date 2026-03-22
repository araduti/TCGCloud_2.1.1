function Write-TCGStatus {
    <#
    .SYNOPSIS
        Writes a colour-coded status message to the console.
    .DESCRIPTION
        Internal helper used by public TCGCloud functions for consistent output.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Type = 'Info'
    )

    $colour = switch ($Type) {
        'Info'    { 'Cyan'   }
        'Success' { 'Green'  }
        'Warning' { 'Yellow' }
        'Error'   { 'Red'    }
    }

    Write-Host $Message -ForegroundColor $colour
}
