#!/usr/bin/env bash
# Archive DecoderSec and produce installable .ipa file(s) for GitHub Actions / local CI.
#
# Modes:
#   SIGNING=unsigned   — archive unsigned, then ad-hoc codesign + zip Payload → .ipa
#   SIGNING=manual     — use cert/profile already installed in the keychain
#   BOTH=1 (default)   — emit full VPN IPA + Lite (no PacketTunnel) from one archive
#   LITE=1             — Lite only (UI / config browsing)
#   LITE=0 BOTH=0      — full VPN IPA only
#
# Why we strip EverywhereCore.framework from the IPA:
#   Upstream EverywhereCore is a *static* .a wrapped as a .framework. Xcode links
#   Evcore* into DecoderSecTunnel (and the app) at build time. Embedding that .a
#   as Frameworks/EverywhereCore.framework/EverywhereCore makes iOS refuse install
#   ("invalid framework binary"). The tiny Xcode "codeless stub" is also useless
#   at runtime when everything is already statically linked. So we delete it.
#
# Env:
#   CONFIGURATION   Debug|Release (default Release)
#   DERIVED_DATA    path (default ./DerivedData)
#   ARCHIVE_PATH    path (default ./build/DecoderSec.xcarchive)
#   IPA_DIR         path (default ./build/ipa)
#   EXPORT_OPTIONS  plist path (default Config/ExportOptions-ad-hoc.plist)
#   DEVELOPMENT_TEAM optional Apple Team ID override
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/DerivedData}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT/build/DecoderSec.xcarchive}"
IPA_DIR="${IPA_DIR:-$ROOT/build/ipa}"
SIGNING="${SIGNING:-unsigned}"
EXPORT_OPTIONS="${EXPORT_OPTIONS:-$ROOT/Config/ExportOptions-ad-hoc.plist}"
LITE="${LITE:-0}"
BOTH="${BOTH:-0}"

APP_ENTITLEMENTS="$ROOT/DecoderSec/DecoderSec.entitlements"
TUNNEL_ENTITLEMENTS="$ROOT/DecoderSecTunnel/DecoderSecTunnel.entitlements"

mkdir -p "$(dirname "$ARCHIVE_PATH")" "$IPA_DIR" "$DERIVED_DATA"
rm -f "$IPA_DIR"/*.ipa

echo "→ wire SwiftPM deps"
./build.sh

COMMON=(
  -project DecoderSec.xcodeproj
  -scheme DecoderSec
  -configuration "$CONFIGURATION"
  -destination 'generic/platform=iOS'
  -archivePath "$ARCHIVE_PATH"
  -derivedDataPath "$DERIVED_DATA"
)
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  COMMON+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
fi

case "$(printf '%s' "$LITE" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|lite) IS_LITE=1 ;;
  *) IS_LITE=0 ;;
esac
case "$(printf '%s' "$BOTH" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|both) IS_BOTH=1 ;;
  *) IS_BOTH=0 ;;
esac

if [[ "$IS_LITE" == "1" ]]; then
  IS_BOTH=0
fi

if [[ ("$IS_LITE" == "1" || "$IS_BOTH" == "1") && "$SIGNING" != "unsigned" ]]; then
  echo "error: Lite / BOTH variants are only supported for unsigned exports; resign afterwards." >&2
  exit 1
fi

echo "→ archive ($CONFIGURATION, signing=$SIGNING, lite=$IS_LITE, both=$IS_BOTH)"
if [[ "$SIGNING" == "unsigned" ]]; then
  xcodebuild "${COMMON[@]}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    archive
else
  xcodebuild "${COMMON[@]}" archive

  echo "→ export IPA via $EXPORT_OPTIONS"
  xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$IPA_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS"
  echo "✓ IPA at $IPA_DIR"
  ls -la "$IPA_DIR"
  exit 0
fi

# Unsigned path: pack .app into Payload → .ipa
APP_PATH="$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 1 -name '*.app' | head -n1)"
if [[ -z "$APP_PATH" ]]; then
  echo "error: no .app inside $ARCHIVE_PATH/Products/Applications" >&2
  exit 1
fi

is_macho_dylib() {
  local bin="$1"
  [[ -f "$bin" ]] || return 1
  local info
  info="$(file -b "$bin" 2>/dev/null || true)"
  # Reject static .a wrapped as "framework" binary — iOS will not install it.
  if grep -qi 'ar archive' <<<"$info"; then
    return 1
  fi
  grep -qiE 'Mach-O|dynamically linked shared library|dylib' <<<"$info"
}

repair_app_bundle() {
  local app="$1"

  # Drop Xcode source icon bundle — runtime uses Assets.car / PNG icons.
  rm -rf "$app/AppIcon.icon"

  # EverywhereCore is a static library. Embedding it (or Xcode's stub) as a
  # Frameworks/*.framework binary breaks or confuses installers. Evcore is
  # already linked into DecoderSecTunnel; remove the embed.
  if [[ -d "$app/Frameworks/EverywhereCore.framework" ]]; then
    echo "→ removing static/stub EverywhereCore.framework (linked into binaries at build time)"
    rm -rf "$app/Frameworks/EverywhereCore.framework"
  fi
  # Clean empty Frameworks dir
  if [[ -d "$app/Frameworks" ]] && [[ -z "$(ls -A "$app/Frameworks" 2>/dev/null || true)" ]]; then
    rmdir "$app/Frameworks" || true
  fi

  # Fix any remaining framework Info.plist MinimumOSVersion=100.0 (gomobile artifact)
  while IFS= read -r -d '' plist; do
    if command -v plutil >/dev/null 2>&1; then
      local min
      min="$(plutil -extract MinimumOSVersion raw "$plist" 2>/dev/null || true)"
      if [[ "$min" == "100.0" || "$min" == "100" ]]; then
        plutil -replace MinimumOSVersion -string "15.0" "$plist"
        echo "→ fixed MinimumOSVersion in $plist"
      fi
    fi
  done < <(find "$app" -name 'Info.plist' -print0)

  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$app" 2>/dev/null || true
  fi
}

adhoc_sign_bundle() {
  local app="$1"
  if ! command -v codesign >/dev/null 2>&1; then
    echo "error: codesign missing — cannot produce installable IPA on this host" >&2
    exit 1
  fi

  echo "→ ad-hoc codesign WITHOUT entitlements (ESign/Sideloadly inject from the provisioning profile)"

  # Nested Mach-O first: dylibs, then frameworks, then appex, then app.
  # Do NOT bake packet-tunnel entitlements into the CI IPA: ESign remaps
  # bundle IDs and injects entitlements from the user's mobileprovision.
  # Pre-baked com.apple.developer.networking.networkextension on an ad-hoc
  # signature is a common "Unable to Install" / resign failure on device.
  while IFS= read -r -d '' bin; do
    codesign --force --sign - --timestamp=none "$bin" 2>/dev/null || true
  done < <(find "$app" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 2>/dev/null || true)

  while IFS= read -r -d '' fw; do
    codesign --force --sign - --timestamp=none "$fw"
  done < <(find "$app/Frameworks" -maxdepth 1 -type d -name '*.framework' -print0 2>/dev/null || true)

  while IFS= read -r -d '' appex; do
    codesign --force --sign - --timestamp=none "$appex"
  done < <(find "$app/PlugIns" -maxdepth 1 -type d -name '*.appex' -print0 2>/dev/null || true)

  codesign --force --sign - --timestamp=none "$app"

  if [[ ! -d "$app/_CodeSignature" ]]; then
    echo "error: ad-hoc codesign did not produce _CodeSignature" >&2
    exit 1
  fi
  if ! codesign --verify --no-strict "$app" >/dev/null 2>&1; then
    echo "warning: codesign --verify reported issues (continuing; ESign will re-sign)" >&2
    codesign -dv "$app" 2>&1 | tail -8 || true
  fi
  echo "✓ ad-hoc signature present (no baked entitlements)"
}

validate_installable_app() {
  local app="$1"
  local lite="$2"

  [[ -f "$app/Info.plist" ]] || { echo "error: missing Info.plist"; return 1; }
  [[ -x "$app/DecoderSec" || -f "$app/DecoderSec" ]] || { echo "error: missing DecoderSec binary"; return 1; }

  # Must not ship a static .a as a framework binary.
  if [[ -f "$app/Frameworks/EverywhereCore.framework/EverywhereCore" ]]; then
    if ! is_macho_dylib "$app/Frameworks/EverywhereCore.framework/EverywhereCore"; then
      echo "error: EverywhereCore.framework binary is not a dylib (static .a breaks install)" >&2
      file "$app/Frameworks/EverywhereCore.framework/EverywhereCore" >&2 || true
      return 1
    fi
  fi

  if [[ "$lite" != "1" ]]; then
    [[ -d "$app/PlugIns/DecoderSecTunnel.appex" ]] || {
      echo "error: full IPA missing DecoderSecTunnel.appex" >&2
      return 1
    }
    [[ -f "$app/PlugIns/DecoderSecTunnel.appex/DecoderSecTunnel" ]] || {
      echo "error: missing tunnel binary" >&2
      return 1
    }
  else
    if [[ -d "$app/PlugIns" ]]; then
      echo "error: lite IPA still has PlugIns/" >&2
      return 1
    fi
  fi

  # Ad-hoc signature must exist for install tools.
  if [[ ! -d "$app/_CodeSignature" ]]; then
    echo "error: app is not codesigned (ad-hoc required for install)" >&2
    return 1
  fi
}

pack_ipa() {
  local lite="$1"
  local name="$2"
  local stage app_name app_copy out check
  stage="$(mktemp -d)"
  mkdir -p "$stage/Payload"
  ditto "$APP_PATH" "$stage/Payload/$(basename "$APP_PATH")"
  app_name="$(basename "$APP_PATH")"
  app_copy="$stage/Payload/$app_name"

  repair_app_bundle "$app_copy"

  if [[ "$lite" == "1" ]]; then
    rm -rf "$app_copy/PlugIns"
  fi

  adhoc_sign_bundle "$app_copy"
  validate_installable_app "$app_copy" "$lite"

  out="$IPA_DIR/$name"
  rm -f "$out"
  (
    cd "$stage"
    zip -r -X -9 "$out" Payload
  )

  check="$(mktemp -d)"
  unzip -q "$out" -d "$check"
  validate_installable_app "$check/Payload/$app_name" "$lite"
  unzip -t "$out" >/dev/null
  rm -rf "$stage" "$check"

  echo "✓ IPA: $out ($(du -h "$out" | awk '{print $1}'))"
}

if [[ "$IS_BOTH" == "1" ]]; then
  pack_ipa 0 "DecoderSec-unsigned.ipa"
  pack_ipa 1 "DecoderSec-lite-unsigned.ipa"
elif [[ "$IS_LITE" == "1" ]]; then
  pack_ipa 1 "DecoderSec-lite-unsigned.ipa"
else
  pack_ipa 0 "DecoderSec-unsigned.ipa"
fi

ls -lah "$IPA_DIR"
