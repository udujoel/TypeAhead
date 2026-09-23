# Shipping TypeAhead to other Macs (signed DMG + auto-update)

TypeAhead currently runs only as a development build on this Mac. Giving it to other people needs
three things only the owner can provide: a **paid Apple Developer account** (Developer ID
certificate + notarization), and a **web address** to host the download and its update feed.
This guide lists every step; nothing here has been run yet.

## 1. One-time setup (owner)

1. **Join the Apple Developer Program** (developer.apple.com → Account → Enroll, yearly fee).
2. **Create a "Developer ID Application" certificate:** Xcode → Settings → Accounts → select your
   team → Manage Certificates → **+** → Developer ID Application.
3. **Save notarization credentials** so the tools can log in without prompting. In Terminal:
   ```bash
   xcrun notarytool store-credentials TypeAheadNotary --apple-id YOUR_APPLE_ID --team-id U2Y24928BV
   ```
   It asks for an *app-specific password* — create one at appleid.apple.com → Sign-In and Security.
4. **Pick hosting** for `TypeAhead.dmg` and `appcast.xml` (e.g. GitHub Releases + GitHub Pages).

## 2. Build, sign, notarize, package (each release)

```bash
cd TypeAhead
xcodebuild archive -project TypeAhead.xcodeproj -scheme TypeAhead -configuration Release \
  -archivePath /tmp/TypeAhead.xcarchive
xcodebuild -exportArchive -archivePath /tmp/TypeAhead.xcarchive \
  -exportOptionsPlist ../docs/ExportOptions.plist -exportPath /tmp/TypeAhead-export
hdiutil create -volname TypeAhead -srcfolder /tmp/TypeAhead-export/TypeAhead.app -ov -format UDZO /tmp/TypeAhead.dmg
xcrun notarytool submit /tmp/TypeAhead.dmg --keychain-profile TypeAheadNotary --wait
xcrun stapler staple /tmp/TypeAhead.dmg
```

`docs/ExportOptions.plist` needs to be created with `method` = `developer-id` and your team ID.
The Release build must keep **App Sandbox off** (see CLAUDE.md) and keep the hardened runtime on
(notarization requires it).

## 3. Auto-update with Sparkle

1. In Xcode: File → Add Package Dependencies → `https://github.com/sparkle-project/Sparkle` → add
   the **Sparkle** product to the TypeAhead target.
2. Generate update-signing keys once (Sparkle's `generate_keys` tool, in the package's `bin`
   folder). It stores the private key in your keychain and prints a **public key**.
3. In `Info.plist` add `SUFeedURL` (your `appcast.xml` address) and `SUPublicEDKey` (that key).
4. Wire the menu: create an `SPUStandardUpdaterController` in `AppDelegate` and add a
   "Check for Updates…" item to `StatusBarMenu` that calls `checkForUpdates(_:)`. (The old
   greyed-out placeholder was removed on purpose — only add it back once it works.)
5. For each release, run Sparkle's `generate_appcast` on the folder holding the new DMG and
   upload the DMG and `appcast.xml`.

## 4. Before the first public release

- Test the notarized DMG on a second Mac (or a new macOS user account): open it, drag to
  Applications, launch, grant Accessibility, and confirm suggestions appear.
- Remember: models download on first run (~1–4 GB), so the first launch needs internet access;
  completions themselves never use the network.
