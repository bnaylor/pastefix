#!/bin/zsh
# Cut a Pastefix release: archive → Developer ID sign → notarize → staple → DMG → notarize DMG
# → Sparkle EdDSA sign → GitHub Release → prepend an <item> to appcast.xml on gh-pages.
#
#   scripts/release.sh 1.2.3            full release
#   scripts/release.sh 1.2.3 --dry-run  everything up to the DMG + appcast item; no tag, no
#                                       release, no appcast push (notarization DOES run)
#
# Versioning: CFBundleShortVersionString = the version given; CFBundleVersion (what Sparkle
# compares) = `git rev-list --count HEAD`, monotonic on main. Both are xcodebuild overrides.
#
# Identity: $CODESIGN_IDENTITY if set, else the first "Developer ID Application" identity in the
# keychain (same convention as ../iris/scripts/sign.sh). Notary profile: pastefix-notary.
# One-time setup and recovery steps: docs/RELEASING.md.
set -euo pipefail

# --- arguments -----------------------------------------------------------------------------
VERSION="${1:-}"
DRY_RUN=0
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=1
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "usage: scripts/release.sh MAJOR.MINOR.PATCH [--dry-run]" >&2; exit 64
fi

# --- constants -----------------------------------------------------------------------------
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
PROJECT="$REPO_ROOT/Pastefix/Pastefix.xcodeproj"
SCHEME="Pastefix"
INFO_PLIST="$REPO_ROOT/Pastefix/Pastefix/Info.plist"
EXPORT_OPTIONS="$REPO_ROOT/scripts/ExportOptions.plist"
TEAM_ID="RMKGLPG4K4"
NOTARY_PROFILE="pastefix-notary"
GH_REPO="bnaylor/pastefix"
FEED_URL="https://bnaylor.github.io/pastefix/appcast.xml"
MIN_SYSTEM_VERSION="14.6"     # keep in step with MACOSX_DEPLOYMENT_TARGET in the pbxproj
TAG="v$VERSION"
DMG_NAME="Pastefix-$VERSION.dmg"
RELEASE_URL="https://github.com/$GH_REPO/releases/tag/$TAG"
ENCLOSURE_URL="https://github.com/$GH_REPO/releases/download/$TAG/$DMG_NAME"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pastefix-release-$VERSION.XXXX")
DERIVED="$WORK/DerivedData"
ARCHIVE="$WORK/Pastefix.xcarchive"
EXPORT_DIR="$WORK/export"
APP="$EXPORT_DIR/Pastefix.app"
DMG="$WORK/$DMG_NAME"
ITEM_FILE="$WORK/item.xml"

step() { print -P "%F{cyan}==> $*%f"; }
die()  { print -P "%F{red}error: $*%f" >&2; exit 1; }

cd "$REPO_ROOT"

# --- preconditions -------------------------------------------------------------------------
step "Checking preconditions"
[[ -z "$(git status --porcelain)" ]] || die "working tree not clean"
git fetch -q origin gh-pages
if [[ "${RELEASE_ALLOW_BRANCH:-0}" == "1" ]]; then
  # Dry-run testing from a feature branch only; a real release must never set this.
  (( DRY_RUN )) || die "RELEASE_ALLOW_BRANCH is only honoured with --dry-run"
  echo "RELEASE_ALLOW_BRANCH=1: skipping the main/pushed checks"
else
  [[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || die "must be on main"
  git fetch -q origin main
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "HEAD is not pushed to origin/main"
fi
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"
git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 && die "tag $TAG already exists on origin"
git rev-parse -q --verify origin/gh-pages >/dev/null || die "origin/gh-pages missing (see docs/RELEASING.md)"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notary profile '$NOTARY_PROFILE' missing (see docs/RELEASING.md)"

IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
[[ -n "$IDENTITY" ]] || die "no Developer ID Application identity found; set CODESIGN_IDENTITY"
echo "identity: $IDENTITY"

PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$INFO_PLIST" 2>/dev/null || true)
[[ -n "$PUBLIC_KEY" ]] || die "SUPublicEDKey missing from $INFO_PLIST"

BUILD=$(git rev-list --count HEAD)
echo "version: $VERSION  build: $BUILD  tag: $TAG"

# --- Sparkle tools (from the SPM artifact; resolving packages downloads them) ---------------
step "Resolving packages"
xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME" \
  -derivedDataPath "$DERIVED" -quiet
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_BIN/sign_update" ]] || die "sign_update not found under $SPARKLE_BIN"
KEYCHAIN_PUBLIC_KEY=$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null || true)
[[ "$KEYCHAIN_PUBLIC_KEY" == "$PUBLIC_KEY" ]] \
  || die "EdDSA key in keychain does not match SUPublicEDKey in Info.plist — do NOT ship (see docs/RELEASING.md)"

# --- archive + export ----------------------------------------------------------------------
step "Archiving $VERSION ($BUILD)"
xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_IDENTITY="$IDENTITY" \
  -quiet

step "Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_DIR" -quiet
[[ -d "$APP" ]] || die "export did not produce $APP"

BUILT_SHORT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
[[ "$BUILT_SHORT" == "$VERSION" && "$BUILT_BUILD" == "$BUILD" ]] \
  || die "built app reports $BUILT_SHORT ($BUILT_BUILD), expected $VERSION ($BUILD)"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox" \
  && die "app-sandbox entitlement present — Critical Invariant 9 violated"
codesign --verify --deep --strict "$APP" || die "code signature invalid"

# --- notarize + staple the app -------------------------------------------------------------
notarize() {  # notarize <path>
  local path="$1" out id status
  out=$(xcrun notarytool submit "$path" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
  echo "$out"
  id=$(echo "$out" | awk '/^ *id:/{print $2; exit}')
  status=$(echo "$out" | awk '/^ *status:/{print $2}' | tail -1)
  if [[ "$status" != "Accepted" ]]; then
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
    die "notarization of $(basename "$path") was not accepted (status: ${status:-unknown})"
  fi
}

step "Notarizing the app"
APP_ZIP="$WORK/Pastefix-$VERSION-app.zip"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
notarize "$APP_ZIP"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP" || die "spctl rejected the stapled app"

# --- DMG -----------------------------------------------------------------------------------
step "Building $DMG_NAME"
STAGE="$WORK/dmg-stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Pastefix $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

step "Notarizing the DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

# --- Sparkle signature + appcast item ------------------------------------------------------
step "Signing the DMG for Sparkle"
SIG_ATTRS=$("$SPARKLE_BIN/sign_update" "$DMG")      # → sparkle:edSignature="…" length="…"
[[ "$SIG_ATTRS" == *sparkle:edSignature=* ]] || die "sign_update produced no signature: $SIG_ATTRS"
PUB_DATE=$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")

cat > "$ITEM_FILE" <<EOF
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM_VERSION</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$RELEASE_URL</sparkle:releaseNotesLink>
      <enclosure url="$ENCLOSURE_URL" type="application/octet-stream" $SIG_ATTRS/>
    </item>
EOF

step "Appcast item"
cat "$ITEM_FILE"

if (( DRY_RUN )); then
  print -P "%F{yellow}dry run: not tagging, publishing, or updating the appcast.%f"
  echo "artifacts left in: $WORK"
  echo "  app:  $APP"
  echo "  dmg:  $DMG"
  echo "  item: $ITEM_FILE"
  exit 0
fi

# --- publish: tag → release → appcast (the release must exist before the feed points at it) -
step "Tagging $TAG"
git tag -a "$TAG" -m "Pastefix $VERSION (build $BUILD)"
git push origin "$TAG"

step "Creating GitHub release"
gh release create "$TAG" "$DMG" --repo "$GH_REPO" --title "Pastefix $VERSION" --generate-notes --verify-tag
# Fail fast if the asset URL Sparkle will fetch is not actually there.
curl -fsSLI -o /dev/null "$ENCLOSURE_URL" || die "release asset not reachable at $ENCLOSURE_URL"

step "Updating appcast on gh-pages"
PAGES_WT="$WORK/gh-pages"
git worktree add -q "$PAGES_WT" origin/gh-pages
(
  cd "$PAGES_WT"
  git checkout -q -B gh-pages origin/gh-pages
  [[ -f appcast.xml ]] || die "appcast.xml missing on gh-pages"
  # Insert the new item before the first existing <item>, or before </channel> if none.
  awk -v itemfile="$ITEM_FILE" '
    !done && ($0 ~ /<item>/ || $0 ~ /<\/channel>/) {
      while ((getline line < itemfile) > 0) print line
      close(itemfile); done = 1
    }
    { print }
  ' appcast.xml > appcast.xml.new
  mv appcast.xml.new appcast.xml
  xmllint --noout appcast.xml
  git add appcast.xml
  git commit -q -m "appcast: $VERSION (build $BUILD)"
  git push -q origin gh-pages
)
git worktree remove --force "$PAGES_WT"

step "Done"
echo "release:  $RELEASE_URL"
echo "feed:     $FEED_URL  (Pages may take a minute to refresh)"
echo "dmg:      $DMG"
