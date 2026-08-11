# Install

## Pick an IPA

| Asset | Use when |
|-------|----------|
| `DecoderSec-*-lite-unsigned.ipa` | You want the app to **open after one simple resign** (configs / deep links; no VPN) |
| `DecoderSec-*-unsigned.ipa` | You need real VPN (Packet Tunnel) |

## One-command resign

```bash
# Lite (simplest)
./Scripts/resign_ipa.sh --lite \
  --ipa DecoderSec-vX.Y.Z-lite-unsigned.ipa \
  --profile App.mobileprovision \
  --identity "Apple Development: You (TEAMID)"

# Full VPN (app + extension in one step, no App Group)
./Scripts/resign_ipa.sh \
  --ipa DecoderSec-vX.Y.Z-unsigned.ipa \
  --profile App.mobileprovision \
  --identity "Apple Development: You (TEAMID)"
```

If iOS requires a separate extension profile:

```bash
./Scripts/resign_ipa.sh \
  --ipa DecoderSec-vX.Y.Z-unsigned.ipa \
  --profile App.mobileprovision \
  --tunnel-profile Tunnel.mobileprovision \
  --identity "Apple Development: You (TEAMID)"
```

Full VPN needs Network Extension (packet-tunnel) on the profile(s). No App Group.

## Tags

| Pattern | Meaning |
|---------|---------|
| `vX.Y.Z` | Stable release |
| `vX.Y.Z-beta.N` | Prerelease |
| `vX.Y.Z-rc.N` | Release candidate |
| `vX.Y.Z-alpha.N` | Early preview |

Pushing a `v*` tag runs **Build IPA** and publishes a GitHub Release (prerelease if the tag contains `alpha` / `beta` / `rc` / `dev` / `pre`). Each release includes **both** full and lite unsigned IPAs.

```bash
git tag -a v0.1.0-beta.5 -m "decoder sec. v0.1.0-beta.5"
git push origin v0.1.0-beta.5
```

If an older IPA “cannot unpack” in Sideloadly / 3uTools: use **beta.5+** (packaged with `ditto --norsrc` and a real EverywhereCore binary).
## Manual prerelease

Actions → **Build IPA** → Run workflow with `publish_prerelease: true`.
