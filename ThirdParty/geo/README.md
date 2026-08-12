# Bundled geo lists (roscomvpn / hydraponique via jsDelivr)

Shipped inside **DecoderSecTunnel** like v2rayNG APK assets. On first tunnel start,
`GeoResourceBootstrap.seedBundledGeoIfNeeded` copies these into the extension container
before `EvcoreStartCore`.

CI/local builds refresh via `Scripts/fetch_geo.sh` when files are missing.
