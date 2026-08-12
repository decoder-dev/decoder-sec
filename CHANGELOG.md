# Changelog

All notable changes to **decoder sec.** are documented here.

## [Unreleased]

## [0.1.0-beta.25] — 2026-08-12

### Fixed
- **«Connection failed before the tunnel came up»** — Packet Tunnel больше не блокирует `startTunnel` на скачивании geo (до 45s); geo strip сразу, download в фоне
- Реальная ошибка extension теперь подтягивается из **Log console** / diagnostics вместо generic-сообщения

## [0.1.0-beta.24] — 2026-08-12

### Fixed
- **Кнопка Connect не работала** — не блокируется во время connecting/disconnecting (можно отменить); geo pre-warm больше не блокирует `startVPNTunnel`
- Убрано авто-отключение VPN через 15s при «core failed» (ломало повторное подключение)
- Меньше агрессивный polling diagnostics/traffic на Home

## [0.1.0-beta.23] — 2026-08-12

### Fixed
- **CI archive failure** — `XrayNormalizer.normalize(useZashboard:)` parameter was discarded (`_`), breaking DecoderSecTunnel compile (beta.21–22)

### Added
- **Log console** (Settings → Network): ring-buffer of Packet Tunnel lifecycle events via IPC
- **Session metrics** on Home when connected: session timer + ↑/↓ traffic (Clash API when Dashboard enabled for mihomo/sing-box; Xray shows timer only — EverywhereCore has no traffic API)
- Diagnostics: session duration + traffic section
- **zh-Hans** catch-up for Settings / Diagnostics / HWID / servers strings

## [0.1.0-beta.22] — 2026-08-12

### Added
- **Выбор сервера** — список outbound-узлов в конфиге (swipe «Серверы» или sheet), выбор сохраняется и применяется при подключении
- **Device ID (HWID)** в Settings → Устройство: копирование ID для провайдера
- Статус **«Подключено (ядро не запущено)»** на Home при VPN без Xray

### Fixed
- **XrayNormalizer** — только TUN inbound + sniffing (http/tls/quic), strip geo/balancer, catch-all на proxy, `IPIfNonMatch`
- **GeoResourceBootstrap** — параллельная загрузка geoip/geosite с таймаутом 45s в extension
- **TunnelManager** — pre-warm geo, `waitForTerminalStatus`, ошибки не стираются при disconnect, auto-disconnect через 15s если core не стартовал
- **quickConnect** — корректная смена конфига без гонки disconnect/connect

### Changed
- Diagnostics, DNS, Happ routing, Tunnel settings — полная RU-локализация
- Tunnel settings: APNs (iOS 17+) и Cellular (iOS 16.4+) скрыты на неподдерживаемых версиях

## [0.1.0-beta.21] — 2026-08-12

### Fixed
- **VPN connected / Core running: no / Last error: —** — ошибка ядра больше не теряется при disconnect; явный флаг `coreStarted`; IPC всегда отдаёт текст ошибки
- Конфиги Happ с `geosite:`/`geoip:` и balancer: best-effort скачивание `.dat`, иначе **strip geo-правил** + flatten balancer → catch-all на `proxy`
- DNS: убран `localhost`/`127.0.0.1` из Xray DNS (ломал старт без локального DNS inbound)
- Diagnostics: поле **Geo rules stripped**, geo-статус по конфигу сессии

## [0.1.0-beta.20] — 2026-08-12

### Fixed
- **Tunnel timeout** — Packet Tunnel снова следует паттерну [NodePassProject/Everywhere](https://github.com/NodePassProject/Everywhere): синхронный `EvcoreStartCore`, `completionHandler(nil)` при ошибке ядра (ошибка через IPC)
- `TunnelFD` — retry + выбор последнего `utun` (sing-box/WireGuard pattern)
- **Подписки (26 failed)** — `SubscriptionURLResolver` (happwn): decrypt `happ://crypt*` при refresh; HWID headers `x-hwid-max-devices-reached` / `x-hwid-limit`; группировка ошибок bulk refresh
- Routing apply при refresh больше не валит всю подписку (`try?`)

## [0.1.0-beta.19] — 2026-08-12

### Fixed
- Таймаут «Tunnel reset after timing out» — `startTunnel` в Packet Tunnel больше не использует Swift `Task`/`MainActor` (зависал без `completionHandler`)
- Гарантированный однократный callback старта + watchdog 25s с понятной ошибкой
- Geo-загрузка переведена на blocking URLSession (стабильнее в Network Extension)

## [0.1.0-beta.18] — 2026-08-12

### Fixed
- **Core running: no** — VPN больше не показывает «connected», если Xray не стартовал; ошибка ядра возвращается в приложение
- Авто-загрузка `geoip.dat` / `geosite.dat` в Packet Tunnel при конфигах с `geoip:` / `geosite:` (файлы из Settings → Resources не видны extension без App Group)
- `XrayNormalizer`: убирает desktop-only inbounds (socks/http), `burstObservatory`, чинит DNS `localhost`, правила с несуществующим `balancerTag`
- Diagnostics: реальная ошибка ядра, статус geo-файлов, кнопка Refresh core status

## [0.1.0-beta.17] — 2026-08-12

### Added
- Встроенный экран **Diagnostics** (Settings → Network): статус туннеля, active Xray, outbound tags, proxy tag, DNS, routing rules
- Кнопки быстрого восстановления: re-apply Happ routing и reconnect VPN

## [0.1.0-beta.16] — 2026-08-12

### Fixed
- Дополнительный фикс Happ routing: catch-all правило больше не перекрывает правила провайдера
- Существующие `routing.rules` из подписки сохраняются полностью; Happ-правила добавляются безопасно
- Если в подписке уже есть свой catch-all (включая `balancerTag`), второй не добавляется

## [0.1.0-beta.15] — 2026-08-12

### Fixed
- Исправлена нестабильность сети после импорта/обновления подписки с Happ routing
- `HappRoutingApplier` больше не предполагает tag `proxy`; выбирает реальный proxy outbound из конфига
- Роутинг теперь merge-ится с существующими правилами, а не разрушительно заменяет их
- DNS секция не перезаписывается, если в подписке уже есть собственный `dns`
- При refresh/update подписок роутинг применяется повторно для Xray (когда routing enabled)

## [0.1.0-beta.14] — 2026-08-12

### Rewrite Phase 2 — зависимости и протоколы
- `EVCore.swift` разбит на три модуля: `BundleIdentifiers`, `ContainerPaths`, `AppSettingsStore`
- Введены протоколы-швы: `TunnelControlling`, `ConfigurationRepository`, `AppSettingsProviding`
- `AppEnvironment` — единая точка сборки зависимостей, заменяет прямые `.shared` во всех Views
- Views (Home, Content, Configs, Settings, Editor) переведены на `@EnvironmentObject` инжекцию
- `DecoderSecApp` применяет `AppEnvironment.modifier` на корневой сцене

## [0.1.0-beta.13] — 2026-08-12

### Changed
- Полный rewrite начат: структурная перекладка проекта по слоям (`App/Core/Features/UI`, `Shared/Domain/Persistence/Runtime`)
- Введён единый typed-контракт `TunnelConfigPayload` между приложением и PacketTunnel (без смены wire-format)
- Добавлен blueprint миграции: `docs/REWRITE_BLUEPRINT.md`

## [0.1.0-beta.12] — 2026-08-12

### Added
- Список профилей: быстрый **Connect** (кнопка в строке + swipe)
- Pull-to-refresh и массовое обновление подписок из меню

## [0.1.0-beta.11] — 2026-08-12

### Fixed
- Восстановлена совместимость установки: minimum iOS возвращён на **15.0** (beta.10 требовал iOS 17)
- UI-полировка из beta.10 сохранена, но без iOS17-only API (совместимо с iOS 15/16)

## [0.1.0-beta.10] — 2026-08-11

### Changed
- Minimum iOS **17.0**; marketing version aligned to `0.1.0`
- `NavigationStack`, modern `onChange`, ContentUnavailable empty states
- Brand type: rounded display + mono chrome; quieter neon glow; iOS 26 panel material hook
- Home empty state with **Add subscription** CTA
- Subscribe sheet (SwiftUI) for https / `happ://crypt…` / share links
- Xray running session shows brand + active config (not a blank stub)
- Settings show app version; Ideal roadmap in `docs/IDEAL.md`

## [0.1.0-beta.9] — 2026-08-11

### Fixed
- Диалог «Подписка» принимает `happ://crypt5/…` и share-ссылки (раньше только http/https)
- Загрузка подписки из этого диалога идёт через DeepLinkCenter + HWID (как deep link)

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
