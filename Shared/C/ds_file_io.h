#ifndef DS_FILE_IO_H
#define DS_FILE_IO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Atomically write `len` bytes to `path` via temp file + rename.
/// Returns 0 on success, -1 on error (errno set).
int ds_atomic_write(const char *path, const void *data, size_t len);

/// Read entire file into a malloc'd buffer (NUL-terminated).
/// On success returns pointer and sets *out_len to byte count (excluding NUL).
/// Caller must free(). Returns NULL on error.
char *ds_read_file(const char *path, size_t *out_len);

#ifdef __cplusplus
}
#endif

#endif /* DS_FILE_IO_H */
