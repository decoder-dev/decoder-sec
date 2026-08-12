#ifndef DS_BYTES_H
#define DS_BYTES_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Swap adjacent bytes in-place: AB CD EF → BA DC FE (odd trailing byte untouched).
void ds_swap_adjacent(uint8_t *buf, size_t len);

/// Per 4-byte block ABCD → CDAB (self-inverse). Trailing <4 bytes untouched.
void ds_swap_block_halves(uint8_t *buf, size_t len);

/// Decode standard / URL-safe Base64 into `out` (capacity `out_cap`).
/// Whitespace ignored; `-`/`_` treated as `+`/`/`.
/// Returns decoded byte count, or -1 on error.
int32_t ds_base64_decode(const char *in, size_t in_len, uint8_t *out, size_t out_cap);

#ifdef __cplusplus
}
#endif

#endif /* DS_BYTES_H */
