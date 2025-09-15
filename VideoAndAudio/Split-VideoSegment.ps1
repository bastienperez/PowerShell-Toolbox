function Split-VideoSegment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,
        [Parameter(Mandatory = $false)]
        [string]$OutputPath,
        [Parameter(Mandatory = $true)]
        [string]$StartTime,
        [Parameter(Mandatory = $false)]
        [string]$EndTime
    )

    # function to get time in hh:mm:ss format
    function Get-TimeInHHMMSSFormat {
        param(
            [string]$Time
        )

        $timeParts = $time.Split(':')

        switch ($timeParts.Count) {
            1 { return [TimeSpan]::FromSeconds([int]$timeParts[0]) }
            2 { return [TimeSpan]::FromMinutes([int]$timeParts[0]).Add([TimeSpan]::FromSeconds([int]$timeParts[1])) }
            3 { return [TimeSpan]::FromHours([int]$timeParts[0]).Add([TimeSpan]::FromMinutes([int]$timeParts[1])).Add([TimeSpan]::FromSeconds([int]$timeParts[2])) }
            default { throw 'Invalid time format. Please use one of the following formats: SS, MM:SS, or HH:MM:SS.' }
        }
    }

    # Get video duration using FFmpeg
    $duration = & $PSScriptRoot\ffmpeg.exe -i $InputPath 2>&1 | Select-String -Pattern 'Duration: (\d+):(\d+):(\d+\.\d+)' | ForEach-Object { $_.Matches.Groups[1].Value, $_.Matches.Groups[2].Value, $_.Matches.Groups[3].Value -join ':' }

    # Use the custom Parse-Time function
    $startCutTimeSpan = Get-TimeInHHMMSSFormat -Time $StartTime

    # If no end cut time is provided, set it to the duration of the video
    if ([string]::IsNullOrWhitespace($EndTime)) {
        Write-Host -ForegroundColor Cyan "No end cut time provided. Using the full duration of the video $duration"
        $endTime = $duration
    }

    $endCutTimeSpan = Get-TimeInHHMMSSFormat -Time $EndTime

    # Calculate new duration by subtracting start cut from end cut
    $newDuration = $endCutTimeSpan.Subtract($startCutTimeSpan)

    # Format new duration for FFmpeg
    $newDuration = '{0:00}:{1:00}:{2:00}.{3:000}' -f $newDuration.Hours, $newDuration.Minutes, $newDuration.Seconds, $newDuration.Milliseconds

    if ([string]::IsNullOrWhitespace($OutputPath)) {
        # get the directory where the input file is located
        $directory = [System.IO.Path]::GetDirectoryName($InputPath)
        # set the output path to the same directory as the input file
        $OutputPath = Join-Path -Path $directory -ChildPath "trimmed_$([System.IO.Path]::GetFileName($InputPath))"
    }

    # Use FFmpeg to cut the video
    & $PSScriptRoot\ffmpeg.exe -ss $StartTime -i $InputPath -t $newDuration -c copy $OutputPath
}