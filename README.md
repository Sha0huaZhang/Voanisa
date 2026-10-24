<div align="center">
    <img src="images/Voanisa-icon-512-rounded.png" alt="Logo" width="206" />
    <h1>Voanisa</h1>
</div>

# Voanisa

A local music library for macOS, in the visual spirit of Elysia.

**English** · [简体中文](./README.zh-Hans.md)

## Official Website

[voanisa.macwave.org](https://voanisa.macwave.org)  (Short link: [v.macwave.org](https://v.macwave.org))

## Download

[Click here to Downloads](https://voanisa.macwave.org/Downloads/)

This repository contains **Voanisa 1.0.7**. Every imported audio file
becomes one song in a self-contained library. Audio is copied into the library,
named by the user, given a square cover, and played locally — no Apple Music
dependency and no files written outside the library.

## Languages

Swift and Rust make up the app and the portable core. C appears only in the two
FFI headers between them, and SQL is used through SQLite inside the core; the
headers, the Shell/Python tooling and the configuration files are all kept out of
GitHub's language bar so it reflects the two languages the project is written in.

## Requirements

- macOS 15 (Sequoia) or later
- Xcode 16.4 or later for building

## What Voanisa does

- Import audio files or whole folders from the sidebar, by drag and drop, or ⌘O
- Detect the container from the **file header**, not the extension
- Pre-fill title, artist, album, album artist, track/disc number and cover from
  embedded tags when the file provides them
- Give every song a title, artist, album, album artist, track/disc number and a
  square cover with pan/zoom crop
- Edit metadata and replace or remove the cover at any time from the row menu;
  title, artist, album and track numbers are written back into the audio file
- Create playlists, add or remove songs, rename and delete them
- Move a song to the Trash from the row menu, with Delete or with ⌘⌫
- Previous/next follows the list currently on screen — the library or a
  playlist — never an unrelated queue
- Songs without a cover use a gray music-note placeholder everywhere
- Copy audio into `~/Music/Voanisa`, leaving the originals untouched
- Local playback with play/pause, previous/next, seek, volume, repeat and media keys;
  the Rust core decodes every supported format
- Search, drag-to-reorder, hover play button and double-click to play
- Elysia-style clean list: artwork on the left, title over artist, red now-playing state
- English and Simplified Chinese interface

### Supported formats

MP3, AAC/ADTS, M4A, ALAC, FLAC, WAV, AIFF, CAF.

These are decoded in-process by the Rust core and played through
`AVAudioEngine`. No external decoder binary, codec pack or ffmpeg installation
is involved, and nothing has to be installed next to the app.

- Ogg Vorbis — Symphonia
- Ogg Opus — `opus-pure` (Ogg encapsulation, pre-skip and end-trim)
- WavPack — `wavicle` (lossless, mono/stereo up to 32-bit; hybrid mode and
  DSD are out of scope, and files over ~19 minutes of stereo 44.1 kHz exceed
  the in-memory decode limit)
- Monkey's Audio (APE) — `ape-decoder` (all compression levels, frame-level
  seeking; files written by Monkey's Audio 3.95 and newer)

MP4/MOV files are imported as audio-only M4A; the video track is discarded.

WMA, DSD (DSF/DFF) and Matroska/WebM are detected by signature but not decoded
yet. WMA cannot be decoded on macOS at all, so convert those files to FLAC or
MP3 first — `Scripts/convert-wma.sh` converts a whole folder with ffmpeg.

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

### Looking at a packaged image

`Scripts/voanisadmgrun` mounts a packaged image and opens it in Finder, which is
the quickest way to check the install experience:

```sh
Scripts/voanisadmgrun              # newest image in dmg/
Scripts/voanisadmgrun path.dmg     # a specific image
Scripts/voanisadmgrun --eject      # eject it again
```

To have it as a command, link it somewhere on your `PATH`:

```sh
ln -s "$PWD/Scripts/voanisadmgrun" ~/.local/bin/voanisadmgrun
```

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

The README logo is `images/Voanisa-icon-512-rounded.png`: artwork for docs and
the website is always rounded first, with the macOS icon mask ratio:

```sh
swift Scripts/make-rounded-icon.swift ~/Downloads/artwork.heic \
    images/Voanisa-icon-512-rounded.png 512
```

## Roadmap

1. Rust portable core: header probing, SQLite library, tag reading and
   Symphonia/`opus-pure`/`wavicle`/`ape-decoder` decoding.
2. Playlists; album browsing is parked for now and may return later.
3. Optional Apple Music integration: merge the Music library into Voanisa,
   with explicit import/remove actions.
4. WMA and DSD stay unsupported until a pure-Rust decoder fits; Voanisa
   deliberately does not ship or bundle ffmpeg.

## Rust core (in progress)

- `Rust/voanisa-core` — header-based probing, SQLite storage, library CRUD and
  streaming PCM decoding for Ogg, Opus, WavPack and APE
- `Rust/voanisa-ffi` — C ABI returning JSON, linked as a static library
- Xcode runs `Scripts/build-rust.sh` before every build
- Tests: `cargo test --manifest-path Rust/Cargo.toml --workspace`

The remaining Swift core stays free of SwiftUI and AppKit so it can be migrated
module by module.

## License

MIT. See [LICENSE](LICENSE).
