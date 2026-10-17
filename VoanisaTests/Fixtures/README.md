# Test fixtures

Small files used by the Swift tests.

- `audio/tone-a.wav`, `audio/tone-b.wav` — 0.3 s mono 22.05 kHz sine tones.
- `audio/tagged.m4a` — AAC audio with title, artist, album, album artist,
  track/disc numbers and an embedded PNG cover.
- `images/cover-a.png`, `images/cover-b.png` — 256×256 placeholder covers.
- `images/missing-cover.png` is intentionally absent; tests use it to verify
  that missing artwork falls back to the default gray note cover.

The tests resolve this directory from `#filePath`, so the files do not need to
be copied into the test bundle.
