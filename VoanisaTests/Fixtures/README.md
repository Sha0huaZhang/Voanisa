# Test fixtures

Small files used by the Swift and Rust tests.

- `audio/tone-a.wav`, `audio/tone-b.wav` — 0.3 s mono 22.05 kHz sine tones.
- `audio/tagged.m4a` — AAC audio with title, artist, album, album artist,
  track/disc numbers and an embedded PNG cover.
- `audio/tone.ogg` (Vorbis), `audio/tone.opus` — the same tone encoded for the
  Rust decoder path; both stereo, so the interleaving is exercised.
- `audio/tagged.ogg`, `audio/tagged.opus` — the same tone with Vorbis/Opus
  comments (title, artist, album, track number).
- `audio/tone.wv` — WavPack, used to prove unsupported containers are still
  detected and refused.
- `images/cover-a.png`, `images/cover-b.png` — 256×256 placeholder covers.
- `images/missing-cover.png` is intentionally absent; tests use it to verify
  that missing artwork falls back to the default gray note cover.

The compressed fixtures were produced once with a locally installed ffmpeg and
checked in. ffmpeg is only a fixture generator: the app and its Rust core never
link to or invoke it.

The tests resolve this directory from `#filePath`, so the files do not need to
be copied into the test bundle.
