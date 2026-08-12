#ifndef DS_CONFIG_SCAN_H
#define DS_CONFIG_SCAN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Bit flags returned by ds_config_scan.
enum {
    DS_SCAN_GEOIP       = 1u << 0,
    DS_SCAN_GEOSITE     = 1u << 1,
    DS_SCAN_LOCALHOST   = 1u << 2,
    DS_SCAN_BALANCER    = 1u << 3, // "balancers" or "balancerTag"
    DS_SCAN_OBSERVATORY = 1u << 4  // "observatory" / "burstObservatory"
};

/// Single-pass ASCII/UTF-8 substring scan over raw config bytes (no JSON parse).
/// Case-insensitive for geo/localhost tokens; case-sensitive for JSON keys.
uint32_t ds_config_scan(const char *utf8, size_t len);

/// Copy file with POSIX read/write (seed geo .dat). Returns 0 on success, -1 on error.
int ds_copy_file(const char *src_path, const char *dst_path);

/// Rewrite JSON text: blank `"geosite:…"` / `"geoip:…"` string values to `""`.
/// Returns malloc'd NUL-terminated buffer (caller frees). NULL on OOM.
char *ds_json_blank_geo_strings(const char *utf8, size_t len, size_t *out_len);

#ifdef __cplusplus
}
#endif

#endif /* DS_CONFIG_SCAN_H */
