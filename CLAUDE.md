# TypeAhead — Build Instructions

## What This Is
TypeAhead is a native macOS app that provides system-wide, real-time AI text completion in any text field. It uses MLX Swift for on-device inference (Apple Silicon only) and the macOS Accessibility API to read/write text fields across all apps. No cloud, no sandbox.

## How to Run
```bash
# Open in Xcode (required for macOS app bundle, entitlements, and AX testing)
open TypeAhead.xcodeproj

# Or build via SPM for unit tests only
swift test

# Type-check
swift build
```

## Requirements
- macOS 14+ (Sonoma)
- Apple Silicon (M1 or above) — MLX is Apple Silicon only
- Xcode 16+
- Accessibility permission granted to the built app in System Settings → Privacy & Security

## Tech Stack
- Swift 6, SwiftUI, AppKit (NSPanel, NSStatusItem, NSEvent)
- MLX Swift (`ml-explore/mlx-swift`) + MLXLLM (`mlx-swift-examples`)
- swift-transformers (Gemma/Qwen tokenization)
- SwiftData (typing history, SQLite under the hood)
- Swift Charts (Statistics view)
- Sparkle (auto-update)
- AXUIElement / CGEventTap (system-wide text field access)
- CGWindowListCreateImage (screenshot context)

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
- No sandbox. Distributed as notarized DMG only (App Store incompatible due to AX APIs).
- All inference runs on-device. No network calls for completions ever.
- Never read `kAXPasswordRole` fields — the AX API blocks this by design, do not attempt workarounds.
- Cancel active inference immediately on any non-Tab keystroke.
- Per-app exception list (bundle IDs) always takes precedence over global toggle.
- Model files live in `~/Library/Application Support/TypeAhead/Models/` — never bundle models.
- History DB lives in `~/Library/Application Support/TypeAhead/history.db` — encrypted.

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
