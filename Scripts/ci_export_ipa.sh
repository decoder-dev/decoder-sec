#!/usr/bin/env bash
# Archive DecoderSec and produce unsigned .ipa file(s) for GitHub Actions / local CI.
#
# Modes:
#   SIGNING=unsigned   — archive with CODE_SIGNING_ALLOWED=NO, zip Payload → .ipa
#   SIGNING=manual     — use cert/profile already installed in the keychain
#   BOTH=1 (default)   — emit full VPN IPA + Lite (no PacketTunnel) from one archive
#   LITE=1             — Lite only (UI / config browsing)
#   LITE=0 BOTH=0      — full VPN IPA only
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
BOTH="${BOTH:-1}"

mkdir -p "$(dirname "$ARCHIVE_PATH")" "$IPA_DIR" "$DERIVED_DATA"

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

# Unsigned path: pack .app into Payload.zip → .ipa
APP_PATH="$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 1 -name '*.app' | head -n1)"
if [[ -z "$APP_PATH" ]]; then
  echo "error: no .app inside $ARCHIVE_PATH/Products/Applications" >&2
  exit 1
fi

pack_ipa() {
  local lite="$1"
  local name="$2"
  local stage
  stage="$(mktemp -d)"
  mkdir -p "$stage/Payload"
  cp -R "$APP_PATH" "$stage/Payload/"
  if [[ "$lite" == "1" ]]; then
    rm -rf "$stage/Payload/$(basename "$APP_PATH")/PlugIns"
  fi
  (
    cd "$stage"
    zip -qry "$IPA_DIR/$name" Payload
  )
  rm -rf "$stage"
  echo "✓ unsigned IPA: $IPA_DIR/$name"
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
