#!/bin/sh
# Build the Developer ID signed, notarized and stapled Release DMG and, with --publish, put it on the GitHub
# Release for its tag (#249, #271). docs/release.md explains the one-time credential setup.
# Usage: scripts/release.sh [--publish | --unsigned] [--no-build] [<version> | v<version>]
#   <version>   must equal CFBundleShortVersionString in scripts/Info.plist (the default); the tag is v<version>.
#   --no-build  pack the existing build/Silkweb.app instead of building the Release configuration first.
#   --publish   create the Release for tag v<version>, or update it in place (asset and notes) if it exists.
#               Needs gh, the tag pushed to GitHub, a clean checkout and HEAD at the tag.
#   --unsigned  a local test DMG: ad hoc signed, not notarized, never published. Needs no credentials.
# Environment: SILKWEB_SIGN_IDENTITY (default below) and SILKWEB_NOTARY_PROFILE, the name of a
# `xcrun notarytool store-credentials` keychain profile (default silkweb-notary). The repo holds no secret.
# Output: build/release/Silkweb-<version>.dmg and build/release/release-notes.md.
set -e
cd "$(dirname "$0")/.."
PUBLISH=0
BUILD=1
SIGN=1
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --no-build) BUILD=0 ;;
    --unsigned) SIGN=0 ;;
    -*) echo "release: unknown option $arg" >&2; exit 64 ;;
    *) VERSION="${arg#v}" ;;
  esac
done
if [ $PUBLISH -eq 1 ] && [ $SIGN -eq 0 ]; then
  echo "release: --unsigned can't combine with --publish. Only a signed, notarized DMG is published." >&2
  exit 64
fi
IDENTITY="${SILKWEB_SIGN_IDENTITY:-Developer ID Application: Mark Hinojosa (V8X3GYRTNK)}"
PROFILE="${SILKWEB_NOTARY_PROFILE:-silkweb-notary}"
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

# Check the credentials before the build, so a missing one costs seconds, not a Release build.
if [ $SIGN -eq 1 ]; then
  case "$IDENTITY" in
    "Developer ID Application: "*) ;;
    *) echo "release: $IDENTITY isn't a Developer ID Application identity. See docs/release.md." >&2; exit 1 ;;
  esac
  security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$IDENTITY\"" \
    || { echo "release: no Developer ID Application identity \"$IDENTITY\" in the keychain. See docs/release.md." >&2; exit 1; }
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || { echo "release: notarytool keychain profile $PROFILE is missing or Apple's notary service didn't answer. See docs/release.md." >&2; exit 1; }
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

# Submit $1 to Apple's notary service and wait. If Apple doesn't accept it, print the submission ID and the
# notarytool log, then stop before anything is uploaded.
notarize() {
  RESULT="$OUT/notary-$(basename "$1").plist"
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format plist >"$RESULT" || true
  SUBMISSION=$(plutil -extract id raw "$RESULT" 2>/dev/null || echo "none")
  STATUS=$(plutil -extract status raw "$RESULT" 2>/dev/null || echo "no answer")
  if [ "$STATUS" != "Accepted" ]; then
    echo "release: notarization of $1 failed: status $STATUS, submission ID $SUBMISSION." >&2
    [ "$SUBMISSION" = "none" ] || xcrun notarytool log "$SUBMISSION" --keychain-profile "$PROFILE" >&2 || true
    exit 1
  fi
  echo "notarized $1 (submission $SUBMISSION)"
}
staple() {
  xcrun stapler staple -q "$1"
  xcrun stapler validate -q "$1"
  echo "stapled $1"
}

if [ $SIGN -eq 1 ]; then
  # Hardened runtime and a secure timestamp are what notarization requires. The app needs no entitlements.
  codesign --force --options runtime --timestamp -s "$IDENTITY" -i "$APP_ID" "$APP"
  codesign --verify --strict --deep "$APP"
  echo "signed $APP"
  # The app is notarized and stapled on its own too, so it opens offline after it is copied out of the DMG.
  ZIP="$OUT/Silkweb-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
  staple "$APP"
else
  echo "release: --unsigned: $APP stays ad hoc signed and the DMG isn't notarized. Use it for local tests only."
fi
sh ./scripts/make_dmg.sh "$APP" "$VERSION" "$DMG"
if [ $SIGN -eq 1 ]; then
  codesign --force --timestamp -s "$IDENTITY" "$DMG"
  codesign --verify --strict "$DMG"
  echo "signed $DMG"
  notarize "$DMG"
  staple "$DMG"
  spctl -a -t open --context context:primary-signature "$DMG" \
    || { echo "release: Gatekeeper rejects $DMG." >&2; exit 1; }
  rm -f "$OUT"/notary-*.plist
fi
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
