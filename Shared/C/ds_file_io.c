#include "ds_file_io.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int ds_atomic_write(const char *path, const void *data, size_t len) {
    if (path == NULL || (data == NULL && len > 0)) {
        errno = EINVAL;
        return -1;
    }

    size_t path_len = strlen(path);
    if (path_len == 0 || path_len > 1024) {
        errno = ENAMETOOLONG;
        return -1;
    }

    char tmp[1100];
    int n = snprintf(tmp, sizeof(tmp), "%s.tmp.%d", path, (int)getpid());
    if (n <= 0 || (size_t)n >= sizeof(tmp)) {
        errno = ENAMETOOLONG;
        return -1;
    }

    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        return -1;
    }

    const char *p = (const char *)data;
    size_t left = len;
    while (left > 0) {
        ssize_t w = write(fd, p, left);
        if (w < 0) {
            int saved = errno;
            close(fd);
            unlink(tmp);
            errno = saved;
            return -1;
        }
        p += (size_t)w;
        left -= (size_t)w;
    }

    if (fsync(fd) != 0) {
        int saved = errno;
        close(fd);
        unlink(tmp);
        errno = saved;
        return -1;
    }
    if (close(fd) != 0) {
        unlink(tmp);
        return -1;
    }

    if (rename(tmp, path) != 0) {
        int saved = errno;
        unlink(tmp);
        errno = saved;
        return -1;
    }
    return 0;
}

char *ds_read_file(const char *path, size_t *out_len) {
    if (out_len) {
        *out_len = 0;
    }
    if (path == NULL) {
        errno = EINVAL;
        return NULL;
    }

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return NULL;
    }

    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 0) {
        int saved = errno;
        close(fd);
        errno = saved != 0 ? saved : EINVAL;
        return NULL;
    }

    size_t size = (size_t)st.st_size;
    // Cap defensive read (config / error files stay well under this).
    if (size > 8u * 1024u * 1024u) {
        close(fd);
        errno = EFBIG;
        return NULL;
    }

    char *buf = (char *)malloc(size + 1);
    if (buf == NULL) {
        close(fd);
        errno = ENOMEM;
        return NULL;
    }

    size_t got = 0;
    while (got < size) {
        ssize_t r = read(fd, buf + got, size - got);
        if (r < 0) {
            int saved = errno;
            free(buf);
            close(fd);
            errno = saved;
            return NULL;
        }
        if (r == 0) {
            break;
        }
        got += (size_t)r;
    }
    close(fd);
    buf[got] = '\0';
    if (out_len) {
        *out_len = got;
    }
    return buf;
}
