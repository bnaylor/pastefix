---
type: spec
status: approved
id: 2026-09-21-pastefix-v2-sensitive-app-exclusion
title: Pastefix v2 — Sensitive-App Exclusion for Clipboard History (Plan 7)
description: Never record clipboard items copied from password managers and other user-listed apps; determine the source app before the pasteboard is read, fail closed across app switches, seed the list with common managers, edit it in a new Privacy tab, and add a menu-bar pause toggle.
tags: [pastefix, macos, swift, clipboard, history, privacy]
timestamp: 2026-09-21T04:30:00Z
---

# Pastefix v2 — Sensitive-App Exclusion (Plan 7)

Source: [issue #10](https://github.com/bnaylor/pastefix/issues/10). Builds on Plan 6's
two-stage `CaptureFilter` chain (`docs/specs/2026-09-21-pastefix-v2-clipboard-history.md`,
amendment 4) and closes that spec's open question about #10 readiness: the source app
must be known *before* the read, and both filter stages must receive it.

## Scope

**In scope:**

- `FrontmostAppTracker` (app target): tracks the frontmost application via
  `NSWorkspace` activation notifications and answers "which apps were frontmost
  within the last *n* seconds" without touching the pasteboard.
- `CaptureContext` passed to both `CaptureFilter` stages; `read` no longer samples the
  frontmost app; the candidate's source fields come from the context.
- `AppExclusionFilter`: rejects at stage 1 (content never read) when the source app,
  or any app frontmost within the poll window, is in the exclusion list.
- Filters, context, and the seed list move to `PastefixAppCore/Capture/` and get unit
  tests. The monitor stays in the app target.
- Setting `historyExcludedBundleIDs: [String]`, seeded with common password managers;
  Restore Defaults.
- New Settings tab **Privacy**: the History section (moved from General) plus the
  Excluded Apps list (icon + name, add from Applications, add by identifier, remove,
  restore defaults) and a caption about browser-extension managers.
- Menu-bar **Clipboard History** checkmark item toggling capture; a pause glyph in the
  menu-bar icon while capture is off.
- README, AGENTS (Critical Invariant 12 amended), this spec.

**Out of scope:** per-app *inclusion* lists; excluding by window title or URL; pausing
for a timed interval; exclusions for the summon editor (⌘⇧C is user-initiated on the
current clipboard and is unaffected); moving the monitor into the package.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| When the source app is determined | Before the read, from a tracker fed by `didActivateApplicationNotification`, not from `frontmostApplication` inside `read` | The poll runs up to 0.5 s after the copy; the user may already have switched apps. A notification-fed tracker knows what was frontmost during the whole window. |
| App switch inside the window | Fail closed: the context carries every app frontmost within the last `windowSeconds` (1.0 s = two poll intervals); the exclusion filter rejects if **any** is excluded | Missing a recording is cheap; recording a password is not. |
| Where the exclusion decision runs | Stage 1 (`shouldRead`) as well as stage 2 | An excluded app's bytes are never read, matching the concealed-marker treatment. Stage 2 repeats the check because the tracker may have learned of a switch between the two stages. |
| Match rule | Bundle identifier, case-insensitive, exact | Bundle ids are the stable identity; prefixes would over-match (`com.apple.*`). |
| Seed list | 1Password 8 `com.1password.1password`, 1Password 7 `com.agilebits.onepassword7`, Bitwarden `com.bitwarden.desktop`, Keychain Access `com.apple.keychainaccess`, Passwords `com.apple.Passwords`, Dashlane `com.dashlane.dashlanephonefinal`, LastPass `com.lastpass.LastPass`, KeePassXC `org.keepassxc.keepassxc`, Enpass `in.sinew.Enpass-Desktop`, NordPass `com.nordpass.macos`, Proton Pass `me.proton.pass.electron`, Strongbox `com.markmcguill.strongbox.mac` | The common managers; the list is user-editable so a wrong or missing id is a settings edit, not a release. |
| List semantics | The stored array is authoritative (default = seeds). Removing a seed sticks. "Restore Defaults" replaces the list with the seeds | Least surprising; no hidden "always excluded" set. |
| Browser-extension managers | Not addressable by bundle id (the copy comes from the browser); rely on the concealed marker, which 1Password, Bitwarden and Apple set | Stated in the Privacy tab caption and README rather than pretended away. |
| Settings layout | New **Privacy** tab (`hand.raised`) hosting History + Excluded Apps; General loses the History section | The General tab is at the fixed window height already (Plan 6 review nit). |
| Pause | Menu item `Toggle("Clipboard History", isOn: $settings.historyEnabled)`; `MenuBarExtra` icon `doc.on.clipboard` when on, `pause.circle` when off | Reuses the existing setting, sink, and overlay empty state; visible at a glance. |
| Testability | `CaptureFilter`, `CaptureContext`, `ConcealedTypeFilter`, `AppExclusionFilter`, `ExclusionSeeds` live in `PastefixAppCore/Capture/` (the package already imports AppKit for `ClipboardSnapshot`); `FrontmostAppTracker` and `PasteboardMonitor` stay in the app | The decision logic gets tests before a second filter joins the chain; the monitor is glue. |
| Invariant | Critical Invariant 12 gains: "the source app is determined before the read and every app frontmost within the poll window is checked against the exclusion list" | Load-bearing for the guarantee. |

## Architecture

### `PastefixAppCore/Capture/`

```swift
import AppKit

/// What the monitor knows about a pasteboard change before reading it.
public struct CaptureContext: Sendable, Equatable {
    /// Frontmost app at the time the change was noticed (best attribution).
    public var sourceBundleID: String?
    public var sourceAppName: String?
    /// Bundle ids of every app that was frontmost within the poll window, newest first,
    /// including `sourceBundleID`. Filters must treat all of them as possible sources.
    public var recentBundleIDs: [String]
    public init(sourceBundleID: String? = nil, sourceAppName: String? = nil, recentBundleIDs: [String] = [])
}

public protocol CaptureFilter: Sendable {
    func shouldRead(types: [NSPasteboard.PasteboardType], context: CaptureContext) -> Bool
    func shouldCapture(_ candidate: CaptureCandidate, types: [NSPasteboard.PasteboardType], context: CaptureContext) -> Bool
}

public struct ConcealedTypeFilter: CaptureFilter { /* moved verbatim; ignores context */ }

public struct AppExclusionFilter: CaptureFilter {
    public init(excludedBundleIDs: [String])           // lowercased into a Set
    public func isExcluded(_ bundleID: String?) -> Bool
    // shouldRead / shouldCapture: false if isExcluded(context.sourceBundleID) or any of context.recentBundleIDs
}

public enum ExclusionSeeds {
    public static let passwordManagers: [String]        // the twelve ids above, in that order
}
```

`SettingsStore`:
```swift
@Published public var historyExcludedBundleIDs: [String]   // key "pastefix.historyExcludedBundleIDs", JSON array
public func addExcludedBundleID(_ id: String)               // trims, rejects empty, de-dupes case-insensitively, appends
public func removeExcludedBundleID(_ id: String)
public func restoreDefaultExclusions()                      // = ExclusionSeeds.passwordManagers
```
Default when the key is absent: the seeds. An empty stored array is a valid user
choice ("exclude nothing") and is not re-seeded.

### `Pastefix` app

**`FrontmostAppTracker.swift`** (new, `@MainActor final class`):
- On init records `NSWorkspace.shared.frontmostApplication` as the current entry and
  observes `NSWorkspace.didActivateApplicationNotification` on
  `NSWorkspace.shared.notificationCenter`; each activation appends
  `(bundleID, name, activatedAt)` and trims entries older than `retention` (5 s).
- `func context(window: TimeInterval) -> CaptureContext`: `sourceBundleID`/`sourceAppName`
  = newest entry; `recentBundleIDs` = every distinct bundle id whose entry was current at
  any point within the last `window` seconds (the newest entry always; older entries
  while `activatedAt(next) > now − window`).
- Deterministic core extracted for tests? No — the tracker is app-side glue; its
  windowing arithmetic lives in a tiny pure helper `RecentApps.window(entries:now:window:)`
  in `PastefixAppCore/Capture/RecentApps.swift`, which *is* tested.

**`PasteboardMonitor`** — takes `tracker: FrontmostAppTracker` and `windowSeconds`
(1.0). In `tick`: sample types → `context = tracker.context(window: windowSeconds)` →
stage 1 with `(types, context)` → read → changeCount re-check → **refresh the context**
(`tracker.context(...)` again, so a switch learned during the read counts) → stage 2
with the union types and the refreshed context → fill `candidate.sourceBundleID/Name`
from the refreshed context's source → `onCapture`. `read` no longer touches
`NSWorkspace`.

**`AppDelegate`** — owns the tracker; builds the monitor with
`[ConcealedTypeFilter(), AppExclusionFilter(excludedBundleIDs: settings.historyExcludedBundleIDs)]`
and rebuilds the filter list when `settings.$historyExcludedBundleIDs` changes (the
monitor gets `var filters` with a setter, or is recreated — recreate is simpler and the
existing `updateMonitor` already handles start/stop).

**Menu bar** — `MenuBarExtra("Pastefix", systemImage: settings.historyEnabled ? "doc.on.clipboard" : "pause.circle")`
(the scene body observes `delegate.settings`), plus `Toggle("Clipboard History", isOn: $settings.historyEnabled)`
after "Summon Pastefix".

**`SettingsView`** — new `privacy` tab: `Section("History")` moved from General
verbatim; `Section("Excluded apps")` with a `List(selection:)` of rows
(`NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` → icon via
`NSWorkspace.shared.icon(forFile:)` and name via `Bundle(url:)`'s display name; missing
→ generic icon, raw id, "not installed" caption), a toolbar-style row of buttons:
**Add App…** (`NSOpenPanel`, `allowedContentTypes: [.application]`, directory
`/Applications`, bundle id read from `Bundle(url:)?.bundleIdentifier`; alert if none),
**Add Identifier…** (popover with a text field), **Remove** (selection), **Restore
Defaults**; caption: "Copies made by browser password extensions come from the browser,
not the manager; those are skipped when the extension marks them concealed, which
1Password, Bitwarden and Apple do." Window stays 460×400; the list scrolls.

## Data flow

User copies in 1Password → tracker already knows 1Password is frontmost → next tick:
types sampled, context = {1Password, recent [1Password]} → `AppExclusionFilter.shouldRead`
false → return (content never read; `lastChangeCount` advanced). User copies in
1Password and switches to Safari within 300 ms → tick: context source = Safari, recent
[Safari, 1Password] → rejected on the recent list. User copies in Safari from a
browser extension → not excluded by app; skipped iff the concealed marker is present.
Menu → Clipboard History off → icon becomes `pause.circle`, monitor stops, overlay
shows "Clipboard history is off".

## Error handling

- Tracker has no frontmost app (login window edge): context has nil source and empty
  recents; filters treat nil as not excluded (nothing to match) — the concealed filter
  still applies.
- `NSOpenPanel` selection without a bundle id → alert "That item has no bundle
  identifier", nothing added.
- Duplicate add → no-op (case-insensitive).
- Settings observer rebuilds the monitor on the main actor; a rebuild mid-tick is safe
  because the old timer is invalidated before the new one starts.

## Testing

`Tests/PastefixAppCoreTests/`:
- `AppExclusionFilterTests`: excluded source → both stages false; excluded app only in
  `recentBundleIDs` → both stages false; case-insensitive match; unrelated app → true;
  nil source + empty recents → true; empty exclusion list → true.
- `ConcealedTypeFilterTests` (new, now testable): each marker rejects at both stages;
  plain types pass; context ignored.
- `RecentAppsTests`: windowing — single entry; two entries with the switch inside the
  window → both; switch outside → newest only; de-duplication of repeated ids; order
  newest first.
- `ExclusionSeedsTests`: twelve ids, all lowercase-unique, contains the 1Password 8 and
  Apple Passwords ids.
- `SettingsStoreTests` additions: default is the seeds; empty array persists as empty
  (not re-seeded); add trims/de-dupes case-insensitively; remove; restore.

Automated app pass (controller drives the Debug build): add the terminal's bundle id
via `defaults`, relaunch, copy → not recorded; remove it → recorded; toggle capture via
the setting → icon/overlay state; existing Plan 6 checks still pass (concealed, de-dup,
⌘⇧V/⌘↵). Visual: Privacy tab layout.

## Documentation

- README: "Clipboard history" gains an "Excluded apps" paragraph and the pause item;
  Settings list updated (Privacy tab).
- AGENTS.md: layout (`Capture/`, `FrontmostAppTracker.swift`), Invariant 12 amended,
  status row for Plan 7, "bitten us" entries from review.
- Plan 6 spec: "Open questions" entry for #10 marked resolved here.

## Project layout delta

```
Sources/PastefixAppCore/
  Capture/CaptureContext.swift       # CaptureContext, CaptureFilter protocol
  Capture/ConcealedTypeFilter.swift  # moved from the app target
  Capture/AppExclusionFilter.swift
  Capture/ExclusionSeeds.swift
  Capture/RecentApps.swift           # pure windowing helper
  SettingsStore.swift                # + historyExcludedBundleIDs (+ add/remove/restore)
Pastefix/Pastefix/
  FrontmostAppTracker.swift          # new
  PasteboardMonitor.swift            # context in both stages; read no longer samples NSWorkspace
  PastefixApp.swift                  # tracker, filter rebuild on setting change, menu toggle + icon
  SettingsView.swift                 # Privacy tab
```
