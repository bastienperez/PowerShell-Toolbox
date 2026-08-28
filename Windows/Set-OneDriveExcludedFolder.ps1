<#
.SYNOPSIS
    Manages the OneDrive policy "Exclude specific kinds of folders from being uploaded".

.DESCRIPTION
    Configures the registry key backing the GPO setting
    HKLM\SOFTWARE\Policies\Microsoft\OneDrive\EnableODIgnoreFolderListFromGPO,
    which prevents the OneDrive sync app (OneDrive.exe) from uploading folders
    whose name matches one of the listed keywords.

    Typical use case: exclude PowerShell / WindowsPowerShell (or any folder holding
    binaries and other technical files) from a Documents folder redirected by
    Known Folder Move, to avoid module sync conflicts and stop uploading
    non-collaborative data.

    Things to know before deploying:
      - Complete folder names only, wildcards (*) are not supported.
      - The match is on the name, not on a path: excluding "Modules" excludes
        every folder named "Modules" in the synced content.
      - Not retroactive: already synced folders are not removed from the cloud.
      - OneDrive.exe must be restarted after enabling or changing the policy.
      - Currently available through GPO only (no native Intune setting yet).

    Reference:
    https://learn.microsoft.com/en-us/sharepoint/use-group-policy#exclude-specific-kinds-of-folders-from-being-uploaded

.PARAMETER FolderName
    One or more complete folder names to exclude from the upload.
    A full path is accepted, only its last segment is kept: the policy matches a
    folder name wherever it appears, it cannot be scoped to a single path.

.PARAMETER Replace
    Replace the whole list with the folder names passed to -FolderName.
    Without this switch the new names are added to the existing list.

.PARAMETER Remove
    Remove the specified folder names from the list instead of adding them.

.PARAMETER Clear
    Remove the whole policy (deletes the registry key).

.PARAMETER RestartOneDrive
    Restart OneDrive.exe so the policy takes effect immediately.

.EXAMPLE
    .\Set-OneDriveExcludedFolder.ps1

    Displays the folder names currently excluded.

.EXAMPLE
    .\Set-OneDriveExcludedFolder.ps1 -FolderName 'PowerShell', 'WindowsPowerShell' -RestartOneDrive

    Adds both folders to the list and restarts the sync app.

.EXAMPLE
    .\Set-OneDriveExcludedFolder.ps1 -FolderName 'node_modules', 'bin' -Replace

    Replaces the whole list with these two folder names.

.EXAMPLE
    .\Set-OneDriveExcludedFolder.ps1 -FolderName 'node_modules' -Remove

    Removes a folder name from the list.

.EXAMPLE
    .\Set-OneDriveExcludedFolder.ps1 -Clear

    Removes the policy.

.NOTES
    Requires administrative rights (HKLM).
#>
[CmdletBinding(DefaultParameterSetName = 'List', SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Set')]
    [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Remove')]
    [ValidateNotNullOrEmpty()]
    [string[]]$FolderName,

    [Parameter(ParameterSetName = 'Set')]
    [switch]$Replace,

    [Parameter(Mandatory = $true, ParameterSetName = 'Remove')]
    [switch]$Remove,

    [Parameter(Mandatory = $true, ParameterSetName = 'Clear')]
    [switch]$Clear,

    [switch]$RestartOneDrive
)

$ErrorActionPreference = 'Stop'

$policyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive\EnableODIgnoreFolderListFromGPO'

function Get-ExcludedFolder {
    [System.Collections.Generic.List[string]]$folders = @()

    if (-not (Test-Path $policyKey)) {
        return , $folders
    }

    $key = Get-Item -Path $policyKey

    # The GPO list stores one REG_SZ per entry, named 1, 2, 3, ...
    $valueNames = $key.GetValueNames() | Sort-Object -Property @{ Expression = { if ($_ -match '^\d+$') { [int]$_ } else { [int]::MaxValue } } }, @{ Expression = { $_ } }

    foreach ($valueName in $valueNames) {
        $value = $key.GetValue($valueName)

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $folders.Add([string]$value)
        }
    }

    return , $folders
}

function Set-ExcludedFolder {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Folder
    )

    if (Test-Path $policyKey) {
        $null = Remove-Item -Path $policyKey -Recurse -Force
    }

    $null = New-Item -Path $policyKey -Force

    $index = 1

    foreach ($item in $Folder) {
        $params = @{
            Path         = $policyKey
            Name         = $index.ToString()
            Value        = $item
            PropertyType = 'String'
            Force        = $true
        }
        $null = New-ItemProperty @params
        $index++
    }
}

# Administrative rights are required to write under HKLM
if ($PSCmdlet.ParameterSetName -ne 'List') {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    if (-not ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
        Write-Warning '[!] This script must be run in an elevated PowerShell session.'
        return
    }
}

$currentFolders = Get-ExcludedFolder

switch ($PSCmdlet.ParameterSetName) {
    'Clear' {
        if (-not (Test-Path $policyKey)) {
            Write-Host -ForegroundColor Yellow '[i] The policy is not configured, nothing to remove.'
            return
        }

        if ($PSCmdlet.ShouldProcess($policyKey, 'Remove the OneDrive folder exclusion policy')) {
            try {
                $null = Remove-Item -Path $policyKey -Recurse -Force
                Write-Host -ForegroundColor Green '[OK] Policy removed.'
            }
            catch {
                $message = $_.Exception.Message
                Write-Warning "[!] Failed to remove the policy: $message"
                return
            }
        }
    }

    'Remove' {
        [System.Collections.Generic.List[string]]$newFolders = @()

        foreach ($folder in $currentFolders) {
            if ($FolderName -notcontains $folder) {
                $newFolders.Add($folder)
            }
        }

        if ($newFolders.Count -eq $currentFolders.Count) {
            Write-Host -ForegroundColor Yellow '[i] None of the specified folder names were configured.'
            return
        }

        if ($PSCmdlet.ShouldProcess($policyKey, 'Update the OneDrive folder exclusion list')) {
            try {
                Set-ExcludedFolder -Folder $newFolders
                Write-Host -ForegroundColor Green '[OK] Folder exclusion list updated.'
            }
            catch {
                $message = $_.Exception.Message
                Write-Warning "[!] Failed to update the policy: $message"
                return
            }
        }
    }

    'Set' {
        [System.Collections.Generic.List[string]]$newFolders = @()

        # The list is additive by default, -Replace starts from an empty one
        if (-not $Replace) {
            foreach ($folder in $currentFolders) {
                $newFolders.Add($folder)
            }
        }

        foreach ($folder in $FolderName) {
            $folder = $folder.Trim()

            # The policy only accepts complete folder names
            if ($folder -match '[\*\?]') {
                Write-Warning "[!] '$folder' is ignored: wildcards are not supported, use a complete folder name."
                continue
            }

            # A path is accepted for convenience but only its last segment is kept:
            # the policy matches a folder name wherever it is, it cannot target one path
            if ($folder -match '[\\/]') {
                $inputPath = $folder
                $folder = Split-Path -Path $folder.TrimEnd('\', '/') -Leaf

                if ([string]::IsNullOrWhiteSpace($folder)) {
                    Write-Warning "[!] '$inputPath' is ignored: no folder name could be extracted."
                    continue
                }

                Write-Warning "[*] '$inputPath' is a path, only the name '$folder' is kept: every folder named '$folder' will be excluded, whatever its location."
            }

            if ($newFolders -notcontains $folder) {
                $newFolders.Add($folder)
            }
        }

        if ($newFolders.Count -eq 0) {
            Write-Warning '[!] No valid folder name to configure.'
            return
        }

        if ($PSCmdlet.ShouldProcess($policyKey, 'Set the OneDrive folder exclusion list')) {
            try {
                Set-ExcludedFolder -Folder $newFolders
                Write-Host -ForegroundColor Green '[OK] Folder exclusion list configured.'
            }
            catch {
                $message = $_.Exception.Message
                Write-Warning "[!] Failed to configure the policy: $message"
                return
            }
        }
    }
}

# Report the resulting configuration
$finalFolders = Get-ExcludedFolder

if ($finalFolders -and $finalFolders.Count -gt 0) {
    $count = $finalFolders.Count
    Write-Host -ForegroundColor Cyan "[i] Folders excluded from the OneDrive upload ($count):"

    foreach ($folder in $finalFolders) {
        Write-Host "    - $folder"
    }
}
else {
    Write-Host -ForegroundColor Cyan '[i] No folder is excluded from the OneDrive upload.'
}

if ($RestartOneDrive) {
    $oneDriveProcesses = @(Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue)

    if ($oneDriveProcesses -and $oneDriveProcesses.Count -gt 0) {
        $oneDrivePath = $oneDriveProcesses[0].Path

        Write-Host -ForegroundColor Cyan '[...] Restarting OneDrive.exe'

        try {
            $oneDriveProcesses | Stop-Process -Force
            Start-Process -FilePath $oneDrivePath -ArgumentList '/background'
            Write-Host -ForegroundColor Green '[OK] OneDrive.exe restarted.'
        }
        catch {
            $message = $_.Exception.Message
            Write-Warning "[!] Failed to restart OneDrive.exe: $message"
        }
    }
    else {
        Write-Warning '[!] OneDrive.exe is not running, restart it manually to apply the policy.'
    }
}
elseif ($PSCmdlet.ParameterSetName -ne 'List') {
    Write-Host -ForegroundColor Yellow '[*] Restart OneDrive.exe to apply the policy (the setting is not retroactive).'
}

return
