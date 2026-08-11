#!/usr/bin/env bash
# Resign a DecoderSec IPA for sideloading.
#
# Full IPA: signs DecoderSec.app and DecoderSecTunnel.appex, preserving only the
# Network Extension entitlement needed for packet-tunnel VPN. No App Groups.
# Lite IPA: removes/signs without the appex for config browsing only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLISTBUDDY="/usr/libexec/PlistBuddy"

usage() {
  cat <<'USAGE'
Usage:
  Scripts/resign_ipa.sh --ipa build/ipa/DecoderSec-unsigned.ipa \
    --profile DecoderSec.mobileprovision \
    --identity "Apple Development: Name (TEAMID)"

  Scripts/resign_ipa.sh --ipa DecoderSec-unsigned.ipa \
    --profile DecoderSec.mobileprovision \
    --p12 cert.p12 --p12-password "$P12_PASSWORD"

Options:
  -i, --ipa PATH              Unsigned IPA to resign.
  -p, --profile PATH          Provisioning profile for the app. If it is a
                              wildcard profile that covers both bundle IDs, it
                              is also used for the PacketTunnel extension.
      --tunnel-profile PATH   Optional PacketTunnel profile when iOS requires a
                              separate explicit profile.
  -s, --identity NAME         codesign identity already installed in Keychain.
      --p12 PATH              Import this certificate into a temporary keychain.
      --p12-password VALUE    Password for --p12. May be empty for no password.
  -o, --output PATH           Output IPA. Default: <input>-resigned.ipa.
      --lite                  Remove PacketTunnel.appex and sign as UI-only.
  -h, --help                  Show this help.

Notes:
  * A real VPN install needs Network Extension packet-tunnel entitlement for
    both com.decodersec.app and com.decodersec.app.PacketTunnel.
  * No App Group entitlement is used or emitted.
  * If a single explicit profile cannot cover both bundle IDs, the script exits
    before signing. Use --tunnel-profile, or --lite for config browsing only.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

need_tool() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

plist_print() {
  local plist="$1"
  local key="$2"
  "$PLISTBUDDY" -c "Print :$key" "$plist" 2>/dev/null || true
}

plist_delete() {
  local plist="$1"
  local key="$2"
  "$PLISTBUDDY" -c "Delete :$key" "$plist" >/dev/null 2>&1 || true
}

plist_set_string() {
  local plist="$1"
  local key="$2"
  local value="$3"
  if ! "$PLISTBUDDY" -c "Set :$key $value" "$plist" >/dev/null 2>&1; then
    "$PLISTBUDDY" -c "Add :$key string $value" "$plist" >/dev/null
  fi
}

profile_to_plist() {
  local profile="$1"
  local out="$2"
  security cms -D -i "$profile" > "$out"
}

profile_team_id() {
  local plist="$1"
  local team
  team="$(plist_print "$plist" "TeamIdentifier:0")"
  if [[ -z "$team" ]]; then
    team="$(plist_print "$plist" "Entitlements:com.apple.developer.team-identifier")"
  fi
  if [[ -z "$team" ]]; then
    local app_id
    app_id="$(plist_print "$plist" "Entitlements:application-identifier")"
    team="${app_id%%.*}"
  fi
  printf '%s' "$team"
}

profile_app_pattern() {
  local plist="$1"
  local team="$2"
  local app_id
  app_id="$(plist_print "$plist" "Entitlements:application-identifier")"
  printf '%s' "${app_id#"$team."}"
}

profile_has_network_extension() {
  local plist="$1"
  plist_print "$plist" "Entitlements:com.apple.developer.networking.networkextension:0" \
    | grep -q "packet-tunnel-provider"
}

profile_covers_bundle() {
  local pattern="$1"
  local bundle_id="$2"
  case "$pattern" in
    "$bundle_id"|"*")
      return 0
      ;;
    *'*')
      local prefix="${pattern%\*}"
      [[ "$bundle_id" == "$prefix"* ]]
      return
      ;;
    *)
      return 1
      ;;
  esac
}

make_entitlements() {
  local profile_plist="$1"
  local bundle_id="$2"
  local out="$3"
  local keep_network_extension="$4"
  local team_id="$5"

  plutil -extract Entitlements xml1 -o "$out" "$profile_plist"

  plist_delete "$out" "com.apple.security.application-groups"
  plist_delete "$out" "com.apple.developer.associated-application-identifier"
  plist_set_string "$out" "application-identifier" "$team_id.$bundle_id"
  plist_set_string "$out" "com.apple.developer.team-identifier" "$team_id"

  plist_delete "$out" "keychain-access-groups"
  "$PLISTBUDDY" -c "Add :keychain-access-groups array" "$out" >/dev/null
  "$PLISTBUDDY" -c "Add :keychain-access-groups:0 string $team_id.$bundle_id" "$out" >/dev/null

  if [[ "$keep_network_extension" == "1" ]]; then
    plist_delete "$out" "com.apple.developer.networking.networkextension"
    "$PLISTBUDDY" -c "Add :com.apple.developer.networking.networkextension array" "$out" >/dev/null
    "$PLISTBUDDY" -c "Add :com.apple.developer.networking.networkextension:0 string packet-tunnel-provider" "$out" >/dev/null
  else
    plist_delete "$out" "com.apple.developer.networking.networkextension"
  fi

  plutil -lint "$out" >/dev/null
}

sign_nested_payloads() {
  local container="$1"
  [[ -d "$container/Frameworks" ]] || return 0
  while IFS= read -r -d '' item; do
    rm -rf "$item/_CodeSignature"
    codesign --force --sign "$IDENTITY" --timestamp=none "$item"
  done < <(find "$container/Frameworks" -mindepth 1 -maxdepth 1 \( -name "*.framework" -o -name "*.dylib" \) -print0)
}

IPA=""
PROFILE=""
TUNNEL_PROFILE=""
IDENTITY=""
P12=""
P12_PASSWORD=""
OUTPUT=""
LITE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--ipa)
      IPA="${2:-}"; shift 2 ;;
    -p|--profile)
      PROFILE="${2:-}"; shift 2 ;;
    --tunnel-profile)
      TUNNEL_PROFILE="${2:-}"; shift 2 ;;
    -s|--identity)
      IDENTITY="${2:-}"; shift 2 ;;
    --p12)
      P12="${2:-}"; shift 2 ;;
    --p12-password)
      P12_PASSWORD="${2:-}"; shift 2 ;;
    -o|--output)
      OUTPUT="${2:-}"; shift 2 ;;
    --lite)
      LITE=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    -*)
      die "unknown option: $1" ;;
    *)
      if [[ -z "$IPA" ]]; then
        IPA="$1"; shift
      else
        die "unexpected argument: $1"
      fi ;;
  esac
done

[[ -n "$IPA" ]] || { usage; die "--ipa is required"; }
[[ -n "$PROFILE" ]] || { usage; die "--profile is required"; }
[[ -f "$IPA" ]] || die "IPA not found: $IPA"
[[ -f "$PROFILE" ]] || die "profile not found: $PROFILE"
if [[ -n "$TUNNEL_PROFILE" && ! -f "$TUNNEL_PROFILE" ]]; then
  die "tunnel profile not found: $TUNNEL_PROFILE"
fi
if [[ -n "$P12" && ! -f "$P12" ]]; then
  die "P12 not found: $P12"
fi

need_tool security
need_tool codesign
need_tool plutil
need_tool unzip
need_tool zip
[[ -x "$PLISTBUDDY" ]] || die "missing PlistBuddy at $PLISTBUDDY"

if [[ -z "$OUTPUT" ]]; then
  base="${IPA%.ipa}"
  if [[ "$LITE" == "1" ]]; then
    OUTPUT="${base}-lite-resigned.ipa"
  else
    OUTPUT="${base}-resigned.ipa"
  fi
fi
mkdir -p "$(dirname "$OUTPUT")"
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT")" && pwd)"
OUTPUT="$OUTPUT_DIR/$(basename "$OUTPUT")"

WORK="$(mktemp -d)"
KEYCHAIN=""
OLD_KEYCHAINS=""
cleanup() {
  if [[ -n "$KEYCHAIN" ]]; then
    if [[ -n "$OLD_KEYCHAINS" ]]; then
      # shellcheck disable=SC2086
      security list-keychains -d user -s $OLD_KEYCHAINS >/dev/null 2>&1 || true
    fi
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

if [[ -n "$P12" ]]; then
  KEYCHAIN="$WORK/decodersec-signing.keychain-db"
  OLD_KEYCHAINS="$(security list-keychains -d user | tr -d '"')"
  security create-keychain -p "decodersec" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "decodersec" "$KEYCHAIN"
  security import "$P12" -P "$P12_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN"
  security set-key-partition-list -S apple-tool:,apple: -s -k "decodersec" "$KEYCHAIN" >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$KEYCHAIN" $OLD_KEYCHAINS
fi

if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Apple Distribution|iPhone Developer|iPhone Distribution/ { print $2; exit }')"
fi
[[ -n "$IDENTITY" ]] || die "no codesign identity found; pass --identity or --p12"

echo "==> unpack IPA"
unzip -q "$IPA" -d "$WORK/unpacked"
APP_CANDIDATES=("$WORK"/unpacked/Payload/*.app)
[[ -d "${APP_CANDIDATES[0]}" ]] || die "no .app found in IPA Payload"
APP_PATH="${APP_CANDIDATES[0]}"
APP_INFO="$APP_PATH/Info.plist"
APP_BUNDLE_ID="$(plist_print "$APP_INFO" "CFBundleIdentifier")"
[[ -n "$APP_BUNDLE_ID" ]] || die "could not read app bundle identifier"

APP_PROFILE_PLIST="$WORK/app-profile.plist"
profile_to_plist "$PROFILE" "$APP_PROFILE_PLIST"
APP_TEAM_ID="$(profile_team_id "$APP_PROFILE_PLIST")"
APP_PATTERN="$(profile_app_pattern "$APP_PROFILE_PLIST" "$APP_TEAM_ID")"
[[ -n "$APP_TEAM_ID" && -n "$APP_PATTERN" ]] || die "could not read provisioning profile identifiers"

if ! profile_covers_bundle "$APP_PATTERN" "$APP_BUNDLE_ID"; then
  die "profile App ID '$APP_TEAM_ID.$APP_PATTERN' does not cover app bundle '$APP_BUNDLE_ID'"
fi

rm -rf "$APP_PATH/_CodeSignature"
cp "$PROFILE" "$APP_PATH/embedded.mobileprovision"

if [[ "$LITE" == "1" ]]; then
  echo "==> Lite mode: remove PacketTunnel.appex"
  rm -rf "$APP_PATH/PlugIns"
fi

TUNNEL_APPEX=""
if [[ -d "$APP_PATH/PlugIns" ]]; then
  APPEX_CANDIDATES=("$APP_PATH"/PlugIns/*.appex)
  if [[ -d "${APPEX_CANDIDATES[0]}" ]]; then
    TUNNEL_APPEX="${APPEX_CANDIDATES[0]}"
  fi
fi

if [[ -n "$TUNNEL_APPEX" ]]; then
  TUNNEL_INFO="$TUNNEL_APPEX/Info.plist"
  TUNNEL_BUNDLE_ID="$(plist_print "$TUNNEL_INFO" "CFBundleIdentifier")"
  [[ -n "$TUNNEL_BUNDLE_ID" ]] || die "could not read PacketTunnel bundle identifier"

  TUNNEL_PROFILE="${TUNNEL_PROFILE:-$PROFILE}"
  TUNNEL_PROFILE_PLIST="$WORK/tunnel-profile.plist"
  profile_to_plist "$TUNNEL_PROFILE" "$TUNNEL_PROFILE_PLIST"
  TUNNEL_TEAM_ID="$(profile_team_id "$TUNNEL_PROFILE_PLIST")"
  TUNNEL_PATTERN="$(profile_app_pattern "$TUNNEL_PROFILE_PLIST" "$TUNNEL_TEAM_ID")"

  if ! profile_covers_bundle "$TUNNEL_PATTERN" "$TUNNEL_BUNDLE_ID"; then
    die "profile App ID '$TUNNEL_TEAM_ID.$TUNNEL_PATTERN' does not cover extension bundle '$TUNNEL_BUNDLE_ID'. Use a wildcard profile that covers both IDs, pass --tunnel-profile, or use --lite."
  fi
  if ! profile_has_network_extension "$APP_PROFILE_PLIST"; then
    die "app profile lacks Network Extension packet-tunnel entitlement; use --lite for config browsing only"
  fi
  if ! profile_has_network_extension "$TUNNEL_PROFILE_PLIST"; then
    die "tunnel profile lacks Network Extension packet-tunnel entitlement"
  fi

  APP_ENTITLEMENTS="$WORK/app.entitlements"
  TUNNEL_ENTITLEMENTS="$WORK/tunnel.entitlements"
  make_entitlements "$APP_PROFILE_PLIST" "$APP_BUNDLE_ID" "$APP_ENTITLEMENTS" 1 "$APP_TEAM_ID"
  make_entitlements "$TUNNEL_PROFILE_PLIST" "$TUNNEL_BUNDLE_ID" "$TUNNEL_ENTITLEMENTS" 1 "$TUNNEL_TEAM_ID"

  echo "==> sign PacketTunnel extension"
  rm -rf "$TUNNEL_APPEX/_CodeSignature"
  cp "$TUNNEL_PROFILE" "$TUNNEL_APPEX/embedded.mobileprovision"
  sign_nested_payloads "$TUNNEL_APPEX"
  codesign --force --sign "$IDENTITY" --timestamp=none --entitlements "$TUNNEL_ENTITLEMENTS" "$TUNNEL_APPEX"
else
  echo "==> no PacketTunnel extension in IPA; signing app as Lite/UI-only"
  APP_ENTITLEMENTS="$WORK/app-lite.entitlements"
  make_entitlements "$APP_PROFILE_PLIST" "$APP_BUNDLE_ID" "$APP_ENTITLEMENTS" 0 "$APP_TEAM_ID"
fi

echo "==> sign app"
sign_nested_payloads "$APP_PATH"
codesign --force --sign "$IDENTITY" --timestamp=none --entitlements "$APP_ENTITLEMENTS" "$APP_PATH"

echo "==> verify signatures"
if [[ -n "$TUNNEL_APPEX" ]]; then
  codesign --verify --strict --verbose=2 "$TUNNEL_APPEX"
fi
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> package $OUTPUT"
rm -f "$OUTPUT"
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$WORK/unpacked/Payload" 2>/dev/null || true
fi
(
  cd "$WORK/unpacked"
  zip -r -X -9 "$OUTPUT" Payload
)
unzip -t "$OUTPUT" >/dev/null
if [[ ! -f "$WORK/unpacked/Payload/$(basename "$APP_PATH")/Info.plist" ]]; then
  die "internal error: Payload app Info.plist missing before package"
fi
# Confirm packed structure
VERIFY="$(mktemp -d)"
unzip -q "$OUTPUT" -d "$VERIFY"
[[ -f "$VERIFY/Payload/$(basename "$APP_PATH")/Info.plist" ]] || die "resigned IPA missing Payload app Info.plist"
rm -rf "$VERIFY"

echo "OK: resigned IPA: $OUTPUT"
