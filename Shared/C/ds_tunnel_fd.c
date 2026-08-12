#include "ds_tunnel_fd.h"

#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/sys_domain.h>
#include <sys/kern_control.h>
#include <net/if_utun.h>

// AF_SYSTEM = 32 on Darwin; sockaddr_ctl layout uses ss_family at offset 1 for getpeername buffer.
#ifndef AF_SYSTEM
#define AF_SYSTEM 32
#endif

#ifndef SYSPROTO_CONTROL
#define SYSPROTO_CONTROL 2
#endif

#ifndef UTUN_OPT_IFNAME
#define UTUN_OPT_IFNAME 2
#endif

static int ds_utun_index(int fd) {
    char name[96];
    socklen_t name_len = sizeof(name);
    memset(name, 0, sizeof(name));
    if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, name, &name_len) != 0) {
        return -1;
    }
    if (strncmp(name, "utun", 4) != 0) {
        return -1;
    }
    int idx = 0;
    const char *p = name + 4;
    if (*p == '\0') {
        return 0;
    }
    while (*p >= '0' && *p <= '9') {
        idx = idx * 10 + (*p - '0');
        p++;
    }
    return idx;
}

static int ds_is_utun_socket(int fd) {
    uint8_t sa_buf[32];
    socklen_t sa_len = sizeof(sa_buf);
    memset(sa_buf, 0, sizeof(sa_buf));
    if (getpeername(fd, (struct sockaddr *)sa_buf, &sa_len) != 0) {
        return 0;
    }
    // sockaddr.sa_family is at offset 1 on Darwin (sa_len then sa_family).
    if (sa_buf[1] != (uint8_t)AF_SYSTEM) {
        return 0;
    }
    char name[96];
    socklen_t name_len = sizeof(name);
    if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, name, &name_len) != 0) {
        return 0;
    }
    return 1;
}

static int32_t ds_scan_utun_fds(void) {
    int32_t best = -1;
    int best_index = -1;
    for (int fd = 0; fd < 1024; fd++) {
        if (!ds_is_utun_socket(fd)) {
            continue;
        }
        int idx = ds_utun_index(fd);
        if (idx >= best_index) {
            best_index = idx;
            best = (int32_t)fd;
        } else if (best < 0) {
            best = (int32_t)fd;
        }
    }
    return best;
}

int32_t ds_utun_lookup_fd(int max_attempts, int delay_ms) {
    if (max_attempts < 1) {
        max_attempts = 1;
    }
    if (delay_ms < 0) {
        delay_ms = 0;
    }
    for (int attempt = 0; attempt < max_attempts; attempt++) {
        int32_t fd = ds_scan_utun_fds();
        if (fd >= 0) {
            return fd;
        }
        if (attempt + 1 < max_attempts && delay_ms > 0) {
            usleep((useconds_t)delay_ms * 1000u);
        }
    }
    return -1;
}
