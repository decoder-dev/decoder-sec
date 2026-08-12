#!/usr/bin/env bash
# Fetch default geo lists (roscomvpn via jsDelivr) into ThirdParty/geo/
# for bundling into DecoderSecTunnel — same role as v2rayNG APK assets.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEO_DIR="$ROOT/ThirdParty/geo"
GEOIP_URL="${GEOIP_URL:-https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geoip/release/geoip.dat}"
GEOSITE_URL="${GEOSITE_URL:-https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/geosite.dat}"

mkdir -p "$GEO_DIR"

fetch() {
  local url="$1" dest="$2"
  echo "→ $dest"
  curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$dest"
}

fetch "$GEOSITE_URL" "$GEO_DIR/geosite.dat"
fetch "$GEOIP_URL" "$GEO_DIR/geoip.dat"
ls -lh "$GEO_DIR"
