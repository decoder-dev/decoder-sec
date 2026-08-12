# decoder sec. — rewrite blueprint

Implementation-ready plan for restructuring `DecoderSec` cleanly while
preserving every working feature: installability, tunnel connect,
subscriptions, Happ-compatible deep links (`crypt5`, HWID), routing,
Settings, and the release scripts. This is a **structural** rewrite, not a
feature rewrite — behavior and wire formats are preserved at every step.

## 0. Ground truth (read before touching anything)

- **No Xcode/Swift toolchain in this environment.** Every step below is
  designed to be reviewed as a diff and verified by the existing macOS CI
  (`.github/workflows/build-ipa.yml`, triggers on any `cursor/**` push) and a
  local `./build.sh --build-app` simulator smoke build. Don't merge a step
  whose CI run is red.
- **The project already uses Xcode 16 synchronized groups**
  (`PBXFileSystemSynchronizedRootGroup`) for `DecoderSec/`, `DecoderSecTunnel/`,
  and `Shared/` (see `DecoderSec.xcodeproj/project.pbxproj` and
  `Scripts/wire_project.rb`). Practical consequence: **moving/renaming files
  inside these three roots requires zero `.pbxproj` edits** — Xcode
  auto-discovers anything on disk under a synced root. This is what makes
  most of the migration below low-risk `git mv`, not risky project surgery.
  Only *new top-level roots* (e.g. a local SwiftPM package) need project
  edits — those are pushed to the end of the plan, after the payoff is
  already visible.
- **Git history is the regression map.** Recent branches
  (`fix-installable-ipa`, `fix-ipa-packaging`, `one-sign-crash-fix`,
  `install-compat-fix`, `fix-beta10/11-build`) show the actual fragility:
  IPA packaging (static `.a` embedded as a framework), launch-time Core Data
  init ordering, and iOS 15 SwiftUI API availability. The rewrite must not
  re-open any of these; see the constraints in §3 and the checklist in §5.
- **No App Groups.** The extension gets the whole config via
  `NETunnelProviderProtocol.providerConfiguration` / `startVPNTunnel(options:)`.
  Keep it that way — do not introduce a shared container as a "cleanup."

## 1. Current shape (what exists today)

```
DecoderSec/                      # app target (sync root)
  DecoderSecApp.swift             # @main, wires DeepLinkCenter
  ContentView.swift               # root switch: TabView vs "running" screen
  Core/AppState.swift             # settings singleton (Always-On, DNS, tunnel opts, zashboard)
  Core/ConfigurationStore.swift   # Core Data-backed config CRUD + "active per core"
  Core/Brand.swift                # design tokens
  TunnelManager.swift             # NETunnelProviderManager lifecycle singleton
  DeepLink/DeepLinkCenter.swift   # UI-facing deep-link orchestration
  DeepLink/HappCryptDecryptor.swift
  DeepLink/crypt5-keys.json, crypt-legacy-keys.json
  Home/, Configurations/, Settings/, Dashboard/, Editor/, Components/
Shared/                          # sync root, compiled into BOTH targets
  Configuration.swift             # NSManagedObject
  CoreType.swift
  EVCore.swift                    # bundle-id resolution + paths + UserDefaults (3 concerns in 1 enum)
  PersistenceController.swift     # manual NSManagedObjectModel (no .xcdatamodeld)
  BrandIdentity.swift, ExampleConfigs.swift
  Normalizer/                     # per-core config normalization (pure)
  DeepLink/HappDeepLink.swift, DeviceIdentity.swift, ShareLinkToXray.swift,
            SubscriptionImporter.swift, RoutingProfileStore.swift   # pure parsing/HTTP, no UI
DecoderSecTunnel/                 # NE appex target (sync root)
  PacketTunnelProvider.swift, TunnelFD.swift
Scripts/                          # wire_project.rb, ci_export_ipa.sh, resign_ipa.sh
```

Everything is reachable via `.shared` singletons (`AppState`, `ConfigurationStore`,
`TunnelManager`, `RoutingProfileStore`, `DeepLinkCenter`) with no protocol
seams, so nothing is unit-testable in isolation and every SwiftUI view reaches
across the whole app through a global. That's the core "cleanliness" problem
to fix — not the features, which work.

## 2. Target structure

Everything stays inside the same three synced roots (no target/pbxproj churn
for phases 1–4). New subfolders are created purely by `git mv`.

```
DecoderSec/
  App/
    DecoderSecApp.swift
    ContentView.swift
    AppEnvironment.swift          # NEW — builds the singletons once, exposes them
                                   #        as `.environmentObject` / `.environment(\.*)`
  Core/
    Brand.swift
    TunnelManager.swift            # moved from DecoderSec/TunnelManager.swift
    ConfigurationStore.swift
    AppSettingsState.swift         # renamed from AppState.swift (phase 2)
    Protocols/
      TunnelControlling.swift      # NEW protocol TunnelManager conforms to
      ConfigurationRepository.swift
      AppSettingsProviding.swift
  Features/
    Home/HomeView.swift
    Configurations/ConfigurationsView.swift, SubscribeSheet.swift
    Settings/*View.swift, ResourcesStore.swift
    Dashboard/DashboardView.swift, FloatingMenuButton.swift
    Editor/ConfigEditorScreen.swift, ConfigEditorView.swift
  DeepLink/
    DeepLinkCenter.swift
    HappCryptDecryptor.swift
    crypt5-keys.json, crypt-legacy-keys.json
  UI/Components/
    NameInputAlert.swift, URLInputAlert.swift

Shared/
  Domain/
    CoreType.swift
    Configuration.swift            # NSManagedObject — left as-is (see §4, Phase 4 risk note)
  Persistence/
    PersistenceController.swift
  Runtime/
    BundleIdentifiers.swift        # split out of EVCore.swift: Identifier enum
    ContainerPaths.swift           # split out of EVCore.swift: containerURL/resourcesURL
    AppSettingsStore.swift         # split out of EVCore.swift: typed UserDefaults wrapper
  Tunnel/
    TunnelConfigPayload.swift      # NEW — single typed contract app <-> extension (Slice 1, §4)
  DeepLink/
    HappDeepLink.swift, DeviceIdentity.swift, ShareLinkToXray.swift,
    SubscriptionImporter.swift, RoutingProfileStore.swift
  Normalizer/
    ConfigNormalizer.swift, XrayNormalizer.swift, SingBoxNormalizer.swift, MihomoNormalizer.swift
  BrandIdentity.swift, ExampleConfigs.swift

DecoderSecTunnel/
  PacketTunnelProvider.swift       # slims down once it consumes TunnelConfigPayload
  TunnelFD.swift
```

Later, optional (only after phases 1–4 are merged and stable): promote
`Shared/Domain`, `Shared/Normalizer`, `Shared/DeepLink` (the parts with zero
CoreData/UIKit/SwiftUI dependencies) into a real local SwiftPM package
(`Packages/DecoderSecKit`) for a real unit-test target. This is the only step
that touches `project.pbxproj` beyond what `wire_project.rb` already
automates, so it is deliberately last — see §4 Phase 5.

## 3. Compatibility constraints (non-negotiable)

- **`IPHONEOS_DEPLOYMENT_TARGET` stays `15.0`.** Enforced today by
  `Scripts/wire_project.rb` (`DEPLOYMENT_TARGET = '15.0'`, re-applied on every
  `./build.sh` run) — don't remove that reassertion, and don't let an Xcode
  UI edit silently bump it. `EverywhereCore`'s `Package.swift` requires
  `.iOS(.v15)`, so 15 is also the SwiftPM floor, not just our choice.
- **Every iOS 16+ / 17+ API must be availability-guarded**, following the
  patterns already in the codebase:
  - `if #available(iOS 16.4, *) { proto.excludeCellularServices = ... }`
    (`DecoderSec/TunnelManager.swift`)
  - `if #available(iOS 17.0, *) { proto.excludeAPNs = ... }` (same file)
  - `HideScrollBackgroundIfAvailable` wrapping `.scrollContentBackground(.hidden)`
    (`DecoderSec/Settings/SettingsView.swift`)
  - `NavigationView` + `.navigationViewStyle(.stack)` is used deliberately
    instead of `NavigationStack` (iOS 16+) in `HomeView`/`SettingsView`. Any
    new screen must either match this or be gated.
  - New code review rule: **grep the diff for `#available` whenever a new
    SwiftUI modifier or `NE*` symbol is introduced**; if the symbol's
    availability floor is above 15.0, it must be guarded or given an
    iOS-15-safe fallback branch, not just an early return.
- **No static analyzer for this today** — add a lightweight CI grep step
  (`rg` over the diff for common iOS16+-only symbols like
  `NavigationStack`, `NavigationSplitView`, `.scrollContentBackground`,
  `ImageRenderer`, `ContentUnavailableView`) as a follow-up; out of scope for
  the first slice but worth a ticket.
- **Keep the "no App Groups" invariant.** The tunnel config contract
  (`TunnelConfigPayload`, §4) must keep going through
  `providerConfiguration` / `startVPNTunnel(options:)`, never a shared
  container.
- **Don't touch the manual `NSManagedObjectModel` casually.**
  `PersistenceController.makeManagedObjectModel()` hand-builds the model
  because there's no `.xcdatamodeld`; `entity.managedObjectClassName` must
  stay `"Configuration"` with no module prefix (see the comment in that file
  and in `PATCHES.md`). If `Configuration.swift` ever moves into a different
  module (e.g. a future SwiftPM package), this string has to become
  `"ModuleName.Configuration"` or the store fails to load at runtime with no
  compile-time warning — treat any such move as its own reviewed, tested
  step, never bundled with an unrelated refactor.
- **IPA packaging invariants** (`Scripts/ci_export_ipa.sh`) are load-bearing,
  not incidental: stripping `Frameworks/EverywhereCore.framework` (static
  `.a` masquerading as a framework breaks install), ad-hoc signing order
  (dylibs → frameworks → appex → app), and `MinimumOSVersion` repair for
  gomobile-produced nested `Info.plist`s. The rewrite must not change target
  names (`DecoderSec`, `DecoderSecTunnel`), bundle IDs
  (`com.decodersec.app`, `com.decodersec.app.PacketTunnel`), or the
  Payload layout these scripts pattern-match on, without updating the
  scripts in the same PR.

## 4. Migration sequence

Each phase is its own PR/branch, in this order, so risk stays isolated and
bisectable. Every phase ends with the full acceptance checklist in §5 before
moving to the next.

### Phase 0 — Safety net (no code changes)
1. `git tag pre-rewrite-baseline` on current `main` (already `v0.1.0-beta.12`
   per `CHANGELOG.md`) and push the tag, so there's a hard rollback point.
2. Confirm a green `./build.sh --build-app` simulator smoke build and a green
   `build-ipa.yml` run on `main` right now, before any rewrite branch lands —
   this is the control to diff every later phase against.
3. Freeze net-new features on `main`; land only rewrite-structural PRs until
   Phase 4 is merged, to avoid rebasing structural moves against feature
   drift.

### Phase 1 — Pure regrouping (zero logic changes)
`git mv` only, matching the tree in §2. No renamed symbols, no changed
imports beyond what the compiler needs for the new relative paths (which is
none — Swift doesn't care about file location within a target). Example
moves:

```
git mv DecoderSec/DecoderSecApp.swift DecoderSec/App/DecoderSecApp.swift
git mv DecoderSec/ContentView.swift   DecoderSec/App/ContentView.swift
git mv DecoderSec/TunnelManager.swift DecoderSec/Core/TunnelManager.swift
git mv DecoderSec/Home          DecoderSec/Features/Home
git mv DecoderSec/Configurations DecoderSec/Features/Configurations
git mv DecoderSec/Settings       DecoderSec/Features/Settings
git mv DecoderSec/Dashboard      DecoderSec/Features/Dashboard
git mv DecoderSec/Editor         DecoderSec/Features/Editor
git mv DecoderSec/Components     DecoderSec/UI/Components
```
Acceptance: `git diff --stat` shows only renames; `./build.sh --build-app`
green; app launches in Simulator, all five tabs/screens open.

### Phase 2 — Split the god objects (behavior-preserving)
1. Split `Shared/EVCore.swift` into `Shared/Runtime/BundleIdentifiers.swift`
   (the `Identifier` enum), `Shared/Runtime/ContainerPaths.swift`
   (`containerURL`, `resourcesURL(for:)`), and
   `Shared/Runtime/AppSettingsStore.swift` (the `UserDefaults` get/set pairs).
   Keep every `UserDefaults` key string byte-identical (`"decoder.dnsServers"`
   etc.) — this is on-disk state for real installs, not a fresh schema.
2. Rename `DecoderSec/Core/AppState.swift` → `AppSettingsState.swift`
   (class name can stay `AppState` for now — rename the type in a follow-up
   once call sites are inventoried, to keep this PR's diff small).
3. Introduce `Core/Protocols/{TunnelControlling,ConfigurationRepository,
   AppSettingsProviding}.swift` and make `TunnelManager`, `ConfigurationStore`,
   `AppState` conform. No behavior change — this only adds seams for Phase 3.

Acceptance: same as Phase 1, plus confirm Settings screen round-trips every
toggle (Always On, DNS, tunnel network options, zashboard) after relaunch
(UserDefaults keys unchanged).

### Phase 3 — Replace `.shared` access with injected dependencies, feature by feature
Order (lowest → highest blast radius): **Dashboard → Editor → Settings →
Configurations → Home → DeepLink**. Each is its own PR:
1. `AppEnvironment.swift` (new, in `DecoderSec/App/`) constructs the existing
   singletons once in `DecoderSecApp.init()` and injects them via
   `.environmentObject`. Views switch from
   `@ObservedObject private var tunnel = TunnelManager.shared` to
   `@EnvironmentObject private var tunnel: TunnelManager` one feature at a
   time; `TunnelManager.shared` keeps existing as the single call site inside
   `AppEnvironment` until every feature is migrated, then gets removed.
2. `DeepLinkCenter` currently reaches `ConfigurationStore.shared`,
   `TunnelManager.shared`, `RoutingProfileStore.shared` directly in its
   initializer — convert those to injected `let` constants passed into a
   non-singleton initializer, and construct the single instance in
   `AppEnvironment` alongside the others.

Acceptance per PR: the one migrated tab/screen exercises identically
(manual pass through §5's relevant rows); other tabs untouched in the diff.

### Phase 4 — Persistence seam (careful, low-touch)
Wrap the existing Core Data code behind `ConfigurationRepository` from Phase
2 (`CoreDataConfigurationRepository`), but **do not touch
`PersistenceController.makeManagedObjectModel()` or the `Configuration`
entity/class wiring** — see the hard constraint in §3. This phase only adds
an interface in front of unchanged internals, enabling a fake/in-memory
repository for future unit tests without touching the real store logic that
three past hotfix branches (`Fix launch crash`, `Fix PersistenceController
init capture before initialization`) already had to fix.

### Phase 5 — Optional: promote pure Shared/ code to a local SwiftPM package
Only after Phases 1–4 are merged and a release has gone out clean. Candidates
with zero CoreData/UIKit/SwiftUI/NetworkExtension imports:
`Shared/Domain/CoreType.swift`, `Shared/Normalizer/*`,
`Shared/DeepLink/HappDeepLink.swift`, `ShareLinkToXray.swift`,
`SubscriptionImporter.swift`. This is the first step that needs real
`.pbxproj` surgery (`Scripts/wire_project.rb`-style, via the `xcodeproj` gem)
to add a local package reference and link it into both targets, and the
first step that gets an `XCTest` target for pure-logic unit tests
(deep-link grammar, normalizers, share-link parsing). Do not fold this into
an earlier phase — it's the only phase where a mistake needs an Xcode GUI or
careful `xcodeproj` scripting to unwind.

## 5. First large implementation slice (today) — implemented in this PR

**Typed tunnel-config contract.** Today the app ↔ extension config handoff
is two independently hand-rolled `[String: Any]` / `[String: NSObject]`
dictionaries with 5 stringly-typed keys, built in
`DecoderSec/TunnelManager.swift` (`setEnabled`, `ensureManager`) and read
back with a 4-line `options?[...] ?? providerConfig[...] ?? default` chain
per field in `DecoderSecTunnel/PacketTunnelProvider.swift`. That duplication
is exactly the shape of bug that produced past hotfixes — a key typo or a
missed field on one side silently breaks the extension with no compiler
help. It's also self-contained (`Shared/`, already compiled into both
targets — zero `.pbxproj` changes) and has a byte-identical wire format
requirement (existing `NETunnelProviderManager` entries persisted on real
devices must keep decoding).

Files touched:

- **New** `Shared/Tunnel/TunnelConfigPayload.swift` — single struct
  `TunnelConfigPayload { configContent, configID, coreType, dnsServers,
  useZashboard }` with `asStartOptions: [String: NSObject]`,
  `asProviderConfiguration: [String: Any]`, and
  `static func decode(options:providerConfiguration:) -> TunnelConfigPayload?`
  that reproduces the exact current fallback order and defaults (including
  DNS cleanup/defaulting, previously `PacketTunnelProvider.cleanDNS`).
- **Changed** `DecoderSec/TunnelManager.swift` — `setEnabled` and
  `ensureManager` build a `TunnelConfigPayload` and use
  `.asStartOptions` / `.asProviderConfiguration` instead of inline dicts.
- **Changed** `DecoderSecTunnel/PacketTunnelProvider.swift` —
  `startTunnel(options:completionHandler:)` decodes one
  `TunnelConfigPayload` instead of 5 separate inline lookups; the
  now-unused private `cleanDNS` is removed (moved into the payload type).

No dictionary keys, types, or fallback semantics changed — this is a
type-safety refactor, not a protocol change. It also establishes the pattern
Phase 2/3 protocol seams will follow (one small typed contract per boundary,
introduced without moving or renaming anything else in the same PR).

Verified: pushing this slice to `cursor/rewrite-blueprint-7e20` triggered
`build-ipa.yml` on a macOS GitHub Actions runner — the `macOS IPA` job
(`./build.sh` + archive + unsigned IPA export/validation for both
`DecoderSec` and `DecoderSecTunnel`) completed green, confirming the app
target and the Packet Tunnel extension target both compile against the new
`Shared/Tunnel/TunnelConfigPayload.swift` and the resulting `.ipa` still
passes `ci_export_ipa.sh`'s installability checks (appex present, no static
`EverywhereCore.framework` embed, ad-hoc signature applied).

## 6. Acceptance checklist before tagging any release cut during/after the rewrite

Run this in full before cutting a tag (`vX.Y.Z` / `vX.Y.Z-beta.N`), and after
every migration phase above as a smoke pass:

- [ ] `./build.sh --build-app` (simulator, `CODE_SIGNING_ALLOWED=NO`) is green.
- [ ] `BOTH=0 LITE=0 ./Scripts/ci_export_ipa.sh` produces
      `build/ipa/DecoderSec-unsigned.ipa`; unzip and confirm
      `Payload/DecoderSec.app/PlugIns/DecoderSecTunnel.appex` exists and
      `Frameworks/EverywhereCore.framework` does **not**.
- [ ] `build-ipa.yml` GitHub Actions run on the branch is green
      (`gh run list --branch <branch>`).
- [ ] Fresh install (no prior app data): app launches, first-run seed configs
      (Xray/sing-box/mihomo) appear, no Core Data crash on first launch.
- [ ] Connect flow: pick a config → Connect → `TunnelManager.status` reaches
      `.connected` → running-screen shows the active config name → Disconnect
      returns to tabs.
- [ ] On-demand / Always On: toggle on, background-kill the app, confirm
      reconnect-on-network-change still works; toggle off, confirm on-demand
      rule is removed (`m.isOnDemandEnabled == false`).
- [ ] Deep links, one per family, via `xcrun simctl openurl booted <url>` or
      device Safari:
  - [ ] `happ://add/https://…` — subscription import, correct core detected
        (`proxies:` → mihomo, else Xray), HWID headers sent
        (`Shared/DeepLink/DeviceIdentity.swift`).
  - [ ] `happ://crypt5/…` — decrypts via `HappCryptDecryptor`, resolves to a
        subscription URL or share-link and imports it.
  - [ ] `vless://…` (bare share-link scheme) — direct import via
        `ShareLinkToXray`.
  - [ ] `happ://routing/onadd/{base64}` — routing profile activates and
        merges into the active Xray config (`HappRoutingApplier`).
  - [ ] `happ://connect` / `happ://disconnect` / `happ://toggle` /
        `happ://status` — tunnel control + banner text.
  - [ ] Alias schemes `everywhere://`, `decodersec://`, `decoder://` resolve
        identically to `happ://` for at least one case above.
- [ ] Settings round-trip: Always On, DNS servers, tunnel network options
      (all-networks / local-networks / APNs / cellular — respecting the
      `#available` guards), zashboard toggle — each persists across relaunch.
- [ ] Routing off (`happ://routing/off`) disables routing and a reconnect no
      longer injects routing rules into the Xray config.
- [ ] iOS 15 device or 15.x simulator smoke pass — this is the actual install
      floor for sideload users, not just a CI setting. At minimum: launch,
      Connect, one deep link, Settings toggle.
- [ ] Resign flow: `Scripts/resign_ipa.sh --ipa … --profile … --identity …`
      against the produced unsigned IPA succeeds and the resigned app
      installs on a real device via Sideloadly/AltStore/ESign.
- [ ] `CHANGELOG.md` updated; tag matches `docs/RELEASES.md` pattern
      (`vX.Y.Z` stable / `vX.Y.Z-beta.N` prerelease).
