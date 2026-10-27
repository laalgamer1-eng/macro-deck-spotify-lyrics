# Background Spotify Synced-Lyrics Daemon for Macro Deck
# Uses WinRT GSMTC API for exact media timestamps with -300ms lookahead and 250ms polling loop

$ErrorActionPreference = "SilentlyContinue"

$lyricsPath = Join-Path $env:APPDATA "Macro Deck\spotify_lyrics.txt"
$lyricsDir = Split-Path -Path $lyricsPath
if (-not (Test-Path $lyricsDir)) {
    New-Item -ItemType Directory -Path $lyricsDir -Force | Out-Null
}

$lastWrittenLine = $null

function Write-LyricsFile([string]$line) {
    if ($line -eq $script:lastWrittenLine) {
        return
    }
    try {
        Set-Content -Path $lyricsPath -Value $line -Encoding utf8 -Force
        $script:lastWrittenLine = $line
    } catch {
        # Silently retry or ignore concurrent read locks
    }
}

# Ensure initial file state
if (-not (Test-Path $lyricsPath)) {
    Write-LyricsFile "..."
}

# Initialize WinRT types for GSMTC
try {
    [System.Reflection.Assembly]::LoadWithPartialName("System.Runtime.WindowsRuntime") | Out-Null
    [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime] | Out-Null
    [Windows.Media.Control.GlobalSystemMediaTransportControlsSession, Windows.Media.Control, ContentType = WindowsRuntime] | Out-Null
    [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType = WindowsRuntime] | Out-Null

    $asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq "AsTask" -and $_.GetParameters().Count -eq 1 -and $_.GetGenericArguments().Count -eq 1
    } | Select-Object -First 1

    function Await-WinRT($asyncOp, $type) {
        if (-not $asyncOp) { return $null }
        $concreteMethod = $script:asTaskMethod.MakeGenericMethod($type)
        $task = $concreteMethod.Invoke($null, @($asyncOp))
        $task.Wait(1500) | Out-Null
        return $task.Result
    }
} catch {
    # Fallback if WinRT loading fails
}

$manager = $null
try {
    if ($asTaskMethod) {
        $manager = Await-WinRT ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
    }
} catch {}

$currentTrackKey = ""
$parsedLyrics = @()
$hasLyrics = $false
$fallbackStopwatch = [System.Diagnostics.Stopwatch]::new()

while ($true) {
    $artist = ""
    $track = ""
    $positionMs = -1
    $isPlaying = $false
    $foundMedia = $false

    # 1. Attempt GSMTC WinRT lookup strictly for Spotify
    try {
        if (-not $manager -and $asTaskMethod) {
            $manager = Await-WinRT ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
        }

        if ($manager) {
            # Target exclusively Spotify media sessions, ignoring Chrome, Edge, and other media players
            $session = $manager.GetSessions() | Where-Object { $_.SourceAppUserModelId -match 'Spotify' } | Select-Object -First 1

            if ($session) {
                $mediaOp = $session.TryGetMediaPropertiesAsync()
                $mediaProps = Await-WinRT $mediaOp ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])

                if ($mediaProps -and $mediaProps.Title) {
                    $artist = $mediaProps.Artist
                    $track = $mediaProps.Title
                    $foundMedia = $true

                    $timeline = $session.GetTimelineProperties()
                    $playback = $session.GetPlaybackInfo()
                    $isPlaying = ($playback.PlaybackStatus -eq "Playing")

                    if ($timeline) {
                        $positionMs = $timeline.Position.TotalMilliseconds
                        if ($isPlaying -and $timeline.LastUpdatedTime) {
                            $delta = ([DateTimeOffset]::UtcNow - $timeline.LastUpdatedTime.ToUniversalTime()).TotalMilliseconds
                            if ($delta -gt 0 -and $delta -lt 15000) {
                                $positionMs += $delta
                            }
                        }
                    }
                }
            }
        }
    } catch {
        # GSMTC exception, fallback below
    }

    # 2. Fallback to Spotify Window Title if GSMTC yielded no media
    if (-not $foundMedia) {
        $rawTitle = (Get-Process -Name Spotify -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -match ' - ' } | Select-Object -First 1).MainWindowTitle
        if ($rawTitle) {
            $parts = $rawTitle -split ' - ', 2
            $artist = $parts[0].Trim()
            $track = if ($parts.Length -ge 2) { $parts[1].Trim() } else { "" }
            $foundMedia = $true
            $isPlaying = $true
            if (-not $fallbackStopwatch.IsRunning) {
                $fallbackStopwatch.Start()
            }
            $positionMs = $fallbackStopwatch.ElapsedMilliseconds
        } else {
            $fallbackStopwatch.Reset()
        }
    }

    # 3. Handle Lyrics Synchronization
    if ($foundMedia -and $track) {
        $trackKey = "$artist - $track"

        if ($trackKey -ne $currentTrackKey) {
            $currentTrackKey = $trackKey
            $fallbackStopwatch.Restart()
            $parsedLyrics = @()
            $hasLyrics = $false
            Write-LyricsFile "..."

            try {
                $url = "https://lrclib.net/api/get?artist_name=$([Uri]::EscapeDataString($artist))&track_name=$([Uri]::EscapeDataString($track))"
                $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 5 -ErrorAction Stop
                if ($resp -and $resp.syncedLyrics) {
                    $lines = $resp.syncedLyrics -split "`r?`n"
                    $list = [System.Collections.Generic.List[PSCustomObject]]::new()
                    foreach ($l in $lines) {
                        if ($l -match '^\[(\d+):(\d+(?:\.\d+)?)\](.*)$') {
                            $min = [int]$matches[1]
                            $sec = [double]$matches[2]
                            $timeMs = [long](($min * 60 + $sec) * 1000)
                            $txt = $matches[3].Trim()
                            $list.Add([PSCustomObject]@{ TimeMs = $timeMs; Text = $txt })
                        }
                    }
                    $parsedLyrics = $list
                    $hasLyrics = ($parsedLyrics.Count -gt 0)
                }
            } catch {
                $parsedLyrics = @()
                $hasLyrics = $false
            }

            if (-not $hasLyrics) {
                Write-LyricsFile ""
            }
        }

        # Apply -300ms lookahead offset (advance position by 300ms so lyric line activates ahead of speech)
        if ($hasLyrics -and $parsedLyrics.Count -gt 0 -and $positionMs -ge 0) {
            $effectiveMs = $positionMs + 300
            $activeIdx = -1

            for ($idx = 0; $idx -lt $parsedLyrics.Count; $idx++) {
                if ($effectiveMs -ge $parsedLyrics[$idx].TimeMs) {
                    $activeIdx = $idx
                } else {
                    break
                }
            }

            if ($activeIdx -ge 0) {
                $prevLine = if ($activeIdx -gt 0) { $parsedLyrics[$activeIdx - 1].Text } else { "" }
                $currentLine = $parsedLyrics[$activeIdx].Text
                $nextLine = if ($activeIdx -lt ($parsedLyrics.Count - 1)) { $parsedLyrics[$activeIdx + 1].Text } else { "" }

                $formattedOutput = "$prevLine`n>> $currentLine <<`n$nextLine"
                Write-LyricsFile $formattedOutput
            } else {
                # Before the first lyric begins (intro)
                $nextLine = $parsedLyrics[0].Text
                $formattedOutput = "`n>> ... <<`n$nextLine"
                Write-LyricsFile $formattedOutput
            }
        }
    } else {
        # No Spotify media playing / closed
        if ($currentTrackKey -ne "") {
            $currentTrackKey = ""
            $parsedLyrics = @()
            $hasLyrics = $false
            $fallbackStopwatch.Reset()
            Write-LyricsFile ""
        }
    }

    Start-Sleep -Milliseconds 250
}
