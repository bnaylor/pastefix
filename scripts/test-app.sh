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
# Tests make a UserDefaults suite each. ModelFixture removes the domain *and* its plist; if that
# ever regresses, every run leaves files in ~/Library/Preferences forever (#85). Fail on growth.
count_test_plists() { ls "$HOME/Library/Preferences" 2>/dev/null | grep -c '^net\.scromp\.PastefixTests\.' || true; }
before=$(count_test_plists)
status=0
xcodebuild test \
  -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -destination 'platform=macOS' \
  -derivedDataPath "${PFX_TEST_DERIVED_DATA:-/tmp/pastefix-app-tests}" \
  CODE_SIGN_IDENTITY=- "$@" || status=$?
after=$(count_test_plists)
if [ "$after" -gt "$before" ]; then
  echo "test-app.sh: the run left $((after - before)) net.scromp.PastefixTests.*.plist file(s) in ~/Library/Preferences" >&2
  [ "$status" -eq 0 ] && status=1
fi
exit "$status"
