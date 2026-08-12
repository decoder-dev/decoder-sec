#include "ds_config_scan.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static inline int ds_ascii_ieq(char a, char b) {
    return (char)tolower((unsigned char)a) == (char)tolower((unsigned char)b);
}

static int ds_prefix_ci(const char *s, size_t len, const char *prefix) {
    size_t n = strlen(prefix);
    if (len < n) {
        return 0;
    }
    for (size_t i = 0; i < n; i++) {
        if (!ds_ascii_ieq(s[i], prefix[i])) {
            return 0;
        }
    }
    return 1;
}

/// Single-pass multi-needle scan over raw config bytes.
uint32_t ds_config_scan(const char *utf8, size_t len) {
    if (utf8 == NULL || len == 0) {
        return 0;
    }

    uint32_t flags = 0;
    // Track which needles are still needed so we can early-exit.
    int need_geoip = 1;
    int need_geosite = 1;
    int need_localhost = 1;
    int need_balancer = 1;
    int need_observatory = 1;

    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)utf8[i];

        // Case-insensitive: geoip: / geosite:
        if (need_geoip && (c == 'g' || c == 'G') && i + 6 <= len
            && ds_prefix_ci(utf8 + i, len - i, "geoip:")) {
            flags |= DS_SCAN_GEOIP;
            need_geoip = 0;
        }
        if (need_geosite && (c == 'g' || c == 'G') && i + 8 <= len
            && ds_prefix_ci(utf8 + i, len - i, "geosite:")) {
            flags |= DS_SCAN_GEOSITE;
            need_geosite = 0;
        }

        // Localhost / loopback literals common in Happ DNS.
        if (need_localhost) {
            if ((c == 'l' || c == 'L') && i + 9 <= len
                && ds_prefix_ci(utf8 + i, len - i, "localhost")) {
                flags |= DS_SCAN_LOCALHOST;
                need_localhost = 0;
            } else if (c == '1' && i + 9 <= len
                       && memcmp(utf8 + i, "127.0.0.1", 9) == 0) {
                flags |= DS_SCAN_LOCALHOST;
                need_localhost = 0;
            }
        }

        // JSON keys — case-sensitive.
        if (need_balancer && c == '"') {
            if (i + 11 <= len && memcmp(utf8 + i, "\"balancers\"", 11) == 0) {
                flags |= DS_SCAN_BALANCER;
                need_balancer = 0;
            } else if (i + 13 <= len && memcmp(utf8 + i, "\"balancerTag\"", 13) == 0) {
                flags |= DS_SCAN_BALANCER;
                need_balancer = 0;
            }
        }
        if (need_observatory && c == '"') {
            if (i + 13 <= len && memcmp(utf8 + i, "\"observatory\"", 13) == 0) {
                flags |= DS_SCAN_OBSERVATORY;
                need_observatory = 0;
            } else if (i + 18 <= len && memcmp(utf8 + i, "\"burstObservatory\"", 18) == 0) {
                flags |= DS_SCAN_OBSERVATORY;
                need_observatory = 0;
            }
        }

        if (!need_geoip && !need_geosite && !need_localhost
            && !need_balancer && !need_observatory) {
            break;
        }
    }
    return flags;
}

int ds_copy_file(const char *src_path, const char *dst_path) {
    if (src_path == NULL || dst_path == NULL) {
        errno = EINVAL;
        return -1;
    }
    int in_fd = open(src_path, O_RDONLY);
    if (in_fd < 0) {
        return -1;
    }
    int out_fd = open(dst_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out_fd < 0) {
        int saved = errno;
        close(in_fd);
        errno = saved;
        return -1;
    }

    char buf[64 * 1024];
    for (;;) {
        ssize_t n = read(in_fd, buf, sizeof(buf));
        if (n < 0) {
            int saved = errno;
            close(in_fd);
            close(out_fd);
            unlink(dst_path);
            errno = saved;
            return -1;
        }
        if (n == 0) {
            break;
        }
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(out_fd, buf + off, (size_t)(n - off));
            if (w < 0) {
                int saved = errno;
                close(in_fd);
                close(out_fd);
                unlink(dst_path);
                errno = saved;
                return -1;
            }
            off += w;
        }
    }

    close(in_fd);
    if (close(out_fd) != 0) {
        unlink(dst_path);
        return -1;
    }
    return 0;
}

/// Blank `"geosite:…"` / `"geoip:…"` JSON string values to `""` (keeps JSON valid).
char *ds_json_blank_geo_strings(const char *utf8, size_t len, size_t *out_len) {
    if (out_len) {
        *out_len = 0;
    }
    if (utf8 == NULL || len == 0) {
        char *empty = (char *)calloc(1, 1);
        return empty;
    }

    // Worst case: output same size as input (blanking only shortens).
    char *out = (char *)malloc(len + 1);
    if (out == NULL) {
        return NULL;
    }

    size_t o = 0;
    size_t i = 0;
    while (i < len) {
        if (utf8[i] != '"') {
            out[o++] = utf8[i++];
            continue;
        }

        // Start of a JSON string.
        size_t start = i;
        i++; // skip opening quote
        int escaped = 0;
        while (i < len) {
            char ch = utf8[i];
            if (escaped) {
                escaped = 0;
                i++;
                continue;
            }
            if (ch == '\\') {
                escaped = 1;
                i++;
                continue;
            }
            if (ch == '"') {
                i++; // include closing quote
                break;
            }
            i++;
        }
        size_t end = i; // exclusive
        size_t content_start = start + 1;
        size_t content_len = (end > content_start + 1) ? (end - content_start - 1) : 0;

        if (content_len >= 6
            && (ds_prefix_ci(utf8 + content_start, content_len, "geoip:")
                || ds_prefix_ci(utf8 + content_start, content_len, "geosite:"))) {
            out[o++] = '"';
            out[o++] = '"';
        } else {
            memcpy(out + o, utf8 + start, end - start);
            o += (end - start);
        }
    }

    out[o] = '\0';
    if (out_len) {
        *out_len = o;
    }
    return out;
}
