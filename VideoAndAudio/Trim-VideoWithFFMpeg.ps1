Param(
    [Parameter(Mandatory = $false)]
    [string]$InputVideo,
    [Parameter(Mandatory = $false)]
    [string]$OutputVideo,
    [Parameter(Mandatory = $true)]
    [string]$StartCut,
    [Parameter(Mandatory = $false)]
    [string]$EndCut
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
$duration = & ffmpeg -i $InputVideo 2>&1 | Select-String -Pattern 'Duration: (\d+):(\d+):(\d+\.\d+)' | ForEach-Object { $_.Matches.Groups[1].Value, $_.Matches.Groups[2].Value, $_.Matches.Groups[3].Value -join ':' }

# Use the custom Parse-Time function
$startCutTimeSpan = Get-TimeInHHMMSSFormat -Time $StartCut

# If no end cut time is provided, set it to the duration of the video
if ([string]::IsNullOrWhitespace($EndCut)) {
    Write-Host -ForegroundColor Cyan "No end cut time provided. Using the full duration of the video $duration"
    $endCut = $duration
}

$endCutTimeSpan = Get-TimeInHHMMSSFormat -Time $EndCut

# Calculate new duration by subtracting start cut from end cut
$newDuration = $endCutTimeSpan.Subtract($startCutTimeSpan)

# Format new duration for FFmpeg
$newDuration = '{0:00}:{1:00}:{2:00}.{3:000}' -f $newDuration.Hours, $newDuration.Minutes, $newDuration.Seconds, $newDuration.Milliseconds

# Use FFmpeg to cut the video
& ffmpeg -ss $StartCut -i $InputVideo -t $newDuration -c copy $OutputVideo