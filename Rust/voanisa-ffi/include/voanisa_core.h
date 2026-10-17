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
void voanisa_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif
