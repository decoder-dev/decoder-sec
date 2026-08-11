# Changelog

All notable changes to **decoder sec.** are documented here.

## [Unreleased]

### Planned
- Subscription UX (node list / one-tap connect)
- `ru` / `en` localization
- Signed TestFlight builds

## [0.1.0-beta.4] — 2026-08-11

### Fixed
- Launch crash: Core Data model is built in code (repo had no `Model.xcdatamodeld`)
- Soft degrade + UI banner if storage cannot open
- PacketTunnel no longer compiles Core Data / DeepLink sources

### Added
- `Scripts/resign_ipa.sh` — one command signs app + PacketTunnel (no App Groups)
- Every CI build ships **two** IPAs: full (VPN) + **lite** (UI only, simple resign)

### Notes
- Prefer **lite** if you only need the app to open after one simple resign
- Full VPN still needs Network Extension on the profile; use `resign_ipa.sh` once

## [0.1.0-beta.3] — 2026-08-11

### Changed
- Removed App Groups entirely
- Configs live only in the app (local Core Data)
- Tunnel starts with full `configContent` via `providerConfiguration` + start options
- Packet Tunnel no longer opens Core Data

### Notes
- Resign unsigned IPA with Network Extension only — App Group not needed

## [0.1.0-beta.2] — 2026-08-11

### Fixed
- Crash on launch when App Group is missing (unsigned sideload): fall back to local Application Support + `UserDefaults.standard` instead of `fatalError`
- Soft Core Data recovery if the primary store fails to open
- Banner when running without App Group (VPN needs proper signing)

## [0.1.0-beta.1] — 2026-08-11

First public prerelease of the decoder-sec product line.

### Added
- Project rename to `DecoderSec` / `DecoderSecTunnel`
- Brand: OLED black + neon green mark, `com.decodersec.app`
- Happ-compatible deep links (`happ://add`, routing, share-links, connect)
- GitHub Actions unsigned IPA pipeline
- Docs: `BRAND.md`, `DEEPLINKS.md`, `FORK.md`

### Notes
- IPA is **unsigned** — resign with a team that has Network Extension for `com.decodersec.app` / `PacketTunnel`
- Upstream lineage: Everywhere + EverywhereCore (GPLv3)
