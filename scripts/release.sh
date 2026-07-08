#!/bin/bash
# Release pipeline: Release build → Developer ID codesign (hardened runtime)
# → DMG (plain hdiutil, no dependencies) → notarize (notarytool) → staple.
#
# Every step is parameterized and individually skippable, because the full
# chain needs credentials the repo does not have (and the owner may not have
# minted yet). With no arguments the script goes as far as it can and fails
# with an actionable message at the first missing prerequisite.
#
# Usage:
#   scripts/release.sh [options]
#
# Options (each also settable via the environment variable in parens):
#   --identity "Developer ID Application: Name (TEAMID)"
#                          (PDFREADER_SIGN_IDENTITY) Signing identity. If
#                          unset, the newest "Developer ID Application"
#                          identity in the keychain is used.
#   --notary-profile NAME  (PDFREADER_NOTARY_PROFILE) notarytool keychain
#                          profile, created once with:
#                          xcrun notarytool store-credentials NAME \
#                            --apple-id you@example.com --team-id A448YLFLYC \
#                            --password <app-specific password>
#   --apple-id ID          (PDFREADER_NOTARY_APPLE_ID)   Alternative to the
#   --team-id ID           (PDFREADER_NOTARY_TEAM_ID)    profile: pass the
#   --password PW          (PDFREADER_NOTARY_PASSWORD)   three raw values
#                          (password = app-specific password, not the real
#                          Apple ID password). Used by CI, where secrets
#                          arrive as env vars.
#   --output DIR           (PDFREADER_RELEASE_DIR, default dist) Where the
#                          .app/.dmg land.
#   --version X.Y          Override the version in the DMG filename
#                          (default: MARKETING_VERSION from the project).
#   --skip-build           Reuse the app already in DIR/build.
#   --skip-sign            Ad-hoc sign instead of Developer ID (the DMG works
#                          locally but Gatekeeper will reject it elsewhere).
#   --skip-notarize        Stop after the DMG (implies no stapling).
#   -h | --help            This text.
#
# Exit codes: 0 success, 1 failed prerequisite/step (message says which).
set -euo pipefail
cd "$(dirname "$0")/.."

# ---------------------------------------------------------------- parameters
IDENTITY="${PDFREADER_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${PDFREADER_NOTARY_PROFILE:-}"
NOTARY_APPLE_ID="${PDFREADER_NOTARY_APPLE_ID:-}"
NOTARY_TEAM_ID="${PDFREADER_NOTARY_TEAM_ID:-}"
NOTARY_PASSWORD="${PDFREADER_NOTARY_PASSWORD:-}"
OUT_DIR="${PDFREADER_RELEASE_DIR:-dist}"
VERSION=""
SKIP_BUILD=0
SKIP_SIGN=0
SKIP_NOTARIZE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --identity)       IDENTITY="$2"; shift 2 ;;
        --notary-profile) NOTARY_PROFILE="$2"; shift 2 ;;
        --apple-id)       NOTARY_APPLE_ID="$2"; shift 2 ;;
        --team-id)        NOTARY_TEAM_ID="$2"; shift 2 ;;
        --password)       NOTARY_PASSWORD="$2"; shift 2 ;;
        --output)         OUT_DIR="$2"; shift 2 ;;
        --version)        VERSION="$2"; shift 2 ;;
        --skip-build)     SKIP_BUILD=1; shift ;;
        --skip-sign)      SKIP_SIGN=1; shift ;;
        --skip-notarize)  SKIP_NOTARIZE=1; shift ;;
        -h|--help)        sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown option '$1' (see --help)"; exit 1 ;;
    esac
done

fail() { echo ""; echo "FAIL: $1"; echo "$2"; exit 1; }

DERIVED="$OUT_DIR/build"
APP="$DERIVED/Build/Products/Release/PDFReader.app"
mkdir -p "$OUT_DIR"

# ------------------------------------------------------------- 1/5 build
if [ "$SKIP_BUILD" = 1 ]; then
    echo "== 1/5 build: SKIPPED (reusing $APP) =="
    [ -d "$APP" ] || fail "--skip-build but no app at $APP" \
        "Run once without --skip-build first."
else
    echo "== 1/5 Release build =="
    xcodebuild -project App/PDFReader.xcodeproj -scheme PDFReader \
        -configuration Release -derivedDataPath "$DERIVED" \
        -quiet build
    [ -d "$APP" ] || fail "build finished but $APP is missing" \
        "Check the xcodebuild output above."
fi

if [ -z "$VERSION" ]; then
    # `defaults read` needs an absolute path (and no .plist extension).
    case "$APP" in
        /*) INFO="$APP/Contents/Info" ;;
        *)  INFO="$(pwd)/$APP/Contents/Info" ;;
    esac
    VERSION=$(defaults read "$INFO" CFBundleShortVersionString 2>/dev/null || echo "0.0")
fi
DMG="$OUT_DIR/PDFReader-$VERSION.dmg"
echo "   app: $APP"
echo "   version: $VERSION"

# ------------------------------------------------------------- 2/5 codesign
if [ "$SKIP_SIGN" = 1 ]; then
    echo "== 2/5 codesign: SKIPPED (ad-hoc signature; local testing only) =="
    codesign --force --deep --sign - "$APP"
else
    echo "== 2/5 codesign (Developer ID, hardened runtime) =="
    if [ -z "$IDENTITY" ]; then
        IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
            | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
    fi
    if [ -z "$IDENTITY" ]; then
        fail "no Developer ID Application identity found in the keychain" \
"To mint one (one-time, account holder only):
  1. Xcode > Settings > Accounts > select the team (A448YLFLYC)
     > Manage Certificates… > + > Developer ID Application
     (or create it at developer.apple.com/account/resources/certificates)
  2. Re-run this script — it will pick the identity up automatically,
     or pass it explicitly: --identity 'Developer ID Application: … (A448YLFLYC)'
Until then: --skip-sign builds an unsigned DMG for local testing."
    fi
    echo "   identity: $IDENTITY"
    # Nested code first (none today — SwiftPM links statically — but harmless
    # and future-proof if a framework/helper ever gets embedded).
    find "$APP/Contents" \
        \( -name "*.framework" -o -name "*.dylib" -o -path "*/MacOS/*" -type f \) \
        -not -path "*/MacOS/PDFReader" 2>/dev/null \
        | while read -r nested; do
            codesign --force --options runtime --timestamp --sign "$IDENTITY" "$nested"
        done
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP" \
        || fail "codesign failed" "Is the identity's private key in this keychain (unlocked)?"
    codesign --verify --strict --deep "$APP" \
        || fail "signature verification failed" "codesign --verify output above has details."
fi

# ------------------------------------------------------------- 3/5 DMG
echo "== 3/5 DMG =="
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "PDFReader $VERSION" -srcfolder "$STAGING" \
    -fs HFS+ -format UDZO -quiet "$DMG" \
    || fail "hdiutil create failed" "Is there free disk space? Is $OUT_DIR writable?"
echo "   dmg: $DMG"

# ------------------------------------------------------------- 4/5 notarize
if [ "$SKIP_NOTARIZE" = 1 ]; then
    echo "== 4/5 notarize: SKIPPED =="
    echo "== 5/5 staple: SKIPPED (nothing to staple without notarization) =="
    echo ""
    echo "DONE (unnotarized): $DMG"
    [ "$SKIP_SIGN" = 1 ] && echo "NOTE: ad-hoc signed — Gatekeeper will block this DMG on other Macs."
    exit 0
fi

echo "== 4/5 notarize (notarytool submit --wait) =="
if [ -n "$NOTARY_PROFILE" ]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "$NOTARY_APPLE_ID" ] && [ -n "$NOTARY_TEAM_ID" ] && [ -n "$NOTARY_PASSWORD" ]; then
    NOTARY_ARGS=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
else
    fail "no notarization credentials" \
"Either store a keychain profile once:
    xcrun notarytool store-credentials pdfreader \\
        --apple-id you@example.com --team-id A448YLFLYC \\
        --password <app-specific password from appleid.apple.com>
and re-run with --notary-profile pdfreader, or pass
--apple-id/--team-id/--password directly (CI does this from secrets).
Or re-run with --skip-notarize for an unnotarized DMG."
fi

xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait \
    || fail "notarization failed or was rejected" \
"Fetch the log with: xcrun notarytool log <submission-id> ${NOTARY_ARGS[*]}
Common causes: unsigned nested code, missing hardened runtime, ad-hoc signature."

# ------------------------------------------------------------- 5/5 staple
echo "== 5/5 staple =="
xcrun stapler staple "$DMG" \
    || fail "stapling failed" "Notarization must have succeeded first; see step 4."
spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 || true

echo ""
echo "DONE: $DMG (signed, notarized, stapled)"
