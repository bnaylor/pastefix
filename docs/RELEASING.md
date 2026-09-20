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
5. **Export signing certificate.** `scripts/ExportOptions.plist` names the
   generic `signingCertificate` "Developer ID Application" rather than one
   exact identity. If more than one Developer ID Application certificate is in
   the keychain (e.g. an old, expired one left behind), `-exportArchive` may
   pick a different certificate than the `CODESIGN_IDENTITY` the archive step
   used. Remove expired certificates from the keychain, or edit the plist's
   `signingCertificate` to the exact certificate name, to avoid the mismatch.

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

Any second argument other than exactly `--dry-run` is rejected. `RELEASE_ALLOW_BRANCH=1`
skips the `main`/pushed-to-origin checks so a release can be dry-run tested from a
feature branch; the script refuses to honor it without `--dry-run`, and a real
release must never set it.

What it does, in order: archive (Release, Developer ID, hardened runtime,
**universal** — `-destination 'generic/platform=macOS'`, because
`minimumSystemVersion` 14.6 includes Intel Macs) → export → notarize + staple
the app → DMG → sign + notarize + staple the DMG → `sign_update` (EdDSA) →
tag → `gh release create` with the DMG → prepend an `<item>` to `appcast.xml`
on `gh-pages`. Every step is fatal. The three irreversible steps (tag,
release, appcast) are last and adjacent.

Versions: the argument becomes `CFBundleShortVersionString`; `CFBundleVersion`
(what Sparkle compares) is `git rev-list --count HEAD`. No version-bump commit
is needed or wanted.

Release notes are whatever `gh release create --generate-notes` produces from
merged PRs; the appcast links to the release page. Edit the release on GitHub
afterwards if the generated notes need help.

Each run leaves its work directory (DerivedData, archive, DMG) under
`$TMPDIR`; delete it when done.

## If something goes wrong

- **Notarization rejected.** The script prints the notary log. Usual causes:
  a nested binary not signed with the Developer ID (check
  `scripts/ExportOptions.plist`), or hardened runtime off on a configuration.
- **Wrong key.** If `generate_keys -p` disagrees with `SUPublicEDKey`, stop.
  Restore the correct private key from backup. Do not change the public key in
  the app to match a new private key: every installed copy would stop updating.

### Recovery after a failure past the tag push

The tag is pushed before the GitHub release is created, so a failure in
`gh release create`, the asset-reachability check that follows it, or the
appcast push leaves `v<version>` on `origin` — and the script's own
precondition ("tag already exists on origin") then refuses to let you just
re-run it.

- If the release was **not** created: `git push --delete origin vX.Y.Z && git tag -d vX.Y.Z`,
  then re-run `scripts/release.sh X.Y.Z`.
- If the release **was** created: `gh release delete vX.Y.Z --yes --cleanup-tag`
  (deletes both the release and the tag, locally and on origin), then re-run.
- If only the appcast push failed, the release itself is fine and doesn't need
  undoing — paste the saved `$WORK/item.xml` (the work-directory path the
  script prints) into `appcast.xml` on `gh-pages` by hand: as the first
  `<item>` in `<channel>`, commit, push.
- If the script was interrupted between adding and removing its `gh-pages`
  worktree, run `git worktree prune`. Normally an `EXIT` trap removes the
  worktree even on failure, but a killed process can skip it.

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
