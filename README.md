<div align="center">
<p align="center">
  <img src="icon/river.png" alt="river app icon" width="128">
</p>
# river

**A music player for your local library.**

Created by **jane(not remover)**

</div>

---

river is a desktop music player built with Flutter. It brings your local music library, playlists, lyrics, listening statistics, and player appearance together in one place.

> **Platform:** river is currently developed for Windows. Other desktop platforms are not yet promised or tested.

## Features

### your music, your way

- Scan music folders and build a searchable local library.
- Add tracks to the queue and create playlists.
- Drag and drop supported audio files into the app.
- Edit track information and choose or create album artwork.
- Browse recently played tracks and view listening statistics, including play counts and time listened.

### A player you can make your own

- Play, pause, skip, seek, adjust volume, and repeat tracks.
- Customize the player layout, keyboard shortcuts, and text size.
- Choose a background style: blurred artwork, artwork colors, or a solid color.
- Adjust the Windows font used by the app.
- Use the visualizer, or enable Economy mode to reduce visual effects.

### Lyrics and integrations

- Show lyrics from supported embedded metadata and local `.lrc` files.
- Look up lyrics through LRCLIB when available.
- Connect Last.fm for now-playing updates and scrobbling.
- Optionally share the currently playing track through Discord Rich Presence.
- Choose the interface language: English, Spanish, Russian, Ukrainian, or Chinese.

### Supported audio formats

MP3, FLAC, WAV, M4A, and OGG are supported. Playback availability can also depend on the file and Windows media decoding support.

## Getting started

### Install on Windows

Download the latest `river` installer from the repository's **Releases** page, run it, and follow the installation instructions. Releases are the recommended way to install river; you do not need Flutter or development tools.

## Privacy

Your audio files are read from your computer; river does not upload the audio itself. Some optional features send information to external services:

- **Lyrics:** a lyrics lookup can send track information, such as title and artist, to LRCLIB.
- **Last.fm:** when connected, track information is sent to Last.fm for now-playing updates and scrobbles. Tracks of 30 seconds or less are not scrobbled; longer tracks are scrobbled after half their duration or four minutes, whichever comes first.
- **Discord:** when enabled and playing, the track title and artist are shared with Discord Rich Presence.

You can leave these integrations disconnected or disabled. Internet access is not needed to play music stored on your computer.

## FAQ

### Does river include music?

No. Add folders containing music you have access to. The project does not provide or distribute audio tracks.

### Do I need an account to use the player?

No account is needed for local playback, playlists, or the core player. Last.fm and Discord are optional integrations that use their respective services.

### Why aren't lyrics showing?

river checks available track lyrics and local `.lrc` files, then can look them up through LRCLIB. If LRCLIB shows an error or the lyrics do not load, click **Try again** in the lyrics panel and retry a few times; the service may fail temporarily. If the lyrics still do not appear, they may not be available from LRCLIB for that track.

### How do I enable Last.fm or Discord?

Open the relevant integration in river's settings and follow its in-app steps. Last.fm scrobbling requires connecting a Last.fm account. Discord Rich Presence requires the Discord desktop app to be available.

### Can I change or redistribute river?

Yes. river is released under the GNU General Public License v3.0. You may modify and redistribute it under that license's terms; keep the applicable copyright and license notices and provide the corresponding source as required by the GPL.

The GPL does not guarantee that a modified version will keep river's Credits screen or identify its original author in the app UI. Please also respect the separate licenses and notices for bundled fonts and third-party dependencies.

### Where can I report a bug or suggest an idea?

Open an issue in the repository and include the river version, your Windows version, what happened, and what you expected to happen. Do not include private music files or account credentials.

## Credits and licenses

Created by **jane(not remover)**.

river's source code is licensed under **GNU GPL v3.0**; see [`LICENSE`](LICENSE). Bundled Inter fonts are provided under the **SIL Open Font License 1.1**. Third-party packages and assets may have their own licenses and notices.
