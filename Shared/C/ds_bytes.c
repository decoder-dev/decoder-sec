#include "ds_bytes.h"

#include <ctype.h>

void ds_swap_adjacent(uint8_t *buf, size_t len) {
    if (buf == NULL) {
        return;
    }
    for (size_t i = 0; i + 1 < len; i += 2) {
        uint8_t tmp = buf[i];
        buf[i] = buf[i + 1];
        buf[i + 1] = tmp;
    }
}

void ds_swap_block_halves(uint8_t *buf, size_t len) {
    if (buf == NULL) {
        return;
    }
    size_t full = len - (len % 4);
    for (size_t i = 0; i < full; i += 4) {
        uint8_t a = buf[i];
        uint8_t b = buf[i + 1];
        buf[i] = buf[i + 2];
        buf[i + 1] = buf[i + 3];
        buf[i + 2] = a;
        buf[i + 3] = b;
    }
}

static int ds_b64_val(unsigned char c) {
    if (c >= 'A' && c <= 'Z') {
        return c - 'A';
    }
    if (c >= 'a' && c <= 'z') {
        return c - 'a' + 26;
    }
    if (c >= '0' && c <= '9') {
        return c - '0' + 52;
    }
    if (c == '+' || c == '-') {
        return 62;
    }
    if (c == '/' || c == '_') {
        return 63;
    }
    return -1;
}

int32_t ds_base64_decode(const char *in, size_t in_len, uint8_t *out, size_t out_cap) {
    if (in == NULL || (out == NULL && out_cap > 0)) {
        return -1;
    }

    int val[4];
    int nval = 0;
    size_t o = 0;
    int pad = 0;

    for (size_t i = 0; i < in_len; i++) {
        unsigned char c = (unsigned char)in[i];
        if (isspace(c)) {
            continue;
        }
        if (c == '=') {
            pad++;
            val[nval++] = 0;
        } else {
            int v = ds_b64_val(c);
            if (v < 0) {
                return -1;
            }
            if (pad > 0) {
                return -1; // data after padding
            }
            val[nval++] = v;
        }

        if (nval == 4) {
            if (pad > 2) {
                return -1;
            }
            uint32_t triple = ((uint32_t)val[0] << 18)
                | ((uint32_t)val[1] << 12)
                | ((uint32_t)val[2] << 6)
                | (uint32_t)val[3];
            int produce = 3 - pad;
            for (int k = 0; k < produce; k++) {
                if (o >= out_cap) {
                    return -1;
                }
                out[o++] = (uint8_t)((triple >> (16 - 8 * k)) & 0xff);
            }
            nval = 0;
            pad = 0;
        }
    }

    if (nval != 0) {
        return -1; // incomplete quartet
    }
    return (int32_t)o;
}
