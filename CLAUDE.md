# TypeAhead — Build Instructions

## What This Is
TypeAhead is a native macOS app that provides system-wide, real-time AI text completion in any text field. It uses MLX Swift for on-device inference (Apple Silicon only) and the macOS Accessibility API to read/write text fields across all apps. No cloud, no sandbox.

## How to Run
```bash
# Open in Xcode (required for macOS app bundle, entitlements, and AX testing)
open TypeAhead.xcodeproj

# Build with Cmd+B (never Cmd+R — debugger becomes AX responsible process, reads fail)
# Then run: ./run.sh (launches via LaunchServices for correct TCC responsible process)

# Unit tests via SPM (pure logic only; 491 tests)
swift test

# Full app build (headless, signing disabled for compile-check)
# ALWAYS pass an isolated -derivedDataPath for this command — never omit it.
cd TypeAhead && xcodebuild build -project TypeAhead.xcodeproj -scheme TypeAhead -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/typeahead-compile-check
```

**Never launch the product of this compile-check** — it is ad-hoc signed (CODE_SIGNING_ALLOWED=NO), and launching it (e.g. via run.sh) poisons the Accessibility (TCC) grant for the real Xcode-built app, forcing a re-grant on every subsequent rebuild. The isolated -derivedDataPath keeps it out of the directory run.sh launches from.

**Note for agents:** any headless/scripted compile-check invocation of `xcodebuild` MUST use an isolated `-derivedDataPath` (e.g. `/tmp/typeahead-compile-check`), never the default DerivedData directory. `run.sh` finds and launches the newest build under `~/Library/Developer/Xcode/DerivedData/TypeAhead-*/...`; a compile-check build left there is ad-hoc signed and, if launched, breaks the Accessibility permission (see `docs/signing.md` for recovery steps).

## Requirements
- macOS 14+ (Sonoma)
- Apple Silicon (M1 or above) — MLX is Apple Silicon only
- Xcode 16+
- Accessibility permission granted to the built app in System Settings → Privacy & Security

## Tech Stack
- Swift 6, SwiftUI, AppKit (NSPanel, NSStatusItem, NSEvent)
- MLX: `ml-explore/mlx-swift-lm` 3.31.3 (products MLXLLM, MLXLMCommon); `HFBridge.swift` implements tokenizer protocols (v3 ships no defaults)
- swift-transformers 0.1.24 (Gemma/Qwen tokenization; one product `Transformers`, import `Hub` directly)
- SwiftData (typing history, SQLite under the hood)
- Swift Charts (Statistics view)
- Sparkle (auto-update)
- AXUIElement / CGEventTap (system-wide text field access)
- ScreenCaptureKit (screenshot context)

## Key Architecture
```
KeyEventMonitor → CompletionPipeline → InferenceEngine
                       ↑                     ↑
               AccessibilityManager    ContextBuilder
                                             ↑
                               ScreenshotContextProvider
                               ClipboardContextProvider
                               PersonalizationEngine
                        ↓
                 CompletionOverlay (NSPanel ghost text)
```

## Important Rules
- **No sandbox.** `ENABLE_APP_SANDBOX` must be **NO** in pbxproj build settings (Debug & Release). Xcode injects sandbox from build settings, not `.entitlements` file. Sandboxed app cannot do cross-process AX (every read fails `-25204 cannotComplete`).
- All inference runs on-device. No network calls for completions ever.
- Never read `kAXPasswordRole` fields — the AX API blocks this by design, do not attempt workarounds.
- Cancel active inference immediately on any non-Tab keystroke.
- Per-app precedence (`AppPolicyResolver`): the **global** "Enable Completions" and "Collect inputs" toggles are master switches — off means off in every app. Under an enabled global switch, the per-app exception list disables an app, and an explicit per-app override (Settings → Apps, status menu, ⌃⌥⌘`) beats the exception list, so a user can re-enable a specific excluded app.
- Every settings toggle must do what it says. Typing history is written only when `ResolvedPolicy.recordHistory` allows it.
- Secret fields (`SecureFieldClassifier`: password role, `AXSecureTextField` subrole, password/PIN/OTP labels, masked contents) are never read, and never fall back to the keystroke buffer.
- Model files download to `~/Library/Caches/models/{repoId}/` via MLXLLM. Never bundle models; never hardcode paths.
- History DB lives in `~/Library/Application Support/TypeAhead/history.db` — plain SwiftData/SQLite, not encrypted at rest; the file is chmod 0600 (owner read/write only) and never leaves the Mac. Real at-rest encryption is out of scope (see overhaul design doc, WS1) — don't claim "encrypted" in UI copy.
- **AX responsible process:** Use `./run.sh` to launch (LaunchServices). Never use Cmd+R (debugger becomes responsible process, AX reads fail -25204 even when trusted).
- **CGEventTap callback:** Return `handleGlobal()`'s value directly; never use `?? passRetained(event)` (coalesces swallow-nil into passthrough). See KeyEventMonitor.swift.

## Keyboard
- Tab / ⌥→ accept the next word · ⇧Tab accepts the whole suggestion · ⌥Tab sends a plain Tab
- Esc dismisses and pauses until the next word (`DismissCooldown`) · ⌃⌥⌘` toggles the current app · ⌃⌥⌘T opens the menu

## Entitlements Required
- `com.apple.security.automation.apple-events`
- `NSAccessibilityUsageDescription` (Info.plist)
- `NSScreenCaptureUsageDescription` (Info.plist)

## Models (MLX 4-bit quantized, from mlx-community on HuggingFace)
| Model | Repo | RAM |
|-------|------|-----|
| Gemma 4 E2B (default) | mlx-community/gemma-4-e2b-it-4bit | 3.2GB |
| Gemma 4 E4B | mlx-community/gemma-4-e4b-it-4bit | 6.2GB |
| Gemma 3 4B | mlx-community/gemma-3-4b-it-4bit | 2.3GB |
| Qwen 3 1.7B | mlx-community/Qwen3-1.7B-4bit | 1.2GB |
| Qwen 3 1B | mlx-community/Qwen3-1B-4bit | 0.8GB |

## Target Metrics
- P50 completion latency: < 80ms on M2
- P95 latency: < 250ms
- RAM at steady state: < 2.5GB
- Acceptance rate: 40% week 1 → 65% week 4
