#!/bin/bash
# Publish a release to the public download site.
#
# Runs the full release pipeline (scripts/release.sh: Release build →
# Developer ID sign → DMG → notarize → staple), then publishes the DMG as a
# GitHub release on this repo — which is what the website's download button
# (gh-pages branch → https://cable729.github.io/bluefold/) points at.
#
# One-time prerequisites (see docs/RELEASING.md):
#   1. A "Developer ID Application" certificate in the keychain
#   2. notarytool credentials:  xcrun notarytool store-credentials bluefold …
#
# Usage:
#   scripts/publish-release.sh [--version X.Y] [--draft] [--skip-pipeline]
#
#   --version X.Y     Override MARKETING_VERSION for the DMG name and git tag.
#   --draft           Create the GitHub release as a draft (inspect, then
#                     publish by hand in the web UI).
#   --skip-pipeline   Reuse dist/Bluefold-<version>.dmg from a previous
#                     release.sh run instead of rebuilding.
set -euo pipefail
cd "$(dirname "$0")/.."

SITE_REPO="cable729/bluefold"
NOTARY_PROFILE="${BLUEFOLD_NOTARY_PROFILE:-bluefold}"
VERSION=""
DRAFT=()
SKIP_PIPELINE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --version)       VERSION="$2"; shift 2 ;;
        --draft)         DRAFT=(--draft); shift ;;
        --skip-pipeline) SKIP_PIPELINE=1; shift ;;
        *) echo "ERROR: unknown option '$1'"; exit 1 ;;
    esac
done

# ------------------------------------------------- 1/3 signed, notarized DMG
if [ "$SKIP_PIPELINE" = 0 ]; then
    ARGS=(--notary-profile "$NOTARY_PROFILE")
    [ -n "$VERSION" ] && ARGS+=(--version "$VERSION")
    scripts/release.sh "${ARGS[@]}"
fi

if [ -z "$VERSION" ]; then
    VERSION=$(ls dist/Bluefold-*.dmg 2>/dev/null \
        | sed -E 's/.*Bluefold-(.*)\.dmg/\1/' | sort -V | tail -1)
    [ -n "$VERSION" ] || { echo "ERROR: no DMG in dist/ — run without --skip-pipeline"; exit 1; }
fi
DMG="dist/Bluefold-$VERSION.dmg"
[ -f "$DMG" ] || { echo "ERROR: $DMG not found"; exit 1; }

# Belt-and-suspenders: never publish an unnotarized DMG.
xcrun stapler validate "$DMG" \
    || { echo "ERROR: $DMG has no notarization ticket — refusing to publish."; exit 1; }

# ------------------------------------------------- 2/3 GitHub release
# The site's download button uses the STABLE asset name Bluefold.dmg via
# /releases/latest/download/Bluefold.dmg — upload both names.
cp -f "$DMG" "dist/Bluefold.dmg"
shasum -a 256 "$DMG" | tee "dist/Bluefold-$VERSION.sha256"

TAG="v$VERSION"
NOTES="Bluefold $VERSION — signed and notarized for macOS 15+ (Apple silicon & Intel).

SHA-256: \`$(cut -d' ' -f1 "dist/Bluefold-$VERSION.sha256")\`"

if gh release view "$TAG" --repo "$SITE_REPO" >/dev/null 2>&1; then
    echo "Release $TAG exists — uploading assets (clobber)."
    gh release upload "$TAG" "$DMG" "dist/Bluefold.dmg" --clobber --repo "$SITE_REPO"
else
    # ${DRAFT[@]+…}: macOS bash 3.2 + set -u errors on expanding an empty
    # array — guard the expansion so a non-draft release doesn't die here.
    gh release create "$TAG" "$DMG" "dist/Bluefold.dmg" \
        --repo "$SITE_REPO" --title "Bluefold $VERSION" --notes "$NOTES" \
        ${DRAFT[@]+"${DRAFT[@]}"}
fi

# ------------------------------------------------- 3/3 sanity
echo ""
echo "Published: https://github.com/$SITE_REPO/releases/tag/$TAG"
echo "Download:  https://github.com/$SITE_REPO/releases/latest/download/Bluefold.dmg"
echo "Site:      https://cable729.github.io/bluefold/"
echo ""
echo "Check the site — the version line under the download button updates"
echo "automatically from the GitHub API (hard-refresh if cached)."
