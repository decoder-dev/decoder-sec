# decoder sec.

Premium iOS proxy client — **decoder-sec**.

Built for our own product direction on top of the open Everywhere / Xray stack (GPLv3).

[![Build IPA](https://github.com/decoder-dev/decoder-sec/actions/workflows/build-ipa.yml/badge.svg)](https://github.com/decoder-dev/decoder-sec/actions/workflows/build-ipa.yml)

## What it is

- Native **Swift** app + Network Extension
- Engines via [EverywhereCore](https://github.com/NodePassProject/EverywhereCore): **Xray**, **sing-box**, **mihomo**
- Brand: OLED black + neon green (`decoder sec.`)
- Happ-compatible deep links (`happ://add/…`, routing, share-links)
- GitHub Actions → IPA artifacts

## Identity

| | |
|---|---|
| Display name | `decoder sec.` |
| Xcode project | `DecoderSec.xcodeproj` |
| Targets | `DecoderSec` · `DecoderSecTunnel` |
| Bundle ID | `com.decodersec.app` |
| Packet Tunnel | `com.decodersec.app.PacketTunnel` |
| App Group | `group.com.decodersec.app` |

Details: [BRAND.md](./BRAND.md) · deep links: [DEEPLINKS.md](./DEEPLINKS.md) · roadmap: [FORK.md](./FORK.md)

## Build

```bash
git clone https://github.com/decoder-dev/decoder-sec.git
cd decoder-sec
./build.sh
open DecoderSec.xcodeproj
```

Unsigned IPA (CI / local macOS):

```bash
./Scripts/ci_export_ipa.sh
```

Requires: Xcode 16+, Apple Team with Network Extension + App Group for the IDs above.

## License

GPLv3 — see [LICENSE](./LICENSE).

Upstream networking cores: Xray-core, sing-box, mihomo.  
Application lineage: [NodePassProject/Everywhere](https://github.com/NodePassProject/Everywhere).
