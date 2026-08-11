# Happ-compatible deep links

This fork registers the **`happ://`** URL scheme (plus `everywhere://` and share-link schemes) so existing Happ provider bots, QR codes, and Telegram buttons work without rewriting links.

## Supported

| Link | Behavior |
|------|----------|
| `happ://add/{https://…}` | Fetch subscription → Xray (or mihomo YAML) config → set active |
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

## Not supported (yet)

| Link | Reason |
|------|--------|
| `happ://crypt4/…` `happ://crypt5/…` | RSA keys are private to Happ; we show an explicit error |

## Examples

```text
happ://add/https://provider.example/sub/abc
happ://routing/onadd/eyJOYW1lIjoiVGVzdCJ9
happ://connect
vless://uuid@host:443?encryption=none&security=reality&pbk=…&sid=…&sni=…#Node
```

Alias: every `happ://…` form also works as `everywhere://…`.

## Code map

- `Shared/DeepLink/HappDeepLink.swift` — parser
- `Shared/DeepLink/ShareLinkToXray.swift` — share-link → Xray outbound JSON
- `Shared/DeepLink/SubscriptionImporter.swift` — HTTP subscription body
- `Shared/DeepLink/RoutingProfileStore.swift` — profile storage + Xray merge
- `Everywhere/DeepLink/DeepLinkCenter.swift` — UI orchestration
- `Everywhere/Info.plist` — URL scheme registration
