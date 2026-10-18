use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use voanisa_core::{
    hash_file, import_snapshot, inspect, read_tags, probe_path, write_artwork, write_snapshot,
    write_square_cover, write_tags, AudioDecoder, NewTrack, ProbeResult, Store, StoreError,
    TagWrite, TrackUpdate,
};

#[derive(Deserialize)]
struct NewPlaylistPayload {
    id: String,
    name: String,
}

#[derive(Deserialize)]
struct RenamePlaylistPayload {
    id: String,
    name: String,
}

#[derive(Deserialize)]
struct PlaylistTracksPayload {
    playlist_id: String,
    track_ids: Vec<String>,
}

const VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), "\0");

/// Returns a static NUL-terminated version string. Do not free it.
#[no_mangle]
pub extern "C" fn voanisa_core_version() -> *const c_char {
    VERSION.as_ptr() as *const c_char
}

/// Returns a heap-allocated JSON probe result. Free it with
/// `voanisa_string_free`.
#[no_mangle]
pub extern "C" fn voanisa_probe_json(path: *const c_char) -> *mut c_char {
    if path.is_null() {
        return to_c_string(error_json("null path"));
    }

    let path = unsafe { CStr::from_ptr(path) }
        .to_string_lossy()
        .into_owned();

    let result = catch_unwind(AssertUnwindSafe(|| probe_path(Path::new(&path))));
    let json = match result {
        Ok(Ok(probe)) => {
            serde_json::to_string(&probe).unwrap_or_else(|error| error_json(&error.to_string()))
        }
        Ok(Err(error)) => error_json(&error),
        Err(_) => error_json("panic in Rust core"),
    };
    to_c_string(json)
}

// MARK: - Streaming decode

/// Opaque handle to a decoder owned by the Rust core.
pub struct VoanisaDecoder {
    decoder: AudioDecoder,
    last_error: Option<String>,
}

/// Opens a decoder for a container AVFoundation cannot play.
///
/// Returns NULL on failure; ask `voanisa_decoder_open_error_json` why.
#[no_mangle]
pub extern "C" fn voanisa_decoder_open(path: *const c_char) -> *mut VoanisaDecoder {
    if path.is_null() {
        return std::ptr::null_mut();
    }
    let path = unsafe { CStr::from_ptr(path) }
        .to_string_lossy()
        .into_owned();

    match catch_unwind(AssertUnwindSafe(|| AudioDecoder::open(Path::new(&path)))) {
        Ok(Ok(decoder)) => Box::into_raw(Box::new(VoanisaDecoder {
            decoder,
            last_error: None,
        })),
        _ => std::ptr::null_mut(),
    }
}

/// Describes why `voanisa_decoder_open` failed. Returns an error envelope.
#[no_mangle]
pub extern "C" fn voanisa_decoder_open_error_json(path: *const c_char) -> *mut c_char {
    if path.is_null() {
        return to_c_string(message_error_json("null path", "invalid_argument"));
    }
    let path = unsafe { CStr::from_ptr(path) }
        .to_string_lossy()
        .into_owned();

    let result = catch_unwind(AssertUnwindSafe(|| AudioDecoder::open(Path::new(&path))));
    let message = match result {
        Ok(Ok(_)) => "decoder opened".to_string(),
        Ok(Err(error)) => error,
        Err(_) => "panic in Rust core".to_string(),
    };
    to_c_string(message_error_json(&message, "decode"))
}

/// JSON `{container, codec, sample_rate, channels, duration_seconds}`.
#[no_mangle]
pub extern "C" fn voanisa_decoder_info_json(handle: *mut VoanisaDecoder) -> *mut c_char {
    let Some(decoder) = (unsafe { handle.as_ref() }) else {
        return to_c_string(message_error_json("null decoder", "invalid_argument"));
    };
    to_c_string(success_json(decoder.decoder.info()))
}

/// Reads up to `frames` frames into `out`, which must hold
/// `frames * channels` floats. Returns the frames read, `0` at end of stream,
/// or `-1` on error.
#[no_mangle]
pub extern "C" fn voanisa_decoder_read(
    handle: *mut VoanisaDecoder,
    out: *mut f32,
    frames: u32,
) -> i64 {
    let Some(decoder) = (unsafe { handle.as_mut() }) else {
        return -1;
    };
    let channels = decoder.decoder.info().channels;
    if out.is_null() || frames == 0 || channels == 0 {
        decoder.last_error = Some("invalid buffer".to_string());
        return -1;
    }

    let slice = unsafe { std::slice::from_raw_parts_mut(out, frames as usize * channels) };
    match catch_unwind(AssertUnwindSafe(|| decoder.decoder.read(slice))) {
        Ok(Ok(samples)) => (samples / channels) as i64,
        Ok(Err(error)) => {
            decoder.last_error = Some(error);
            -1
        }
        Err(_) => {
            decoder.last_error = Some("panic in Rust core".to_string());
            -1
        }
    }
}

/// Seeks to `seconds`. Returns `0` on success or `-1` on error.
#[no_mangle]
pub extern "C" fn voanisa_decoder_seek(handle: *mut VoanisaDecoder, seconds: f64) -> i32 {
    let Some(decoder) = (unsafe { handle.as_mut() }) else {
        return -1;
    };
    match catch_unwind(AssertUnwindSafe(|| decoder.decoder.seek(seconds))) {
        Ok(Ok(())) => 0,
        Ok(Err(error)) => {
            decoder.last_error = Some(error);
            -1
        }
        Err(_) => {
            decoder.last_error = Some("panic in Rust core".to_string());
            -1
        }
    }
}

/// Seconds of audio handed out so far.
#[no_mangle]
pub extern "C" fn voanisa_decoder_position(handle: *mut VoanisaDecoder) -> f64 {
    match unsafe { handle.as_ref() } {
        Some(decoder) => decoder.decoder.position_seconds(),
        None => 0.0,
    }
}

/// Last decoder error as an error envelope. Clears the stored error.
#[no_mangle]
pub extern "C" fn voanisa_decoder_error_json(handle: *mut VoanisaDecoder) -> *mut c_char {
    let Some(decoder) = (unsafe { handle.as_mut() }) else {
        return to_c_string(message_error_json("null decoder", "invalid_argument"));
    };
    let message = decoder
        .last_error
        .take()
        .unwrap_or_else(|| "no error".to_string());
    to_c_string(message_error_json(&message, "decode"))
}

/// Releases a decoder. Safe to call with NULL.
#[no_mangle]
pub extern "C" fn voanisa_decoder_close(handle: *mut VoanisaDecoder) {
    if handle.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(handle) });
}

/// Stream properties read from headers only. JSON shape matches
/// `voanisa_decoder_info_json`, but no audio is decoded.
#[no_mangle]
pub extern "C" fn voanisa_stream_info_json(path: *const c_char) -> *mut c_char {
    let path = match c_string_arg(path, "path") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };

    guard(move || match inspect(Path::new(&path)) {
        Ok(info) => success_json(&info),
        Err(error) => message_error_json(&error, "decode"),
    })
}

/// Basic tags for containers AVFoundation cannot read.
#[no_mangle]
pub extern "C" fn voanisa_tags_json(path: *const c_char) -> *mut c_char {
    let path = match c_string_arg(path, "path") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };

    guard(move || success_json(&read_tags(Path::new(&path))))
}

/// SHA-256 of the file contents as lowercase hex, used for import deduplication.
#[no_mangle]
pub extern "C" fn voanisa_hash_file_json(path: *const c_char) -> *mut c_char {
    let path = match c_string_arg(path, "path") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };

    guard(move || match hash_file(Path::new(&path)) {
        Ok(hash) => success_json(&json!({ "hash": hash })),
        Err(error) => message_error_json(&error, "io"),
    })
}

/// Renders a square JPEG cover from any picture the core can decode. JSON:
///
///     {"ok":true,"data":{"source_width":400,"source_height":200,"side":1024}}
///
/// HEIC and other formats `image` does not support return an error; Swift falls
/// back to ImageIO for those.
#[no_mangle]
pub extern "C" fn voanisa_cover_to_file_json(
    src: *const c_char,
    out: *const c_char,
    side: u32,
    quality: u32,
) -> *mut c_char {
    let src = match c_string_arg(src, "src") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };
    let out = match c_string_arg(out, "out") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };

    guard(move || {
        match write_square_cover(
            Path::new(&src),
            Path::new(&out),
            side,
            quality.min(100) as u8,
        ) {
            Ok(result) => success_json(&result),
            Err(error) => message_error_json(&error, "image"),
        }
    })
}

#[derive(Deserialize)]
struct WriteTagsPayload {
    title: Option<String>,
    artist: Option<String>,
    album: Option<String>,
    album_artist: Option<String>,
    track_number: Option<u32>,
    disc_number: Option<u32>,
}

/// Writes the editor's metadata into the audio file. Missing or empty fields
/// remove the corresponding tag. Returns `{"ok":true,"data":null}`.
#[no_mangle]
pub extern "C" fn voanisa_write_tags_json(
    path: *const c_char,
    payload: *const c_char,
) -> *mut c_char {
    let path = match c_string_arg(path, "path") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };
    let payload = match c_string_arg(payload, "payload") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };

    guard(move || {
        let values: WriteTagsPayload = match serde_json::from_str(&payload) {
            Ok(values) => values,
            Err(error) => return message_error_json(&error.to_string(), "invalid_argument"),
        };
        let update = TagWrite {
            title: values.title,
            artist: values.artist,
            album: values.album,
            album_artist: values.album_artist,
            track_number: values.track_number,
            disc_number: values.disc_number,
        };
        match write_tags(Path::new(&path), &update) {
            Ok(()) => ok_json(),
            Err(error) => message_error_json(&error, "io"),
        }
    })
}

/// Writes the container's attached picture to `out`. JSON:
///
///     {"ok":true,"data":{"written":true,"mime":"image/png"}}
///     {"ok":true,"data":{"written":false}}
#[no_mangle]
pub extern "C" fn voanisa_artwork_to_file_json(
    path: *const c_char,
    out: *const c_char,
) -> *mut c_char {
    let path = match c_string_arg(path, "path") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };
    let out = match c_string_arg(out, "out") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };

    guard(move || match write_artwork(Path::new(&path), Path::new(&out)) {
        Ok(Some(mime)) => success_json(&json!({ "written": true, "mime": mime })),
        Ok(None) => success_json(&json!({ "written": false })),
        Err(error) => message_error_json(&error, "io"),
    })
}

/// Writes `library.json` from SQLite. JSON:
///
///     {"ok":true,"data":{"tracks":69,"playlists":1}}
#[no_mangle]
pub extern "C" fn voanisa_export_snapshot_json(
    database: *const c_char,
    out: *const c_char,
) -> *mut c_char {
    let database = match c_string_arg(database, "database") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };
    let out = match c_string_arg(out, "out") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };

    guard(move || match write_snapshot(Path::new(&database), Path::new(&out)) {
        Ok(counts) => success_json(&counts),
        Err(error) => message_error_json(&error, "snapshot"),
    })
}

/// Restores `library.json` into SQLite, skipping tracks and playlists that
/// already exist. JSON:
///
///     {"ok":true,"data":{"tracks":69,"playlists":1}}
#[no_mangle]
pub extern "C" fn voanisa_import_snapshot_json(
    json: *const c_char,
    database: *const c_char,
) -> *mut c_char {
    let json = match c_string_arg(json, "json") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };
    let database = match c_string_arg(database, "database") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };

    guard(move || match import_snapshot(Path::new(&json), Path::new(&database)) {
        Ok(counts) => success_json(&counts),
        Err(error) => message_error_json(&error, "snapshot"),
    })
}

// MARK: - SQLite library

/// Lists tracks, or searches with a non-null query.
#[no_mangle]
pub extern "C" fn voanisa_tracks_json(path: *const c_char, query: *const c_char) -> *mut c_char {
    let path = match c_string_arg(path, "path") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };
    let query = if query.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(query) }
            .to_string_lossy()
            .into_owned()
    };

    guard(move || {
        with_store(&path, |store| match store.search_tracks(&query) {
            Ok(tracks) => success_json(&tracks),
            Err(error) => store_error_json(&error),
        })
    })
}

#[no_mangle]
pub extern "C" fn voanisa_schema_version_json(path: *const c_char) -> *mut c_char {
    let path = match c_string_arg(path, "path") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };

    guard(move || {
        with_store(&path, |store| match store.schema_version() {
            Ok(version) => success_json(&json!({ "version": version })),
            Err(error) => store_error_json(&error),
        })
    })
}

#[no_mangle]
pub extern "C" fn voanisa_insert_track_json(
    path: *const c_char,
    payload: *const c_char,
) -> *mut c_char {
    let path = match c_string_arg(path, "path") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };
    let payload = match c_string_arg(payload, "payload") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };

    guard(move || match parse_json::<NewTrack>(&payload) {
        Ok(track) => with_store(&path, |store| match store.insert_track(&track) {
            Ok(record) => success_json(&record),
            Err(error) => store_error_json(&error),
        }),
        Err(error) => message_error_json(&error, "invalid_json"),
    })
}

#[no_mangle]
pub extern "C" fn voanisa_insert_tracks_json(
    path: *const c_char,
    payload: *const c_char,
) -> *mut c_char {
    let path = match c_string_arg(path, "path") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };
    let payload = match c_string_arg(payload, "payload") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };

    guard(move || match parse_json::<Vec<NewTrack>>(&payload) {
        Ok(tracks) => with_store(&path, |store| match store.insert_tracks(&tracks) {
            Ok(records) => success_json(&records),
            Err(error) => store_error_json(&error),
        }),
        Err(error) => message_error_json(&error, "invalid_json"),
    })
}

#[no_mangle]
pub extern "C" fn voanisa_update_track_json(
    path: *const c_char,
    payload: *const c_char,
) -> *mut c_char {
    let path = match c_string_arg(path, "path") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };
    let payload = match c_string_arg(payload, "payload") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };

    guard(move || match parse_json::<TrackUpdate>(&payload) {
        Ok(update) => with_store(&path, |store| match store.update_track(&update) {
            Ok(()) => ok_json(),
            Err(error) => store_error_json(&error),
        }),
        Err(error) => message_error_json(&error, "invalid_json"),
    })
}

#[no_mangle]
pub extern "C" fn voanisa_delete_track_json(path: *const c_char, id: *const c_char) -> *mut c_char {
    let path = match c_string_arg(path, "path") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };
    let id = match c_string_arg(id, "id") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };

    guard(move || {
        with_store(&path, |store| match store.delete_track(&id) {
            Ok(deleted) => success_json(&json!({ "deleted": deleted })),
            Err(error) => store_error_json(&error),
        })
    })
}

#[no_mangle]
pub extern "C" fn voanisa_reorder_tracks_json(
    path: *const c_char,
    payload: *const c_char,
) -> *mut c_char {
    let path = match c_string_arg(path, "path") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };
    let payload = match c_string_arg(payload, "payload") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };

    guard(move || match parse_json::<Vec<String>>(&payload) {
        Ok(ids) => with_store(&path, |store| match store.reorder_tracks(&ids) {
            Ok(()) => ok_json(),
            Err(error) => store_error_json(&error),
        }),
        Err(error) => message_error_json(&error, "invalid_json"),
    })
}

/// Replaces the stored track list in one transaction.
#[no_mangle]
pub extern "C" fn voanisa_sync_tracks_json(
    path: *const c_char,
    payload: *const c_char,
) -> *mut c_char {
    let path = match c_string_arg(path, "path") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };
    let payload = match c_string_arg(payload, "payload") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };

    guard(move || match parse_json::<Vec<NewTrack>>(&payload) {
        Ok(tracks) => with_store(&path, |store| match store.sync_tracks(&tracks) {
            Ok(()) => ok_json(),
            Err(error) => store_error_json(&error),
        }),
        Err(error) => message_error_json(&error, "invalid_json"),
    })
}

#[no_mangle]
pub extern "C" fn voanisa_playlists_json(path: *const c_char) -> *mut c_char {
    let path = match c_string_arg(path, "path") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };

    guard(move || {
        with_store(&path, |store| match store.list_playlists() {
            Ok(playlists) => success_json(&playlists),
            Err(error) => store_error_json(&error),
        })
    })
}

#[no_mangle]
pub extern "C" fn voanisa_create_playlist_json(
    path: *const c_char,
    payload: *const c_char,
) -> *mut c_char {
    let path = match c_string_arg(path, "path") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };
    let payload = match c_string_arg(payload, "payload") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };

    guard(move || match parse_json::<NewPlaylistPayload>(&payload) {
        Ok(payload) => with_store(&path, |store| {
            match store.create_playlist(&payload.id, &payload.name) {
                Ok(playlist) => success_json(&playlist),
                Err(error) => store_error_json(&error),
            }
        }),
        Err(error) => message_error_json(&error, "invalid_json"),
    })
}

#[no_mangle]
pub extern "C" fn voanisa_rename_playlist_json(
    path: *const c_char,
    payload: *const c_char,
) -> *mut c_char {
    let path = match c_string_arg(path, "path") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };
    let payload = match c_string_arg(payload, "payload") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };

    guard(
        move || match parse_json::<RenamePlaylistPayload>(&payload) {
            Ok(payload) => with_store(&path, |store| {
                match store.rename_playlist(&payload.id, &payload.name) {
                    Ok(()) => ok_json(),
                    Err(error) => store_error_json(&error),
                }
            }),
            Err(error) => message_error_json(&error, "invalid_json"),
        },
    )
}

#[no_mangle]
pub extern "C" fn voanisa_delete_playlist_json(
    path: *const c_char,
    id: *const c_char,
) -> *mut c_char {
    let path = match c_string_arg(path, "path") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };
    let id = match c_string_arg(id, "id") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };

    guard(move || {
        with_store(&path, |store| match store.delete_playlist(&id) {
            Ok(deleted) => success_json(&json!({ "deleted": deleted })),
            Err(error) => store_error_json(&error),
        })
    })
}

#[no_mangle]
pub extern "C" fn voanisa_set_playlist_tracks_json(
    path: *const c_char,
    payload: *const c_char,
) -> *mut c_char {
    let path = match c_string_arg(path, "path") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };
    let payload = match c_string_arg(payload, "payload") {
        Ok(value) => value,
        Err(error) => return to_c_string(message_error_json(&error, "invalid_argument")),
    };

    guard(
        move || match parse_json::<PlaylistTracksPayload>(&payload) {
            Ok(payload) => with_store(&path, |store| {
                match store.set_playlist_tracks(&payload.playlist_id, &payload.track_ids) {
                    Ok(()) => ok_json(),
                    Err(error) => store_error_json(&error),
                }
            }),
            Err(error) => message_error_json(&error, "invalid_json"),
        },
    )
}

#[no_mangle]
pub extern "C" fn voanisa_string_free(value: *mut c_char) {
    if !value.is_null() {
        unsafe {
            drop(CString::from_raw(value));
        }
    }
}

fn c_string_arg(pointer: *const c_char, name: &str) -> Result<String, String> {
    if pointer.is_null() {
        Err(format!("{name} is null"))
    } else {
        Ok(unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned())
    }
}

fn parse_json<T: DeserializeOwned>(value: &str) -> Result<T, String> {
    serde_json::from_str(value).map_err(|error| format!("invalid JSON: {error}"))
}

fn with_store<F>(path: &str, body: F) -> String
where
    F: FnOnce(&Store) -> String,
{
    match Store::open(Path::new(path)) {
        Ok(store) => body(&store),
        Err(error) => store_error_json(&error),
    }
}

fn success_json<T: Serialize>(value: &T) -> String {
    json!({ "ok": true, "data": value }).to_string()
}

fn ok_json() -> String {
    json!({ "ok": true, "data": null }).to_string()
}

fn store_error_json(error: &StoreError) -> String {
    let kind = match error {
        StoreError::NotFound => "not_found",
        StoreError::InvalidReorder => "invalid_reorder",
        StoreError::DuplicateTrack => "duplicate_track",
        StoreError::InvalidPlaylistName => "invalid_name",
        StoreError::UnsupportedSchema { .. } => "schema",
        StoreError::Sqlite(_) => "sqlite",
    };
    message_error_json(&error.to_string(), kind)
}

fn message_error_json(message: &str, kind: &str) -> String {
    json!({ "ok": false, "error": message, "kind": kind }).to_string()
}

fn guard<F>(body: F) -> *mut c_char
where
    F: FnOnce() -> String,
{
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(json) => to_c_string(json),
        Err(_) => to_c_string(message_error_json("panic in Rust core", "panic")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_db() -> PathBuf {
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);

        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let sequence = SEQUENCE.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "voanisa-ffi-{}-{nanos}-{sequence}.sqlite",
            std::process::id()
        ))
    }

    fn c(value: &str) -> CString {
        CString::new(value).expect("CString")
    }

    fn take(pointer: *mut c_char) -> Value {
        assert!(!pointer.is_null());
        let text = unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned();
        voanisa_string_free(pointer);
        serde_json::from_str(&text).expect("valid JSON envelope")
    }

    fn track_json(id: &str, title: &str) -> String {
        json!({
            "id": id,
            "title": title,
            "artist": "",
            "album": "",
            "album_artist": "",
            "track_number": null,
            "disc_number": null,
            "duration": 0.0,
            "file_name": format!("{id}.mp3"),
            "cover_file_name": null,
            "format": "MP3",
            "content_hash": format!("hash-{id}"),
            "source": "local",
            "music_persistent_id": null,
            "date_added": 0.0
        })
        .to_string()
    }

    #[test]
    fn crud_roundtrip_through_c_abi() {
        let path = temp_db();
        let path_c = c(path.to_string_lossy().as_ref());

        let insert = c(&track_json("a", "A"));
        let inserted = take(voanisa_insert_track_json(path_c.as_ptr(), insert.as_ptr()));
        assert_eq!(inserted["ok"], true);
        assert_eq!(inserted["data"]["id"], "a");
        assert_eq!(inserted["data"]["sort_index"], 0);

        let listed = take(voanisa_tracks_json(path_c.as_ptr(), std::ptr::null()));
        assert_eq!(listed["data"].as_array().expect("array").len(), 1);

        let update = c(&json!({
            "id": "a",
            "title": "New",
            "artist": "Artist",
            "album": "Album",
            "album_artist": "Album Artist",
            "track_number": 1,
            "disc_number": 1,
            "cover_file_name": null,
            "music_persistent_id": null
        })
        .to_string());
        let updated = take(voanisa_update_track_json(path_c.as_ptr(), update.as_ptr()));
        assert_eq!(updated["ok"], true);

        let listed = take(voanisa_tracks_json(path_c.as_ptr(), std::ptr::null()));
        assert_eq!(listed["data"][0]["title"], "New");

        let deleted = take(voanisa_delete_track_json(path_c.as_ptr(), c("a").as_ptr()));
        assert_eq!(deleted["data"]["deleted"], true);

        let listed = take(voanisa_tracks_json(path_c.as_ptr(), std::ptr::null()));
        assert!(listed["data"].as_array().expect("array").is_empty());

        std::fs::remove_file(path).ok();
    }

    #[test]
    fn reorder_errors_are_reported() {
        let path = temp_db();
        let path_c = c(path.to_string_lossy().as_ref());

        let batch = c(&format!(
            "[{},{}]",
            track_json("a", "A"),
            track_json("b", "B")
        ));
        let inserted = take(voanisa_insert_tracks_json(path_c.as_ptr(), batch.as_ptr()));
        assert_eq!(inserted["ok"], true);

        let reorder = c("[\"a\"]");
        let result = take(voanisa_reorder_tracks_json(
            path_c.as_ptr(),
            reorder.as_ptr(),
        ));
        assert_eq!(result["ok"], false);
        assert_eq!(result["kind"], "invalid_reorder");

        std::fs::remove_file(path).ok();
    }

    #[test]
    fn sync_replaces_rows_through_c_abi() {
        let path = temp_db();
        let path_c = c(path.to_string_lossy().as_ref());

        let batch = c(&format!(
            "[{},{}]",
            track_json("a", "A"),
            track_json("b", "B")
        ));
        assert_eq!(
            take(voanisa_insert_tracks_json(path_c.as_ptr(), batch.as_ptr()))["ok"],
            true
        );

        let sync = c(&format!("[{}]", track_json("b", "B2")));
        let synced = take(voanisa_sync_tracks_json(path_c.as_ptr(), sync.as_ptr()));
        assert_eq!(synced["ok"], true);

        let listed = take(voanisa_tracks_json(path_c.as_ptr(), std::ptr::null()));
        assert_eq!(listed["data"].as_array().expect("array").len(), 1);
        assert_eq!(listed["data"][0]["title"], "B2");

        let duplicate = c(&format!(
            "[{},{}]",
            track_json("c", "C"),
            track_json("c", "C2")
        ));
        let result = take(voanisa_sync_tracks_json(
            path_c.as_ptr(),
            duplicate.as_ptr(),
        ));
        assert_eq!(result["ok"], false);
        assert_eq!(result["kind"], "duplicate_track");

        std::fs::remove_file(path).ok();
    }

    #[test]
    fn playlist_roundtrip_through_c_abi() {
        let path = temp_db();
        let path_c = c(path.to_string_lossy().as_ref());

        let batch = c(&format!(
            "[{},{}]",
            track_json("a", "A"),
            track_json("b", "B")
        ));
        assert_eq!(
            take(voanisa_insert_tracks_json(path_c.as_ptr(), batch.as_ptr()))["ok"],
            true
        );

        let create = c(&json!({ "id": "p1", "name": "Favorites" }).to_string());
        let created = take(voanisa_create_playlist_json(
            path_c.as_ptr(),
            create.as_ptr(),
        ));
        assert_eq!(created["ok"], true);
        assert_eq!(created["data"]["name"], "Favorites");
        assert!(created["data"]["track_ids"]
            .as_array()
            .expect("array")
            .is_empty());

        let set = c(&json!({
            "playlist_id": "p1",
            "track_ids": ["b", "a"]
        })
        .to_string());
        assert_eq!(
            take(voanisa_set_playlist_tracks_json(
                path_c.as_ptr(),
                set.as_ptr()
            ))["ok"],
            true
        );

        let listed = take(voanisa_playlists_json(path_c.as_ptr()));
        assert_eq!(listed["data"][0]["track_ids"], json!(["b", "a"]));

        let rename = c(&json!({ "id": "p1", "name": "Best" }).to_string());
        assert_eq!(
            take(voanisa_rename_playlist_json(
                path_c.as_ptr(),
                rename.as_ptr()
            ))["ok"],
            true
        );

        let invalid = c(&json!({ "id": "p2", "name": " " }).to_string());
        let invalid_result = take(voanisa_create_playlist_json(
            path_c.as_ptr(),
            invalid.as_ptr(),
        ));
        assert_eq!(invalid_result["ok"], false);
        assert_eq!(invalid_result["kind"], "invalid_name");

        let deleted = take(voanisa_delete_playlist_json(
            path_c.as_ptr(),
            c("p1").as_ptr(),
        ));
        assert_eq!(deleted["data"]["deleted"], true);

        std::fs::remove_file(path).ok();
    }

    #[test]
    fn schema_version_is_reported() {
        let path = temp_db();
        let path_c = c(path.to_string_lossy().as_ref());
        let result = take(voanisa_schema_version_json(path_c.as_ptr()));
        assert_eq!(result["data"]["version"], 1);
        std::fs::remove_file(path).ok();
    }
}

fn error_json(message: &str) -> String {
    serde_json::to_string(&ProbeResult {
        container: "unknown".to_string(),
        codec: None,
        recognized: false,
        error: Some(message.to_string()),
    })
    .unwrap_or_else(|_| {
        "{\"container\":\"unknown\",\"codec\":null,\"recognized\":false,\"error\":\"unknown\"}"
            .to_string()
    })
}

fn to_c_string(json: String) -> *mut c_char {
    CString::new(json)
        .unwrap_or_else(|_| {
            CString::new(
                "{\"container\":\"unknown\",\"codec\":null,\"recognized\":false,\"error\":\"nul byte\"}",
            )
            .expect("static JSON has no NUL")
        })
        .into_raw()
}
