#ifndef VOANISA_CORE_H
#define VOANISA_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Static version string. Do not free.
const char *voanisa_core_version(void);

/// Probes a file and returns a heap-allocated UTF-8 JSON string:
///
///     {"container":"m4a","codec":"aac","recognized":true,"error":null}
///
/// The caller owns the returned string and must release it with
/// voanisa_string_free().
char *voanisa_probe_json(const char *path);

/// Streaming decoder for containers AVFoundation cannot play (Ogg Vorbis,
/// Opus, ...). All PCM is interleaved 32-bit float.
typedef struct VoanisaDecoder VoanisaDecoder;

/// Returns NULL when the file cannot be decoded; ask
/// voanisa_decoder_open_error_json() why.
VoanisaDecoder *voanisa_decoder_open(const char *path);
char *voanisa_decoder_open_error_json(const char *path);

/// JSON: {"container":"ogg","codec":"vorbis","sample_rate":44100,
///        "channels":2,"duration_seconds":213.4}
char *voanisa_decoder_info_json(VoanisaDecoder *decoder);

/// Fills `out` with up to `frames * channels` floats. Returns the frames read,
/// 0 at end of stream, or -1 on error (see voanisa_decoder_error_json).
int64_t voanisa_decoder_read(VoanisaDecoder *decoder, float *out, uint32_t frames);
int32_t voanisa_decoder_seek(VoanisaDecoder *decoder, double seconds);
double voanisa_decoder_position(VoanisaDecoder *decoder);
char *voanisa_decoder_error_json(VoanisaDecoder *decoder);
void voanisa_decoder_close(VoanisaDecoder *decoder);

/// Basic tags for containers AVFoundation cannot read. JSON:
///
///     {"ok":true,"data":{"title":...,"artist":...,"album":...,
///      "album_artist":...,"track_number":...,"disc_number":...,
///      "duration_seconds":...}}
char *voanisa_tags_json(const char *path);

/// SQLite library calls. Every function returns a heap-allocated JSON string:
///
///     {"ok":true,"data":...}
///     {"ok":false,"error":"...","kind":"not_found"}
///
/// The caller owns the returned string and must release it with
/// voanisa_string_free().
char *voanisa_tracks_json(const char *path, const char *query);
char *voanisa_schema_version_json(const char *path);
char *voanisa_insert_track_json(const char *path, const char *payload);
char *voanisa_insert_tracks_json(const char *path, const char *payload);
char *voanisa_update_track_json(const char *path, const char *payload);
char *voanisa_delete_track_json(const char *path, const char *id);
char *voanisa_reorder_tracks_json(const char *path, const char *payload);
char *voanisa_sync_tracks_json(const char *path, const char *payload);
char *voanisa_playlists_json(const char *path);
char *voanisa_create_playlist_json(const char *path, const char *payload);
char *voanisa_rename_playlist_json(const char *path, const char *payload);
char *voanisa_delete_playlist_json(const char *path, const char *id);
char *voanisa_set_playlist_tracks_json(const char *path, const char *payload);
void voanisa_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif
