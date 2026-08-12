#ifndef DS_TUNNEL_FD_H
#define DS_TUNNEL_FD_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Scan process FDs for the newest utun control socket (Xray/sing-box TUN).
/// Returns fd >= 0 on success, or -1 if none found after retries.
int32_t ds_utun_lookup_fd(int max_attempts, int delay_ms);

#ifdef __cplusplus
}
#endif

#endif /* DS_TUNNEL_FD_H */
