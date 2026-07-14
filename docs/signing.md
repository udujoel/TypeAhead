# Fixing "TypeAhead keeps asking to re-grant Accessibility"

If TypeAhead asks you to re-grant Accessibility permission every single time you rebuild it, a broken permission record got created and needs a one-time reset. Follow these steps in order.

## One-time recovery steps

1. **Quit TypeAhead.** Click the TypeAhead icon in the menu bar and choose Quit (or use the "Quit TypeAhead" button in Settings if you added one).

2. **Open Terminal.** Press `Cmd+Space`, type `Terminal`, and press `Enter`.

3. **Paste and run this command** to clear the broken permission record:

   ```
   tccutil reset Accessibility com.hashtari.TypeAhead
   ```

   This wipes out whatever Accessibility grant is currently on file for TypeAhead (good or bad), so macOS will ask you to grant it fresh, cleanly, for the next build you launch.

4. **In Xcode, press `Cmd+B`** to rebuild the app. Do **not** press `Cmd+R` — that runs the app through Xcode's debugger, which becomes the "responsible process" for Accessibility instead of TypeAhead itself, and Accessibility reads will fail even if you grant permission.

5. **In Terminal**, `cd` into the repo folder and run:

   ```
   ./run.sh
   ```

   This launches the freshly built app the correct way (via macOS LaunchServices), so the Accessibility grant attaches to the real app.

6. **Grant Accessibility.** Open System Settings → Privacy & Security → Accessibility, and turn ON the toggle next to TypeAhead.

7. **Verify the fix.** Press `Cmd+B` in Xcode again, then run `./run.sh` again. It should **not** ask you to re-grant Accessibility this time. If it does, something is still launching an ad-hoc-signed build — double check you're not accidentally opening the build produced by the headless compile-check command described in `CLAUDE.md` (that build is intentionally not signed for Accessibility, and `run.sh` now refuses to launch it and will tell you so).

## Optional cleanup (safe to skip)

These two items showed up during investigation. They are **not** the cause of the re-grant problem — they're just harmless clutter you can tidy up if you want to:

- **Duplicate certificates in Keychain Access.** You may see two "Apple Development: udujoel@gmail.com" certificates — one issued 2026-05-25 and one issued 2026-06-08. It's safe to delete the older one (2026-05-25) and keep the newer one (2026-06-08). Open Keychain Access, find the certificate, right-click → Delete.
- **Orphan DerivedData folder.** There may be a leftover folder named `~/Library/Developer/Xcode/DerivedData/typeahead-bweeswsakytzgycbyjupnieytwaz`. This is cosmetic and can be deleted via Finder → Go → Go to Folder, paste the path, then delete the folder. It plays no role in the Accessibility problem.

## If it regresses again

The root cause of this bug is launching an ad-hoc-signed (not "Apple Development" signed) build of TypeAhead — most commonly the product of the headless `xcodebuild ... CODE_SIGNING_ALLOWED=NO` compile-check described in `CLAUDE.md`. `run.sh` now checks the code signature before launching and refuses to launch anything that isn't signed "Apple Development", so this shouldn't be able to happen again through `run.sh`.

If the re-grant loop still comes back:

1. Run `tccutil reset Accessibility com.hashtari.TypeAhead` again.
2. Make sure the only builds you ever launch are ones built with `Cmd+B` in Xcode (never the isolated compile-check build, and never anything launched with `Cmd+R`).
