# Changelog

All notable changes to **decoder sec.** are documented here.

## [Unreleased]

## [0.1.0-beta.34] — 2026-08-12

### Fixed
- **Пустая консоль логов + «не удалось до старта туннеля»** — большой Happ JSON в `startVPNTunnel(options:)` мог убивать Packet Tunnel **до** `startTunnel`. Теперь конфиг >96 KiB уходит только в VPN profile; options — lean (`usePersistedConfig`)
- **App-side ClientLogBuffer** — логи Connect видны даже если extension не запустился
- Проверка, что `configContent` сохранился после `saveToPreferences`/`loadFromPreferences`
- Settings version: **0.1.0 (34)**

## [0.1.0-beta.33] — 2026-08-12

### Root cause
- **Watchdog cleanup could block before publishing the failure.** beta.32's watchdog set `coreError`,
  then synchronously called `EvcoreStopAll` before completing the NE start. `EverywhereCore.StartCore`
  holds its singleton mutex while booting Xray; if Xray wedged in `core.StartInstance`, the watchdog's
  StopAll could block behind that mutex and leave the app with a connected tunnel but no concrete error.
- **The geo-strip retry was not fully geo-free.** Routing `geosite:`/`geoip:` tokens were stripped, but
  DNS server `domains` could still contain `geosite:` entries. Xray treats missing geo categories as a
  hard config load failure, so the retry could fail with the same class of error.

### Fixed
- Packet Tunnel now logs `startTunnel` → `prepare` → `SetResourcesPath` → `EvcoreStartCore try/result`
  with geo file presence and byte sizes.
- Every failed start writes the concrete last error to `last-core-error.txt` in the extension container;
  Diagnostics includes that persisted error and file path if in-memory state or the log ring races.
- `EvcoreStartCore` false results now record full NSError `domain`, `code`, and `userInfo` in both
  Log console and Diagnostics.
- Watchdog completion now reaches iOS before any cleanup `EvcoreStopAll` attempt, so a hung Go mutex
  cannot hide the timeout cause.
- Happ/Xray retry now strips geo tokens from both routing rules and DNS server domains, retries once
  on the first Xray failure even when the core error text is incomplete, adds a valid `direct` fallback
  outbound, and rewrites rules that point to missing outbound tags.
- Settings shows `version (build)` and the build number is bumped to `33`.

## [0.1.0-beta.32] — 2026-08-12

### Root cause (Android/v2rayNG + Xray-core research)

Studied `2dust/v2rayNG` (`V2rayConfigManager.getBalance`/`getV2rayCustomConfig`),
`2dust/AndroidLibXrayLite` (`InitCoreEnv`/`xray.location.asset`), `NodePassProject/EverywhereCore`
(`go/core.go`, `go/resources.go`, `go/xray.go`, `PATCHES.md`) and Happ's routing docs. Two concrete
gaps beta.31 missed, both matching the reported symptom (VPN connected, Core running: no, stuck on
*"Tunnel up — starting core…"* forever, no error text):

1. **`EvcoreStartCore` shared the NEProvider callback queue with `handleAppMessage`.** iOS delivers
   `startTunnel`/`handleAppMessage`/`stopTunnel`/etc. serialized on one internal queue (same reason
   WireGuardKit/Mullvad dispatch their tunnel bring-up onto a private queue). `EvcoreStartCore` is a
   synchronous cgo call into Xray; a slow or wedged start (unreachable balancer target, DNS lookup
   with no timeout) starved that queue, so `sendProviderMessage` from the app never got a reply —
   Diagnostics had nothing to show because the extension never answered, not because it had no error.
2. **Xray-core hard-fails (not hangs) when a routing/DNS rule references a geosite/geoip category the
   loaded `.dat` doesn't contain** — `infra/conf: failed to load geosite: WHITELIST-LV2 > infra/conf:
   list not found in geosite.dat: WHITELIST-LV2`. Happ ships its own curated geo files; our bundled
   roscomvpn set doesn't necessarily contain every category (e.g. `whitelist-lv2`/`whitelist-lv3`) a
   given Happ config expects. `GeoResourceBootstrap` only checked file *existence*, not category
   coverage, so `EvcoreStartCore` failed even though "geo resources: ready" showed in Diagnostics.

### Fixed
- **`PacketTunnelProvider`**: `EvcoreStartCore`/`EvcoreSetResourcesPath`/`EvcoreStopAll` now run on a
  dedicated `coreQueue`, never inline on the queue `handleAppMessage` shares — Diagnostics/logs IPC
  now always answers, even mid-hang. All state shared between that queue and IPC is lock-guarded
  (`stateLock`) instead of touched from two threads unsynchronized.
- **Geo-category hard-failure retry**: if `EvcoreStartCore` fails with an error that looks like a
  missing geosite/geoip category, automatically retries once with `stripGeoRules` forced — matches
  Xray-core's actual fail-fast behavior instead of leaving the tunnel stuck.
- **`XrayNormalizer`**: balancer flatten now resolves each `balancers[].tag` via its `selector`
  prefix list (mirrors v2rayNG `getBalance()`'s `lstSelector`) instead of collapsing every
  `balancerTag` rule onto the same outbound — a config with a "whitelist" balancer alongside the main
  "proxy" balancer (`whitelist-lv2`/`whitelist-lv3` outbounds) keeps its routing intent.
- **DNS sanitize**: stripping `localhost`/`127.0.0.1` no longer risks leaving DNS with only
  domain-scoped servers and no catch-all resolver — re-adds the default servers when nothing else
  covers unmatched domains.
- Diagnostics IPC now includes `hazards` (balancers/observatory/dns-localhost detected in the active
  config); surfaced in Diagnostics under **iOS hazards (auto-fixed before start)**.

## [0.1.0-beta.31] — 2026-08-12

### Fixed
- **Happ конфиг с balancer + DNS localhost** — по Diagnostics: balancer=да, catch-all=нет, DNS=`localhost`. Android (v2rayNG) держит observatory **вместе** с balancer; beta.30 minimal убирал observatory и оставлял balancer → ядро зависало/не стартовало
- Всегда **ios-safe normalize**: flatten balancer → `proxy`, strip DNS localhost, catch-all, TUN sniffing
- Watchdog 12s на `EvcoreStartCore` + понятная ошибка вместо «Tunnel up — starting core…»

### Analysis (Android → iOS)
| Нужно | Android | decoder sec. beta.31 |
|-------|---------|----------------------|
| Geo в bundle | APK assets | `ThirdParty/geo/` в appex |
| Balancer | + observatory | flatten (observatory в NE ненадёжен) |
| DNS localhost | desktop OK | strip |
| Catch-all | в шаблоне | всегда добавляем |

## [0.1.0-beta.30] — 2026-08-12

### Fixed
- **Ядро не стартует (Happ/v2ray конфиги)** — dual-start как Android/libv2ray: сначала minimal normalize (Everywhere-паттерн), затем hardened fallback
- `EvcoreStopAll` перед стартом; лог `EvcoreStartCore try minimal/hardened`
- Убрано удаление catch-all routing rules в hardened normalize
- Diagnostics/IPC: ошибка ядра из Log console, если IPC generic

### Changed
- `XrayNormalizer.prepareForTunnel` — minimal (TUN + log) vs hardened (DNS/routing/geo strip)

## [0.1.0-beta.29] — 2026-08-12

### Added
- **Bundled geo в Packet Tunnel** (паттерн v2rayNG/Happ): `ThirdParty/geo/` → seed в extension container до `EvcoreStartCore`
- `Scripts/fetch_geo.sh` — roscomvpn geo для CI/local build

### Fixed
- **XrayNormalizer** — strip geo для `domain`/`ip` как string (Happ routing rules)
- Ядро должно стартовать с geosite/geoip без ожидания CDN на первом connect

## [0.1.0-beta.28] — 2026-08-12

### Changed
- Geo по умолчанию: `hydraponique/roscomvpn` через jsDelivr (`geoip.dat` ~411 KB, `geosite.dat` ~66 KB) вместо Loyalsoldier

## [0.1.0-beta.27] — 2026-08-12

### Fixed
- **Ядро не стартует при geosite/geoip** — регрессия beta.26: geo-детекция снова находит правила (string/array в rules, DNS domains, substring fallback); strip срабатывает без .dat
- Diagnostics: geo-строки только из extension IPC (без ложного «нужен geo» из app-конфига)
- Реальная ошибка EvcoreStartCore подтягивается из Log console, если IPC отдаёт generic «Core is not running»
- Auto-reconnect после фоновой загрузки geo, когда правила были stripped

## [0.1.0-beta.26] — 2026-08-12

### Added
- **`docs/TUNNEL_SCHEME.md`** — полная схема app ↔ Packet Tunnel (mermaid, IPC, geo, приоритеты P0–P2)
- **`TunnelLifecyclePhase`** — явная машина состояний поверх `NEVPNStatus` + core IPC
- **`TunnelConfigPayload.validateSize()`** — лимит 512 KiB до сохранения VPN-профиля

### Fixed
- Убран бесполезный geo pre-warm в host app (sandbox приложения ≠ extension)
- Geo detection по `routing.rules`, а не substring по всему JSON
- Settings → Resources: пояснение про разные контейнеры app / NE

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
