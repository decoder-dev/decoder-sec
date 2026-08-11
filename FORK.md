# decoder-sec — development notes

This repository is the **decoder sec.** product line: we keep the working client code, own the branding/UX, and evolve features for our purposes.

Upstream lineage (GPLv3): [NodePassProject/Everywhere](https://github.com/NodePassProject/Everywhere) + [EverywhereCore](https://github.com/NodePassProject/EverywhereCore).

## Done

- [x] Project rename → `DecoderSec` / `DecoderSecTunnel`
- [x] Brand pack (logo, OLED + neon, bundle IDs)
- [x] Happ-compatible deep links + crypt5 + HWID
- [x] IPA via GitHub Actions (single full IPA for ESign)
- [x] EverywhereCore floor `2026.08.09` (Xray `v1.260327.0`)
- [x] Russian UI (`ru`)
- [x] Ideal foundation: iOS 17+, NavigationStack, subscribe sheet, home empty state

## Ideal roadmap

See **[docs/IDEAL.md](docs/IDEAL.md)** for the full plan.

**Next up**
1. Subscription node / profile list + one-tap connect
2. In-app logs + session metrics
3. Finish Settings localization
4. TestFlight when certs exist

## Layout

```
DecoderSec/           # app target
DecoderSecTunnel/     # packet tunnel appex
Shared/               # models, normalizers, deep links, brand identity
Scripts/              # wire_project.rb, ci_export_ipa.sh
ThirdParty/zashboard/ # dashboard UI bundle
docs/IDEAL.md         # polish roadmap
```

## Env overrides

- `EVERYWHERE_CORE_REPO` — point at a forked EverywhereCore
- `EVERYWHERE_CORE_MIN_VERSION` — raise SwiftPM floor
