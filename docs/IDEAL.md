# Ideal roadmap — decoder sec.

Working plan to take the client from **beta** to a polished daily-driver on modern iOS.

## Platform

| Choice | Decision |
|--------|----------|
| Minimum OS | **iOS 15** (sideload compatibility) |
| Design target | **iOS 26** look & feel where APIs exist; graceful fallbacks on 17–18 |
| Distribution | Single full `DecoderSec.ipa` (ESign) → TestFlight when certs exist |

We do **not** raise the floor to iOS 26-only — that would lock out most sideload users. We *design for* 26 and ship on 15+.

## Phases

### 1 — Foundation (this sprint)
- [x] Document Ideal roadmap
- [x] Deployment target kept at iOS 15 (install compatibility)
- [x] Modern nav style where possible (with iOS 15 compatibility)
- [x] Brand tokens: expressive type, surfaces, motion (keep OLED + neon — not purple/cream AI defaults)
- [x] Home empty state + clear CTA to import / subscribe
- [x] Subscribe sheet (https + `happ://crypt…`) via SwiftUI, not UIKit-only
- [x] Xray “running” session screen (not a blank stub)
- [x] Align `MARKETING_VERSION` with git tags (`0.1.0`)

### 2 — Subscription UX (next)
- [x] Node / profile list after import (already multi-config for Xray arrays)
- [x] One-tap activate + connect from list
- [x] Pull-to-refresh subscription update
- [x] Clear HWID / “App not supported” errors in UI

### 3 — Session & ops
- [ ] In-app log console (tunnel / core)
- [ ] Latency / traffic readout when EverywhereCore exposes it
- [x] Tunnel settings: hide APNs/cellular toggles below OS that support them

### 4 — Localization & release
- [x] Finish `ru` / `en` for Settings literals
- [ ] Optional `zh-Hans` catch-up
- [ ] Signed TestFlight when Apple / ESign certs are ready

## Design north star

One composition on Home: **brand → status → Connect → active config**.  
No dashboard clutter in the first viewport. Secondary chrome (cores, dashboard toggle) stays quiet.  
Brand test: without the nav, it must still read as **decoder sec.**
