#!/bin/sh
# Build the unsigned Release DMG and, with --publish, put it on the GitHub Release for its tag (#249).
# Usage: scripts/release.sh [--publish] [--no-build] [<version> | v<version>]
#   <version>   must equal CFBundleShortVersionString in scripts/Info.plist (the default); the tag is v<version>.
#   --no-build  pack the existing build/Silkweb.app instead of building the Release configuration first.
#   --publish   create the Release for tag v<version>, or update it in place (asset and notes) if it exists.
#               Needs gh, the tag pushed to GitHub, a clean checkout and HEAD at the tag.
# Output: build/release/Silkweb-<version>.dmg and build/release/release-notes.md.
# .github/workflows/release.yml runs `scripts/release.sh --publish <tag>` on every v* tag push.
set -e
cd "$(dirname "$0")/.."
PUBLISH=0
BUILD=1
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --no-build) BUILD=0 ;;
    -*) echo "release: unknown option $arg" >&2; exit 64 ;;
    *) VERSION="${arg#v}" ;;
  esac
done
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$2"; }
PLIST_VERSION=$(plist_value CFBundleShortVersionString scripts/Info.plist)
VERSION="${VERSION:-$PLIST_VERSION}"
TAG="v$VERSION"
if [ "$VERSION" != "$PLIST_VERSION" ]; then
  echo "release: $TAG doesn't match CFBundleShortVersionString $PLIST_VERSION in scripts/Info.plist." >&2
  exit 1
fi
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || { echo "release: $VERSION isn't a semver version like 0.1.0." >&2; exit 1; }

if [ $PUBLISH -eq 1 ]; then
  command -v gh >/dev/null || { echo "release: --publish needs the gh CLI." >&2; exit 1; }
  [ -z "$(git status --porcelain)" ] || { echo "release: commit or remove local changes first." >&2; exit 1; }
  TAG_COMMIT=$(git rev-parse -q --verify "refs/tags/$TAG^{commit}") \
    || { echo "release: no tag $TAG here. Tag the commit and push it: git tag $TAG && git push origin $TAG" >&2; exit 1; }
  [ "$TAG_COMMIT" = "$(git rev-parse HEAD)" ] \
    || { echo "release: HEAD isn't at $TAG. Check out $TAG first." >&2; exit 1; }
fi

APP="build/Silkweb.app"
[ $BUILD -eq 0 ] || ./scripts/build.sh release
[ -d "$APP" ] || { echo "release: no $APP; run without --no-build." >&2; exit 1; }
APP_ID=$(plist_value CFBundleIdentifier "$APP/Contents/Info.plist")
APP_VERSION=$(plist_value CFBundleShortVersionString "$APP/Contents/Info.plist")
[ "$APP_ID" = "io.github.mhinolv.silkweb" ] || { echo "release: $APP has bundle ID $APP_ID." >&2; exit 1; }
[ "$APP_VERSION" = "$VERSION" ] || { echo "release: $APP is version $APP_VERSION, not $VERSION." >&2; exit 1; }

OUT="build/release"
DMG="$OUT/Silkweb-$VERSION.dmg"
NOTES="$OUT/release-notes.md"
rm -rf "$OUT"
mkdir -p "$OUT"
sh ./scripts/make_dmg.sh "$APP" "$VERSION" "$DMG"
sed "s/{{VERSION}}/$VERSION/g" scripts/release_notes.md > "$NOTES"
echo "notes $NOTES"

[ $PUBLISH -eq 1 ] || exit 0
TITLE="Silkweb $VERSION"
if gh release view "$TAG" >/dev/null 2>&1; then
  # Re-running for an existing tag updates that Release in place.
  gh release upload "$TAG" "$DMG" --clobber
  gh release edit "$TAG" --title "$TITLE" --notes-file "$NOTES"
  echo "updated release $TAG"
else
  gh release create "$TAG" "$DMG" --verify-tag --title "$TITLE" --notes-file "$NOTES"
  echo "published release $TAG"
fi
