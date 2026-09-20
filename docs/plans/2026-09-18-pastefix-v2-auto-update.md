# Pastefix v2 Auto-update & Release Pipeline (Plan 2c) — Implementation Plan

> ## ✅ STATUS: COMPLETE — merged to `main` as [PR #5](https://github.com/bnaylor/pastefix/pull/5) (`0cc1082`), 2026-09-20. All tasks done, including the notarized dry run.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Swift specifics:** SwiftUI → `swiftui-pro`; async/AppKit concurrency → `swift-concurrency-pro`. There are no new package tests in this plan; `swift test` must simply stay green.
>
> **Maintainer-only steps** are marked **[MAINTAINER]**. They touch the login keychain, Apple's notary service, or publish to GitHub. An agent executing this plan stops at each one, states exactly what it is about to run and why, and proceeds only on explicit confirmation from the human. Never work around a missing credential by weakening a check.

**Goal:** The Pastefix app checks for, verifies, and installs its own updates via Sparkle, and `scripts/release.sh` produces the notarized DMG and appcast entry those updates come from.

**Architecture:** Sparkle 2 is added to the `Pastefix` Xcode target only. A small `@MainActor` `UpdaterController` wraps `SPUStandardUpdaterController` and feeds a menu item and a Settings section. The target gains hardened runtime, an entitlements file, and a real `Info.plist` carrying the Sparkle keys. A zsh release script archives, Developer-ID-signs, notarizes, staples, builds and notarizes a DMG, EdDSA-signs it, publishes it to GitHub Releases, and prepends an item to `appcast.xml` on the `gh-pages` branch.

**Tech Stack:** Swift 6 (Xcode 26.x), SwiftUI `MenuBarExtra`/`Settings`, Sparkle 2.x (remote SPM dep, app target only), `xcodebuild archive`/`-exportArchive`, `notarytool`, `stapler`, `hdiutil`, `codesign`, Sparkle's `generate_keys`/`sign_update`, `gh`, GitHub Pages.

**Spec:** `docs/specs/2026-09-18-pastefix-v2-auto-update.md` — read it first; this plan argues from it.

## Global Constraints

- **Packages untouched.** No file under `Sources/` or `Tests/` changes. `PastefixCore` and `PastefixAppCore` stay free of third-party dependencies (Critical Invariant 4). Sparkle is linked to the `Pastefix` target only.
- **Sandbox stays off.** `ENABLE_APP_SANDBOX = NO`; `Pastefix.entitlements` must never contain `com.apple.security.app-sandbox` (Critical Invariant 9).
- **Hardened runtime on** with exactly one entitlement, `com.apple.security.cs.allow-jit`, unless Task 2's manual check proves JavaScriptCore runs without it, in which case the entitlement is removed and the spec note updated.
- **Feed URL:** `https://bnaylor.github.io/pastefix/appcast.xml`. **Bundle id:** `scromp.net.Pastefix`. **Team:** `RMKGLPG4K4`. **Identity:** `Developer ID Application: Brian Naylor (RMKGLPG4K4)`, selected via `CODESIGN_IDENTITY` else keychain lookup (iris convention). **Notary profile:** `pastefix-notary`.
- **Versioning:** `CFBundleShortVersionString` = tag without `v`; `CFBundleVersion` = `git rev-list --count HEAD`. Both are `xcodebuild` overrides; the pbxproj keeps `MARKETING_VERSION = 1.0` / `CURRENT_PROJECT_VERSION = 1`.
- **Update preference** lives in Sparkle's `SPUUpdater.automaticallyChecksForUpdates`, not `SettingsStore`.
- **Debug-only feed override** via the `PastefixUpdateFeedURL` user default; compiled out of Release.
- **pbxproj edits** are limited to: the Sparkle package entries (mirroring KeyboardShortcuts), and build-setting values (`ENABLE_HARDENED_RUNTIME`, `CODE_SIGN_ENTITLEMENTS`, `INFOPLIST_FILE`). New `.swift` files are picked up by the filesystem-synchronized group; do not add them by hand.
- **Branch:** all work on `feat/auto-update`, PR against `main`. Conventional commits with `Co-Authored-By` trailer.

---

## File structure

| Path | Responsibility |
|---|---|
| `Pastefix/Pastefix.xcodeproj/project.pbxproj` | Sparkle package reference + product dependency; hardened runtime, entitlements, Info.plist build settings |
| `Pastefix/Pastefix.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | Sparkle pin |
| `Pastefix/Pastefix/Info.plist` (new) | `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUScheduledCheckInterval` |
| `Pastefix/Pastefix/Pastefix.entitlements` (new) | `com.apple.security.cs.allow-jit` |
| `Pastefix/Pastefix/UpdaterController.swift` (new) | Sparkle wrapper: start, check, `canCheckForUpdates`, auto-check passthrough, version string, Debug feed override |
| `Pastefix/Pastefix/PastefixApp.swift` | Owns `UpdaterController`, starts it after launch, "Check for Updates…" menu item, passes updater to Settings |
| `Pastefix/Pastefix/SettingsView.swift` | Updates section on the General tab |
| `scripts/ExportOptions.plist` (new) | developer-id export options |
| `scripts/release.sh` (new) | The release pipeline |
| `docs/RELEASING.md` (new) | One-time setup + per-release procedure + local update test |
| `README.md`, `AGENTS.md` | Currency |
| `gh-pages` branch: `appcast.xml` | The feed |

---

### Task 0: Branch

**Files:** none.

- [ ] **Step 1: Create the branch**

```bash
git checkout main && git pull --ff-only && git checkout -b feat/auto-update
```

---

### Task 1: Add the Sparkle package to the app target

**Files:**
- Modify: `Pastefix/Pastefix.xcodeproj/project.pbxproj` (five sections, mirroring the KeyboardShortcuts entries)
- Modify: `Pastefix/Pastefix.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (regenerated by resolve)

**Interfaces:**
- Produces: `import Sparkle` compiles in the `Pastefix` target; Sparkle's command-line tools appear under DerivedData at `SourcePackages/artifacts/sparkle/Sparkle/bin/`.

The pbxproj uses 24-hex-digit object ids. Use these four fresh ids (verified absent from the file): `44C98360303C000000BB563C` (build file), `44C98361303C000000BB563C` (product dependency), `44C98362303C000000BB563C` (remote package reference). Before editing, confirm they are unused:

```bash
grep -c "44C9836[012]303C000000BB563C" Pastefix/Pastefix.xcodeproj/project.pbxproj   # expect 0
```

- [ ] **Step 1: PBXBuildFile section** — after the KeyboardShortcuts line (`44C9835C303BE8DF00BB563C /* KeyboardShortcuts in Frameworks */ …`), add:

```
		44C98360303C000000BB563C /* Sparkle in Frameworks */ = {isa = PBXBuildFile; productRef = 44C98361303C000000BB563C /* Sparkle */; };
```

- [ ] **Step 2: PBXFrameworksBuildPhase `files` list** — after `44C9835C303BE8DF00BB563C /* KeyboardShortcuts in Frameworks */,` add:

```
				44C98360303C000000BB563C /* Sparkle in Frameworks */,
```

- [ ] **Step 3: PBXNativeTarget `packageProductDependencies`** — after `44C9835B303BE8DF00BB563C /* KeyboardShortcuts */,` add:

```
				44C98361303C000000BB563C /* Sparkle */,
```

- [ ] **Step 4: PBXProject `packageReferences`** — after `44C9835A303BE8DF00BB563C /* XCRemoteSwiftPackageReference "KeyboardShortcuts" */,` add:

```
				44C98362303C000000BB563C /* XCRemoteSwiftPackageReference "Sparkle" */,
```

- [ ] **Step 5: XCRemoteSwiftPackageReference section** — after the KeyboardShortcuts block's closing `};`, add:

```
		44C98362303C000000BB563C /* XCRemoteSwiftPackageReference "Sparkle" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/sparkle-project/Sparkle";
			requirement = {
				kind = upToNextMajorVersion;
				minimumVersion = 2.7.0;
			};
		};
```

- [ ] **Step 6: XCSwiftPackageProductDependency section** — after the KeyboardShortcuts block's closing `};`, add:

```
		44C98361303C000000BB563C /* Sparkle */ = {
			isa = XCSwiftPackageProductDependency;
			package = 44C98362303C000000BB563C /* XCRemoteSwiftPackageReference "Sparkle" */;
			productName = Sparkle;
		};
```

- [ ] **Step 7: Resolve and build**

```bash
xcodebuild -resolvePackageDependencies -project Pastefix/Pastefix.xcodeproj -scheme Pastefix
xcodebuild build -project Pastefix/Pastefix.xcodeproj -scheme Pastefix \
  -destination 'platform=macOS,arch=arm64' -configuration Debug -quiet
```

Expected: both succeed. `Package.resolved` now has a `sparkle` pin at 2.7.x or later. If resolve fails with a pbxproj parse error, `git checkout` the pbxproj and ask the human to add the package in Xcode (File → Add Package Dependencies…, URL above, "Up to Next Major" from 2.7.0, product `Sparkle` → target `Pastefix`), then continue from Step 8.

- [ ] **Step 8: Confirm the tools shipped**

```bash
find ~/Library/Developer/Xcode/DerivedData -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys" | head -1
```

Expected: one path printed. Note it; Task 2 uses it.

- [ ] **Step 9: Confirm `swift test` is unaffected**

```bash
swift test 2>&1 | tail -1
```

Expected: `Test run with 66 tests in 14 suites passed`.

- [ ] **Step 10: Commit**

```bash
git add Pastefix/Pastefix.xcodeproj/project.pbxproj \
        Pastefix/Pastefix.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
git commit -m "build(app): add Sparkle 2 package dependency to the Pastefix target

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: EdDSA key, Info.plist, entitlements, hardened runtime

**Files:**
- Create: `Pastefix/Pastefix/Info.plist`
- Create: `Pastefix/Pastefix/Pastefix.entitlements`
- Modify: `Pastefix/Pastefix.xcodeproj/project.pbxproj` (Debug and Release target build settings, lines ~270–332)

**Interfaces:**
- Produces: the built app's `Info.plist` contains the four `SU*` keys; `codesign -d --entitlements -` shows `allow-jit` and no sandbox; Sparkle can find `SUPublicEDKey` at runtime.

- [ ] **Step 1: [MAINTAINER] Generate the EdDSA key pair**

Stop and tell the human: "I'm about to run Sparkle's `generate_keys`. It creates an Ed25519 key pair and stores the private key in your login keychain (service `https://sparkle-project.org`, account `ed25519`). It prints the public key, which I'll put in Info.plist. If a key already exists it prints that one and changes nothing. OK?"

On confirmation, with `SPARKLE_BIN` set to the directory found in Task 1 Step 8:

```bash
"$SPARKLE_BIN/generate_keys"
```

Expected output ends with a line like:

```
<key>SUPublicEDKey</key>
<string>BASE64PUBLICKEY=</string>
```

Then immediately export a backup and tell the human where it is:

```bash
"$SPARKLE_BIN/generate_keys" -x "$HOME/Desktop/pastefix-sparkle-private-key.txt"
```

Tell the human: "The private key backup is at ~/Desktop/pastefix-sparkle-private-key.txt. Move it to your password manager and delete the file. If this key is ever lost, no installed copy of Pastefix can update again."

- [ ] **Step 2: Write Info.plist** with the public key from Step 1 substituted for `PUBLIC_KEY_FROM_GENERATE_KEYS`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>SUFeedURL</key>
	<string>https://bnaylor.github.io/pastefix/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>PUBLIC_KEY_FROM_GENERATE_KEYS</string>
	<key>SUEnableAutomaticChecks</key>
	<true/>
	<key>SUScheduledCheckInterval</key>
	<integer>86400</integer>
</dict>
</plist>
```

Save as `Pastefix/Pastefix/Info.plist`. Validate: `plutil -lint Pastefix/Pastefix/Info.plist` → `OK`.

- [ ] **Step 3: Write the entitlements file** `Pastefix/Pastefix/Pastefix.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
</dict>
</plist>
```

Validate: `plutil -lint Pastefix/Pastefix/Pastefix.entitlements` → `OK`.

- [ ] **Step 4: Build settings** — in **both** the `44988CDB… /* Debug */` and `44988CDC… /* Release */` target configurations (the ones containing `PRODUCT_BUNDLE_IDENTIFIER = scromp.net.Pastefix;`), add three lines in alphabetical position within `buildSettings`:

```
				CODE_SIGN_ENTITLEMENTS = Pastefix/Pastefix.entitlements;
```
(after `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`, before `CODE_SIGN_STYLE`)

```
				ENABLE_HARDENED_RUNTIME = YES;
```
(after `ENABLE_APP_SANDBOX = NO;`)

```
				INFOPLIST_FILE = Pastefix/Info.plist;
```
(after `GENERATE_INFOPLIST_FILE = YES;`)

Paths are relative to the project directory `Pastefix/`, hence `Pastefix/Info.plist` not `Pastefix/Pastefix/Info.plist`. `GENERATE_INFOPLIST_FILE` stays `YES` so `INFOPLIST_KEY_*` settings keep merging in.

- [ ] **Step 5: Build and inspect the product**

```bash
Pastefix/launch.sh --path
xcodebuild build -project Pastefix/Pastefix.xcodeproj -scheme Pastefix \
  -destination 'platform=macOS,arch=arm64' -configuration Debug -quiet
APP=$(Pastefix/launch.sh --path)
/usr/libexec/PlistBuddy -c "Print :SUFeedURL" -c "Print :SUPublicEDKey" -c "Print :SUEnableAutomaticChecks" -c "Print :SUScheduledCheckInterval" -c "Print :LSUIElement" -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist"
codesign -d --entitlements - "$APP" 2>&1
codesign -dv "$APP" 2>&1 | grep -E "flags=|runtime"
```

Expected: the four SU values, `true` for `LSUIElement`, `scromp.net.Pastefix`; entitlements output contains `com.apple.security.cs.allow-jit` and does **not** contain `app-sandbox`; the flags line contains `runtime`.

- [ ] **Step 6: Manual: transforms still run under hardened runtime**

```bash
mkdir -p ~/.config/pastefix/scripts
cat > ~/.config/pastefix/scripts/hr-shell.sh <<'EOF'
#!/bin/sh
# pastefix: name = HR Shell Check
tr 'a-z' 'A-Z'
EOF
chmod +x ~/.config/pastefix/scripts/hr-shell.sh
cat > ~/.config/pastefix/scripts/hr-js.js <<'EOF'
// pastefix: name = HR JS Check
function transform(text) { return text.split("").reverse().join(""); }
EOF
Pastefix/launch.sh
```

Copy `hello world`, press ⌘⇧C, click **HR Shell Check** → editor shows `HELLO WORLD`. Undo, click **HR JS Check** → `dlrow olleh`. Both must succeed with no red error banner. If the JS one fails with a JavaScriptCore/JIT error, that confirms the entitlement is needed (it is present, so it should not fail). Optional negative check: temporarily empty the entitlements dict, rebuild, retry the JS transform; if it *still* works, remove `allow-jit` permanently and update the spec's entitlements paragraph and the AGENTS.md invariant text in Task 8. Restore the file either way. Remove the two check scripts afterwards.

- [ ] **Step 7: Commit**

```bash
git add Pastefix/Pastefix/Info.plist Pastefix/Pastefix/Pastefix.entitlements Pastefix/Pastefix.xcodeproj/project.pbxproj
git commit -m "build(app): hardened runtime, entitlements, and Sparkle Info.plist keys

Adds a real Info.plist carrying SUFeedURL, SUPublicEDKey, and the daily
automatic-check settings; enables the hardened runtime with the
JavaScriptCore JIT entitlement so the app can be notarized.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: `UpdaterController`

**Files:**
- Create: `Pastefix/Pastefix/UpdaterController.swift`

**Interfaces:**
- Produces, for Task 4:
  - `@MainActor final class UpdaterController: NSObject, ObservableObject`
  - `init()` — does not start Sparkle
  - `func start()` — call once from `applicationDidFinishLaunching`
  - `func checkForUpdates()` — activates the app then runs a user-initiated check
  - `@Published private(set) var canCheckForUpdates: Bool`
  - `var automaticallyChecksForUpdates: Bool { get set }`
  - `var versionDescription: String` — e.g. `1.0 (build 1)`

- [ ] **Step 1: Write the file**

```swift
import AppKit
import Combine
import Sparkle

/// Owns Sparkle's standard updater and exposes the little the UI needs.
///
/// The "automatically check" preference is Sparkle's own (`SPUUpdater.automaticallyChecksForUpdates`,
/// persisted by Sparkle in UserDefaults) — it is deliberately not mirrored in `SettingsStore`.
@MainActor
final class UpdaterController: NSObject, ObservableObject {
    /// Mirrors `SPUUpdater.canCheckForUpdates` so menu items and buttons disable during a check.
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    private var cancellables = Set<AnyCancellable>()

    override init() {
        // Not started here: Sparkle wants to start after the app has finished launching.
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            }
            .store(in: &cancellables)
    }

    /// Starts scheduled checking. Call once from `applicationDidFinishLaunching`.
    func start() {
        #if DEBUG
        controller.updater.delegate = self
        #endif
        controller.startUpdater()
    }

    /// User-initiated check. An LSUIElement agent gets no foreground promotion, so activate first
    /// or Sparkle's window opens behind the frontmost app (same lesson as the Settings window).
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.updater.checkForUpdates()
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (build \(build))"
    }
}

#if DEBUG
extension UpdaterController: SPUUpdaterDelegate {
    /// Debug-only feed override for the local end-to-end update test:
    ///   defaults write scromp.net.Pastefix PastefixUpdateFeedURL http://localhost:8000/appcast.xml
    /// Release builds never compile this, so they always use SUFeedURL from Info.plist.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "PastefixUpdateFeedURL")
    }
}
#endif
```

- [ ] **Step 2: Build**

```bash
xcodebuild build -project Pastefix/Pastefix.xcodeproj -scheme Pastefix \
  -destination 'platform=macOS,arch=arm64' -configuration Debug -quiet
```

Expected: success. Likely compile issues and their fixes:
- *"Main actor-isolated instance method cannot satisfy nonisolated requirement"* on `feedURLString` → the `nonisolated` keyword is missing.
- *"Cannot assign delegate"* / delegate is read-only → `SPUUpdater.delegate` is `weak var` and settable in Sparkle 2; if the installed version disagrees, pass `updaterDelegate: self` in the initializer instead by making `controller` an implicitly unwrapped var assigned after `super.init()`.
- `publisher(for:)` unavailable → `SPUUpdater` is an `NSObject` and `canCheckForUpdates` is KVO-compliant; confirm `import Combine` is present.

Also build **Release** once to prove the `#if DEBUG` branch compiles out:

```bash
xcodebuild build -project Pastefix/Pastefix.xcodeproj -scheme Pastefix \
  -destination 'platform=macOS,arch=arm64' -configuration Release -quiet
```

- [ ] **Step 3: Commit**

```bash
git add Pastefix/Pastefix/UpdaterController.swift
git commit -m "feat(app): add UpdaterController wrapping Sparkle's standard updater

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Menu item, Settings section, wiring

**Files:**
- Modify: `Pastefix/Pastefix/PastefixApp.swift` (menu body ~lines 13–24; `AppDelegate` properties and `applicationDidFinishLaunching`)
- Modify: `Pastefix/Pastefix/SettingsView.swift` (properties ~lines 7–9; `general` ~lines 22–40)

**Interfaces:**
- Consumes: `UpdaterController` from Task 3.
- Produces: `AppDelegate.updater: UpdaterController`; `SettingsView(settings:model:updater:)`.

- [ ] **Step 1: AppDelegate owns and starts the updater** — in `PastefixApp.swift`, alongside the other `AppDelegate` stored properties add:

```swift
    let updater = UpdaterController()
```

and as the first statement of `applicationDidFinishLaunching` add:

```swift
        // Sparkle: scheduled daily checks start here, after launch, per Sparkle's guidance.
        updater.start()
```

- [ ] **Step 2: Menu item** — replace the `MenuBarExtra` body with:

```swift
        MenuBarExtra("Pastefix", systemImage: "doc.on.clipboard") {
            Button("Summon Pastefix") { delegate.summon() }
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",", modifiers: .command)
            CheckForUpdatesButton(updater: delegate.updater)
            Divider()
            Button("Quit Pastefix") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
```

and add this view at the bottom of `PastefixApp.swift` (a separate view so the menu observes `canCheckForUpdates` without observing the whole delegate):

```swift
/// Menu item that disables itself while a check is already running.
struct CheckForUpdatesButton: View {
    @ObservedObject var updater: UpdaterController

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
```

- [ ] **Step 3: Pass the updater to Settings** — change the `Settings` scene to:

```swift
        Settings {
            SettingsView(settings: delegate.settings, model: delegate.model, updater: delegate.updater)
        }
```

- [ ] **Step 4: Settings General tab** — in `SettingsView.swift` add the property after `model`:

```swift
    @ObservedObject var updater: UpdaterController
```

and append to the `Form` in `general`, after the `LabeledContent("Scripts folder")` block:

```swift
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                HStack {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                    Spacer()
                    Text("Pastefix \(updater.versionDescription)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
```

If the General tab now clips, raise the `.frame(width: 460, height: 340)` height to `400`.

- [ ] **Step 5: Build and run**

```bash
Pastefix/launch.sh
```

Manual checks:
1. Menu bar → **Check for Updates…** exists above the divider. Click it. Expected: the app comes forward and Sparkle shows an alert. Because the feed doesn't exist yet it will be an error alert ("An error occurred… update feed…"); that is correct for now. The window must appear **in front**, not behind the previous app.
2. While that alert is up, open the menu again: the item is disabled. Dismiss the alert; it re-enables.
3. Settings → General shows the Updates section with the toggle **on**, a working **Check Now**, and `Pastefix 1.0 (build 1)`.
4. Toggle auto-check off, quit, relaunch, reopen Settings: still off. Then:
   ```bash
   defaults read scromp.net.Pastefix SUEnableAutomaticChecks   # expect 0
   ```
   Turn it back on.

- [ ] **Step 6: Commit**

```bash
git add Pastefix/Pastefix/PastefixApp.swift Pastefix/Pastefix/SettingsView.swift
git commit -m "feat(app): Check for Updates menu item and Updates section in Settings

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: `gh-pages` branch and GitHub Pages

**Files:**
- Create on branch `gh-pages`: `appcast.xml`, `.nojekyll`

**Interfaces:**
- Produces: `https://bnaylor.github.io/pastefix/appcast.xml` serves an empty channel; `scripts/release.sh` (Task 6) prepends items to it.

- [ ] **Step 1: [MAINTAINER] Confirm** — tell the human: "I'm going to create an orphan `gh-pages` branch with an empty appcast, push it to origin, and enable GitHub Pages on it via the API. Nothing on `main` changes. OK?"

- [ ] **Step 2: Create the branch in a worktree**

```bash
WT=$(mktemp -d)/gh-pages
git worktree add --detach "$WT"
cd "$WT"
git checkout --orphan gh-pages
git rm -rf . >/dev/null 2>&1 || true
cat > appcast.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Pastefix</title>
    <link>https://github.com/bnaylor/pastefix</link>
    <description>Pastefix updates</description>
    <language>en</language>
  </channel>
</rss>
EOF
touch .nojekyll
git add appcast.xml .nojekyll
git commit -m "appcast: empty channel"
git push -u origin gh-pages
cd - && git worktree remove "$WT"
```

- [ ] **Step 3: Enable Pages**

```bash
gh api -X POST repos/bnaylor/pastefix/pages -f "source[branch]=gh-pages" -f "source[path]=/"
```

Expected: JSON with `"html_url": "https://bnaylor.github.io/pastefix/"`. If it returns 409 (already enabled), fine.

- [ ] **Step 4: Verify the feed is live** (Pages can take a minute)

```bash
sleep 60; curl -fsSL https://bnaylor.github.io/pastefix/appcast.xml | head -3
```

Expected: the XML header. Retry once or twice if 404.

- [ ] **Step 5: Re-check the app** — launch the app, **Check for Updates…**. Expected: Sparkle now says "You're up to date!" (1.0 build 1 vs an empty feed) in front. This closes the loop on Task 4's error alert.

No commit on `feat/auto-update` for this task.

---

### Task 6: Release script

**Files:**
- Create: `scripts/ExportOptions.plist`
- Create: `scripts/release.sh` (executable, `100755`)

**Interfaces:**
- Consumes: `Info.plist` public key (Task 2), `gh-pages` (Task 5), notary profile `pastefix-notary` (created in Step 1 below).
- Produces: `scripts/release.sh <version> [--dry-run]`.

- [ ] **Step 1: [MAINTAINER] Notary credentials** — check first:

```bash
xcrun notarytool history --keychain-profile pastefix-notary 2>&1 | head -2
```

If it prints `No Keychain password item found`, tell the human: "Notarization needs an Apple credential stored as keychain profile `pastefix-notary`. Please run this yourself, it prompts interactively:

```
xcrun notarytool store-credentials pastefix-notary --team-id RMKGLPG4K4
```

Use either an App Store Connect API key (Issuer ID + Key ID + .p8 path) or your Apple ID with an app-specific password from appleid.apple.com. Tell me when it's done." Suggest `! xcrun notarytool store-credentials pastefix-notary --team-id RMKGLPG4K4` so it runs in-session. Re-run the history command to confirm it now lists (possibly zero) submissions without error.

- [ ] **Step 2: Write `scripts/ExportOptions.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>destination</key>
	<string>export</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
	<key>teamID</key>
	<string>RMKGLPG4K4</string>
</dict>
</plist>
```

- [ ] **Step 3: Write `scripts/release.sh`**

```zsh
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
```

Then:

```bash
chmod +x scripts/release.sh
zsh -n scripts/release.sh && plutil -lint scripts/ExportOptions.plist
```

Expected: no output from `zsh -n`; `OK` from plutil.

- [ ] **Step 4: Unit-check the awk insertion in isolation** (cheap, avoids discovering an awk bug during a real release)

```bash
T=$(mktemp -d); cd "$T"
printf '    <item>\n      <title>NEW</title>\n    </item>\n' > item.xml
printf '<rss>\n  <channel>\n    <title>Pastefix</title>\n  </channel>\n</rss>\n' > a.xml
awk -v itemfile=item.xml '!done && ($0 ~ /<item>/ || $0 ~ /<\/channel>/) { while ((getline line < itemfile) > 0) print line; close(itemfile); done=1 } { print }' a.xml
printf '<rss>\n  <channel>\n    <item>\n      <title>OLD</title>\n    </item>\n  </channel>\n</rss>\n' > b.xml
awk -v itemfile=item.xml '!done && ($0 ~ /<item>/ || $0 ~ /<\/channel>/) { while ((getline line < itemfile) > 0) print line; close(itemfile); done=1 } { print }' b.xml
cd - >/dev/null
```

Expected: in the first output NEW appears before `</channel>`; in the second NEW appears before OLD and OLD is intact.

- [ ] **Step 5: Commit the script before the dry run** (so the dry run's precondition "clean tree" can be satisfied by stashing nothing)

```bash
git add scripts/release.sh scripts/ExportOptions.plist
git commit -m "build: add scripts/release.sh (notarized DMG + Sparkle appcast publish)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

- [ ] **Step 6: [MAINTAINER] Dry run** — the script insists on `main` with HEAD pushed, which the feature branch is not; `RELEASE_ALLOW_BRANCH=1` bypasses exactly those two checks and only when `--dry-run` is also given. Tell the human: "Dry run submits the app and DMG to Apple's notary service under your account. Nothing is tagged or published. OK?" On confirmation:

```bash
RELEASE_ALLOW_BRANCH=1 scripts/release.sh 0.0.1 --dry-run
```

Expected: every step prints, both notarizations end `status: Accepted`, `spctl` prints `accepted`, the item XML is printed, and the artifact paths are listed. Then verify the artifact by hand:

```bash
# paths from the script output
codesign -d --entitlements - "$APP" | grep -c app-sandbox      # 0
xcrun stapler validate "$DMG"                                    # The validate action worked!
hdiutil attach "$DMG" -quiet && ls /Volumes/Pastefix*/ && hdiutil detach /Volumes/Pastefix* -quiet
```

Common failures: notarization `Invalid` with "The binary is not signed with a valid Developer ID certificate" for `Sparkle.framework/…/Autoupdate` or an XPC service → the export step did not re-sign nested code; confirm `signingStyle manual` and `signingCertificate` in `ExportOptions.plist`. "The executable does not have the hardened runtime enabled" → Task 2 Step 4 missed one configuration.

Leave the artifacts in `$WORK`; Task 7 uses this build's shape as reference.

---

### Task 7: End-to-end local update test

**Files:** none committed. Uses two Debug builds, both signed with the Developer ID so Sparkle's same-team check passes.

**Interfaces:**
- Consumes: the Debug feed override (Task 3), `sign_update` (Task 1), the identity.

- [ ] **Step 1: Build and install "old" 1.0.0 (build 100)**

```bash
OLD=$(mktemp -d)/dd
xcodebuild build -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$OLD" \
  MARKETING_VERSION=1.0.0 CURRENT_PROJECT_VERSION=100 \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=RMKGLPG4K4 CODE_SIGN_IDENTITY="Developer ID Application" -quiet
pkill -x Pastefix || true
rm -rf /Applications/Pastefix.app
cp -R "$OLD/Build/Products/Debug/Pastefix.app" /Applications/Pastefix.app
```

- [ ] **Step 2: Build "new" 1.0.1 (build 101), DMG it, sign it, write the feed**

```bash
NEW=$(mktemp -d)/dd
xcodebuild build -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$NEW" \
  MARKETING_VERSION=1.0.1 CURRENT_PROJECT_VERSION=101 \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=RMKGLPG4K4 CODE_SIGN_IDENTITY="Developer ID Application" -quiet
FEED=$(mktemp -d)
STAGE=$(mktemp -d); cp -R "$NEW/Build/Products/Debug/Pastefix.app" "$STAGE/"
hdiutil create -volname "Pastefix 1.0.1" -srcfolder "$STAGE" -ov -format UDZO -quiet "$FEED/Pastefix-1.0.1.dmg"
SPARKLE_BIN="$NEW/SourcePackages/artifacts/sparkle/Sparkle/bin"
SIG=$("$SPARKLE_BIN/sign_update" "$FEED/Pastefix-1.0.1.dmg")
cat > "$FEED/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Pastefix (local test)</title>
    <item>
      <title>Version 1.0.1</title>
      <sparkle:version>101</sparkle:version>
      <sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.6</sparkle:minimumSystemVersion>
      <enclosure url="http://localhost:8000/Pastefix-1.0.1.dmg" type="application/octet-stream" $SIG/>
    </item>
  </channel>
</rss>
EOF
(cd "$FEED" && python3 -m http.server 8000 >/dev/null 2>&1 &)
curl -fsS http://localhost:8000/appcast.xml | grep -c edSignature    # 1
```

- [ ] **Step 3: Point the old app at the local feed and check**

```bash
defaults write scromp.net.Pastefix PastefixUpdateFeedURL "http://localhost:8000/appcast.xml"
open /Applications/Pastefix.app
```

Menu bar → **Check for Updates…**. Expected, in order:
1. Sparkle alert in front: "A new version of Pastefix is available! Pastefix 1.0.1 is now available—you have 1.0.0."
2. Click **Install Update**. Download completes, Sparkle asks to Install and Relaunch. Click it.
3. The app relaunches. Settings → General shows `Pastefix 1.0.1 (build 101)`.

```bash
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" /Applications/Pastefix.app/Contents/Info.plist   # 101
defaults read scromp.net.Pastefix SULastCheckTime
```

If Sparkle reports "The update is improperly signed" → the `sign_update` key does not match `SUPublicEDKey` (Task 2 Step 1 vs Step 2). If it reports a code-signing mismatch → one of the two builds was not signed with the Developer ID overrides.

- [ ] **Step 4: Scheduled-check behaviour for an LSUIElement app** — with 1.0.1 installed, rebuild a 1.0.2/102 the same way as Step 2 (replace the DMG and edit the appcast numbers), then force a scheduled check rather than a manual one:

```bash
defaults write scromp.net.Pastefix SUScheduledCheckInterval -int 60
defaults delete scromp.net.Pastefix SULastCheckTime
pkill -x Pastefix; sleep 1; open /Applications/Pastefix.app
```

Within about a minute Sparkle should surface the 1.0.2 alert. Record what happens: **(a)** alert appears in front → done; **(b)** alert exists but is behind other windows or only a Dock-less bounce → implement the fallback: in `UpdaterController.init` pass `userDriverDelegate: self`, conform (Debug **and** Release) to `SPUStandardUserDriverDelegate`, and implement

```swift
    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }
```

rebuild both test apps and repeat this step. Commit the fallback as `fix(app): bring scheduled Sparkle alerts to the front for the menu-bar agent` if it was needed. Whichever branch happened, note the result in the PR description; Task 8 records it in AGENTS.md.

- [ ] **Step 5: Clean up**

```bash
defaults delete scromp.net.Pastefix PastefixUpdateFeedURL
defaults delete scromp.net.Pastefix SUScheduledCheckInterval
pkill -f "http.server 8000" || true
pkill -x Pastefix || true
rm -rf /Applications/Pastefix.app
```

---

### Task 8: Documentation

**Files:**
- Create: `docs/RELEASING.md`
- Modify: `README.md` (Settings section, lines 19–29)
- Modify: `AGENTS.md` (project description, build/test/run, layout, invariants, "bitten us", status table)

- [ ] **Step 1: Write `docs/RELEASING.md`**

```markdown
# Releasing Pastefix

Pastefix ships as a notarized DMG from GitHub Releases and updates itself via
Sparkle, reading `https://bnaylor.github.io/pastefix/appcast.xml` (the
`gh-pages` branch). `scripts/release.sh` does the whole thing from a
maintainer's machine. Design: `docs/specs/2026-09-18-pastefix-v2-auto-update.md`.

## One-time setup (per maintainer machine)

1. **Developer ID.** A `Developer ID Application` certificate for team
   `RMKGLPG4K4` in the login keychain. The script picks the first one it finds;
   override with `CODESIGN_IDENTITY="Developer ID Application: … (RMKGLPG4K4)"`.
2. **Notary credentials.** Interactive, once:
   ```sh
   xcrun notarytool store-credentials pastefix-notary --team-id RMKGLPG4K4
   ```
   Use an App Store Connect API key, or your Apple ID plus an app-specific
   password from appleid.apple.com. Verify with
   `xcrun notarytool history --keychain-profile pastefix-notary`.
3. **Sparkle EdDSA private key.** This is the root of trust for every
   installed copy: an update signed with any other key is rejected, and a lost
   key means no installed copy can ever update again. The public half is in
   `Pastefix/Pastefix/Info.plist` (`SUPublicEDKey`).
   - Import an existing key on a new machine:
     `generate_keys -f /path/to/exported-key.txt`
   - Confirm the keychain key matches the app:
     `generate_keys -p` must print exactly the `SUPublicEDKey` value.
   - `generate_keys` lives in the Sparkle SPM artifact after any build:
     `find ~/Library/Developer/Xcode/DerivedData -path "*/artifacts/sparkle/Sparkle/bin/generate_keys"`.
   - **Never** run a bare `generate_keys` on a machine that lacks the key
     expecting to "regenerate" it. Restore from the backup export instead.
4. **`gh`** authenticated with push access to `bnaylor/pastefix`.

The `gh-pages` branch and GitHub Pages already exist. If they ever need
recreating: an orphan branch with an `appcast.xml` containing an empty
`<channel>` (title, link, description, language) and a `.nojekyll`, then
`gh api -X POST repos/bnaylor/pastefix/pages -f "source[branch]=gh-pages" -f "source[path]=/"`.

## Cutting a release

From a clean, pushed `main`:

```sh
scripts/release.sh 1.2.3 --dry-run   # builds, notarizes, DMGs, signs, prints the appcast item; publishes nothing
scripts/release.sh 1.2.3             # the same, then tags v1.2.3, creates the GitHub release, pushes the appcast
```

What it does, in order: archive (Release, Developer ID, hardened runtime) →
export → notarize + staple the app → DMG → sign + notarize + staple the DMG →
`sign_update` (EdDSA) → tag → `gh release create` with the DMG → prepend an
`<item>` to `appcast.xml` on `gh-pages`. Every step is fatal. The three
irreversible steps (tag, release, appcast) are last and adjacent.

Versions: the argument becomes `CFBundleShortVersionString`; `CFBundleVersion`
(what Sparkle compares) is `git rev-list --count HEAD`. No version-bump commit
is needed or wanted.

Release notes are whatever `gh release create --generate-notes` produces from
merged PRs; the appcast links to the release page. Edit the release on GitHub
afterwards if the generated notes need help.

## If something goes wrong

- **Notarization rejected.** The script prints the notary log. Usual causes:
  a nested binary not signed with the Developer ID (check
  `scripts/ExportOptions.plist`), or hardened runtime off on a configuration.
- **Release created but appcast push failed.** The release is harmless without
  a feed entry. Re-run only the appcast part: check out `gh-pages`, paste the
  printed `<item>` as the first item in `<channel>`, commit, push.
- **Tag pushed but release failed.** `gh release create vX.Y.Z <dmg> --verify-tag …`
  by hand using the DMG left in the script's work directory (path is printed).
- **Wrong key.** If `generate_keys -p` disagrees with `SUPublicEDKey`, stop.
  Restore the correct private key from backup. Do not change the public key in
  the app to match a new private key: every installed copy would stop updating.

## Testing an update locally without publishing

The Debug build honours a feed override:

```sh
defaults write scromp.net.Pastefix PastefixUpdateFeedURL http://localhost:8000/appcast.xml
```

Build two Debug apps with different `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`
overrides and `CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=RMKGLPG4K4 CODE_SIGN_IDENTITY="Developer ID Application"`
(Sparkle requires old and new to be signed by the same team), install the
older one in `/Applications`, DMG and `sign_update` the newer one, serve the
directory with `python3 -m http.server 8000` alongside an `appcast.xml` whose
`<enclosure>` points at `http://localhost:8000/<dmg>`, then Check for Updates.
Release builds ignore the override. Remove it afterwards with
`defaults delete scromp.net.Pastefix PastefixUpdateFeedURL`.
```

- [ ] **Step 2: README** — replace the line `**Forthcoming (Plan 2c):** auto-update delivery via Sparkle.` with:

```markdown
### Updates (Plan 2c)

Pastefix checks for updates once a day via [Sparkle](https://sparkle-project.org) and asks before installing anything. **Check for Updates…** in the menu bar runs a check on demand; Settings → General has an **Automatically check for updates** toggle, a **Check Now** button, and the installed version. Updates are EdDSA-signed and Developer-ID-verified; the feed is `https://bnaylor.github.io/pastefix/appcast.xml`. Maintainers: see [docs/RELEASING.md](docs/RELEASING.md).
```

- [ ] **Step 3: AGENTS.md** — make these edits:

1. In "What this project is", the `Pastefix` bullet: after "Includes a Settings window for …", append "Sparkle 2 provides auto-update (daily check, Check for Updates… menu item, Settings toggle)." Change the dependency sentence to "**Third-party dependencies:** KeyboardShortcuts (sindresorhus) and Sparkle, both app-target only; both packages remain dependency-free."
2. Delete the line `**Still forthcoming (Plan 2c):** Sparkle auto-update delivery.`
3. In "Build, test, run", after the app build block add:
   ```
   **Release (maintainers):** `scripts/release.sh X.Y.Z [--dry-run]` — notarized DMG to GitHub Releases + Sparkle appcast on `gh-pages`. Setup and recovery: `docs/RELEASING.md`.
   ```
4. In "Fresh clone on a new machine", replace the Signing caveat with: "**Signing:** `CODE_SIGN_STYLE = Automatic` with no team set signs locally for development. Releases are signed with the Developer ID for team `RMKGLPG4K4` and notarized by `scripts/release.sh`; that needs the certificate, the `pastefix-notary` keychain profile, and the Sparkle EdDSA private key on the machine (see `docs/RELEASING.md`)."
5. In the layout tree under `Pastefix/Pastefix/`, add:
   ```
       UpdaterController.swift           # Sparkle SPUStandardUpdaterController wrapper (+ Debug feed override)
       Info.plist                        # SUFeedURL, SUPublicEDKey, SUEnableAutomaticChecks, SUScheduledCheckInterval
       Pastefix.entitlements             # com.apple.security.cs.allow-jit only; NEVER app-sandbox
   ```
   and at top level:
   ```
   scripts/release.sh, scripts/ExportOptions.plist   # release pipeline (see docs/RELEASING.md)
   ```
   Update the `Pastefix/` comment to `# the Xcode app (KeyboardShortcuts + Sparkle dependencies only)` and the `Pastefix.xcodeproj` comment to `# ENABLE_APP_SANDBOX = NO, ENABLE_HARDENED_RUNTIME = YES`.
6. Add Critical Invariant 11:
   ```
   11. **Hardened runtime + notarization are release requirements, and the Sparkle key is the root of trust.** `ENABLE_HARDENED_RUNTIME = YES` with `Pastefix.entitlements` carrying `com.apple.security.cs.allow-jit` (JavaScriptCore) and never `app-sandbox`. Sparkle lives only in the app target. The EdDSA private key in the maintainer's login keychain signs every update; a release signed with a different key is rejected by every installed copy, so the key is backed up and never regenerated, and `scripts/release.sh` refuses to ship if the keychain key does not match `SUPublicEDKey`. The `CFBundleVersion` Sparkle compares is `git rev-list --count HEAD` at release time — never hand-edit it in the pbxproj.
   ```
7. In "Things that have bitten us", add a `*App (Plan 2c):*` subsection with one bullet per runtime finding from Tasks 2, 4, 6 and 7 (JIT entitlement needed or not; the scheduled-alert foregrounding result from Task 7 Step 4; any notarization rejection and its cause). Write what actually happened, with the fixing commit SHA.
8. Status table: `| 2c — Auto-update | Sparkle, hardened runtime, release script | 🟡 in review, PR #N |` (flip to ✅ with the merge SHA when merged).
9. Also update the spec (`docs/specs/2026-09-18-pastefix-v2-auto-update.md`) if Task 2 Step 6 removed the JIT entitlement or Task 7 Step 4 needed the user-driver fallback, so the spec describes what shipped.

- [ ] **Step 4: Commit**

```bash
git add docs/RELEASING.md README.md AGENTS.md docs/specs/2026-09-18-pastefix-v2-auto-update.md
git commit -m "docs: document Sparkle auto-update and the release pipeline

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 9: PR

- [ ] **Step 1: Final checks**

```bash
swift test 2>&1 | tail -1
xcodebuild build -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -destination 'platform=macOS,arch=arm64' -configuration Release -quiet
git status --short     # clean
git ls-files -s scripts/release.sh | awk '{print $1}'   # 100755
```

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin feat/auto-update
gh pr create --title "feat: Sparkle auto-update and release pipeline (Plan 2c)" --body "$(cat <<'EOF'
## Summary
- Sparkle 2 in the app target: daily checks, Check for Updates… menu item, Updates section in Settings
- Hardened runtime + entitlements + real Info.plist so the app can be notarized
- scripts/release.sh: archive → notarize → DMG → sign_update → GitHub Release → appcast on gh-pages
- docs/RELEASING.md, README, AGENTS.md (new Critical Invariant 11)

Spec: docs/specs/2026-09-18-pastefix-v2-auto-update.md
Plan: docs/plans/2026-09-18-pastefix-v2-auto-update.md

## Verification
- swift test green (unchanged, 66 tests)
- Dry-run release notarized and stapled app + DMG (Task 6)
- Local end-to-end update 1.0.0 → 1.0.1 via the Debug feed override (Task 7); scheduled-alert result: REPLACE with the Task 7 Step 4 outcome (a or b)
- Hardened-runtime build runs shell and JS transforms; no app-sandbox entitlement

## Invariants
Adds Critical Invariant 11 (hardened runtime, Sparkle key as root of trust). No existing invariant changed.
EOF
)"
```

- [ ] **Step 3: After merge** — on `main`, flip the status banners in this plan and the AGENTS.md table to ✅ with the merge SHA, then cut the first real release:

```bash
scripts/release.sh 1.0.0 --dry-run && scripts/release.sh 1.0.0
```

1.0.0 is the first build users can update *from*; it must be the merged code with the real public key. Confirm with a fresh install from the published DMG followed by **Check for Updates…** → "You're up to date!".
