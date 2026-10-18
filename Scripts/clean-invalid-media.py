#!/usr/bin/env python3
"""Removes library entries whose media file is not real audio.

Older builds accepted any file with a stray MPEG sync word, so binaries such as
XZ archives or executables entered the library as "MP3". The Rust probe now
validates consecutive frames; this script applies the same check to tracks that
are already stored.

Dry run (default):

    python3 Scripts/clean-invalid-media.py

Apply the removals:

    python3 Scripts/clean-invalid-media.py --apply

Quit Voanisa first: a running app keeps the library in memory and writes it back
on the next change.
"""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import platform
import shutil
import sqlite3
import sys
import time
from pathlib import Path


def load_probe(root: Path):
    machine = platform.machine()
    triple = "aarch64-apple-darwin" if machine == "arm64" else "x86_64-apple-darwin"
    candidates = [
        root / "Rust" / "target" / triple / "release" / "libvoanisa_ffi.dylib",
        root / "Rust" / "target" / "release" / "libvoanisa_ffi.dylib",
        root / "Rust" / "target" / "debug" / "libvoanisa_ffi.dylib",
    ]
    for candidate in candidates:
        if candidate.exists():
            break
    else:
        sys.exit(
            "error: no libvoanisa_ffi.dylib found; run Scripts/build-rust.sh first"
        )

    ffi = ctypes.CDLL(str(candidate))
    ffi.voanisa_probe_json.restype = ctypes.c_void_p
    ffi.voanisa_probe_json.argtypes = [ctypes.c_char_p]
    ffi.voanisa_string_free.argtypes = [ctypes.c_void_p]
    ffi.voanisa_string_free.restype = None

    def probe(path: Path):
        pointer = ffi.voanisa_probe_json(str(path).encode())
        if not pointer:
            return None
        try:
            return json.loads(ctypes.string_at(pointer).decode())
        finally:
            ffi.voanisa_string_free(pointer)

    return probe


def is_audio(probe, path: Path) -> tuple[bool, str]:
    if not path.exists():
        return False, "file missing"
    result = probe(path)
    if not result:
        return False, "probe failed"
    if result.get("error"):
        return False, f"error: {result['error']}"
    if result.get("recognized"):
        return True, result.get("container", "")
    return False, result.get("container") or "unknown"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path.home() / "Music" / "Voanisa",
        help="library root (default: ~/Music/Voanisa)",
    )
    parser.add_argument(
        "--apply", action="store_true", help="delete instead of only reporting"
    )
    args = parser.parse_args()

    library = args.root
    database = library / "library.sqlite"
    snapshot = library / "library.json"
    media = library / "Media"
    if not database.exists():
        sys.exit(f"error: {database} not found")

    repo_root = Path(__file__).resolve().parent.parent
    probe = load_probe(repo_root)

    connection = sqlite3.connect(database)
    rows = connection.execute(
        "SELECT id, title, file_name, cover_file_name, format FROM tracks"
    ).fetchall()

    bad: list[tuple[str, str, str, str, str]] = []
    for track_id, title, file_name, cover, fmt in rows:
        ok, reason = is_audio(probe, media / file_name)
        if not ok:
            bad.append((track_id, title, file_name, cover or "", reason))

    print(f"scanned {len(rows)} tracks: {len(rows) - len(bad)} valid, {len(bad)} invalid")
    for track_id, title, file_name, _cover, reason in bad[:30]:
        print(f"  - {title[:40]!r:44} {file_name}  [{reason}]")
    if len(bad) > 30:
        print(f"  … and {len(bad) - 30} more")

    if not bad:
        return 0

    if not args.apply:
        print("\ndry run: re-run with --apply to remove these entries")
        return 0

    stamp = time.strftime("%Y%m%d%H%M%S")
    shutil.copy2(database, database.with_suffix(f".sqlite.bak-{stamp}"))
    if snapshot.exists():
        shutil.copy2(snapshot, snapshot.with_suffix(f".json.bak-{stamp}"))

    ids = [item[0] for item in bad]
    placeholders = ",".join("?" for _ in ids)
    with connection:
        connection.execute(
            f"DELETE FROM playlist_items WHERE track_id IN ({placeholders})", ids
        )
        connection.execute(f"DELETE FROM tracks WHERE id IN ({placeholders})", ids)
    connection.close()

    removed_files = 0
    for _track_id, _title, file_name, cover, _reason in bad:
        target = media / file_name
        if target.exists():
            target.unlink()
            removed_files += 1
        for folder in ("Rendered", "Originals"):
            cover_path = library / "Covers" / folder / cover
            if cover and cover_path.exists():
                cover_path.unlink()

    if snapshot.exists():
        data = json.loads(snapshot.read_text())
        gone = set(ids)
        data["tracks"] = [t for t in data.get("tracks", []) if t.get("id") not in gone]
        for playlist in data.get("playlists", []):
            playlist["trackIDs"] = [
                track_id
                for track_id in playlist.get("trackIDs", [])
                if track_id not in gone
            ]
        snapshot.write_text(json.dumps(data, ensure_ascii=False, indent=2))

    print(f"\nremoved {len(ids)} entries and {removed_files} media files")
    print(f"backups written next to the library ({stamp})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
