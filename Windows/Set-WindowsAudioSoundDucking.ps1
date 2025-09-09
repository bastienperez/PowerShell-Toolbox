# By default, Windows reduces the volume of other sounds by 80% when Windows detects communications activity

if (((Get-ItemProperty HKCU:\Software\Microsoft\Multimedia\Audio).UserDuckingPreference)) {
    Set-ItemProperty -Path HKCU:\Software\Microsoft\Multimedia\Audio -Name UserDuckingPreference -Value 3
}
else {
    $null = New-ItemProperty -Path HKCU:\Software\Microsoft\Multimedia\Audio -Name UserDuckingPreference -PropertyType 'DWord' -Value 3
}