#include "ds_config_scan.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

static int ds_ascii_ieq(char a, char b) {
    return (char)tolower((unsigned char)a) == (char)tolower((unsigned char)b);
}

static int ds_find_ci(const char *hay, size_t hay_len, const char *needle) {
    size_t nlen = strlen(needle);
    if (nlen == 0 || hay_len < nlen) {
        return 0;
    }
    for (size_t i = 0; i + nlen <= hay_len; i++) {
        size_t j = 0;
        for (; j < nlen; j++) {
            if (!ds_ascii_ieq(hay[i + j], needle[j])) {
                break;
            }
        }
        if (j == nlen) {
            return 1;
        }
    }
    return 0;
}

static int ds_find_cs(const char *hay, size_t hay_len, const char *needle) {
    size_t nlen = strlen(needle);
    if (nlen == 0 || hay_len < nlen) {
        return 0;
    }
    // memmem is available on Darwin.
    return memmem(hay, hay_len, needle, nlen) != NULL;
}

uint32_t ds_config_scan(const char *utf8, size_t len) {
    if (utf8 == NULL || len == 0) {
        return 0;
    }
    uint32_t flags = 0;
    if (ds_find_ci(utf8, len, "geoip:")) {
        flags |= DS_SCAN_GEOIP;
    }
    if (ds_find_ci(utf8, len, "geosite:")) {
        flags |= DS_SCAN_GEOSITE;
    }
    // DNS localhost variants common in Happ desktop configs.
    if (ds_find_ci(utf8, len, "\"localhost\"")
        || ds_find_ci(utf8, len, "\"127.0.0.1\"")
        || ds_find_ci(utf8, len, ": \"localhost\"")
        || ds_find_ci(utf8, len, ":\"localhost\"")) {
        flags |= DS_SCAN_LOCALHOST;
    }
    if (ds_find_cs(utf8, len, "\"balancers\"") || ds_find_cs(utf8, len, "\"balancerTag\"")) {
        flags |= DS_SCAN_BALANCER;
    }
    if (ds_find_cs(utf8, len, "\"observatory\"") || ds_find_cs(utf8, len, "\"burstObservatory\"")) {
        flags |= DS_SCAN_OBSERVATORY;
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
