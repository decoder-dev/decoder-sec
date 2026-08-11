# Changelog

All notable changes to **decoder sec.** are documented here.

## [Unreleased]

### Planned
- Subscription UX (node list / one-tap connect)
- Signed TestFlight builds

## [0.1.0-beta.8] — 2026-08-11

### Added
- Русская локализация (`ru`) для UI
- Расшифровка `happ://crypt` … `happ://crypt5` и импорт подписки из расшифрованного URL
- Заголовки Happ/Remnawave HWID (`X-HWID`, `User-Agent`, device meta) при загрузке подписки
- Импорт JSON-массива полных Xray-конфигов (несколько профилей из одной подписки)

### Notes
- Ссылка `happ://crypt5/…` расшифровывается локально → `https://…` URL подписки
- Без `X-HWID` многие панели отдают заглушку «App not supported» — теперь заголовок отправляется автоматически

## [0.1.0-beta.7] — 2026-08-11

### Changed
- **Один файл:** релиз публикует только полный `DecoderSec.ipa` (app + PacketTunnel) для ESign
- Tunnel bundle ID читается из встроенного `.appex` — переживает ремап Bundle ID в ESign
- `NSExtensionPrincipalClass` = `PacketTunnelProvider` (`@objc`) без имени модуля

### Notes
- ESign: один импорт → одна подпись (серт с Network Extension) → установка → конфиг → Connect

## [0.1.0-beta.6] — 2026-08-11

### Fixed
- **Install failure:** EverywhereCore is a static `.a` — embedding it as `Frameworks/*.framework` made iOS reject the IPA. Removed from the bundle (Evcore is already linked into `DecoderSecTunnel`)
- Ad-hoc `codesign` on app + appex so Sideloadly / device install tools accept the package
- CI validates: no static-lib framework binary, `Payload/*.app` structure, signature present

## [0.1.0-beta.5] — 2026-08-11

### Fixed
- IPA packaging: `zip -r -X` with validated `Payload/*.app` root (Sideloadly / 3uTools can unpack)
- Replace Xcode's ~33KB EverywhereCore **stub** with the real SPM ios-arm64 framework (~120MB) before packing
- Strip `AppIcon.icon` source bundle from the IPA (runtime uses Assets.car)
- CI refuses to publish if EverywhereCore is still a stub or the IPA fails `unzip -t` / structure checks

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
