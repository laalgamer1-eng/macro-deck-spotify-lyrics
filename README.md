# Macro Deck Spotify Synced Lyrics Bridge

A lightweight, zero-latency background synchronization daemon that fetches synchronized LRC lyrics for the currently playing Spotify track and streams them formatted into a 3-line teleprompter-style display for **Macro Deck 3**.

---

## Features

- **Direct Windows GSMTC API Hooking:** Utilizes the Windows Runtime (`WinRT`) `GlobalSystemMediaTransportControlsSessionManager` API to read sub-millisecond accurate track positions directly from the Windows audio subsystem.
- **Strict Spotify Isolation:** Explicitly filters for Spotify (`SourceAppUserModelId -match 'Spotify'`), ignoring other media sources such as Chrome, YouTube, Edge, or Discord.
- **LRCLIB Integration:** Automatically fetches timestamped LRC lyrics from [LRCLIB](https://lrclib.net) upon song change.
- **-300ms Lookahead Timing:** Applies a subtle 300ms lookahead offset to display each line right before it is sung, compensating for human visual perception and display latency.
- **3-Line Format:** Outputs the previous line, active line, and upcoming line:
  ```text
  Previous lyric line
  >> Active synchronized line <<
  Upcoming lyric line
  ```
- **Smart Change Detection:** Only writes to disk when the output line transitions, preventing redundant disk I/O and SSD wear.
- **Silent & Persistent:** Runs completely hidden via WScript with auto-start configured in `shell:startup`.

---

## Architecture & How It Works

1. **Media Detection & Timeline:**
   The daemon queries `Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager` to locate the active Spotify media session. It reads:
   - `MediaProperties`: Track title and artist name.
   - `TimelineProperties`: Media progress timestamp (`Position.TotalMilliseconds`) plus elapsed delta from `LastUpdatedTime`.
2. **Lyric Fetching & Matching:**
   When a track change is detected, timestamped LRC lyrics are retrieved from:
   ```text
   https://lrclib.net/api/get?artist_name={artist}&track_name={title}
   ```
   Each lyric line's millisecond timestamp is parsed and continuously matched against `(positionMs + 300)` every 250ms.
3. **File Output:**
   The active 3-line format is written to:
   ```text
   %APPDATA%\Macro Deck\spotify_lyrics.txt
   ```

---

## One-Click Installation

Clone or download this repository, open PowerShell in the project directory, and run:

```powershell
.\install.ps1
```

The installer will:
1. Copy `macrodeck_lyrics_daemon.ps1` and `launch_macrodeck_lyrics.vbs` to your user profile directory (`%USERPROFILE%`).
2. Register an auto-start shortcut in your Windows Startup folder (`shell:startup`) pointing to the silent VBS launcher.
3. Terminate any previous daemon instances and launch the new daemon in the background.

---

## Macro Deck 3 Configuration

To display lyrics on your Macro Deck pad or stream deck:

1. Open **Macro Deck 3**.
2. Select or create a button on your grid.
3. Set the button type or label to read from the text file:
   - **Label / Text Template:** Bind `{vars.spotify_lyrics}` or read the file at:
     ```text
     {file_read:C:\Users\<YourUser>\AppData\Roaming\Macro Deck\spotify_lyrics.txt}
     ```
   - Alternatively, use the **File Reader / Text File Variable** integration or plugin to assign the file's content to a variable `{vars.spotify_lyrics}`.
4. Set the text formatting to center-aligned, multi-line display with word wrap enabled.

---

## Manual Controls

- **Start Daemon Silently:**
  ```powershell
  wscript.exe "$env:USERPROFILE\.launch_macrodeck_lyrics.vbs"
  ```
- **Stop Daemon:**
  ```powershell
  Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*macrodeck_lyrics_daemon*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
  ```

---

## License

MIT License. Designed for personal and home-automation use with Macro Deck 3 and Spotify.
