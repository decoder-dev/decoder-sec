# Releases

## Tags

| Pattern | Meaning |
|---------|---------|
| `vX.Y.Z` | Stable release |
| `vX.Y.Z-beta.N` | Prerelease |
| `vX.Y.Z-rc.N` | Release candidate |
| `vX.Y.Z-alpha.N` | Early preview |

Pushing a `v*` tag runs **Build IPA** and publishes a GitHub Release (prerelease if the tag contains `alpha` / `beta` / `rc` / `dev` / `pre`).

```bash
git tag -a v0.1.0-beta.2 -m "decoder sec. v0.1.0-beta.2"
git push origin v0.1.0-beta.2
```

## Manual prerelease

Actions → **Build IPA** → Run workflow:

- `publish_prerelease`: true  
- `prerelease_tag`: e.g. `v0.1.0-beta.3` (optional)

## Install

Unsigned IPA must be resigned (Sideloadly / AltStore / Apple cert) with:

- App ID `com.decodersec.app`
- Extension `com.decodersec.app.PacketTunnel`
- App Group `group.com.decodersec.app`
