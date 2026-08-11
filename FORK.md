# Fork roadmap

This tree is a working fork of [NodePassProject/Everywhere](https://github.com/NodePassProject/Everywhere) (GPLv3).

## Current core pin

| Component | Version |
|-----------|---------|
| EverywhereCore floor | `2026.08.09` |
| Xray-core | `v1.260327.0` (`v26.3.27`) — latest stable on Go proxy |
| sing-box | `v1.13.18` |
| mihomo | `v1.19.29` |

Upstream EverywhereCore already auto-releases when Xray/sing-box/mihomo move. This fork raises the SwiftPM floor so resolves do not land on stale May builds, and adds GitHub Actions IPA packaging.

## Implementation ideas (priority)

1. **CI IPA (done in this branch)** — `macos-15` archive → artifact; optional manual signing via secrets.
2. **Core control** — optional fork of EverywhereCore + `EVERYWHERE_CORE_REPO` override when you need patches ahead of upstream.
3. **Subscription UX** — Happ/INCY-style: paste URL / QR → node list → one-tap connect (keep raw JSON/YAML editor as power-user mode).
4. **Share-link parsers** — `vless://`, `vmess://`, `trojan://`, `ss://`, `hy2://` → Xray/sing-box outbound (reuse docs formats from INCY as a compatibility reference).
5. **Deep links** — **Happ-compatible `happ://`** (see [DEEPLINKS.md](./DEEPLINKS.md)): `add`, `routing/onadd`, share-links, connect/disconnect.
6. **NE memory profile** — iOS Network Extension ~50 MB; add “lite” routing / geo trimming toggle.
7. **Branding pack** — rename display name, icons, `PRODUCT_BUNDLE_IDENTIFIER`, app group (requires your Apple Team + NE entitlements).
8. **Xray-only slim build** (optional later) — drop mihomo/sing-box from EverywhereCore to shrink binary and attack surface.
9. **Locales** — `ru` / `en` strings for mass-market UX.
10. **TestFlight lane** — once signing secrets exist, add `method: app-store` export + upload.

## Build IPA locally (macOS)

```bash
./Scripts/ci_export_ipa.sh          # unsigned IPA in build/ipa/
SIGNING=manual DEVELOPMENT_TEAM=XXXX ./Scripts/ci_export_ipa.sh
```

## GitHub Actions

Workflow: `.github/workflows/build-ipa.yml`

- Push / PR / tag / manual dispatch → upload `Everywhere-ipa-<sha>` artifact
- Tag `v*` → attach IPA to GitHub Release
- Optional secrets: `BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`, `BUILD_PROVISION_PROFILE_BASE64`, `KEYCHAIN_PASSWORD`, `TEAM_ID`

Network Extension installs on device require a provisioning profile with the Network Extension capability — unsigned IPAs must be re-signed (Sideloadly / AltStore / your cert).

## License

GPLv3 — modifications shipped as binaries must ship corresponding source.
