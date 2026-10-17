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

/// Frees a string returned by voanisa_probe_json().
void voanisa_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif
