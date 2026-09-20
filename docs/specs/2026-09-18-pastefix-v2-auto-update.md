---
type: spec
status: approved
id: 2026-09-18-pastefix-v2-auto-update
title: Pastefix v2 — Auto-update & Release Pipeline (Plan 2c)
description: Sparkle 2 integration in the app target, a hardened-runtime + notarized Developer ID build, and a local release script that publishes signed DMGs to GitHub Releases and an EdDSA-signed appcast to GitHub Pages.
tags: [pastefix, macos, swift, sparkle, release, notarization]
timestamp: 2026-09-18T00:00:00Z
---

# Pastefix v2 — Auto-update & Release Pipeline (Plan 2c)

## Scope

The foundation spec (`2026-08-11-pastefix-v2-foundation-pipeline.md`) fixed
the distribution model as **direct download, notarized DMG, non-sandboxed,
Sparkle auto-updates** and listed "Check for Updates (Sparkle)" among the
settings. This increment delivers that: the app can find, verify, and install
its own updates, and there is a repeatable way to cut a release that those
updates come from.

**In scope:**

- Sparkle 2 in the `Pastefix` Xcode target: scheduled daily checks, a
  "Check for Updates…" menu item, an automatic-check toggle and Check Now
  button in Settings, a version label.
- Hardened runtime and the entitlements needed to keep the script pipeline
  working under it, so the app can be notarized.
- `scripts/release.sh`: archive → Developer ID sign → notarize → staple → DMG
  → notarize DMG → EdDSA-sign → publish DMG to GitHub Releases → prepend an
  item to the appcast on the `gh-pages` branch.
- `docs/RELEASING.md`: the one-time setup (EdDSA key, notary credentials,
  Pages) and the per-release procedure.
- An end-to-end update test against a local feed before anything is published.

**Explicitly out of scope:**

- CI-driven releases (GitHub Actions). The script is written so a workflow
  could call it later, but secrets management for the Developer ID
  certificate, notary credentials, and EdDSA key is a separate decision.
- Delta updates, beta channels, phased rollouts, and inline HTML release notes.
  Sparkle supports all of them; none earns its complexity at one user.
- A custom Sparkle user driver. Stock UI.
- Any change to `PastefixCore` or `PastefixAppCore`. Sparkle is an app-target
  dependency only (Critical Invariant 4).

## Decisions

Recorded here so the plan and the code don't relitigate them.

| Decision | Choice | Why |
|---|---|---|
| Updater | Sparkle 2.x via SwiftPM, `SPUStandardUpdaterController`, stock UI | Named in the foundation spec. Signed, verified delivery with the installer's privilege handling for free. A custom driver or a hand-rolled GitHub Releases poller gives up EdDSA verification and the installer for no product gain. |
| Hosting | DMGs as GitHub Release assets; `appcast.xml` on a `gh-pages` branch served by GitHub Pages | Zero infrastructure. Release asset URLs are stable. Pages gives the feed a stable URL with sane caching, unlike `raw.githubusercontent.com`. |
| Feed URL | `https://bnaylor.github.io/pastefix/appcast.xml` | Baked into `Info.plist` as `SUFeedURL`. |
| Default behaviour | Automatic checks on, every 24h, Sparkle's standard "update available" prompt; no silent install | A menu-bar agent asking permission on second launch (Sparkle's default) is an odd extra dialog. Silent install is surprising in a tool that edits the clipboard under the user. |
| Build number | `CFBundleVersion` = `git rev-list --count HEAD` at release time; `CFBundleShortVersionString` = the tag without its `v` | Sparkle compares `CFBundleVersion`. The commit count is monotonic on `main`, needs no version-bump commits, and is reproducible from the tag. Both are passed as `xcodebuild` overrides; the pbxproj keeps `1.0` / `1`. |
| Release driver | Local script on the maintainer's machine | Matches how `../iris` releases. Developer ID identity `Developer ID Application: Brian Naylor (RMKGLPG4K4)` is in the login keychain; the script selects it the same way iris's `scripts/sign.sh` does (`CODESIGN_IDENTITY` override, else the first Developer ID Application identity). |
| Appcast maintenance | Script prepends one `<item>` to the committed `appcast.xml` | Sparkle's `generate_appcast` wants every historical DMG on local disk, which ties releases to one machine and one directory. One item per release, edited in place, has no such dependency. |
| Release notes | `<sparkle:releaseNotesLink>` to the GitHub release page | Avoids maintaining HTML in the feed. `gh release create --generate-notes` fills the page. |
| Update preference storage | Sparkle's own `SPUUpdater.automaticallyChecksForUpdates` | Sparkle persists it in `UserDefaults` under its own key. Mirroring it in `SettingsStore` would create two sources of truth. |

## Architecture

### App target

One new file, three small edits. Nothing outside `Pastefix/Pastefix/`.

**`UpdaterController.swift`** (new) — a `@MainActor final class UpdaterController: ObservableObject` that owns a `SPUStandardUpdaterController` created with `startingUpdater: false`; `start()` is called from `applicationDidFinishLaunching`. It exposes:

- `func checkForUpdates()` — calls `NSApp.activate(ignoringOtherApps: true)`
  and then `updater.checkForUpdates()`. The activation is mandatory: an
  `LSUIElement` agent gets no foreground promotion, and without it the
  Sparkle window opens behind the frontmost app exactly as the Settings window
  did before `9ad051b`.
- `@Published private(set) var canCheckForUpdates: Bool` — mirrored from
  `SPUUpdater.canCheckForUpdates` via KVO so the menu item and button disable
  while a check is in flight.
- `var automaticallyChecksForUpdates: Bool { get set }` — passthrough to
  `SPUUpdater`, with `objectWillChange.send()` on set so the toggle re-renders.
- `var versionDescription: String` — `"1.0.0 (build 42)"` from the bundle's
  `CFBundleShortVersionString` and `CFBundleVersion`.

It also acts as `SPUUpdaterDelegate` for exactly one purpose: in `#if DEBUG`
builds, `feedURLString(for:)` returns the value of the `PastefixUpdateFeedURL`
user default when set. That is the hook the end-to-end test uses to point a
Debug build at a local feed. Release builds compile the delegate method away and
always use `SUFeedURL`.

**`PastefixApp.swift`** — the `AppDelegate` owns the `UpdaterController` as a
stored property (the `MenuBarExtra` body reads it) and calls `start()` from
`applicationDidFinishLaunching`, since Sparkle wants to start after launch.
`MenuBarExtra` gains a "Check for Updates…" button between "Settings…" and the
divider, disabled when `!canCheckForUpdates`.

**`SettingsView.swift`** — the General tab's form gains a section at the
bottom: an "Automatically check for updates" `Toggle`, a "Check Now" button,
and a secondary-styled `Text` with the version description. `SettingsView`
receives the `UpdaterController` as an `@ObservedObject`.

**`Info.plist`** (new, `Pastefix/Pastefix/Info.plist`) with
`INFOPLIST_FILE` pointed at it. `GENERATE_INFOPLIST_FILE` stays `YES`; Xcode
merges the generated keys (`LSUIElement`, bundle identifier, versions) into
this file, so nothing currently expressed as an `INFOPLIST_KEY_*` build setting
moves. Contents:

| Key | Value |
|---|---|
| `SUFeedURL` | `https://bnaylor.github.io/pastefix/appcast.xml` |
| `SUPublicEDKey` | the base64 public key printed by `generate_keys` |
| `SUEnableAutomaticChecks` | `YES` |
| `SUScheduledCheckInterval` | `86400` |

**`Pastefix.entitlements`** (new) and build settings: `ENABLE_HARDENED_RUNTIME
= YES`, `CODE_SIGN_ENTITLEMENTS` pointed at the file. The file contains
`com.apple.security.cs.allow-jit = true` for JavaScriptCore. It must **not**
contain `com.apple.security.app-sandbox` (Critical Invariant 9). Shell
transforms spawn separate processes and need nothing from the hardened runtime.
If manual testing shows JavaScriptCore runs without the JIT entitlement, the
entitlement is dropped rather than kept on suspicion.

**Package dependency:** `https://github.com/sparkle-project/Sparkle`, `from:
"2.7.0"`, product `Sparkle`, linked to the `Pastefix` target only. Added by
mirroring the existing KeyboardShortcuts entries in `project.pbxproj` (the one
pbxproj edit AGENTS.md allows), verified by a package resolve and a clean
build. If the surgical edit does not resolve cleanly, the fallback is adding it
in Xcode by hand.

### Release pipeline

**`scripts/release.sh <version> [--dry-run]`**, `zsh`, `set -euo pipefail`,
every step fatal. `<version>` is `MAJOR.MINOR.PATCH` with no `v`.

Preconditions, checked up front:

- On `main`, clean tree, `HEAD` pushed.
- Tag `v<version>` does not exist yet (the script creates and pushes it).
- `gh auth status` succeeds; `gh-pages` branch exists on `origin`.
- A Developer ID Application identity is resolvable (`CODESIGN_IDENTITY` or
  keychain lookup, iris convention).
- Notary keychain profile `pastefix-notary` exists
  (`xcrun notarytool history --keychain-profile pastefix-notary`).
- `SUPublicEDKey` in `Info.plist` is non-empty, and the matching private key is
  in the keychain (`generate_keys -p` prints exactly the `SUPublicEDKey` value).

Steps:

1. Compute `BUILD = git rev-list --count HEAD`.
2. `xcodebuild archive` — scheme `Pastefix`, Release, `MARKETING_VERSION=<version>
   CURRENT_PROJECT_VERSION=<BUILD>`, `CODE_SIGN_IDENTITY="Developer ID
   Application" DEVELOPMENT_TEAM=RMKGLPG4K4 CODE_SIGN_STYLE=Manual`, into a
   temp directory (universal, `-destination 'generic/platform=macOS'`:
   `minimumSystemVersion` 14.6 includes Intel Macs).
3. `xcodebuild -exportArchive` with `scripts/ExportOptions.plist` (method
   `developer-id`, `signingStyle manual`, `teamID RMKGLPG4K4`). The script then
   asserts the exported bundle's `SUFeedURL` and `SUPublicEDKey` match the
   values baked into the release, and that its entitlements carry
   `allow-jit` (and not `app-sandbox`), before proceeding.
4. `xcrun notarytool submit --wait` on a zip of the app; on success `xcrun
   stapler staple` the app. On `Invalid`, print the log
   (`notarytool log`) and stop.
5. Build `Pastefix-<version>.dmg` with `hdiutil create -srcfolder` (app plus an
   `/Applications` symlink), `codesign` it with the same identity, notarize and
   staple it too.
6. Locate Sparkle's tools in the DerivedData package artifacts
   (`SourcePackages/artifacts/sparkle/Sparkle/bin/`), run `sign_update` on the
   DMG, capture `sparkle:edSignature` and `length`.
7. Compose the appcast `<item>`: title `Version <version>`, `pubDate` now in
   RFC 822, `sparkle:version` = BUILD, `sparkle:shortVersionString` = version,
   `sparkle:minimumSystemVersion` = read from the exported app's
   `LSMinimumSystemVersion` (14.6 today), `sparkle:releaseNotesLink` = the
   GitHub release URL, and the
   `<enclosure>` with the release asset URL
   `https://github.com/bnaylor/pastefix/releases/download/v<version>/Pastefix-<version>.dmg`,
   `length`, `type="application/octet-stream"`, `sparkle:edSignature`.
8. `--dry-run` stops here: print the item and the artifact paths, leave the
   temp directory in place, exit 0. Nothing has been tagged, pushed, or
   published.
9. `git tag -a v<version>` and push the tag. `gh release create v<version>
   <dmg> --title "Pastefix <version>" --generate-notes`.
10. Check out `gh-pages` into a temporary `git worktree`, insert the item
    directly after `<channel>`'s header (before the first existing `<item>`, or
    before `</channel>` if none), commit `appcast: <version> (build <BUILD>)`,
    push, remove the worktree.
11. Print the feed URL and the release URL.

Ordering matters in 9–10: the release (and its asset URL) must exist before
the appcast advertises it, or a client polling in between gets a 404.

**`docs/RELEASING.md`** documents the one-time setup and the per-release
procedure:

- `generate_keys` once. The private key goes into the login keychain; the
  printed public key goes into `Info.plist`. Losing it strands every installed
  copy (they will refuse updates signed with any other key), so the doc says
  to run `generate_keys -x <file>` and keep that export somewhere safe.
- `xcrun notarytool store-credentials pastefix-notary` with an App Store
  Connect API key or an Apple ID app-specific password. Interactive; the
  maintainer runs it.
- `gh-pages` branch: orphan branch with an initial empty-channel
  `appcast.xml`; `gh api -X POST repos/bnaylor/pastefix/pages -f
  source[branch]=gh-pages -f source[path]=/` to enable Pages.
- Per release: `scripts/release.sh X.Y.Z --dry-run`, inspect, then
  `scripts/release.sh X.Y.Z`.
- Bootstrapping note: the first published build is the first one users can
  update *from*, so the very first release must already contain Sparkle and
  the correct public key.

## Data flow

**Scheduled check:** Sparkle starts at launch, waits its first-check delay,
fetches `SUFeedURL`, compares the newest item's `sparkle:version` against
`CFBundleVersion`. If newer, the standard alert appears. On Install, Sparkle
downloads the DMG, verifies the EdDSA signature against `SUPublicEDKey` **and**
that the new app's Developer ID matches the running app's, mounts the DMG,
replaces the bundle, relaunches.

**Manual check:** menu item or Check Now → `UpdaterController.checkForUpdates()`
→ activate → `updater.checkForUpdates()` → same path, but "You're up to date"
is shown when nothing is newer.

**Local test feed (Debug only):** `defaults write scromp.net.Pastefix
PastefixUpdateFeedURL http://localhost:8000/appcast.xml` → the delegate
overrides the feed → a locally served appcast pointing at a locally served DMG.

## Error handling

- **Feed unreachable / malformed:** Sparkle handles it. Scheduled checks fail
  silently and retry next interval; manual checks show Sparkle's error alert.
  Nothing in the app catches or wraps this.
- **Signature mismatch or Developer ID mismatch:** Sparkle refuses the update
  and says so. This is the whole point of the EdDSA key; the release script's
  precondition that `SUPublicEDKey` matches the keychain key is what prevents
  publishing an update no client can verify.
- **Release script:** any failing step aborts before the irreversible steps
  (tag push, release creation, appcast push), which are last and adjacent. A
  failure *between* release creation and appcast push leaves a release without
  a feed entry, which is harmless; the fix is re-running the appcast step by
  hand, which `RELEASING.md` describes.
- **Notarization rejected:** the script prints the notary log and exits. The
  usual cause is a missing entitlement or an unsigned nested binary; the log
  names it.

## Testing

Nothing in this increment is unit-testable under the repo's testability rule:
Sparkle is system glue in the Xcode target, and the release script is shell.
`swift test` is untouched and must stay green.

**End-to-end update test (before the first real release):**

1. Build a Debug app with `MARKETING_VERSION=1.0.0 CURRENT_PROJECT_VERSION=100`,
   install it to `/Applications`, run it once.
2. Build a second app with `1.0.1` / `101`, sign with the Developer ID, DMG
   it, `sign_update` it, and write a local `appcast.xml`.
3. Serve the directory with `python3 -m http.server 8000`, set the
   `PastefixUpdateFeedURL` default, relaunch the 1.0.0 app, Check for Updates.
4. Expect: alert shows 1.0.1, Install downloads and relaunches into 1.0.1,
   `defaults read` shows Sparkle's last-check timestamp updated. Then delete
   the override default.

**Manual checklist for the hardened-runtime build:**

- A shell transform applies. A JS transform applies.
- `codesign -d --entitlements - Pastefix.app` shows `allow-jit` and does
  **not** show `app-sandbox`.
- `spctl --assess --type execute Pastefix.app` accepts the stapled app.
- "Check for Updates…" from the menu bar opens the Sparkle window in front.
- A scheduled check with `SUScheduledCheckInterval` temporarily set low also
  surfaces its alert in front. If Sparkle's standard driver does not bring an
  `LSUIElement` app forward for scheduled alerts, the fallback is
  `SPUStandardUserDriverDelegate.standardUserDriverWillHandleShowingUpdate`
  calling the same activation; this is a plan verification step, not assumed
  either way.
- The Settings toggle round-trips through relaunch.

## Documentation

- `README.md`: an "Updates" subsection under Settings describing the daily
  check, the menu item, the toggle, and a pointer to `docs/RELEASING.md`.
- `AGENTS.md`: Sparkle and `UpdaterController.swift` in the layout table;
  `scripts/release.sh` under build/test/run; "Still forthcoming" line removed;
  Plan 2c row flipped when merged; and a new Critical Invariant:

  > **Hardened runtime + notarization are release requirements.**
  > `ENABLE_HARDENED_RUNTIME = YES` with `Pastefix.entitlements` carrying
  > `allow-jit` (JavaScriptCore) and never `app-sandbox`. Sparkle lives only in
  > the app target. The EdDSA private key in the login keychain is the root of
  > trust for every installed copy: a release signed with a different key is
  > rejected by every client, so the key is backed up and never regenerated.

## Project layout delta

```
Pastefix/Pastefix/
  UpdaterController.swift     # SPUStandardUpdaterController wrapper + Debug feed override
  Info.plist                  # SUFeedURL, SUPublicEDKey, SUEnableAutomaticChecks, SUScheduledCheckInterval
  Pastefix.entitlements       # com.apple.security.cs.allow-jit; no sandbox
scripts/
  release.sh                  # archive → notarize → DMG → sign_update → gh release → appcast push
  ExportOptions.plist         # method developer-id, team RMKGLPG4K4
docs/
  RELEASING.md                # one-time setup + per-release procedure
gh-pages branch:
  appcast.xml                 # the Sparkle feed
```

## Open questions / future increments

- GitHub Actions release on tag push, once secrets handling is decided.
- Delta updates if DMG size ever matters.
- A beta channel via `sparkle:channel` if there is ever more than one user
  who wants one.
