# Happ-compatible deep links

This fork registers the **`happ://`** URL scheme (plus `everywhere://`, `decodersec://`, `decoder://`, and share-link schemes) so existing Happ provider bots, QR codes, and Telegram buttons work without rewriting links.

## Supported

| Link | Behavior |
|------|----------|
| `happ://add/{https://…}` | Fetch subscription → Xray (or mihomo YAML) config → set active |
| `happ://crypt` … `happ://crypt5/…` | Decrypt locally → usually an `https://…` subscription URL → same as `add` |
| `happ://import/{vless://…}` | Import one or more share links as Xray JSON |
| `vless://` `vmess://` `trojan://` `ss://` `hy2://` … | Same as import (registered schemes) |
| `happ://routing/add/{base64}` | Add Happ routing profile JSON |
| `happ://routing/onadd/{base64}` | Add **and activate** routing; merge into active Xray config |
| `happ://routing/onadd/{https://…}` | Download routing JSON (or a nested `happ://routing/…` line) |
| `happ://routing/off` | Disable routing |
| `happ://connect` / `open` | Start tunnel with active config |
| `happ://disconnect` / `close` | Stop tunnel |
| `happ://toggle` | Toggle tunnel |
| `happ://status` | Banner with connection state |

`{base64}` is standard or URL-safe Base64 of the Happ routing JSON (see [Happ routing docs](https://www.happ.su/main/dev-docs/routing)).

Subscription URL after `add/` is **plain**, not Base64 (matches Happ + Remnawave practice).

### HWID / Remnawave panels

Many panels (Remnawave / Happ HWID device limit) reject clients that do not send:

- `User-Agent` resembling Happ
- `X-HWID` (stable device id, 10–64 chars `[a-zA-Z0-9=-]`)
- optional `x-device-os`, `x-ver-os`, `x-device-model`

Without these headers the body is often a dummy `vless://…#App%20not%20supported` node and `x-hwid-not-supported: true`. decoder sec. sends HWID on every subscription fetch (`Shared/DeepLink/DeviceIdentity.swift`).

Subscription bodies may be:

- line-oriented share links
- base64 of the above
- a JSON **array of full Xray configs** (imported as multiple profiles; first becomes active)

## Examples

```text
happ://add/https://provider.example/sub/abc
happ://crypt5/…
happ://routing/onadd/eyJOYW1lIjoiVGVzdCJ9
happ://connect
vless://uuid@host:443?encryption=none&security=reality&pbk=…&sid=…&sni=…#Node
```

Alias: every `happ://…` form also works as `everywhere://…`, `decodersec://…`, and `decoder://…`.

## Code map

- `Shared/DeepLink/HappDeepLink.swift` — parser
- `Shared/DeepLink/DeviceIdentity.swift` — HWID + subscription HTTP headers
- `Shared/DeepLink/ShareLinkToXray.swift` — share-link → Xray outbound JSON
- `Shared/DeepLink/SubscriptionImporter.swift` — HTTP subscription body
- `Shared/DeepLink/RoutingProfileStore.swift` — profile storage + Xray merge
- `DecoderSec/DeepLink/HappCryptDecryptor.swift` — crypt / crypt5 decrypt
- `DecoderSec/DeepLink/DeepLinkCenter.swift` — UI orchestration
- `DecoderSec/Info.plist` — URL scheme registration
