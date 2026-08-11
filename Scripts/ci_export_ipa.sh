#!/usr/bin/env bash
# Archive DecoderSec and produce an .ipa for GitHub Actions / local CI.
#
# Modes:
#   SIGNING=unsigned   — archive with CODE_SIGNING_ALLOWED=NO, zip Payload → .ipa
#   SIGNING=manual     — use cert/profile already installed in the keychain
#
# Env:
#   CONFIGURATION   Debug|Release (default Release)
#   DERIVED_DATA    path (default ./DerivedData)
#   ARCHIVE_PATH    path (default ./build/DecoderSec.xcarchive)
#   IPA_DIR         path (default ./build/ipa)
#   EXPORT_OPTIONS  plist path (default Config/ExportOptions-ad-hoc.plist)
#   DEVELOPMENT_TEAM optional Apple Team ID override
#   PRODUCT_BUNDLE_IDENTIFIER optional override for app id
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/DerivedData}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT/build/DecoderSec.xcarchive}"
IPA_DIR="${IPA_DIR:-$ROOT/build/ipa}"
SIGNING="${SIGNING:-unsigned}"
EXPORT_OPTIONS="${EXPORT_OPTIONS:-$ROOT/Config/ExportOptions-ad-hoc.plist}"

mkdir -p "$(dirname "$ARCHIVE_PATH")" "$IPA_DIR" "$DERIVED_DATA"

EXTRA_FLAGS=()
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  EXTRA_FLAGS+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
fi
# Do not pass a global PRODUCT_BUNDLE_IDENTIFIER — it would clobber the NE target.
# Change bundle IDs in the Xcode project (or a CI pbxproj patch) when rebranding.

echo "→ wire SwiftPM deps"
./build.sh

echo "→ archive ($CONFIGURATION, signing=$SIGNING)"
if [[ "$SIGNING" == "unsigned" ]]; then
  xcodebuild \
    -project DecoderSec.xcodeproj \
    -scheme DecoderSec \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    "${EXTRA_FLAGS[@]}" \
    archive
else
  xcodebuild \
    -project DecoderSec.xcodeproj \
    -scheme DecoderSec \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DERIVED_DATA" \
    "${EXTRA_FLAGS[@]}" \
    archive

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

STAGE="$(mktemp -d)"
mkdir -p "$STAGE/Payload"
cp -R "$APP_PATH" "$STAGE/Payload/"
(
  cd "$STAGE"
  zip -qry "$IPA_DIR/DecoderSec-unsigned.ipa" Payload
)
rm -rf "$STAGE"

echo "✓ unsigned IPA: $IPA_DIR/DecoderSec-unsigned.ipa"
ls -lah "$IPA_DIR"
