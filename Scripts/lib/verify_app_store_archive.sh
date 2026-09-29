#!/bin/bash
# Read-only validation for a distribution-signed Khua App Store archive.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"

usage() {
  cat <<'EOF'
Usage: Scripts/lib/verify_app_store_archive.sh \
  --archive-path PATH \
  --team-id TEAM_ID \
  --bundle-id BUNDLE_ID \
  --marketing-version VERSION \
  --build-number BUILD

       Scripts/lib/verify_app_store_archive.sh \
  --archive-path PATH \
  --runtime-boundary-only
EOF
}

die() {
  echo "error: $*" >&2
  exit 2
}

require_argument() {
  [ "$#" -ge 2 ] || die "missing value for $1"
  [ -n "$2" ] || die "empty value for $1"
}

ARCHIVE_PATH=""
TEAM_ID=""
BUNDLE_ID=""
MARKETING_VERSION=""
BUILD_NUMBER=""
RUNTIME_BOUNDARY_ONLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --archive-path)
      require_argument "$@"
      ARCHIVE_PATH="$2"
      shift 2
      ;;
    --team-id)
      require_argument "$@"
      TEAM_ID="$2"
      shift 2
      ;;
    --bundle-id)
      require_argument "$@"
      BUNDLE_ID="$2"
      shift 2
      ;;
    --marketing-version)
      require_argument "$@"
      MARKETING_VERSION="$2"
      shift 2
      ;;
    --build-number)
      require_argument "$@"
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --runtime-boundary-only)
      RUNTIME_BOUNDARY_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$ARCHIVE_PATH" ] || die "--archive-path is required"
if [ "$RUNTIME_BOUNDARY_ONLY" -eq 0 ]; then
  [ -n "$TEAM_ID" ] || die "--team-id is required"
  [ -n "$BUNDLE_ID" ] || die "--bundle-id is required"
  [ -n "$MARKETING_VERSION" ] || die "--marketing-version is required"
  [ -n "$BUILD_NUMBER" ] || die "--build-number is required"
fi

case "$ARCHIVE_PATH" in
  /*) ;;
  *) ARCHIVE_PATH="$ROOT/$ARCHIVE_PATH" ;;
esac

APP="$ARCHIVE_PATH/Products/Applications/Khua.app"
[ -d "$ARCHIVE_PATH" ] || die "archive does not exist: $ARCHIVE_PATH"
[ -d "$APP" ] || die "archive has no Khua.app: $APP"

TEMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT HUP INT TERM

# SP_APP_STORE must compile behavior-changing automation, benchmark, dump, and
# tuning hooks out of every shipping executable. Search only packaged Mach-O
# files, so source comments, documentation, resources, and archive dSYMs cannot
# create false positives. SP_DEBUG and SP_CLKDBG are intentionally retained as
# diagnostic-only logging switches and therefore are not forbidden here.
verify_runtime_boundary() {
  local app="$1"
  python3 "$ROOT/Scripts/verify_public_surface.py" --app "$app"
  local candidate
  local description
  local grep_status
  local relative
  local token
  local strings_file="$TEMP_DIR/runtime-strings.txt"
  local matches_file="$TEMP_DIR/runtime-boundary-matches.txt"
  local forbidden_tokens=(
    SP_AUDIO_PITCHSHIFT
    SP_AUTOMATION
    SP_AUTOPAUSE
    SP_AUTORATE
    SP_AUTOREPLAY
    SP_AUTOSEEK
    SP_AUTOSHOT
    SP_AUTOVOLUME
    SP_AV1_FRAME_DELAY
    SP_BENCHSEEK
    SP_BURSTSEEK
    SP_CLOSETEST
    SP_CAPTIONS_AUTO
    SP_CAPTIONS_DUMP
    SP_DRAWABLES
    SP_DRAGFX
    SP_DRAGFX_TEST
    SP_DUST_PROBE
    SP_DUST_TUNE
    SP_EDR_HEADROOM
    SP_FORCE_EDR
    SP_FORCE_SW
    SP_FQWALL_MB
    SP_FREEZE_LOG
    SP_FULLSCREEN
    SP_HANG_SAMPLE
    SP_HANGTEST
    SP_HOVERSIM
    SP_IO_BUFKB
    SP_IO_INLINE
    SP_IO_NORELAY
    SP_IO_STALL
    SP_IO_STALL_HARD
    SP_KEEPALIVE_SEC
    SP_LOGFILE
    SP_LOOPAB
    SP_MENUTEST
    SP_INTERPOLATION
    SP_MEMC_
    SP_MWCLOSE
    SP_NO_EDR
    SP_NO_CUESPARSE
    SP_NO_COLORMATCH
    SP_NO_FFRACE
    SP_NO_GPUWARMUP
    SP_NO_LANDTRIM
    SP_NO_NRDROP
    SP_NO_PGSPROBE
    SP_NO_SPEC
    SP_NO_WARMUP
    SP_OPENFX_DEMO
    SP_OPENPANELTEST
    SP_PICTEST
    SP_RENDER_INLINE
    SP_RENDERDUMP
    SP_RENDERSHOT
    SP_REOPENTEST
    SP_RESILIENT
    SP_SCHEDPROBE
    SP_SCRUBSIM
    SP_SEEK2
    SP_SEEKDRAG
    SP_SEEKEND
    SP_SEQOPEN
    SP_SEQOPEN2
    SP_SEQSEEK
    SP_SETDEFAULT_TEST
    SP_SR
    SP_SR_DELAY_MS
    SP_STEPSIM
    SP_SUBTITLE_FILE
    SP_SUB_WATCHDOG_MS
    SP_SW_LOWDELAY
    SP_SW_QOS
    SP_SW_THREADS
    SP_TEST_ASPECT
    SP_TEST_CROP
    SP_TEST_GOP_TRACE
    SP_THUMB_IOPOL
    SP_THUMBS
    SP_THUMBSIM
    SP_THUMBS_DUMP
    SP_THUMBS_MAX
    SP_TRACKTEST
    SP_TIER
    SP_TS_NORAPSCAN
    SP_TURBOTEST
    SP_UI
    SP_UISEEK
    SP_UI_AUDIT
    SP_UI_HOVERTEST
    SP_UI_PIN
    SP_UI_TLSIM
    SP_UI_DUST
    SP_UI_TIDE
    SP_UI_SEEKTEST
    SP_UI_SRTEST
    SP_VSTATS
    SP_XDR
    SPUStandardUpdaterController
    SUFeedURL
    SUPublicEDKey
    SUEnableAutomaticChecks
    SUEnableSystemProfiling
    SUVerifyUpdateBeforeExtraction
    SURequireSignedFeed
    SPUpdateUsageEnabled
    SPUpdateUsageInstallationV1
    khua_usage
  )
  local grep_args=()

  [ ! -e "$app/Contents/Frameworks/Sparkle.framework" ] || \
    die "App Store archive must not contain Sparkle.framework"
  for update_key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks \
                    SUEnableSystemProfiling \
                    SUVerifyUpdateBeforeExtraction SURequireSignedFeed SPUpdateUsageEnabled; do
    if /usr/libexec/PlistBuddy -c "Print :$update_key" \
         "$app/Contents/Info.plist" >/dev/null 2>&1; then
      die "App Store Info.plist must not contain $update_key"
    fi
  done

  for token in "${forbidden_tokens[@]}"; do
    grep_args+=( -e "$token" )
  done

  while IFS= read -r -d '' candidate; do
    description="$(/usr/bin/file -b "$candidate")" || \
      die "cannot identify packaged file: $candidate"
    case "$description" in
      *Mach-O*) ;;
      *) continue ;;
    esac

    /usr/bin/strings -a "$candidate" >"$strings_file" || \
      die "cannot inspect packaged Mach-O strings: $candidate"
    if /usr/bin/grep -F -x "${grep_args[@]}" \
         "$strings_file" >"$matches_file"; then
      relative="${candidate#"$app"/}"
      echo "error: App Store Mach-O contains disabled runtime hook token(s): $relative" >&2
      LC_ALL=C /usr/bin/sort -u "$matches_file" | /usr/bin/sed 's/^/  /' >&2
      exit 2
    else
      grep_status=$?
      [ "$grep_status" -eq 1 ] || \
        die "failed to scan packaged Mach-O strings: $candidate"
    fi
  done < <(/usr/bin/find "$app/Contents" -type f -print0)
}

verify_runtime_boundary "$APP"
if [ "$RUNTIME_BOUNDARY_ONLY" -eq 1 ]; then
  echo "==> App Store runtime boundary passed: $APP"
  exit 0
fi

APPEX="$APP/Contents/PlugIns/KhuaPlayerQuickLook.appex"
FRAMEWORK="$APP/Contents/Frameworks/KhuaPlayerMediaCore.framework"
LIBASS="$APP/Contents/Frameworks/libass.9.dylib"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
MAIN_INFO="$APP/Contents/Info.plist"
APPEX_INFO="$APPEX/Contents/Info.plist"
FRAMEWORK_INFO="$FRAMEWORK/Resources/Info.plist"
MAIN_PRIVACY="$APP/Contents/Resources/PrivacyInfo.xcprivacy"
APPEX_PRIVACY="$APPEX/Contents/Resources/PrivacyInfo.xcprivacy"

[ -d "$APPEX" ] || die "Quick Look extension is missing: $APPEX"
[ -d "$FRAMEWORK" ] || die "media framework is missing: $FRAMEWORK"
[ -f "$LIBASS" ] || die "bundled libass is missing: $LIBASS"
[ ! -e "$SPARKLE" ] || die "App Store archive must not contain Sparkle: $SPARKLE"
for update_key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks \
                  SUEnableSystemProfiling \
                  SUVerifyUpdateBeforeExtraction SURequireSignedFeed SPUpdateUsageEnabled; do
  if /usr/libexec/PlistBuddy -c "Print :$update_key" "$MAIN_INFO" \
       >/dev/null 2>&1; then
    die "App Store Info.plist must not contain $update_key"
  fi
done

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || \
    die "missing $key in $plist"
}

assert_equal() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  [ "$actual" = "$expected" ] || \
    die "$label mismatch: expected '$expected', got '$actual'"
}

verify_info() {
  local label="$1"
  local plist="$2"
  local expected_id="$3"

  [ -f "$plist" ] || die "$label Info.plist is missing: $plist"
  /usr/bin/plutil -lint "$plist" >/dev/null
  assert_equal "$label bundle identifier" \
    "$(plist_value "$plist" CFBundleIdentifier)" "$expected_id"
  assert_equal "$label marketing version" \
    "$(plist_value "$plist" CFBundleShortVersionString)" "$MARKETING_VERSION"
  assert_equal "$label build number" \
    "$(plist_value "$plist" CFBundleVersion)" "$BUILD_NUMBER"
}

signature_details() {
  local code="$1"
  /usr/bin/codesign -dvvv "$code" 2>&1
}

verify_distribution_signature() {
  local label="$1"
  local code="$2"
  local details

  /usr/bin/codesign --verify --strict --verbose=4 "$code" >/dev/null 2>&1 || \
    die "$label has an invalid code signature: $code"
  details="$(signature_details "$code")"
  printf '%s\n' "$details" | /usr/bin/grep -Fq "Authority=Apple Distribution:" || \
    die "$label is not signed by Apple Distribution: $code"
  printf '%s\n' "$details" | /usr/bin/grep -Fq "TeamIdentifier=$TEAM_ID" || \
    die "$label is not signed by team $TEAM_ID: $code"
  if printf '%s\n' "$details" | /usr/bin/grep -Fq "Signature=adhoc"; then
    die "$label is ad-hoc signed: $code"
  fi
}

extract_entitlements() {
  local code="$1"
  local output="$2"
  /usr/bin/codesign -d --entitlements - --xml "$code" >"$output" 2>/dev/null || \
    die "cannot read signed entitlements: $code"
  [ -s "$output" ] || die "signed entitlements are empty: $code"
  /usr/bin/plutil -lint "$output" >/dev/null || \
    die "signed entitlements are not a valid plist: $code"
}

verify_boolean_entitlement() {
  local label="$1"
  local plist="$2"
  local key="$3"
  local value

  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)"
  [ "$value" = "true" ] || die "$label entitlement must be true: $key"
}

verify_profile() {
  local label="$1"
  local profile="$2"
  local expected_id="$3"
  local decoded="$4"
  local profile_team
  local application_identifier
  local get_task_allow

  [ -f "$profile" ] || die "$label provisioning profile is missing: $profile"
  /usr/bin/security cms -D -i "$profile" >"$decoded" 2>/dev/null || \
    die "cannot decode $label provisioning profile"
  profile_team="$(plist_value "$decoded" TeamIdentifier:0)"
  assert_equal "$label provisioning team" "$profile_team" "$TEAM_ID"
  application_identifier="$(plist_value "$decoded" Entitlements:com.apple.application-identifier)"
  case "$application_identifier" in
    *."$expected_id") ;;
    *) die "$label provisioning profile does not authorize $expected_id" ;;
  esac
  get_task_allow="$(/usr/libexec/PlistBuddy \
    -c 'Print :Entitlements:com.apple.security.get-task-allow' \
    "$decoded" 2>/dev/null || true)"
  [ "$get_task_allow" != "true" ] || \
    die "$label provisioning profile enables get-task-allow"
}

verify_info "main app" "$MAIN_INFO" "$BUNDLE_ID"
verify_info "Quick Look extension" "$APPEX_INFO" "$BUNDLE_ID.QuickLook"
assert_equal "main bundle name" "$(plist_value "$MAIN_INFO" CFBundleName)" "Khua"
assert_equal "main display name" "$(plist_value "$MAIN_INFO" CFBundleDisplayName)" "Khua"
assert_equal "About product name" "$(plist_value "$MAIN_INFO" SPProductName)" "Khua Player"
assert_equal "main executable name" "$(plist_value "$MAIN_INFO" CFBundleExecutable)" "Khua"
assert_equal "Quick Look display name" \
  "$(plist_value "$APPEX_INFO" CFBundleDisplayName)" "Khua Quick Look"
[ -f "$FRAMEWORK_INFO" ] || die "media framework Info.plist is missing"
assert_equal "media framework bundle identifier" \
  "$(plist_value "$FRAMEWORK_INFO" CFBundleIdentifier)" "$BUNDLE_ID.MediaCore"

[ -f "$MAIN_PRIVACY" ] || die "main app PrivacyInfo.xcprivacy is missing"
[ -f "$APPEX_PRIVACY" ] || die "Quick Look PrivacyInfo.xcprivacy is missing"
/usr/bin/plutil -lint "$MAIN_PRIVACY" >/dev/null
/usr/bin/plutil -lint "$APPEX_PRIVACY" >/dev/null

FOUND_MANIFEST="$(/usr/bin/find "$ARCHIVE_PATH" -name BuildManifest.json -print -quit)"
[ -z "$FOUND_MANIFEST" ] || \
  die "App Store archive must not contain BuildManifest.json: $FOUND_MANIFEST"

MAIN_ENTITLEMENTS="$TEMP_DIR/main-entitlements.plist"
APPEX_ENTITLEMENTS="$TEMP_DIR/quicklook-entitlements.plist"
extract_entitlements "$APP" "$MAIN_ENTITLEMENTS"
extract_entitlements "$APPEX" "$APPEX_ENTITLEMENTS"
verify_boolean_entitlement "main app" "$MAIN_ENTITLEMENTS" \
  com.apple.security.app-sandbox
verify_boolean_entitlement "main app" "$MAIN_ENTITLEMENTS" \
  com.apple.security.files.user-selected.read-write
verify_boolean_entitlement "main app" "$MAIN_ENTITLEMENTS" \
  com.apple.security.files.bookmarks.app-scope
verify_boolean_entitlement "main app" "$MAIN_ENTITLEMENTS" \
  com.apple.security.files.downloads.read-write
verify_boolean_entitlement "main app" "$MAIN_ENTITLEMENTS" \
  com.apple.security.assets.movies.read-write
verify_boolean_entitlement "Quick Look extension" "$APPEX_ENTITLEMENTS" \
  com.apple.security.app-sandbox
verify_boolean_entitlement "Quick Look extension" "$APPEX_ENTITLEMENTS" \
  com.apple.security.files.user-selected.read-only

verify_distribution_signature "main app" "$APP"
verify_distribution_signature "Quick Look extension" "$APPEX"

while IFS= read -r -d '' candidate; do
  if /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
    relative="${candidate#"$APP"/}"
    verify_distribution_signature "nested code $relative" "$candidate"
  fi
done < <(/usr/bin/find "$APP/Contents" -type f -print0)

verify_profile "main app" "$APP/Contents/embedded.provisionprofile" \
  "$BUNDLE_ID" "$TEMP_DIR/main-profile.plist"
verify_profile "Quick Look extension" "$APPEX/Contents/embedded.provisionprofile" \
  "$BUNDLE_ID.QuickLook" "$TEMP_DIR/quicklook-profile.plist"

python3 "$ROOT/Scripts/lib/verify_app_bundle.py" \
  --app "$APP" \
  --lock "$ROOT/ThirdParty/deps.lock.json" \
  --stamp "dav1d=$ROOT/ThirdParty/dav1d-min/.build-stamp.json" \
  --stamp "speex=$ROOT/ThirdParty/speex-min/.build-stamp.json" \
  --stamp "ffmpeg=$ROOT/ThirdParty/ffmpeg-min/.build-stamp.json" \
  --stamp "subtitles=$ROOT/ThirdParty/subtitles-min/.build-stamp.json" \
  --skip-manifest

echo "==> App Store archive verification passed: $ARCHIVE_PATH"
