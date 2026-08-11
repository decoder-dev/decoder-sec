#!/usr/bin/env bash
# Archive DecoderSec and produce unsigned .ipa file(s) for GitHub Actions / local CI.
#
# Modes:
#   SIGNING=unsigned   — archive with CODE_SIGNING_ALLOWED=NO, pack Payload → .ipa
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

# Unsigned archives often embed a ~33KB Xcode "codeless" stub instead of the
# real EverywhereCore binary. Reject anything under this floor.
MIN_CORE_BYTES="${MIN_CORE_BYTES:-1000000}"

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

find_real_everywhere_core() {
  # Prefer the SPM binary artifact that Xcode downloaded for this build.
  local candidates=()
  while IFS= read -r -d '' f; do
    candidates+=("$f")
  done < <(find "$DERIVED_DATA/SourcePackages" \
    "$ROOT/DerivedData/SourcePackages" \
    "$HOME/Library/Developer/Xcode/DerivedData" \
    -type d -path '*/EverywhereCore.xcframework/ios-arm64/EverywhereCore.framework' \
    -print0 2>/dev/null || true)

  local best="" best_size=0 size
  for f in "${candidates[@]+"${candidates[@]}"}"; do
    [[ -f "$f/EverywhereCore" ]] || continue
    size=$(wc -c < "$f/EverywhereCore" | tr -d ' ')
    if (( size > best_size )); then
      best_size=$size
      best=$f
    fi
  done
  printf '%s' "$best"
}

repair_app_bundle() {
  local app="$1"
  local core_src core_dst size

  # Drop Xcode source icon bundle — runtime uses Assets.car / PNG icons.
  # Some Windows unpackers choke on nested .icon packages.
  rm -rf "$app/AppIcon.icon"

  core_dst="$app/Frameworks/EverywhereCore.framework"
  mkdir -p "$app/Frameworks"
  core_src="$(find_real_everywhere_core)"
  if [[ -z "$core_src" ]]; then
    echo "error: could not locate EverywhereCore.xcframework ios-arm64 slice under DerivedData" >&2
    exit 1
  fi
  size=$(wc -c < "$core_src/EverywhereCore" | tr -d ' ')
  echo "→ embedding EverywhereCore from $core_src ($size bytes)"
  if (( size < MIN_CORE_BYTES )); then
    echo "error: source EverywhereCore is only $size bytes (stub?)" >&2
    exit 1
  fi
  rm -rf "$core_dst"
  ditto "$core_src" "$core_dst"
  # Strip extended attributes that break Sideloadly / Windows unzip.
  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$app" 2>/dev/null || true
  fi
  size=$(wc -c < "$core_dst/EverywhereCore" | tr -d ' ')
  if (( size < MIN_CORE_BYTES )); then
    echo "error: embedded EverywhereCore is only $size bytes after copy" >&2
    exit 1
  fi
  echo "✓ EverywhereCore embedded ($size bytes)"
}

pack_ipa() {
  local lite="$1"
  local name="$2"
  local stage app_name app_copy
  stage="$(mktemp -d)"
  mkdir -p "$stage/Payload"
  ditto "$APP_PATH" "$stage/Payload/$(basename "$APP_PATH")"
  app_name="$(basename "$APP_PATH")"
  app_copy="$stage/Payload/$app_name"

  repair_app_bundle "$app_copy"

  if [[ "$lite" == "1" ]]; then
    rm -rf "$app_copy/PlugIns"
  fi

  # Sideload-friendly IPA: no resource forks / Finder metadata.
  # ditto -ck produces a clean zip that Sideloadly / 3uTools / Windows unpack reliably.
  local out="$IPA_DIR/$name"
  rm -f "$out"
  (
    cd "$stage"
    if command -v ditto >/dev/null 2>&1; then
      # Clean zip without resource forks — Sideloadly / 3uTools / Windows-friendly.
      ditto -ck --norsrc --noextattr --noacl Payload "$out"
    else
      zip -r -X -9 "$out" Payload
    fi
  )

  # Validate: must unpack cleanly and contain Payload/*.app/Info.plist
  local check
  check="$(mktemp -d)"
  if command -v ditto >/dev/null 2>&1; then
    ditto -xk "$out" "$check"
  else
    unzip -q "$out" -d "$check"
  fi
  if [[ ! -f "$check/Payload/$app_name/Info.plist" ]]; then
    echo "error: packed IPA missing Payload/$app_name/Info.plist" >&2
    rm -rf "$stage" "$check"
    exit 1
  fi
  local core_size=0
  if [[ -f "$check/Payload/$app_name/Frameworks/EverywhereCore.framework/EverywhereCore" ]]; then
    core_size=$(wc -c < "$check/Payload/$app_name/Frameworks/EverywhereCore.framework/EverywhereCore" | tr -d ' ')
  fi
  if (( core_size < MIN_CORE_BYTES )); then
    echo "error: IPA EverywhereCore is $core_size bytes — refusing to ship a stub" >&2
    rm -rf "$stage" "$check"
    exit 1
  fi
  # zip integrity
  unzip -t "$out" >/dev/null
  rm -rf "$stage" "$check"

  echo "✓ unsigned IPA: $out ($(du -h "$out" | awk '{print $1}'), EverywhereCore=${core_size} bytes)"
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
