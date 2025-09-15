function Join-VideoFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$InputDirectory = '.',
        [Parameter(Mandatory = $false)]
        [string]$FileFilter = '*.mp4',
        [Parameter(Mandatory = $false)]
        [string]$OutputPath = 'outputVideo.mp4'
    )

    # Get the list of video files from the specified directory
    $videoFiles = Get-ChildItem -Path $InputDirectory -Filter $FileFilter

    if ($videoFiles.Count -eq 0) {
        Write-Warning "No video files found in directory '$InputDirectory' with filter '$FileFilter'"
        return
    }

    Write-Host "Found $($videoFiles.Count) video files to concatenate"

    # Create a temporary file to list all video files for ffmpeg
    $tempFile = New-TemporaryFile
    foreach ($videoFile in $videoFiles) {
        Add-Content -Path $tempFile.FullName -Value "file '$($videoFile.FullName)'"
    }

    try {
        # Concatenate videos using ffmpeg
        Write-Host "Concatenating videos to '$OutputPath'..."
        & ffmpeg -f concat -safe 0 -i $tempFile.FullName -c copy $OutputPath
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host -ForegroundColor Green "Video concatenation completed successfully: $OutputPath"
        }
        else {
            Write-Error "FFmpeg failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        # Clean up the temporary file
        Remove-Item -Path $tempFile.FullName -ErrorAction SilentlyContinue
    }
}