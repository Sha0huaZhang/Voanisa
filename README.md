<div align="center">
    <img src="images/Voanisa-icon-1024.png" alt="Logo" width="256" />
    <h1>Voanisa</h1>
</div>

# Voanisa

A local music library for macOS, in the visual spirit of Elysia.

**English** · [简体中文](./README.zh-Hans.md)

This repository contains the **0.1.0 prototype**. Every imported audio file
becomes one song in a self-contained library. Audio is copied into the library,
named by the user, given a square cover, and played locally — no Apple Music
dependency and no files written outside the library.

## Requirements

- macOS 15 (Sequoia) or later
- Xcode 16.4 or later for building

## What the prototype does

- Import audio files or whole folders from the sidebar, by drag and drop, or ⌘O
- Detect the container from the **file header**, not the extension
- Pre-fill title, artist, album, album artist, track/disc number and cover from
  embedded tags when the file provides them
- Give every song a title, artist, album, album artist, track/disc number and a
  square cover with pan/zoom crop
- Edit metadata and replace or remove the cover at any time from the row menu
- Create playlists, add or remove songs, rename and delete them
- Browse albums grouped automatically from album and album-artist tags
- Previous/next follows the list currently on screen — the library, a playlist
  or an album — never an unrelated queue
- Songs without a cover use a gray music-note placeholder everywhere
- Copy audio into `~/Music/Voanisa`, leaving the originals untouched
- Local playback with play/pause, previous/next, seek, volume, repeat and media keys
- Search, drag-to-reorder, hover play button and double-click to play
- Elysia-style clean list: artwork on the left, title over artist, red now-playing state
- English and Simplified Chinese interface

### Supported in this prototype

MP3, AAC/ADTS, M4A, ALAC, FLAC, WAV, AIFF, CAF.

MP4/MOV files are imported as audio-only M4A; the video track is discarded.

Ogg Vorbis, Opus, WMA, APE, WavPack, DSF/DFF and Matroska/WebM are detected but
reported as unsupported. They are the planned Rust decoder layer.

## Library

```
~/Music/Voanisa/
  library.sqlite         primary store
  library.json           portable snapshot and backup
  Media/                 audio files, UUID names
  Covers/Originals/      user-supplied cover originals
  Covers/Rendered/       square covers used by the UI
  .staging/              temporary import area
```

Songs live in `library.sqlite`. Voanisa also writes `library.json` after every
change; an existing snapshot is migrated into SQLite at launch and is used for
recovery if the database is unavailable. The original files selected during
import are never modified or moved.

## Build

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
open Voanisa.xcodeproj
```

To produce a universal DMG in `dmg/`:

```sh
Scripts/package-dmg.sh
```

The script uses the first `Apple Development` identity in the keychain; set
`SIGN_IDENTITY` to override it, or to `-` for ad-hoc signing. Hardened runtime
is intentionally off: the app is distributed directly, and a personal team
cannot notarize anyway.

Because the build is signed but not notarized, Gatekeeper may ask for a
right-click → Open the first time. Or clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/Voanisa.app
```

## App icon

The checked-in icon is temporary artwork. Replace
`images/Voanisa-icon-1024.png` and regenerate the full size set:

```sh
python3 Scripts/generate-appicon.py images/Voanisa-icon-1024.png
```

## Roadmap

1. Rust portable core: header probing, SQLite library, tag reading/writing,
   Symphonia decoding for Ogg/Opus/WavPack.
2. Playlists and albums.
3. Optional Apple Music integration: merge the Music library into Voanisa,
   with explicit import/remove actions.
4. Optional FFmpeg module for WMA/APE/DSD.

## Rust core (in progress)

- `Rust/voanisa-core` — header-based probing, SQLite storage and library CRUD
- `Rust/voanisa-ffi` — C ABI returning JSON, linked as a static library
- Xcode runs `Scripts/build-rust.sh` before every build
- Tests: `cargo test --manifest-path Rust/Cargo.toml --workspace`

The remaining Swift core stays free of SwiftUI and AppKit so it can be migrated
module by module.

## License

MIT. See [LICENSE](LICENSE).
