#!/bin/bash
# Writekin publish pipeline: everything AFTER scripts/release.sh has built
# and notarized the artifacts. Tags, pushes, creates the GitHub Release
# with the DMG, and publishes the appcast to the gh-pages branch — the
# four steps that must all happen or none, so forgetting one can't strand
# a release half-shipped.
#
# Usage:  scripts/publish.sh <version>          e.g. scripts/publish.sh 0.9.0
#         DRY_RUN=1 scripts/publish.sh 0.9.0    print every mutating command instead of running it
#
# This is the ONLY script that touches git, and it is always run by the
# maintainer deliberately — scripts/release.sh stays git-free.
set -euo pipefail

VERSION=${1:?usage: scripts/publish.sh <version>}
TAG="v$VERSION"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

OUT="build/release"
DMG="$OUT/Writekin-$VERSION.dmg"
APPCAST="$OUT/updates/appcast.xml"
NOTES_FILE="$OUT/RELEASE_NOTES.md"
REMOTE_URL=$(git remote get-url origin)
PAGES_URL="https://scouttyg.github.io/writekin/appcast.xml"

step() { printf '\n==> %s\n' "$1"; }
run()  {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf 'DRY RUN: %s\n' "$*"
  else
    "$@"
  fi
}

step "Preflight"
command -v gh > /dev/null || { echo "FATAL: gh CLI not installed (brew install gh)" >&2; exit 1; }
gh auth status > /dev/null || { echo "FATAL: gh not authenticated (gh auth login)" >&2; exit 1; }
[ -f "$DMG" ]     || { echo "FATAL: $DMG missing — run scripts/release.sh $VERSION first" >&2; exit 1; }
[ -f "$APPCAST" ] || { echo "FATAL: $APPCAST missing — release.sh did not generate the appcast (Sparkle tools on PATH?)" >&2; exit 1; }
grep -q "Writekin-$VERSION.dmg" "$APPCAST" \
  || { echo "FATAL: appcast does not reference Writekin-$VERSION.dmg — stale appcast?" >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
  echo "FATAL: tag $TAG already exists — bump the version or delete the tag first" >&2; exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "FATAL: working tree not clean — commit or stash before publishing" >&2; exit 1
fi
if [ -f "$NOTES_FILE" ] && grep -q "(fill in highlights)" "$NOTES_FILE"; then
  echo "FATAL: $NOTES_FILE still has the placeholder highlights — edit it first" >&2; exit 1
fi
echo "ok: artifacts present, tree clean, tag free"

step "Tag $TAG and push"
run git tag -a "$TAG" -m "Writekin $VERSION"
run git push origin HEAD
run git push origin "$TAG"

step "GitHub Release"
if [ -f "$NOTES_FILE" ]; then
  run gh release create "$TAG" "$DMG" --title "Writekin $VERSION" --notes-file "$NOTES_FILE"
else
  run gh release create "$TAG" "$DMG" --title "Writekin $VERSION" --generate-notes
fi

step "Publish appcast to gh-pages"
PAGES_DIR=$(mktemp -d)
if git ls-remote --exit-code --heads origin gh-pages > /dev/null; then
  run git clone --depth 1 --branch gh-pages "$REMOTE_URL" "$PAGES_DIR"
else
  echo "gh-pages branch does not exist yet — creating it"
  run git clone --depth 1 "$REMOTE_URL" "$PAGES_DIR"
  run git -C "$PAGES_DIR" checkout --orphan gh-pages
  run git -C "$PAGES_DIR" rm -rfq .
  run touch "$PAGES_DIR/.nojekyll"
  run git -C "$PAGES_DIR" add .nojekyll
fi
run cp "$APPCAST" "$PAGES_DIR/appcast.xml"
run git -C "$PAGES_DIR" add appcast.xml
# All top-level site assets (html, css, icons, favicon, og card, robots,
# sitemap) — copy every non-directory file in site/ so nothing referenced
# by the page is left unpublished.
for f in site/*; do
  [ -f "$f" ] && run cp "$f" "$PAGES_DIR/"
done
run git -C "$PAGES_DIR" add -A
if [ -d site/screenshots ] && [ -n "$(ls -A site/screenshots 2>/dev/null)" ]; then
  run mkdir -p "$PAGES_DIR/screenshots"
  run cp -R site/screenshots/. "$PAGES_DIR/screenshots/"
  run git -C "$PAGES_DIR" add screenshots
fi
run git -C "$PAGES_DIR" commit -m "Appcast + site for $TAG"
run git -C "$PAGES_DIR" push origin gh-pages
rm -rf "$PAGES_DIR"

step "Verify"
if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "DRY RUN: skipping remote verification"
else
  echo "Release: $(gh release view "$TAG" --json url --jq .url)"
  echo "Waiting for Pages to serve the new appcast (can take ~1 minute)..."
  for _ in 1 2 3 4 5 6; do
    if curl -fsS "$PAGES_URL" | grep -q "Writekin-$VERSION.dmg"; then
      echo "Appcast live: $PAGES_URL"
      exit 0
    fi
    sleep 15
  done
  echo "WARNING: appcast not serving the new version yet — check $PAGES_URL manually" >&2
  echo "(First-ever publish also needs Pages enabled: Settings > Pages > deploy from gh-pages, root.)" >&2
fi
