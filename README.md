<h1 align="center">
  KasetPlusPlus
</h1>

<p align="center">
  <strong>A native macOS client for YouTube Music and YouTube — fast, distraction-free, and built for macOS.</strong>
</p>

<p align="center">
  <a href="https://www.apple.com/macos/">
    <img src="https://img.shields.io/badge/platform-macOS-000000?logo=apple&logoColor=white" alt="macOS">
  </a>
  <a href="https://www.swift.org/">
    <img src="https://img.shields.io/badge/built%20with-SwiftUI-F05138?logo=swift&logoColor=white" alt="SwiftUI">
  </a>
  <a href="https://github.com/omarkahol/KasetPlusPlus/releases/latest">
    <img src="https://img.shields.io/github/v/release/omarkahol/KasetPlusPlus?label=release&color=007AFF" alt="Latest release">
  </a>
  <a href="https://github.com/omarkahol/KasetPlusPlus/stargazers">
    <img src="https://img.shields.io/github/stars/omarkahol/KasetPlusPlus?style=flat&label=stars" alt="Stars">
  </a>
</p>

<p align="center">
  <a href="https://github.com/omarkahol/KasetPlusPlus/releases/latest"><strong>Download Latest Release</strong></a>
  &nbsp;·&nbsp;
  <a href="https://github.com/Yoddikko/kasetPlus">KasetPlus</a>
  &nbsp;·&nbsp;
  <a href="https://github.com/sozercan/kaset">Original Kaset</a>
</p>

---

**KasetPlusPlus** (`Kaset++`) brings YouTube Music and regular YouTube together in a single native SwiftUI app for macOS. No Electron, no browser tabs eating RAM—just a clean Mac app with native media keys, Now Playing integration, offline archival, and built-in quality-of-life tools.

## Key Features

### 🎵 Video & Song Archival
- **Save Music & Videos Offline**: Archive songs (complete with ID3 tags, album art, and like status) or full YouTube videos at your preferred quality (Best Available, 1080p, 720p, or 480p).
- **Dedicated Downloads Library**: Browse your saved collection across *All*, *Music*, and *Videos* tabs, search locally, reveal files in Finder, and play them natively offline—including synced lyrics for downloaded tracks.
- **One-Click Downloads Everywhere**: Start or cancel downloads right from playlists, albums, search results, context menus, or the MiniPlayer bar with a live progress ring.

### 🎬 Improved Video Experience
- **Native Video Playback & Ambient Mode**: Smooth native playback with an optional ambient color backdrop that reacts to the video in real time.
- **Flexible Viewing Modes**: Watch inline, pop out a floating picture-in-picture window, keep videos playing in the docked bar when navigating away, or switch on **Distraction-Free Mode** to hide comments and the related-videos rail.
- **Original Audio Control**: Automatically prefer the creator's original audio track instead of AI-dubbed tracks, and see original languages clearly highlighted in the audio picker.
- **Chapters, Quality & Speed**: Jump between video chapters, pin playback quality, and adjust playback speed right from the player bar.

### 🛡️ Built-in SponsorBlock & Add-ons
- **SponsorBlock**: Automatically skips sponsored segments, intros, outros, and self-promotions with subtle native skip notifications.
- **Ad Blocker**: Built-in request filtering and automatic ad skipping.
- **Return YouTube Dislike**: Restores community dislike counts on videos.
- **DeArrow**: Replaces clickbait titles and thumbnails with community-curated alternatives.

### 🎛️ Queue, Lyrics & On-Device AI
- **Synced Lyrics & Wider Queue**: Follow time-synced lyrics for both streamed and downloaded songs, and enjoy a roomy queue panel with smooth scrolling marquee titles.
- **Apple Intelligence (On-Device)**: Summarize videos, explain lyrics, and create playlists using natural language—processed privately on your Mac with no external API keys.

---

## Installation

1. Download the latest `KasetPlusPlus-v*.dmg` from the [GitHub Releases](https://github.com/omarkahol/KasetPlusPlus/releases/latest) page (Universal Binary for Apple Silicon and Intel).
2. Open the `.dmg` and drag **KasetPlusPlus.app** into **Applications**.
3. Because community releases are ad-hoc signed, macOS Gatekeeper may ask to verify the app on first launch. If it is blocked, run:
   ```bash
   xattr -cr /Applications/KasetPlusPlus.app
   ```
4. *(Optional)* To enable offline song and video downloads, install `yt-dlp` and `ffmpeg` via [Homebrew](https://brew.sh):
   ```bash
   brew install yt-dlp ffmpeg
   ```

---

## Building from Source

### Requirements
- **macOS 15.4 or later** (supports macOS 26.0+ Liquid Glass styling)
- **Xcode 16.0 or later** with Swift 6.0 command-line tools
- *(Optional)* `yt-dlp` and `ffmpeg` via Homebrew for offline downloads

### Build & Run
```bash
git clone https://github.com/omarkahol/KasetPlusPlus.git
cd KasetPlusPlus

# Build debug binary
swift build

# Run unit tests (skipping UI tests)
swift test --skip KasetUITests
```

To package a standalone `.app` bundle and install it to `/Applications`:
```bash
KASET_SIGNING=adhoc ./Scripts/build-app.sh release
pkill -x KasetPlusPlus || true
rm -rf /Applications/KasetPlusPlus.app
cp -R .build/app/KasetPlusPlus.app /Applications/
xattr -cr /Applications/KasetPlusPlus.app
```

You can also open the folder in Xcode (`xed .`), select the `KasetPlus` scheme and **My Mac**, and press **Cmd + R**.

---

## Disclaimer

> [!IMPORTANT]
> **KasetPlusPlus** is an independent, unofficial open-source project and is not affiliated with or endorsed by Google LLC, YouTube, or the original authors.
> Offline archival features (`yt-dlp` / `ffmpeg`) are intended strictly for personal, non-commercial, fair-use archival of content you own or have permission to save. Users are responsible for complying with local copyright laws and YouTube's Terms of Service.

---

## Credits & License

`KasetPlusPlus` builds on the great work of:
- [Kaset](https://github.com/sozercan/kaset) by Sertac Ozercan ([@sozercan](https://github.com/sozercan))
- [KasetPlus](https://github.com/Yoddikko/kasetPlus) by Alessio Iodice ([@Yoddikko](https://github.com/Yoddikko))

Licensed under the [MIT License](LICENSE). Copyright © 2025 sozercan, 2025 Yoddikko, 2026 Omar.
