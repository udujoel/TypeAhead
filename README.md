# TypeAhead

Real-time text completion in any text field on your Mac, running entirely on-device.

TypeAhead is a native macOS menu-bar app. As you type in any app (Mail, Slack, a browser,
an editor), it shows the rest of the sentence as ghost text at the caret. Press Tab to
accept it word by word. Completions come from a small language model running locally on
Apple Silicon, so nothing you type leaves the machine.

## Who it's for

People who want Copilot-style autocomplete everywhere they type, without sending their
writing to a cloud service.

## Features

- Inline ghost-text completions in any text field, positioned at the caret across monitors
- Tab / ⌥→ accepts the next word, ⇧Tab accepts the whole suggestion, ⌥Tab sends a plain Tab
- Word alternatives (⌥↓, then 1–3), autocorrect, emoji and word completion
- Optional context from the clipboard and the current screen to improve suggestions
- Personalisation from your own typing history, stored locally
- Per-app rules: turn completions or history off for specific apps
- Secret fields (passwords, PINs, one-time codes) are never read
- Statistics view of acceptance rate and usage

## Privacy

- All inference runs on-device. TypeAhead makes no network calls for completions.
- Models are downloaded once from Hugging Face (mlx-community) into `~/Library/Caches/models/`.
- Typing history lives in `~/Library/Application Support/TypeAhead/history.db`, readable only
  by your user account, and never leaves the Mac. You can turn collection off globally or per app.

## Built with

- Swift 6, SwiftUI and AppKit
- [MLX Swift](https://github.com/ml-explore/mlx-swift-lm) for on-device inference, with
  swift-transformers for tokenisation
- macOS Accessibility API and CGEventTap for reading and writing text fields system-wide
- ScreenCaptureKit for optional screen context
- SwiftData for local history, Swift Charts for statistics, Sparkle for updates

Default model: Gemma 4 E2B (4-bit). Gemma 4 E4B, Gemma 3 4B and Qwen 3 models can be
selected in Settings.

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon (M1 or later); MLX does not run on Intel Macs
- Xcode 16 or later
- Accessibility permission for the built app (System Settings → Privacy & Security → Accessibility)

## Running it

```bash
open TypeAhead/TypeAhead.xcodeproj
```

1. Build with **Cmd+B** in Xcode. Don't use Cmd+R: when the debugger launches the app,
   macOS attributes Accessibility to the debugger and cross-app reads fail.
2. Launch the build with `./run.sh`, which opens it through LaunchServices and tails its log.
3. Grant Accessibility when prompted, then pick a model from the menu-bar icon.

If macOS keeps asking you to re-grant Accessibility after each build, see
[docs/signing.md](docs/signing.md).

## Tests

The pure-logic code is covered by a Swift Package test target (about 490 tests):

```bash
swift test
```

## Project layout

```
TypeAhead/TypeAhead/   the app: Core (pipeline, inference), Caret, Overlay, Context,
                       Personalization, Persistence, Features, UI
Tests/TypeAheadTests/  unit tests
docs/                  design notes, backlog and release guide
scripts/               helper scripts
```

## Roadmap

Planned work is tracked in [docs/backlog-2026-09-cotypist-parity.md](docs/backlog-2026-09-cotypist-parity.md)
and [docs/next-features.md](docs/next-features.md). Shipping signed, notarised builds to
other Macs is described in [docs/release.md](docs/release.md).

## License

[MIT](LICENSE)
