# Local GUI verification: requirements and process

How the controller drives the real Debug app to verify behaviour the package
tests cannot reach (panel timing, overlays, banners, hotkeys, Settings,
Accessibility-dependent paste). Everything here has been used on this repo;
the helper sources live in `tools/gui-automation/`.

## Ground rules

1. **Ask before taking the screen.** Several sessions share this machine's
   screen and pasteboard. Ask, wait for a yes, and post one line when you
   start. Batch the whole pass into a few minutes.
2. **`pb begin` before the pass, `pb end` after quitting the app, and the
   verify is the proof.** `begin` snapshots every type of every pasteboard
   item (not just text) to `~/.local/state/pfx-ui/clipboard.json` (mode 0600
   in a 0700 directory) and refuses if a save from an unfinished pass is
   already there. `end` restores the items in their original type order,
   reads the pasteboard back, verifies every saved type byte-for-byte, and
   only then deletes the save. That verify is the proof of this rule
   (`cmp <(pbpaste) …` is at most a text-only sanity check). If `end` exits
   non-zero, tell the user exactly what was and was not restored: 3 = the
   save did not parse and the pasteboard was not touched; 4 = written but
   some types read back differently (the save is kept, retry `end`); 5 =
   restored and verified, but types whose data the provider never
   materialised (promised/lazy data) could not be captured at `begin` and
   are not on the pasteboard now — `begin` warns about them and `end` names
   them. Every destructive `pb` subcommand (`text`, `concealed`,
   `concealed-late`, `legacy`, `tiff`, `png`, `rich`) refuses (exit 2)
   unless a save exists, parses, and is younger than `PFX_PB_MAX_AGE_HOURS`
   (default 6); an older save means an abandoned pass — `pb end` it or
   `pb discard` it before starting a new one.
3. **Never type blind.** Keystrokes go to whatever is frontmost. If the panel
   is not up yet (large buffers take seconds, an update dialog may be in
   front), your ⌘K and text land in someone's terminal. Capture and check
   before typing, or wait long enough and verify with a capture afterwards.
4. **Leave the machine as you found it.** Quit the Debug app, remove temporary
   scripts from `~/.config/pastefix/scripts`, clear any test settings or
   Keychain tokens you set, `git checkout main`. This includes the clipboard
   **history**, not just the live clipboard: every fixture you `pb`-copy —
   especially the secret-shaped ones (`concealed`, `legacy`, the private-key
   text in the cookbook) — gets captured into the real history index and blob
   store (`~/Library/Application Support/Pastefix/history/`) and survives
   quitting the app. Purge what a pass created with
   `python3 ~/.local/bin/pfx-ui/idx.py purge --after "$PASS_START" --dry-run`
   and then the same line without `--dry-run`. `--contains TEXT` narrows it,
   but image fixtures have no text to match, so `--after` (the `PASS_START`
   recorded at the top of the pass) is the reliable filter. Pinned items are
   never purged, a backup `index.json.bak-<UTC>` is written first with the
   index's own mode, and it refuses if a Pastefix process is running, since
   the store holds the index in memory.
5. **Never point an upload or network feature at a real server** in a GUI
   pass. Use a `.invalid` host to get a failure path for free.
6. **Measure, don't fix, when another session owns the branch.** Report
   frames, values and screenshots; leave changes to the owner.

## One-time machine requirements

- Xcode with the macOS 15 SDK, `swiftc` on `PATH`.
- Developer ID identity in the login keychain
  (`Developer ID Application: Brian Naylor (RMKGLPG4K4)`).
- TCC grants for the **host app that runs your shell** (Terminal, iTerm, the
  IDE's terminal): Accessibility (CGEvent posting and AX reads), Screen
  Recording (`screencapture`), and Automation → System Events (keystrokes).
  macOS prompts on first use; the grant survives updates of the host app.
- Accessibility grant for the **Debug Pastefix app** only when testing snippet
  paste (⌘V posting). This grant is keyed to the code signature: an ad-hoc
  Debug signature changes every build, so the grant evaporates. Re-sign after
  every build (below) and the grant persists.
- Helpers built once per machine: `tools/gui-automation/build.sh` →
  `~/.local/bin/pfx-ui/` (captures and clipboard saves go in
  `~/.local/state/pfx-ui/`).

## Per-pass process

```sh
# 1. Build the branch's Debug app and re-sign it
xcodebuild -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -configuration Debug \
  -derivedDataPath /tmp/pastefix-dd build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
codesign --force --deep --sign "Developer ID Application: Brian Naylor (RMKGLPG4K4)" \
  /tmp/pastefix-dd/Build/Products/Debug/Pastefix.app
codesign -dvv /tmp/pastefix-dd/Build/Products/Debug/Pastefix.app 2>&1 | grep '^Authority=Developer ID Application'

# 2. Record the start, begin the clipboard pass, launch
PASS_START=$(date -u +%FT%TZ)
~/.local/bin/pfx-ui/pb begin          # ~/.local/state/pfx-ui/clipboard.json; refuses over an unfinished pass
pgrep -fl "MacOS/Pastefix"            # must be empty: two instances both answer the hotkeys
open /tmp/pastefix-dd/Build/Products/Debug/Pastefix.app; sleep 3
PID=$(pgrep -f "MacOS/Pastefix" | head -1)

# 3. Drive it (see the cookbook), capturing after every step
# 4. Quit, end the clipboard pass (restore + byte verify), purge the history
osascript -e 'quit app "Pastefix"'
~/.local/bin/pfx-ui/pb end            # non-zero: report exactly what was and was not restored
python3 ~/.local/bin/pfx-ui/idx.py purge --after "$PASS_START" --dry-run   # then without --dry-run
```

Chain each scenario into one shell invocation with `sleep`s between steps and
a `screencapture` after each state change; read the PNGs afterwards. One
scenario per invocation keeps a failure from cascading into stray keystrokes.

## Cookbook

**Keystrokes and hotkeys** (System Events; the Debug app shares the user's
saved bindings, read them with
`defaults read scromp.net.Pastefix | grep KeyboardShortcuts_`):

```sh
K() { osascript -e "tell application \"System Events\" to $1"; }
K 'keystroke "c" using {command down, shift down}'   # summon (default ⌘⇧C)
K 'keystroke "v" using {command down, shift down}'   # history overlay (⌘⇧V)
K 'keystroke "u" using {command down, shift down}'   # upload overlay (⌘⇧U)
K 'keystroke "k" using {command down}'               # ⌘K palette (only once the panel is up)
K 'keystroke "some text"'; K 'key code 36'           # type, Return
K 'key code 53'                                      # Esc: closes an overlay, then the session
```

Key codes: Return 36, Esc 53, Delete 51, Tab 48, V 9, C 8, K 40, S 1, P 35,
M 46, L 37, Y 16, "1" 18. Modifiers held for a hotkey deadline test:
`~/.local/bin/pfx-ui/hold 600` posts ⌃⌥⌘1 and keeps the modifiers down 600 ms.
If a human touches the keyboard during that window, those modifiers land on
their keystrokes too — say so before running it. The release sequence is
posted on normal exit, from `atexit`, and on SIGINT/SIGTERM/SIGHUP/SIGQUIT;
it is not posted after a fatal signal (SIGSEGV, SIGABRT, SIGTRAP, …) and
SIGKILL cannot be caught, so a crash inside the hold window leaves the
modifiers held. If they stick, tap ⌃, ⌥ and ⌘ once each, or run `hold 0`
(it re-posts the chord and immediately posts the release sequence).

**Pasteboard fixtures:** `pbcopy < file` for anything large;
`~/.local/bin/pfx-ui/pb text "…" | concealed "…" | concealed-late "…" |
legacy "…" | tiff W H | png W H | rich "…" | types | count` for the special
cases (concealed/transient markers, real TIFF/PNG images, RTF + string). Each
of those destructive subcommands refuses (exit 2) unless a fresh save from
`pb begin` exists at `~/.local/state/pfx-ui/clipboard.json` (or
`$PFX_PB_SAVE`) — see ground rule 2. Set `PFX_PB_FORCE=1` only when you
deliberately don't need one; it prints that it skipped the check.
`PFX_PB_NAME=<name>` points every subcommand at a private named pasteboard,
which is how the begin/end round trip is self-tested without touching the
live clipboard.

**Clicking:** System Events cannot click SwiftUI buttons reliably; use
`~/.local/bin/pfx-ui/click $PID X Y` (CGEvent, screen points). `click` reads
the target pid's AX windows first and refuses (exit 2, no event posted) if
the point falls outside every one of them, so a stale coordinate can't land
on whatever else is on screen. That scope is not a scale validator (a
doubled coordinate can still land inside the same window) and does no
z-order check (a foreign window over the target still takes the click).
Exit 3 means the AX windows could not be read at all: no Accessibility grant
for the host app running your shell, or a wrong pid. Get X,Y either from an
AX dump (frames are in screen points, top-left origin) or from a screenshot:
Retina captures are 2×, so `point = rect_origin + pixel / 2`.

**Reading the UI without pixels:** `~/.local/bin/pfx-ui/ax $PID [depth]` dumps every
AX element of the app's windows with role, title, value (length shown when
truncated), placeholder, focus flag and frame. Use it to measure geometry
(is the action row inside the window?), to read field values and
placeholders, to prove typed text did or did not reach the editor (compare
the text area's length before and after), and to find click targets. Depth 0
prints just the windows.

**Screenshots:** `screencapture -x -R "x,y,w,h" out.png`. The panel centres
itself on each summon; read its frame from `ax $PID 0` rather than hard-coding
(`544,189,780,460` has been typical; add ~50 pt above if the panel grew).
Resize to the minimum with
`osascript -e 'tell application "System Events" to tell process "Pastefix" to set size of window 1 to {780, 100}'`
(clamped to the minimum by AppKit).

**Settings:** open from the menu bar extra, not ⌘, (the panel is a
non-activating panel):
`… tell process "Pastefix" to click menu bar item 1 of menu bar 2`, then
`click menu item "Settings…" of menu 1 of menu bar item 1 of menu bar 2`.
Tabs are `AXButton title="Upload"` etc. in the dump; click their centre.
Settings scrolls; rows below the window bottom have AX frames past it.

**Slow transform for cancel tests:** drop
`printf '#!/bin/sh\nsleep 10\ncat\n' > ~/.config/pastefix/scripts/slow.sh; chmod +x …`
(the watcher picks it up within a second; the palette lists it as "slow").
Remove it afterwards. Note `ShellRunner` kills the child at its own timeout;
Esc abandons the wait, it does not kill the process.

**History store inspection:** `python3 ~/.local/bin/pfx-ui/idx.py` prints the
index and blob directory (`~/Library/Application Support/Pastefix/history`).
`idx.py purge --after TS` and/or `--contains TEXT` (`--dry-run` to preview;
a bare `--dry-run` with no filter is refused) removes matching entries and
their blob files: it never removes pinned items, writes
`index.json.bak-<UTC>` with the index's own mode before rewriting the index
atomically (mode preserved), and refuses while a Pastefix process is running.
A naive `--after` is read as local time and the window is printed in UTC
before anything is touched. `PFX_HISTORY_DIR` points it at a copy for testing.

## Where the app keeps state

| What | Where |
|---|---|
| Defaults domain | `scromp.net.Pastefix` (`defaults read scromp.net.Pastefix`) |
| Hotkeys | `KeyboardShortcuts_summonPastefix`, `_summonHistory`, `_uploadToZipline` keys in that domain |
| Scripts directory | `~/.config/pastefix/scripts` unless `pastefix.scriptsDirectory` is set |
| History | `~/Library/Application Support/Pastefix/history/index.json` + blobs |
| Zipline server URL / token | `pastefix.zipline.serverURL` default / Keychain (clear via the Upload tab) |
| Debug build | `/tmp/pastefix-dd/Build/Products/Debug/Pastefix.app` |

## Things that have bitten these passes

- **Sparkle update dialog on the Debug build.** The Debug bundle reports
  version "1.0", the appcast has "1.0.0", so a "new version available" sheet
  can appear at launch and swallow every keystroke. Dismiss with `click $PID X Y` on
  "Remind Me Later" while the dialog is unobstructed (Esc the panel first);
  clicking through the panel hits the panel instead.
- **Typing before the panel exists.** A 2 MB buffer takes ~6 s to show the
  panel (#52). Capture, confirm, then type. Choose the smallest fixture that
  still crosses the threshold you are testing (100 KB, not 2 MB, to hit a
  64 KB cap).
- **Palette focus.** After a stray click the palette can be open with focus in
  the editor; typed text then lands in the buffer. Open the palette with ⌘K
  from a clean panel and check the query field in a capture before Return.
- **Stale incremental builds after protocol changes** can SIGSEGV tests or
  mis-dispatch in the app: build clean when a protocol gained requirements.
- **Fixtures land in the real history.** The Debug app shares the user's history store, so every `pb text` and every summoned fixture is recorded and persists after quit. The Zipline measurement pass left a secret-shaped fixture and two others behind; they were found by the `idx.py` listing the next day. Purge at the end of every pass with `--after "$PASS_START"`, with the app quit.
- **Two instances.** If a release Pastefix is running, both answer the
  hotkeys. Quit it first (and tell the user you did).
- **`click` coordinates from a capture rect that has drifted.** Re-read the
  window frame after any resize or re-summon.
