<p align="center">
  <img src="docs/logo.png" alt="decoder sec." width="160" height="160" />
</p>

<h1 align="center">decoder sec.</h1>

<p align="center">
  <strong>Premium iOS proxy client</strong><br/>
  Xray · sing-box · mihomo — your configs, your rules.
</p>

<p align="center">
  <a href="https://github.com/decoder-dev/decoder-sec/actions/workflows/build-ipa.yml"><img src="https://github.com/decoder-dev/decoder-sec/actions/workflows/build-ipa.yml/badge.svg" alt="Build IPA" /></a>
  <a href="https://github.com/decoder-dev/decoder-sec/releases"><img src="https://img.shields.io/github/v/release/decoder-dev/decoder-sec?include_prereleases" alt="Release" /></a>
</p>

## About

**decoder-sec** is a native Swift iOS app for managing proxy tunnels with a dark neon brand and Happ-compatible deep links for one-tap subscription import.

- Packet Tunnel Network Extension
- Engines via [EverywhereCore](https://github.com/NodePassProject/EverywhereCore): **Xray**, **sing-box**, **mihomo**
- OLED black + neon green UI
- `happ://add/…`, routing profiles, share-links (`vless://`, `vmess://`, …)
- IPA builds on GitHub Actions

## Identity

| | |
|---|---|
| Display name | `decoder sec.` |
| Project | `DecoderSec.xcodeproj` |
| Targets | `DecoderSec` · `DecoderSecTunnel` |
| Bundle ID | `com.decodersec.app` |
| Packet Tunnel | `com.decodersec.app.PacketTunnel` |

[BRAND.md](./BRAND.md) · [DEEPLINKS.md](./DEEPLINKS.md) · [FORK.md](./FORK.md) · [CHANGELOG.md](./CHANGELOG.md) · [Releases](./docs/RELEASES.md)

## Downloads

Prerelease IPAs: **[GitHub Releases](https://github.com/decoder-dev/decoder-sec/releases)** (unsigned — resign before install).

## Build

```bash
git clone https://github.com/decoder-dev/decoder-sec.git
cd decoder-sec
./build.sh
open DecoderSec.xcodeproj
```

```bash
./Scripts/ci_export_ipa.sh   # unsigned IPA → build/ipa/
```

## Sideload signing

Every GitHub build ships **two** unsigned IPAs:

| File | What you get | Resign needs |
|------|----------------|--------------|
| `*-lite-unsigned.ipa` | UI + configs, **no VPN** | One profile for `com.decodersec.app` |
| `*-unsigned.ipa` | Full VPN | Network Extension for app + PacketTunnel |

**Want it to open after one simple resign?** Install the **lite** IPA.

Full VPN — one command for both components (no App Groups):

```bash
./Scripts/resign_ipa.sh \
  --ipa DecoderSec-unsigned.ipa \
  --profile DecoderSec.mobileprovision \
  --identity "Apple Development: Your Name (TEAMID)"
```

With a `.p12`:

```bash
./Scripts/resign_ipa.sh \
  --ipa DecoderSec-unsigned.ipa \
  --profile DecoderSec.mobileprovision \
  --p12 cert.p12 --p12-password "$P12_PASSWORD"
```

If Apple gave you a separate extension profile, add `--tunnel-profile DecoderSecTunnel.mobileprovision`.

Lite:

```bash
./Scripts/resign_ipa.sh --lite \
  --ipa DecoderSec-lite-unsigned.ipa \
  --profile DecoderSec.mobileprovision \
  --identity "Apple Development: Your Name (TEAMID)"
```

Requires Xcode 16+ and an Apple Team with Network Extension for the IDs above. No App Group.

## License

GPLv3 — see [LICENSE](./LICENSE).

Upstream cores: Xray-core, sing-box, mihomo.  
Lineage: [NodePassProject/Everywhere](https://github.com/NodePassProject/Everywhere).
