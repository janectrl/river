<h1 align="center"><img src="icon/river.png" alt="" width="30" height="30">&nbsp;river</h1>

<p align="center">
  <strong>A music player for your local library.</strong><br>
  Created by <strong>jane(not remover)</strong>
</p>

---

river is a desktop music player for your local music library, with playlists, lyrics, listening statistics, and a customizable player.

> **Platform:** river is currently developed for Windows.

## Features

### Music library

- Scan folders on your computer and browse your music library.
- Search for tracks, add them to the queue, and create playlists.
- Drag and drop supported audio files into the app.
- Edit track information and choose or create album artwork.
- Browse recently played tracks and view listening statistics.

### Player and appearance

- Play, pause, skip, seek, adjust volume, and repeat tracks.
- Customize the player layout, keyboard shortcuts, and text size.
- Choose a background style: blurred artwork, artwork colors, or a solid color.
- Choose the Windows font used by the app.
- Use the audio visualizer or enable Economy mode to reduce visual effects.

### Lyrics and integrations

- Show lyrics from supported embedded metadata and local `.lrc` files.
- Look up lyrics through LRCLIB when available.
- Connect Last.fm for now-playing updates and scrobbling.
- Optionally share the currently playing track through Discord Rich Presence.
- Use the interface in English, Spanish, Russian, Ukrainian, or Chinese.

### Supported audio formats

MP3, FLAC, WAV, M4A, and OGG. Playback can also depend on the file and Windows media decoding support.

## Download and install

Download the latest `river` installer from the repository's **Releases** page. Run the installer and follow its instructions. You do not need Flutter or development tools to install river.

## Privacy

Your audio files are read from your computer; river does not upload the audio itself. Optional online features send track information to their services:

- **Lyrics:** a lookup can send the track title and artist to LRCLIB.
- **Last.fm:** when connected, track information is sent to Last.fm for now-playing updates and scrobbles.
- **Discord:** when enabled and music is playing, the track title and artist are shared through Discord Rich Presence.

These integrations are optional. Local playback does not need an internet connection.

## FAQ

### Does river include music?

No. Add folders containing music you have access to. river does not provide or distribute music.

### Do I need an account?

No account is needed for local playback and the core player. Last.fm and Discord are optional integrations that use their own services.

### Why aren't lyrics showing?

river checks available track lyrics and local `.lrc` files, then can look them up through LRCLIB. If LRCLIB shows an error or the lyrics do not load, click **Try again** in the lyrics panel and retry a few times; the service may be temporarily unavailable. If they still do not appear, LRCLIB may not have lyrics for that track.

### How do I enable Last.fm or Discord?

Open the relevant integration in river's settings and follow the steps there. Last.fm scrobbling requires connecting a Last.fm account. Discord Rich Presence requires the Discord desktop app to be available.

### Showcase
<p align="center">
  <img src="showcase photos/photo1.jpg" alt="river interface" width="48%">
  <img src="showcase photos/photo2.jpg" alt="river visualizer" width="48%">
</p>

### Can I modify and share river?

Yes. river is licensed under the GNU General Public License v3.0. You may modify and redistribute it under the terms of that license. Keep the applicable copyright and license notices and follow the GPL requirements when sharing a modified version.

A modified version may change or remove river's Credits screen. Please also respect the separate licenses and notices for bundled fonts and third-party packages.

### Where can I report a bug or suggest an idea?

Open an issue in this repository. Include the river version, your Windows version, what happened, and what you expected to happen. Do not include private music files or account credentials.

## Credits and licenses

Created by **jane(not remover)**.

river's source code is licensed under **GNU GPL v3.0**; see [`LICENSE`](LICENSE). The bundled Inter fonts are provided under the **SIL Open Font License 1.1**. Third-party packages and assets may have their own licenses and notices.
