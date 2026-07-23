#!/bin/bash
# Writekin release pipeline (packaging plan Task 6).
# Usage:  scripts/release.sh <version>          e.g. scripts/release.sh 0.9.0
#         DRY_RUN=1 scripts/release.sh 0.9.0    stop before notarization, ad-hoc sign
#
# This script NEVER touches git. Tagging, pushing, and publishing the
# release are manual steps — see RELEASING.md.
set -euo pipefail

VERSION=${1:?usage: scripts/release.sh <version>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

BUILD_NUM=$(date +%Y%m%d%H%M)               # monotonic build number
OUT="build/release"
ARCHIVE="$OUT/Writekin.xcarchive"
EXPORT="$OUT/export"
APP="$EXPORT/Writekin.app"
DMG="$OUT/Writekin-$VERSION.dmg"
UPDATES="$OUT/updates"
NOTARY_PROFILE=${NOTARY_PROFILE:-writekin-notary}

step() { printf '\n==> %s\n' "$1"; }

step "Clean build directory (stale-products guard)"
rm -rf "$OUT"
mkdir -p "$OUT" "$UPDATES"

step "Regenerate project"
xcodegen generate

if [ "${DRY_RUN:-0}" = "1" ]; then
  # Ad-hoc signing needs no team — dependency targets sign cleanly.
  SIGN_ARGS=(CODE_SIGN_IDENTITY="-" ENABLE_HARDENED_RUNTIME=YES)
else
  # Real Developer ID signing requires a team for EVERY target, including
  # SPM native deps (mlx-swift's CudaBuild / _Cmlx), or the archive fails
  # with "Signing … requires a development team". Derive it from the
  # installed cert rather than hardcoding it in a public repo.
  TEAM_ID=$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" \
    | sed -E 's/.*\(([A-Z0-9]{10})\).*/\1/' | head -1)
  [ -n "$TEAM_ID" ] || {
    echo "FATAL: no 'Developer ID Application' certificate in the keychain (see RELEASING.md Part 1)" >&2
    exit 1
  }
  # CODE_SIGN_STYLE=Manual: the SPM deps default to automatic signing,
  # which conflicts with a manually-specified Developer ID identity
  # ("has conflicting provisioning settings"). Manual style makes every
  # target use the identity+team below. Developer ID needs no provisioning
  # profile, so none is specified.
  SIGN_ARGS=(CODE_SIGN_IDENTITY="Developer ID Application" \
             CODE_SIGN_STYLE=Manual \
             DEVELOPMENT_TEAM="$TEAM_ID" ENABLE_HARDENED_RUNTIME=YES)
fi

step "Archive $VERSION ($BUILD_NUM)"
xcodebuild archive \
  -project Writekin.xcodeproj -scheme Writekin -configuration Release \
  -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUM" \
  "${SIGN_ARGS[@]}" | tail -2

step "Export app"
if [ "${DRY_RUN:-0}" = "1" ]; then
  mkdir -p "$EXPORT"
  cp -R "$ARCHIVE/Products/Applications/Writekin.app" "$APP"
else
  cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
</dict></plist>
PLIST
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$EXPORT" | tail -2
fi

step "GPL guard: exported app must contain no imessage-exporter"
if find "$APP" -name "imessage-exporter*" | grep -q .; then
  echo "FATAL: GPL binary found inside the app bundle" >&2
  exit 1
fi
echo "clean"

step "Version sanity"
plutil -p "$APP/Contents/Info.plist" | grep -E "ShortVersion|CFBundleVersion\"" || true

if [ "${DRY_RUN:-0}" = "1" ]; then
  step "DRY RUN: skipping notarization/stapling"
else
  step "Notarize"
  ditto -c -k --keepParent "$APP" "$OUT/Writekin-notarize.zip"
  xcrun notarytool submit "$OUT/Writekin-notarize.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait
  step "Staple"
  xcrun stapler staple "$APP"
fi

step "Build DMG"
DMG_STAGE="$OUT/dmg-stage"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "Writekin $VERSION" -srcfolder "$DMG_STAGE" \
  -ov -format UDZO "$DMG" | tail -1
cp "$DMG" "$UPDATES/"

step "Appcast"
# --download-url-prefix makes the feed's enclosure URLs point at the GitHub
# Release assets; without it they are bare local filenames that resolve
# nowhere and every update check fails.
DOWNLOAD_PREFIX="https://github.com/scouttyg/writekin/releases/download/v$VERSION/"
GENERATE_APPCAST="${SPARKLE_BIN:+$SPARKLE_BIN/}generate_appcast"
if command -v "$GENERATE_APPCAST" > /dev/null 2>&1; then
  "$GENERATE_APPCAST" --download-url-prefix "$DOWNLOAD_PREFIX" "$UPDATES"
  echo "appcast written to $UPDATES/appcast.xml — publish it to GitHub Pages"
else
  echo "generate_appcast not found (set SPARKLE_BIN=/path/to/Sparkle/bin) — skipped"
fi

step "Checksums"
shasum -a 256 "$DMG"

step "Drafted release notes"
NOTES_FILE="$OUT/RELEASE_NOTES.md"
cat > "$NOTES_FILE" <<NOTES
## Writekin $VERSION

- (fill in highlights)

**SHA-256:** $(shasum -a 256 "$DMG" | cut -d' ' -f1)

Requires an Apple Silicon Mac, macOS 14+. Free for personal use
(PolyForm Noncommercial); commercial licensing: see NOTICE.md.
NOTES
cat <<DONE
----------------------------------------------------------------------
$(cat "$NOTES_FILE")
----------------------------------------------------------------------
Notes drafted to $NOTES_FILE — edit the highlights, then publish with:
  scripts/publish.sh $VERSION
DONE
