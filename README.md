<h1 align="center">
  &nbsp;KasetPlusPlus
</h1>

<p align="center">
  <strong>Native YouTube Music and YouTube client for macOS — refined, feature-packed, and built for you.</strong>
</p>

<p align="center">
  Native SwiftUI · Local Offline Archival · On-device AI<br>
  Wider Queue with Marquee · MiniPlayer Integration · Distraction-free viewing
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
  <a href="https://github.com/omarkahol/KasetPlusPlus"><strong>GitHub Repository</strong></a>
  &nbsp;·&nbsp;
  <a href="https://github.com/omarkahol/KasetPlusPlus/releases/latest"><strong>Releases</strong></a>
  &nbsp;·&nbsp;
  <a href="https://github.com/Yoddikko/kasetPlus">KasetPlus</a>
  &nbsp;·&nbsp;
  <a href="https://github.com/sozercan/kaset">Original Kaset</a>
</p>

---

## Legal Disclaimer & Terms of Use

> [!IMPORTANT]
> - **KasetPlusPlus** is an unofficial, independent open-source fork and is **not** affiliated with, authorized, maintained, or endorsed by Google LLC, YouTube, or the original authors.
> - **User Responsibility & Fair Use**: Any integration with command-line tools (such as `yt-dlp` and `ffmpeg`) is provided strictly for personal, non-commercial, fair-use archival of user-owned media or content for which the user has obtained explicit authorization from the copyright holder. Users are solely responsible for ensuring that their use complies with local copyright laws and YouTube's Terms of Service.

---

## Installation (Pre-built Releases)

Pre-built Universal Binary (Apple Silicon & Intel) `.dmg` releases are published on the [GitHub Releases](https://github.com/omarkahol/KasetPlusPlus/releases/latest) page.

1. Download the latest `KasetPlusPlus-v*.dmg` from [Releases](https://github.com/omarkahol/KasetPlusPlus/releases/latest).
2. Open the `.dmg` and drag **KasetPlusPlus.app** into your **Applications** folder.
3. Because community builds are ad-hoc signed (not notarized with a paid Apple Developer ID), macOS Gatekeeper may block the first launch. If so, clear the quarantine attribute in Terminal:
   ```bash
   xattr -cr /Applications/KasetPlusPlus.app
   ```
4. *(Optional)* Install `ffmpeg` via [Homebrew](https://brew.sh) if you want full media conversion/archival support:
   ```bash
   brew install yt-dlp ffmpeg
   ```

---

## Features & Highlights in KasetPlusPlus

- 🎵 **Offline Media Archival**:
  - Download high-fidelity music tracks (with ID3 metadata, album artwork, and like-status tagging) or full YouTube videos (customizable 1080p, 720p, 480p, or Best Available).
  - Dedicated **Downloads View** with indexed search, categorized tabs (*All / Music / Videos*), Finder access, and native offline playback (including `AVPlayerView` video presentation).
  - One-click downloads available across playlists, albums, search results, history, artist discographies, context menus, and player bars.
- 🎛️ **Polished MiniPlayer**:
  - Integrated download action directly beside Volume in the MiniPlayer bar, complete with animated progress ring and cancellation support.
- 📜 **Wider Queue & Marquee Titles**:
  - 50%+ wider Queue popover and side panel giving track details room to breathe.
  - Smooth horizontal marquee sliding ticker for overflowing song titles.
- 🛡️ **Built-in Addon Suite**:
  - **Ad Blocker**: Multi-tier request filtering and playback ad auto-skip.
  - **SponsorBlock**: Auto-skip sponsored segments with native notifications.
  - **Return YouTube Dislike**: Community dislike stats integrated directly into video and song views.
  - **DeArrow**: Crowd-sourced clickbait-free titles and thumbnails.
- 🧠 **On-Device Apple Intelligence**:
  - Natural-language playlist curation, video summaries, and lyric explanation powered on-device without external API keys.

---

## Requirements & Building from Source

### Prerequisites

1. **macOS**: macOS 15.4 or later (supports macOS 26.0+ Liquid Glass styling).
2. **Xcode**: Xcode 16.0 or later with Swift 6.0 command-line tools.
3. **Optional Archival Dependencies**:
   To enable local offline archival of audio/video using external CLI tools, install `yt-dlp` and `ffmpeg` via [Homebrew](https://brew.sh):
   ```bash
   brew install yt-dlp ffmpeg
   ```

### Step-by-Step Build Instructions

1. **Clone the Repository**:
   ```bash
   git clone https://github.com/omarkahol/KasetPlusPlus.git
   cd KasetPlusPlus
   ```

2. **Build via Command Line**:
   To compile and run tests:
   ```bash
   # Build debug binary
   swift build

   # Run test suites (skipping disruptive UI tests)
   swift test --skip KasetUITests
   ```

3. **Packaging a Standalone Release `.app`**:
   To build, sign, and bundle the app:
   ```bash
   # Ad-hoc sign for local use
   KASET_SIGNING=adhoc ./Scripts/build-app.sh release
   ```
   The finished app bundle will be located at:
   ```
   .build/app/KasetPlusPlus.app
   ```

4. **Install to `/Applications`**:
   ```bash
   # Close any running instance
   pkill -x KasetPlusPlus || true

   # Copy to Applications and clear Gatekeeper quarantine
   rm -rf /Applications/KasetPlusPlus.app
   cp -R .build/app/KasetPlusPlus.app /Applications/
   xattr -cr /Applications/KasetPlusPlus.app
   ```

5. **Building in Xcode (GUI)**:
   - Open the project directory in Xcode: `xed .`
   - Select the `KasetPlus` scheme and choose **My Mac**.
   - Under **Signing & Capabilities**, select your personal Team / Apple ID for local development signing.
   - Press **Cmd + B** to build, or **Cmd + R** to run.

---

## Upstream Credits & Attribution

`KasetPlusPlus` is built with gratitude on the foundational work of the open-source community:
- [Kaset](https://github.com/sozercan/kaset) by Sertac Ozercan ([@sozercan](https://github.com/sozercan)).
- [KasetPlus](https://github.com/Yoddikko/kasetPlus) by Alessio Iodice ([@Yoddikko](https://github.com/Yoddikko)).

---

## License

This project is licensed under the [MIT License](LICENSE).
Copyright (c) 2025 sozercan, 2025 Yoddikko, 2026 Omar.
