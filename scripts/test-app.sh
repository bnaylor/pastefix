#!/bin/sh
# Run the app target's unit tests (Pastefix/PastefixTests), hosted by Pastefix.app (#68).
#
# The host is launched for real, but `PastefixEntry` sees the XCTest environment and runs an
# inert `TestHostApp` instead of the app: no hotkeys, clipboard monitor, history, Sparkle or
# menu-bar item. See docs/specs/2026-09-27-pastefix-v2-app-test-target.md.
#
# - A private derived-data path, so this never overwrites the Developer-ID-re-signed Debug app
#   that GUI passes use (docs/gui-automation.md).
# - Ad-hoc signing (CODE_SIGN_IDENTITY=-): a Developer ID or team signature turns on library
#   validation, which refuses to load the test bundle into the hardened-runtime host. Never
#   "fix" that by adding disable-library-validation to Pastefix.entitlements (Invariant 11).
set -eu
cd "$(dirname "$0")/.."
exec xcodebuild test \
  -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -destination 'platform=macOS' \
  -derivedDataPath "${PFX_TEST_DERIVED_DATA:-/tmp/pastefix-app-tests}" \
  CODE_SIGN_IDENTITY=- "$@"
