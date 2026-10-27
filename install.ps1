# Macro Deck Spotify Synced Lyrics - Installer
# Sets up the daemon script, VBS runner, Startup shortcut, and initializes lyrics file

$ErrorActionPreference = "Stop"

Write-Host "Installing Macro Deck Spotify Lyrics Daemon..." -ForegroundColor Cyan

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Get-Location }

# 1. Target files in user profile
$daemonDest = Join-Path $env:USERPROFILE ".macrodeck_lyrics_daemon.ps1"
$vbsDest = Join-Path $env:USERPROFILE ".launch_macrodeck_lyrics.vbs"

Write-Host "Copying daemon scripts to user profile..." -ForegroundColor Yellow
Copy-Item -Path (Join-Path $scriptRoot "macrodeck_lyrics_daemon.ps1") -Destination $daemonDest -Force
Copy-Item -Path (Join-Path $scriptRoot "launch_macrodeck_lyrics.vbs") -Destination $vbsDest -Force

# 2. Output lyrics file for Macro Deck
$lyricsPath = Join-Path $env:APPDATA "Macro Deck\spotify_lyrics.txt"
$lyricsDir = Split-Path -Path $lyricsPath
if (-not (Test-Path $lyricsDir)) {
    New-Item -ItemType Directory -Path $lyricsDir -Force | Out-Null
}
if (-not (Test-Path $lyricsPath)) {
    Set-Content -Path $lyricsPath -Value "..." -Encoding utf8 -Force
}

# 3. Create Windows Startup shortcut (shell:startup)
Write-Host "Creating Windows Startup shortcut..." -ForegroundColor Yellow
$startupFolder = [System.Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupFolder "MacroDeckLyricsDaemon.lnk"

$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "wscript.exe"
$shortcut.Arguments = "`"$vbsDest`""
$shortcut.Description = "Macro Deck Spotify Synced Lyrics Background Daemon"
$shortcut.Save()

# 4. Stop any existing daemon instance and launch updated daemon
Write-Host "Stopping any running daemon instances..." -ForegroundColor Yellow
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*macrodeck_lyrics_daemon*" -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Write-Host "Starting background daemon..." -ForegroundColor Green
$wmi = [wmiclass]"Win32_Process"
$wmi.Create("wscript.exe `"$vbsDest`"") | Out-Null

Write-Host "Installation completed successfully!" -ForegroundColor Green
Write-Host "Lyrics file location: $lyricsPath" -ForegroundColor Cyan
