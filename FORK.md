# decoder-sec — development notes

This repository is the **decoder sec.** product line: we keep the working client code, own the branding/UX, and evolve features for our purposes.

Upstream lineage (GPLv3): [NodePassProject/Everywhere](https://github.com/NodePassProject/Everywhere) + [EverywhereCore](https://github.com/NodePassProject/EverywhereCore).

## Done

- [x] Project rename → `DecoderSec` / `DecoderSecTunnel`
- [x] Brand pack (logo, OLED + neon, bundle / app group)
- [x] Happ-compatible deep links
- [x] IPA via GitHub Actions
- [x] EverywhereCore floor `2026.08.09` (Xray `v1.260327.0`)

## Next (own roadmap)

1. Subscription UX (node list, one-tap connect) on top of BYOC editor
2. Optional EverywhereCore fork for Xray-only / patches
3. Lite NE mode (~50 MB) + geo trimming
4. `ru` / `en` localization
5. TestFlight / signed distribution when certs exist
6. Provider portal hooks (deep links already in place)

## Layout

```
DecoderSec/           # app target
DecoderSecTunnel/     # packet tunnel appex
Shared/               # models, normalizers, deep links, brand identity
Scripts/              # wire_project.rb, ci_export_ipa.sh
ThirdParty/zashboard/ # dashboard UI bundle
```

## Env overrides

- `EVERYWHERE_CORE_REPO` — point at a forked EverywhereCore
- `EVERYWHERE_CORE_MIN_VERSION` — raise SwiftPM floor
