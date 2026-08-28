[CmdletBinding()]
param (
    [Parameter()]
    # To exclude modules from the update process
    [String[]]$ExcludedModules,
    # To include only these modules for the update process
    [String[]]$IncludedModules,
    [switch]$SkipPublisherCheck,
    [switch]$SimulationMode,
    # Number of concurrent PowerShell Gallery lookups. Only the lookups are parallelized:
    # install / update / uninstall stay sequential because PSResourceGet is not thread-safe.
    # Set to 1 to disable parallelism.
    [ValidateRange(1, 20)]
    [int]$ThrottleLimit = 5
)
<#
/!\/!\/!\ PLEASE READ /!\/!\/!\

/!\     If you look for a quick way to update, please keep in mind Microsoft has a built-in CMDlet to update ALL the PowerShell modules installed:
/!\     Update-PSResource [-Verbose]

/!\     This script is intended as a replacement of the Update-PSResource:
/!\     - to provide more human readable output than the -Verbose option of Update-PSResource
/!\     - to force install with -SkipPublisherCheck (Authenticode change) because Update-PSResource has not this option
/!\     - to exclude some modules from the update process
/!\     - to remove older versions because Update-PSResource does not remove older versions (it only installs a new version in the $env:PSModulePath\<moduleName> and keep the old module)
/!\     - to provide a simulation mode (no install / uninstall / update, only display what would be done)
/!\     - update module AND scrip
/!\     - works ONLY with Powershell 7.0+

This script provides informations about the module version (current and the latest available on PowerShell Gallery) and update to the latest version
If you have a module with two or more versions, the script delete them and reinstall only the latest.

#>

#Requires -Version 7.0

Write-Host -ForegroundColor cyan 'Define PowerShell to add TLS1.2 in this session, needed since 1st April 2020 (https://devblogs.microsoft.com/powershell/powershell-gallery-tls-support/)'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# if needed, register PSGallery
# Register PSGallery PSprovider and set as Trusted source
# Register-PSRepository -Default -ErrorAction SilentlyContinue
# Set-PSRepository -Name PSGallery -InstallationPolicy trusted -ErrorAction SilentlyContinue

if ($SimulationMode) {
    Write-Host -ForegroundColor yellow 'Simulation mode is ON, nothing will be installed / removed / updated'
}

# Uninstall-PSResource failed with 'Access to the path is denied' on redirected folders (OneDrive)
# until this fix: https://github.com/PowerShell/PSResourceGet/pull/1860 (milestone 1.2.0-preview4).
$requiredPSResourceGetVersion = [version]'1.2.0'

# The already imported module wins, otherwise take the highest one available.
$psResourceGetModule = Get-Module -Name 'Microsoft.PowerShell.PSResourceGet'

if ($null -eq $psResourceGetModule) {
    $psResourceGetModule = Get-Module -Name 'Microsoft.PowerShell.PSResourceGet' -ListAvailable | Sort-Object -Property Version -Descending | Select-Object -First 1
}

if ($null -eq $psResourceGetModule) {
    throw 'Microsoft.PowerShell.PSResourceGet is not installed. Run `Install-Module -Name Microsoft.PowerShell.PSResourceGet -Force` and start this script again.'
}

$psResourceGetVersion = [version]$psResourceGetModule.Version
$psResourceGetIsSupported = $psResourceGetVersion -ge $requiredPSResourceGetVersion

if ($psResourceGetIsSupported) {
    Write-Host -ForegroundColor Green "Microsoft.PowerShell.PSResourceGet $psResourceGetVersion detected"
}
else {
    Write-Error "Microsoft.PowerShell.PSResourceGet $psResourceGetVersion is too old: version $requiredPSResourceGetVersion or later is required, otherwise ``Uninstall-PSResource`` fails with 'Access to the path is denied' on redirected folders (OneDrive). Run ``Update-PSResource -Name Microsoft.PowerShell.PSResourceGet -Force`` to fix it. The script keeps going and falls back to ``Remove-Item -Recurse -Force`` when needed. See https://github.com/PowerShell/PSResourceGet/issues/1793"
}

function Get-ExclusionMatch {
    <#
        Returns the first exclusion pattern matching the resource name, or $null.
        Patterns must be evaluated one at a time: "$Pattern" would join the array with $OFS
        and build a wildcard matching nothing, e.g. 'Az.* Microsoft.Graph.*'.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]]$Pattern
    )

    # -eq first: it also covers names holding wildcard characters ([ ] * ?) that -like would interpret.
    return $Pattern | Where-Object { $Name -eq $_ -or $Name -like $_ } | Select-Object -First 1
}

function Resolve-GalleryResource {
    <#
        Queries the PowerShell Gallery for every requested name, in parallel, and returns a
        hashtable keyed by resource name. Each value holds the gallery object or the error
        message, so the sequential loops below can consume it without any network call.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [AllowNull()]
        [string[]]$Name,
        [Parameter(Mandatory = $true)]
        [int]$ThrottleLimit
    )

    $cache = @{}

    # `@($resources.Name)` yields a single empty string when no resource was found, so drop the blanks.
    $uniqueNames = @($Name | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

    if ($uniqueNames.Count -eq 0) {
        Write-Host -ForegroundColor Yellow 'No resource to look up in the PowerShell Gallery'
        return $cache
    }

    Write-Host -ForegroundColor Cyan "Query the PowerShell Gallery for $($uniqueNames.Count) resource(s) with a throttle limit of $ThrottleLimit"

    $lookups = $uniqueNames | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        try {
            # Select-Object -First 1: a resource registered in several repositories returns
            # more than one object, which breaks the [version] casts done by the callers.
            $found = Find-PSResource -Name $_ -ErrorAction Stop | Select-Object -First 1
            [PSCustomObject]@{ Name = $_; Info = $found; Error = $null }
        }
        catch {
            [PSCustomObject]@{ Name = $_; Info = $null; Error = $_.Exception.Message }
        }
    }

    foreach ($lookup in $lookups) {
        $cache[$lookup.Name] = $lookup
    }

    return $cache
}

function Remove-LegacyPSResource {
    param (
        [Parameter(Mandatory = $true)]  
        [System.Object]$Resource,
        [Parameter(Mandatory = $true)]
        [string]$GalleryVersion
    )
    
    try {
        $oldVersions = $Resource | Where-Object { $_.Version -ne $GalleryVersion }

        foreach ($oldVersion in $oldVersions) {
            Write-Host -ForegroundColor Cyan "$($Resource.Name) - Uninstall previous version" -NoNewline
            Write-Host -ForegroundColor White " ($($oldVersion.Version))"
            if (-not($SimulationMode)) {
                try {
                    if ($Resource.InstalledLocation -like "$env:programfiles\*") {
                        Uninstall-PSResource -Name $($Resource.Name) -Version $oldVersion.Version -ErrorAction Stop
                    }
                    else {
                        # module installed in current user location
                        Uninstall-PSResource -Name $($Resource.Name) -Version $oldVersion.Version -Scope CurrentUser -ErrorAction Stop
                    }
                }
                catch {
                    $installedLocation = Join-Path -Path $oldVersion.InstalledLocation -ChildPath "$($Resource.Name)\$($oldVersion.Version)"

                    if ($psResourceGetIsSupported) {
                        # Not the known OneDrive bug: surface it instead of hiding it behind the fallback.
                        Write-Warning "$($Resource.Name) - ``Uninstall-PSResource`` failed on PSResourceGet $psResourceGetVersion, which is not the expected behaviour: $($_.Exception.Message)"
                    }
                    else {
                        Write-Host -ForegroundColor Magenta "$($Resource.Name) - ``Uninstall-PSResource`` failed as expected on PSResourceGet $psResourceGetVersion (< $requiredPSResourceGetVersion): $($_.Exception.Message)"
                    }

                    Write-Host -ForegroundColor Magenta "$($Resource.Name) - falling back to ``Remove-Item -Recurse -Force``"

                    if (Test-Path -Path $installedLocation) {
                        Write-Host -ForegroundColor Cyan "$($Resource.Name) - Remove the folder $installedLocation"
                        Remove-Item -Path $installedLocation -Recurse -Force -ErrorAction Stop -ProgressAction SilentlyContinue
                    }
                    else {
                        Write-Warning "$($Resource.Name) - The folder $installedLocation does not exist, so cannot be removed"
                    }
                }
            }
        }
    }
    catch {
        Write-Warning "$($Resource.Name) - $($_.Exception.Message)"
    }
}

if ($IncludedModules) {
    Write-Host -ForegroundColor Cyan "Get PowerShell modules like $IncludedModules"
    $modules = Get-PSResource | Where-Object { $_.Name -like $IncludedModules -and $_.Type -ne 'Script' }
}
else {
    Write-Host -ForegroundColor Cyan 'Get all PowerShell modules'
    $modules = Get-PSResource | Where-Object { $_.Type -ne 'Script' }
}

if ($ExcludedModules) {
    # Filter before the gallery lookup, otherwise excluded modules still cost a network call.
    $modules = $modules | Where-Object {
        $matchedPattern = Get-ExclusionMatch -Name $_.Name -Pattern $ExcludedModules

        if ($matchedPattern) {
            Write-Host -ForegroundColor Yellow "Module $($_.Name) is excluded from the update process (match '$matchedPattern')"
            return $false
        }

        return $true
    }
}

$moduleGalleryCache = Resolve-GalleryResource -Name @($modules.Name) -ThrottleLimit $ThrottleLimit

foreach ($module in $modules) {
    $moduleName = $module.Name

    $currentVersion = $null
	
    try {
        $currentVersion = $module.Version
    }
    catch {
        Write-Warning "$moduleName - $($_.Exception.Message)"
        continue
    }
	
    $moduleLookup = $moduleGalleryCache[$moduleName]

    if ($null -eq $moduleLookup -or $null -eq $moduleLookup.Info) {
        Write-Warning "$moduleName not found in the PowerShell Gallery. $($moduleLookup.Error)"
        continue
    }

    $moduleGalleryInfo = $moduleLookup.Info
	
    # $current version can also be a version follow by -preview
    if ($currentVersion -like '*-preview') {
        Write-Warning 'The module installed is a preview version, it will not tested by this script'
    }

    if ($moduleGalleryInfo.Version -like '*-preview') {
        Write-Warning 'The module in PowerShell Gallery is a preview version, it will not tested bt this script'
        continue
    }
    else {
        $moduleGalleryVersion = $moduleGalleryInfo.Version
    }

    # Convert published date to YYYY/MM/DD HH:MM:SS format
    $publishedDate = [datetime]$moduleGalleryInfo.PublishedDate
    $publishedDate = $publishedDate.ToString('yyyy/MM/dd HH:mm:ss')

    if ($null -eq $currentVersion) {
        Write-Host -ForegroundColor Cyan "$moduleName - Install from PowerShellGallery version $($moduleGalleryInfo.Version) - Release date: $publishedDate"

        if (-not($SimulationMode)) {
            try {
                if ($module.InstalledLocation -like "$env:programfiles\*") {
                    Install-PSResource -Name $moduleName -Force -ErrorAction Stop
                }
                else {
                    Write-Host -ForegroundColor Cyan "Install $moduleName in CurrentUser scope because the module is installed in $($module.InstalledLocation)"
                    Install-PSResource -Name $moduleName -Scope CurrentUser -Force -ErrorAction Stop
                }
            }
            catch {
                Write-Warning "$moduleName - $($_.Exception.Message)"
            }
        }
    }
    elseif ($moduleGalleryInfo.Version -eq $currentVersion) {
        Write-Host -ForegroundColor Green "$moduleName - already in latest version: " -NoNewline
        Write-Host -ForegroundColor White "$currentVersion" -NoNewline
        Write-Host -ForegroundColor Green ' - Release date:' -NoNewline
        Write-Host -ForegroundColor White " $publishedDate"
    }
    elseif ($currentVersion.count -gt 1) {
        Write-Host -ForegroundColor Yellow "$moduleName is installed in $($currentVersion.count) versions:" -NoNewline
        Write-Host -ForegroundColor White " $($currentVersion -join ' | ')"
        Write-Host -ForegroundColor Cyan "$moduleName - Uninstall previous $moduleName version(s) below the latest version" -NoNewline
        Write-Host -ForegroundColor White " ($($moduleGalleryInfo.Version))"

        Remove-LegacyPSResource -Resource $module -GalleryVersion $moduleGalleryInfo.Version

        # Check again the current Version as we uninstalled some old versions
        $currentVersion = (Get-PSResource -Name $moduleName).Version

        if ($moduleGalleryVersion -ne $currentVersion) {
            Write-Host -ForegroundColor Cyan "$moduleName - Install from PowerShellGallery version" -NoNewline
            Write-Host -ForegroundColor White " $($moduleGalleryInfo.Version)" -NoNewline
            Write-Host -ForegroundColor Cyan ' - Release date:' -NoNewline
            Write-Host -ForegroundColor White " $publishedDate"

            if (-not($SimulationMode)) {
                try {
                    if ($module.InstalledLocation -like "$env:programfiles\*") {
                        Install-PSResource -Name $moduleName -Force -ErrorAction Stop
                    }
                    else {
                        Write-Host -ForegroundColor Cyan "Install $moduleName in CurrentUser scope because the module is installed in $($module.InstalledLocation)"
                        Install-PSResource -Name $moduleName -Scope CurrentUser -Force -ErrorAction Stop
                    }

                    Remove-LegacyPSResource -Resource $module -GalleryVersion $moduleGalleryInfo.Version
                }
                catch {
                    Write-Warning "$moduleName - $($_.Exception.Message)"
                }
            }
        }
    }
    # https://invoke-thebrain.com/2018/12/comparing-version-numbers-powershell/
    elseif ([version]$currentVersion -gt [version]$moduleGalleryVersion) {
        Write-Host -ForegroundColor Yellow "$moduleName - the current version $currentVersion is newer than the version available on PowerShell Gallery $($moduleGalleryInfo.Version) (Release date: $publishedDate). Sometimes happens when you install a module from another repository or via .exe/.msi or if you change the version number manually."
    }
    elseif ([version]$currentVersion -lt [version]$moduleGalleryVersion) {
        Write-Host -ForegroundColor Cyan "$moduleName - Update from PowerShellGallery version" -NoNewline
        Write-Host -ForegroundColor White " $currentVersion -> $($moduleGalleryInfo.Version)" -NoNewline
        Write-Host -ForegroundColor Cyan ' - Release date:' -NoNewline
        Write-Host -ForegroundColor White " $publishedDate"
        
        if (-not($SimulationMode)) {
            try {
                Update-PSResource -Name $moduleName -Force -ErrorAction Stop
                Remove-LegacyPSResource -Resource $module -GalleryVersion $moduleGalleryInfo.Version
            }
            catch {
                if ($_.Exception.Message -match 'Authenticode') {
                    Write-Host -ForegroundColor Yellow "$moduleName - The module certificate used by the creator is either changed since the last module install or the module sign status has changed."

                    if ($SkipPublisherCheck.IsPresent) {
                        Write-Host -ForegroundColor Cyan "$moduleName - SkipPublisherCheck Parameter is present, so install will run without Authenticode check"
                        Write-Host -ForegroundColor Cyan "$moduleName - Install from PowerShellGallery version $($moduleGalleryInfo.Version) - Release date: $publishedDate"
                        try {
                            if ($module.InstalledLocation -like "$env:programfiles\*") {
                                Install-PSResource -Name $moduleName -Force -SkipPublisherCheck -ErrorAction Stop
                            }
                            else {
                                Write-Host -ForegroundColor Cyan "Install $moduleName in CurrentUser scope because the module is installed in $($module.InstalledLocation)"
                                Install-PSResource -Name $moduleName -Scope CurrentUser -Force -SkipPublisherCheck -ErrorAction Stop
                            }
                        }
                        catch {
                            Write-Warning "$module - $($_.Exception.Message)"
                        }
                    
                        Remove-LegacyPSResource -Resource $module -GalleryVersion $moduleGalleryInfo.Version
                    }
                    else {
                        Write-Warning "$moduleName - If you want to update this module, run again with -SkipPublisherCheck switch, but please keep in mind the security risk"
                    }
                }
                else {
                    Write-Warning "$moduleName - $($_.Exception.Message)"
                }
            }
        }
    }
}

if ($IncludedModules) {
    Write-Host -ForegroundColor Cyan "Get PowerShell script modules like $IncludedModules"
    $scripts = Get-PSResource | Where-Object { $_.Name -like $IncludedModules -and $_.Type -eq 'Script' }
}
else {
    Write-Host -ForegroundColor Cyan 'Get all PowerShell script modules'
    $scripts = Get-PSResource | Where-Object Type -eq 'Script'
}

$scriptGalleryCache = Resolve-GalleryResource -Name @($scripts.Name) -ThrottleLimit $ThrottleLimit

foreach ($script in $scripts) {
    $scriptLookup = $scriptGalleryCache[$script.Name]

    if ($null -eq $scriptLookup -or $null -eq $scriptLookup.Info) {
        Write-Warning "$($script.Name) is not available in the PowerShell Gallery, so it is excluded from the update process"
        continue
    }

    $scriptCurrentVersion = $scriptLookup.Info

    if ($scriptCurrentVersion.Version -like '*-preview') {
        Write-Warning 'The script module in PowerShell Gallery is a preview version, it will not tested bt this script'
        continue
    }
    elseif ([version]$scriptCurrentVersion.Version -ne [version]$script.Version) {
        if ($script.InstalledLocation -like "$env:programfiles\*") {
            Write-Host -ForegroundColor Cyan "(script) $($script.Name) - Update from PowerShellGallery version with AllUsers scope" -NoNewline
            Update-PSResource -Name $script.Name -Force
        }
        else {
            Write-Host -ForegroundColor Cyan "(script) $($script.Name) - Update from PowerShellGallery version with CurrentUser scope" -NoNewline
            Update-PSResource -Name $script.Name -Scope CurrentUser -Force
        }
    }
    else {
        Write-Host -ForegroundColor Green "(script) $($script.Name) - already in latest version: " -NoNewline
        Write-Host -ForegroundColor White "$($script.Version)" -NoNewline
        Write-Host -ForegroundColor Green ' - Release date:' -NoNewline
        $scriptPublishedDate = [datetime]$scriptCurrentVersion.PublishedDate
        $scriptPublishedDate = $scriptPublishedDate.ToString('yyyy/MM/dd HH:mm:ss')
        Write-Host -ForegroundColor White " $scriptPublishedDate"
    }
}