# TypeAhead Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS app that delivers system-wide AI text completion in any text field using on-device MLX inference, Tab to accept, with personalization and a settings UI.

**Architecture:** `KeyEventMonitor` captures global keystrokes and feeds them through `CompletionPipeline`, which orchestrates `AccessibilityManager` (AX text read/write), `ContextBuilder` (FIM prompt assembly), and `InferenceEngine` (MLX model). The `CompletionOverlay` (NSPanel) renders ghost text near the cursor. `HistoryStore` (SwiftData) persists accepted completions for personalization.

**Tech Stack:** Swift 6, SwiftUI + AppKit, MLX Swift (MLXLLM), swift-transformers, SwiftData, Swift Charts, AXUIElement, CGEventTap, NSEvent, Sparkle

---

## File Map

```
Sources/TypeAhead/
├── App/
│   ├── TypeAheadApp.swift          — @main SwiftUI App entry, AppDelegate bridge
│   ├── AppDelegate.swift           — NSApplicationDelegate, status bar setup
│   └── AppDependencies.swift       — Dependency container (singleton references)
├── Core/
│   ├── AccessibilityManager.swift  — AXUIElement read/write text fields, cursor pos
│   ├── InferenceEngine.swift       — MLXLLM model load, FIM inference, token streaming
│   ├── CompletionPipeline.swift    — Orchestrates keystroke → inference → overlay
│   ├── KeyEventMonitor.swift       — NSEvent global monitor, CGEventTap, Tab handler
│   └── ContextBuilder.swift        — Assembles FIM prompt from all context sources
├── Overlay/
│   ├── CompletionOverlay.swift     — NSPanel ghost text display near cursor
│   └── OverlayPositioner.swift     — Converts AX cursor rect to screen coordinates
├── Models/
│   ├── ModelConfig.swift           — Enum/struct of available models + metadata
│   ├── ModelDownloader.swift       — URLSession resumable download with progress
│   └── ModelManager.swift          — Download state machine, active model switching
├── Context/
│   ├── ScreenshotContextProvider.swift — CGWindowListCreateImage, async, never stored
│   └── ClipboardContextProvider.swift  — NSPasteboard monitor, 400-char max
├── Persistence/
│   ├── HistoryRecord.swift         — SwiftData @Model for one typing session
│   ├── HistoryStore.swift          — SwiftData container, insert/query/delete history
│   └── StatisticsCalculator.swift  — Aggregate acceptance rate, keystrokes saved
├── Personalization/
│   └── PersonalizationEngine.swift — Inject few-shot examples into FIM prompt prefix
├── Settings/
│   ├── AppSettings.swift           — UserDefaults-backed @Observable settings model
│   └── AppExceptionList.swift      — Per-app bundle ID allow/block list
├── UI/
│   ├── Settings/
│   │   ├── SettingsWindow.swift    — NavigationSplitView two-panel shell
│   │   ├── SetupView.swift         — Onboarding / permission wizard
│   │   ├── GeneralView.swift       — Model picker, completion length, delay
│   │   ├── ContextView.swift       — Screenshot + clipboard context toggles
│   │   ├── PersonalizationView.swift — History toggle, word-choice slider, custom instructions
│   │   ├── EmojiView.swift         — Emoji suggestions, skin tone, gender
│   │   ├── ShortcutsView.swift     — Configurable key bindings
│   │   ├── AppSettingsView.swift   — Per-app exceptions, launch settings
│   │   ├── StatisticsView.swift    — Swift Charts acceptance rate, keystrokes saved
│   │   └── AboutView.swift         — Version, changelog
│   └── StatusBar/
│       └── StatusBarMenu.swift     — NSStatusItem + NSMenu quick controls
├── Features/
│   ├── Autocorrect/
│   │   └── TypoDetector.swift      — Local spell-check typo detection (no model)
│   └── Emoji/
│       └── EmojiSuggester.swift    — Colon-trigger emoji shortcode lookup
└── Resources/
    ├── Info.plist
    └── TypeAhead.entitlements

Tests/TypeAheadTests/
├── ModelConfigTests.swift
├── ContextBuilderTests.swift
├── AccessibilityManagerTests.swift
├── InferenceEngineTests.swift
├── CompletionPipelineTests.swift
├── ModelDownloaderTests.swift
├── HistoryStoreTests.swift
├── StatisticsCalculatorTests.swift
├── PersonalizationEngineTests.swift
├── TypoDetectorTests.swift
└── EmojiSuggesterTests.swift
```

---

## Phase 1: Core Engine

### Task 1: Xcode Project Setup

**Files:**
- Create: `TypeAhead.xcodeproj` (via Xcode UI — do not script)
- Create: `Sources/TypeAhead/Resources/Info.plist`
- Create: `Sources/TypeAhead/Resources/TypeAhead.entitlements`

- [ ] **Step 1: Create Xcode project**

  Open Xcode → New Project → macOS → App.
  - Product Name: `TypeAhead`
  - Bundle ID: `app.typeahead.TypeAhead`
  - Language: Swift
  - Interface: SwiftUI
  - Uncheck "Include Tests" (we'll add the test target manually from Package.swift)
  - Deployment target: macOS 14.0
  - Save to `/Users/joud/sandbox/personal/typeahead/`

- [ ] **Step 2: Disable App Sandbox**

  In `TypeAhead.entitlements`, remove `com.apple.security.app-sandbox`. Add:

  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
      <key>com.apple.security.automation.apple-events</key>
      <true/>
  </dict>
  </plist>
  ```

- [ ] **Step 3: Add Info.plist privacy strings**

  In `Info.plist`, add:

  ```xml
  <key>NSAccessibilityUsageDescription</key>
  <string>TypeAhead reads and writes to text fields to provide AI completions.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>TypeAhead captures the active window to provide more relevant completions. Screenshots are never stored.</string>
  ```

- [ ] **Step 4: Add SPM dependencies in Xcode**

  File → Add Package Dependencies:
  - `https://github.com/ml-explore/mlx-swift` (from: 0.21.0)
  - `https://github.com/ml-explore/mlx-swift-examples` (branch: main) — add `MLXLLM` product
  - `https://github.com/huggingface/swift-transformers` (from: 0.1.14)
  - `https://github.com/sparkle-project/Sparkle` (from: 2.6.0)

- [ ] **Step 5: Verify build**

  Build the empty project: ⌘B
  Expected: Build Succeeded with 0 errors.

- [ ] **Step 6: Commit**

  ```bash
  git add .
  git commit -m "feat: initialize TypeAhead Xcode project"
  ```

---

### Task 2: ModelConfig — Available Models Metadata

**Files:**
- Create: `Sources/TypeAhead/Models/ModelConfig.swift`
- Create: `Tests/TypeAheadTests/ModelConfigTests.swift`

- [ ] **Step 1: Write the failing test**

  ```swift
  // Tests/TypeAheadTests/ModelConfigTests.swift
  import Testing
  @testable import TypeAhead

  @Suite struct ModelConfigTests {
      @Test func allModelsHaveUniqueIDs() {
          let ids = ModelConfig.all.map(\.id)
          #expect(Set(ids).count == ModelConfig.all.count)
      }

      @Test func defaultModelIsGemma4E2B() {
          #expect(ModelConfig.defaultModel.id == "gemma-4-e2b-it-4bit")
      }

      @Test func modelForRAMPicksQwenOnLowMemory() {
          let model = ModelConfig.recommended(availableRAMGB: 8)
          #expect(model.id == "qwen3-1b-4bit" || model.id == "qwen3-1.7b-4bit")
      }

      @Test func modelForRAMPicksGemma4E2BOnMidMemory() {
          let model = ModelConfig.recommended(availableRAMGB: 16)
          #expect(model.id == "gemma-4-e2b-it-4bit")
      }

      @Test func modelForRAMPicksGemma4E4BOnHighMemory() {
          let model = ModelConfig.recommended(availableRAMGB: 36)
          #expect(model.id == "gemma-4-e4b-it-4bit")
      }
  }
  ```

- [ ] **Step 2: Run test to verify it fails**

  ```bash
  swift test --filter ModelConfigTests
  ```
  Expected: FAIL — `ModelConfig` not defined.

- [ ] **Step 3: Implement ModelConfig**

  ```swift
  // Sources/TypeAhead/Models/ModelConfig.swift
  import Foundation

  struct ModelConfig: Identifiable, Equatable, Sendable {
      let id: String
      let displayName: String
      let huggingFaceRepo: String
      let fileSizeGB: Double
      let minRAMGB: Int
      let recommendedForRAMGB: ClosedRange<Int>

      var downloadURL: URL {
          URL(string: "https://huggingface.co/\(huggingFaceRepo)/resolve/main")!
      }

      static let gemma4E2B = ModelConfig(
          id: "gemma-4-e2b-it-4bit",
          displayName: "Gemma 4 E2B",
          huggingFaceRepo: "mlx-community/gemma-4-e2b-it-4bit",
          fileSizeGB: 3.2,
          minRAMGB: 8,
          recommendedForRAMGB: 16...31
      )
      static let gemma4E4B = ModelConfig(
          id: "gemma-4-e4b-it-4bit",
          displayName: "Gemma 4 E4B",
          huggingFaceRepo: "mlx-community/gemma-4-e4b-it-4bit",
          fileSizeGB: 6.2,
          minRAMGB: 16,
          recommendedForRAMGB: 32...Int.max
      )
      static let gemma3_4B = ModelConfig(
          id: "gemma-3-4b-it-4bit",
          displayName: "Gemma 3 4B",
          huggingFaceRepo: "mlx-community/gemma-3-4b-it-4bit",
          fileSizeGB: 2.3,
          minRAMGB: 8,
          recommendedForRAMGB: 8...15
      )
      static let qwen3_1_7B = ModelConfig(
          id: "qwen3-1.7b-4bit",
          displayName: "Qwen 3 1.7B",
          huggingFaceRepo: "mlx-community/Qwen3-1.7B-4bit",
          fileSizeGB: 1.2,
          minRAMGB: 8,
          recommendedForRAMGB: 8...11
      )
      static let qwen3_1B = ModelConfig(
          id: "qwen3-1b-4bit",
          displayName: "Qwen 3 1B",
          huggingFaceRepo: "mlx-community/Qwen3-1B-4bit",
          fileSizeGB: 0.8,
          minRAMGB: 8,
          recommendedForRAMGB: 8...8
      )

      static let all: [ModelConfig] = [gemma4E2B, gemma4E4B, gemma3_4B, qwen3_1_7B, qwen3_1B]
      static let defaultModel = gemma4E2B

      static func recommended(availableRAMGB: Int) -> ModelConfig {
          all.first { $0.recommendedForRAMGB.contains(availableRAMGB) } ?? defaultModel
      }
  }
  ```

- [ ] **Step 4: Run test to verify it passes**

  ```bash
  swift test --filter ModelConfigTests
  ```
  Expected: All 5 tests PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/TypeAhead/Models/ModelConfig.swift Tests/TypeAheadTests/ModelConfigTests.swift
  git commit -m "feat: add ModelConfig with available models and RAM-based selection"
  ```

---

### Task 3: AppSettings — UserDefaults-Backed Settings Model

**Files:**
- Create: `Sources/TypeAhead/Settings/AppSettings.swift`
- Create: `Sources/TypeAhead/Settings/AppExceptionList.swift`

- [ ] **Step 1: Write failing tests**

  ```swift
  // Tests/TypeAheadTests/AppSettingsTests.swift
  import Testing
  @testable import TypeAhead

  @Suite struct AppSettingsTests {
      @Test func defaultsAreCorrect() {
          let settings = AppSettings()
          #expect(settings.completionsEnabled == true)
          #expect(settings.completionDelay == 0.12)
          #expect(settings.completionLength == .medium)
          #expect(settings.activeModelID == ModelConfig.defaultModel.id)
          #expect(settings.showInAllApps == true)
      }

      @Test func completionLengthTokenBudget() {
          #expect(CompletionLength.short.maxTokens == 20)
          #expect(CompletionLength.medium.maxTokens == 40)
          #expect(CompletionLength.long.maxTokens == 80)
      }

      @Test func exceptionListRoundTrips() {
          var list = AppExceptionList()
          list.add(bundleID: "com.example.app")
          #expect(list.isExcluded(bundleID: "com.example.app"))
          list.remove(bundleID: "com.example.app")
          #expect(!list.isExcluded(bundleID: "com.example.app"))
      }

      @Test func defaultExclusionListContainsPasswordManagers() {
          let list = AppExceptionList.defaults
          #expect(list.isExcluded(bundleID: "com.agilebits.onepassword7"))
          #expect(list.isExcluded(bundleID: "desktop.Bitwarden"))
      }
  }
  ```

- [ ] **Step 2: Run test to verify it fails**

  ```bash
  swift test --filter AppSettingsTests
  ```
  Expected: FAIL — types not defined.

- [ ] **Step 3: Implement AppSettings**

  ```swift
  // Sources/TypeAhead/Settings/AppSettings.swift
  import Foundation
  import Observation

  enum CompletionLength: String, CaseIterable, Sendable {
      case short, medium, long
      var maxTokens: Int {
          switch self { case .short: 20; case .medium: 40; case .long: 80 }
      }
      var displayName: String {
          switch self { case .short: "Short (1 word)"; case .medium: "Medium (2-4 words)"; case .long: "Long (full sentence)" }
      }
  }

  @Observable
  final class AppSettings {
      var completionsEnabled: Bool {
          didSet { UserDefaults.standard.set(completionsEnabled, forKey: Keys.completionsEnabled) }
      }
      var completionDelay: Double {
          didSet { UserDefaults.standard.set(completionDelay, forKey: Keys.completionDelay) }
      }
      var completionLength: CompletionLength {
          didSet { UserDefaults.standard.set(completionLength.rawValue, forKey: Keys.completionLength) }
      }
      var activeModelID: String {
          didSet { UserDefaults.standard.set(activeModelID, forKey: Keys.activeModelID) }
      }
      var showInAllApps: Bool {
          didSet { UserDefaults.standard.set(showInAllApps, forKey: Keys.showInAllApps) }
      }
      var storeInputHistory: Bool {
          didSet { UserDefaults.standard.set(storeInputHistory, forKey: Keys.storeInputHistory) }
      }
      var personalizationStrength: Double {
          didSet { UserDefaults.standard.set(personalizationStrength, forKey: Keys.personalizationStrength) }
      }
      var customInstructions: String {
          didSet { UserDefaults.standard.set(customInstructions, forKey: Keys.customInstructions) }
      }
      var useScreenshotContext: Bool {
          didSet { UserDefaults.standard.set(useScreenshotContext, forKey: Keys.useScreenshotContext) }
      }
      var useClipboardContext: Bool {
          didSet { UserDefaults.standard.set(useClipboardContext, forKey: Keys.useClipboardContext) }
      }
      var launchAtLogin: Bool {
          didSet { UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin) }
      }
      var emojiSuggestionsEnabled: Bool {
          didSet { UserDefaults.standard.set(emojiSuggestionsEnabled, forKey: Keys.emojiSuggestionsEnabled) }
      }

      init() {
          let d = UserDefaults.standard
          completionsEnabled = d.object(forKey: Keys.completionsEnabled) as? Bool ?? true
          completionDelay    = d.object(forKey: Keys.completionDelay)    as? Double ?? 0.12
          completionLength   = CompletionLength(rawValue: d.string(forKey: Keys.completionLength) ?? "") ?? .medium
          activeModelID      = d.string(forKey: Keys.activeModelID) ?? ModelConfig.defaultModel.id
          showInAllApps      = d.object(forKey: Keys.showInAllApps) as? Bool ?? true
          storeInputHistory  = d.object(forKey: Keys.storeInputHistory) as? Bool ?? true
          personalizationStrength = d.object(forKey: Keys.personalizationStrength) as? Double ?? 0.5
          customInstructions = d.string(forKey: Keys.customInstructions) ?? ""
          useScreenshotContext = d.object(forKey: Keys.useScreenshotContext) as? Bool ?? true
          useClipboardContext  = d.object(forKey: Keys.useClipboardContext) as? Bool ?? true
          launchAtLogin        = d.object(forKey: Keys.launchAtLogin) as? Bool ?? true
          emojiSuggestionsEnabled = d.object(forKey: Keys.emojiSuggestionsEnabled) as? Bool ?? true
      }

      private enum Keys {
          static let completionsEnabled    = "completionsEnabled"
          static let completionDelay       = "completionDelay"
          static let completionLength      = "completionLength"
          static let activeModelID         = "activeModelID"
          static let showInAllApps         = "showInAllApps"
          static let storeInputHistory     = "storeInputHistory"
          static let personalizationStrength = "personalizationStrength"
          static let customInstructions    = "customInstructions"
          static let useScreenshotContext  = "useScreenshotContext"
          static let useClipboardContext   = "useClipboardContext"
          static let launchAtLogin         = "launchAtLogin"
          static let emojiSuggestionsEnabled = "emojiSuggestionsEnabled"
      }
  }
  ```

- [ ] **Step 4: Implement AppExceptionList**

  ```swift
  // Sources/TypeAhead/Settings/AppExceptionList.swift
  import Foundation

  struct AppExceptionList: Sendable {
      private var excludedBundleIDs: Set<String>

      init(bundleIDs: Set<String> = []) {
          self.excludedBundleIDs = bundleIDs
      }

      mutating func add(bundleID: String) {
          excludedBundleIDs.insert(bundleID)
      }

      mutating func remove(bundleID: String) {
          excludedBundleIDs.remove(bundleID)
      }

      func isExcluded(bundleID: String) -> Bool {
          excludedBundleIDs.contains(bundleID)
      }

      static let defaults = AppExceptionList(bundleIDs: [
          "com.agilebits.onepassword7",
          "com.agilebits.onepassword-osx",
          "desktop.Bitwarden",
          "com.bitwarden.desktop",
          "com.apple.Terminal",
          "com.googlecode.iterm2",
          "com.microsoft.VSCode",
          "com.apple.dt.Xcode",
      ])
  }
  ```

- [ ] **Step 5: Run tests to verify they pass**

  ```bash
  swift test --filter AppSettingsTests
  ```
  Expected: All 4 tests PASS.

- [ ] **Step 6: Commit**

  ```bash
  git add Sources/TypeAhead/Settings/ Tests/TypeAheadTests/AppSettingsTests.swift
  git commit -m "feat: add AppSettings and AppExceptionList with UserDefaults persistence"
  ```

---

### Task 4: ContextBuilder — FIM Prompt Assembly

**Files:**
- Create: `Sources/TypeAhead/Core/ContextBuilder.swift`
- Create: `Tests/TypeAheadTests/ContextBuilderTests.swift`

- [ ] **Step 1: Write failing tests**

  ```swift
  // Tests/TypeAheadTests/ContextBuilderTests.swift
  import Testing
  @testable import TypeAhead

  @Suite struct ContextBuilderTests {
      @Test func shortContextUsesStandardPrompt() {
          let ctx = TextContext(
              textBeforeCursor: "Hello",
              textAfterCursor: "",
              appName: "Notes",
              windowTitle: "My Note"
          )
          let result = ContextBuilder.buildPrompt(context: ctx, clipboard: nil, history: [], customInstructions: "")
          #expect(!result.contains("<|fim_prefix|>"))
          #expect(result.contains("Hello"))
      }

      @Test func longContextUsesFIMPrompt() {
          let longText = String(repeating: "word ", count: 20) // > 50 chars
          let ctx = TextContext(
              textBeforeCursor: longText,
              textAfterCursor: "some text after",
              appName: "Mail",
              windowTitle: "Re: Meeting"
          )
          let result = ContextBuilder.buildPrompt(context: ctx, clipboard: nil, history: [], customInstructions: "")
          #expect(result.contains("<|fim_prefix|>"))
          #expect(result.contains("<|fim_suffix|>"))
          #expect(result.contains("<|fim_middle|>"))
      }

      @Test func clipboardContextCappedAt400Chars() {
          let longClipboard = String(repeating: "a", count: 600)
          let ctx = TextContext(textBeforeCursor: String(repeating: "word ", count: 20), textAfterCursor: "", appName: "Slack", windowTitle: "")
          let result = ContextBuilder.buildPrompt(context: ctx, clipboard: longClipboard, history: [], customInstructions: "")
          // clipboard should be truncated
          let clipboardSectionCount = result.components(separatedBy: String(repeating: "a", count: 401)).count
          #expect(clipboardSectionCount == 1) // no 401-char run of 'a'
      }

      @Test func customInstructionsInjectedFirst() {
          let instructions = "Always write in UK English."
          let ctx = TextContext(textBeforeCursor: String(repeating: "word ", count: 20), textAfterCursor: "", appName: "Notes", windowTitle: "")
          let result = ContextBuilder.buildPrompt(context: ctx, clipboard: nil, history: [], customInstructions: instructions)
          let instrRange = result.range(of: instructions)
          let fimRange = result.range(of: "<|fim_prefix|>")
          guard let i = instrRange, let f = fimRange else {
              Issue.record("Expected both instruction and FIM markers"); return
          }
          #expect(i.lowerBound < f.lowerBound)
      }

      @Test func historyExamplesInjectedAsPrefix() {
          let history = ["I think therefore I am", "To be or not to be"]
          let ctx = TextContext(textBeforeCursor: String(repeating: "word ", count: 20), textAfterCursor: "", appName: "Notes", windowTitle: "")
          let result = ContextBuilder.buildPrompt(context: ctx, clipboard: nil, history: history, customInstructions: "")
          #expect(result.contains("I think therefore I am"))
          #expect(result.contains("To be or not to be"))
      }
  }
  ```

- [ ] **Step 2: Run test to verify it fails**

  ```bash
  swift test --filter ContextBuilderTests
  ```
  Expected: FAIL — `ContextBuilder`, `TextContext` not defined.

- [ ] **Step 3: Implement ContextBuilder**

  ```swift
  // Sources/TypeAhead/Core/ContextBuilder.swift
  import Foundation

  struct TextContext: Sendable {
      let textBeforeCursor: String
      let textAfterCursor: String
      let appName: String
      let windowTitle: String
  }

  enum ContextBuilder {
      private static let fimThresholdChars = 50
      private static let maxClipboardChars = 400
      private static let maxSuffixChars = 100
      private static let maxPrefixChars = 200

      static func buildPrompt(
          context: TextContext,
          clipboard: String?,
          history: [String],
          customInstructions: String
      ) -> String {
          var parts: [String] = []

          if !customInstructions.isEmpty {
              parts.append(customInstructions)
          }

          if !history.isEmpty {
              parts.append("Examples of your writing style:")
              parts.append(contentsOf: history.prefix(5))
          }

          let appContext = "App: \(context.appName)\(context.windowTitle.isEmpty ? "" : " — \(context.windowTitle)")"
          parts.append(appContext)

          if let clip = clipboard, !clip.isEmpty {
              let trimmed = String(clip.prefix(maxClipboardChars))
              parts.append("Clipboard context: \(trimmed)")
          }

          let prefix = String(context.textBeforeCursor.suffix(maxPrefixChars))
          let suffix = String(context.textAfterCursor.prefix(maxSuffixChars))

          if context.textBeforeCursor.count >= fimThresholdChars {
              let header = parts.joined(separator: "\n")
              return "<|fim_prefix|>\(header)\n\(prefix)<|fim_suffix|>\(suffix)<|fim_middle|>"
          } else {
              parts.append(prefix)
              return parts.joined(separator: "\n")
          }
      }
  }
  ```

- [ ] **Step 4: Run tests to verify they pass**

  ```bash
  swift test --filter ContextBuilderTests
  ```
  Expected: All 5 tests PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/TypeAhead/Core/ContextBuilder.swift Tests/TypeAheadTests/ContextBuilderTests.swift
  git commit -m "feat: add ContextBuilder with FIM prompt assembly and clipboard/history injection"
  ```

---

### Task 5: AccessibilityManager — AX Text Reading and Writing

**Files:**
- Create: `Sources/TypeAhead/Core/AccessibilityManager.swift`
- Create: `Tests/TypeAheadTests/AccessibilityManagerTests.swift`

> **Note:** AX APIs require a real running app with Accessibility permission. Unit tests cover only the data parsing logic; integration is tested manually.

- [ ] **Step 1: Write failing unit tests (testable pure logic)**

  ```swift
  // Tests/TypeAheadTests/AccessibilityManagerTests.swift
  import Testing
  @testable import TypeAhead

  @Suite struct AccessibilityManagerTests {
      @Test func extractsTextBeforeAndAfterCursor() {
          let full = "Hello world, how are you"
          let cursorPos = 11 // after "Hello world"
          let (before, after) = AccessibilityManager.split(text: full, at: cursorPos)
          #expect(before == "Hello world")
          #expect(after == ", how are you")
      }

      @Test func handlesEmptyString() {
          let (before, after) = AccessibilityManager.split(text: "", at: 0)
          #expect(before == "")
          #expect(after == "")
      }

      @Test func handlesCursorAtEnd() {
          let text = "Hello"
          let (before, after) = AccessibilityManager.split(text: text, at: text.count)
          #expect(before == "Hello")
          #expect(after == "")
      }

      @Test func clampsCursorBeyondLength() {
          let text = "Hi"
          let (before, after) = AccessibilityManager.split(text: text, at: 100)
          #expect(before == "Hi")
          #expect(after == "")
      }
  }
  ```

- [ ] **Step 2: Run test to verify it fails**

  ```bash
  swift test --filter AccessibilityManagerTests
  ```
  Expected: FAIL — `AccessibilityManager` not defined.

- [ ] **Step 3: Implement AccessibilityManager**

  ```swift
  // Sources/TypeAhead/Core/AccessibilityManager.swift
  import AppKit
  import ApplicationServices

  @MainActor
  final class AccessibilityManager {

      // MARK: - Pure Logic (testable without AX)

      static func split(text: String, at position: Int) -> (before: String, after: String) {
          let clamped = max(0, min(position, text.count))
          let idx = text.index(text.startIndex, offsetBy: clamped)
          return (String(text[..<idx]), String(text[idx...]))
      }

      // MARK: - AX Live API

      func readTextContext() -> TextContext? {
          guard let element = focusedTextElement() else { return nil }
          guard let value = element.stringValue else { return nil }
          let cursorRange = element.selectedRange ?? NSRange(location: value.count, length: 0)
          let (before, after) = Self.split(text: value, at: cursorRange.location)
          let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
          let windowTitle = focusedWindowTitle() ?? ""
          return TextContext(textBeforeCursor: before, textAfterCursor: after, appName: appName, windowTitle: windowTitle)
      }

      func insertCompletion(_ text: String, into element: AXUIElement) {
          AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
      }

      func cursorScreenRect() -> NSRect? {
          guard let element = focusedTextElement() else { return nil }
          var rect: CFTypeRef?
          guard AXUIElementCopyAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, NSRange(location: 0, length: 0) as CFTypeRef, &rect) == .success else {
              return nil
          }
          var screenRect = NSRect.zero
          AXValueGetValue(rect as! AXValue, .cgRect, &screenRect)
          return screenRect
      }

      // MARK: - Helpers

      private func focusedTextElement() -> AXUIElement? {
          let systemElement = AXUIElementCreateSystemWide()
          var focusedApp: CFTypeRef?
          guard AXUIElementCopyAttributeValue(systemElement, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
                let app = focusedApp else { return nil }
          var focusedElement: CFTypeRef?
          guard AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
                let element = focusedElement else { return nil }
          let axElement = element as! AXUIElement
          guard !isPasswordField(axElement) else { return nil }
          return axElement
      }

      private func isPasswordField(_ element: AXUIElement) -> Bool {
          var role: CFTypeRef?
          AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
          return (role as? String) == kAXPasswordFieldRole as String
      }

      private func focusedWindowTitle() -> String? {
          guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
          let axApp = AXUIElementCreateApplication(app.processIdentifier)
          var window: CFTypeRef?
          guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window) == .success,
                let win = window else { return nil }
          var title: CFTypeRef?
          AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &title)
          return title as? String
      }
  }

  private extension AXUIElement {
      var stringValue: String? {
          var value: CFTypeRef?
          AXUIElementCopyAttributeValue(self, kAXValueAttribute as CFString, &value)
          return value as? String
      }
      var selectedRange: NSRange? {
          var value: CFTypeRef?
          guard AXUIElementCopyAttributeValue(self, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
                let axValue = value else { return nil }
          var range = CFRange()
          AXValueGetValue(axValue as! AXValue, .cfRange, &range)
          return NSRange(location: range.location, length: range.length)
      }
  }
  ```

- [ ] **Step 4: Run tests to verify they pass**

  ```bash
  swift test --filter AccessibilityManagerTests
  ```
  Expected: All 4 tests PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/TypeAhead/Core/AccessibilityManager.swift Tests/TypeAheadTests/AccessibilityManagerTests.swift
  git commit -m "feat: add AccessibilityManager with AX text read/write and pure-logic unit tests"
  ```

---

### Task 6: InferenceEngine — MLX Model Loading and FIM Inference

**Files:**
- Create: `Sources/TypeAhead/Core/InferenceEngine.swift`

> Integration test only — MLX requires Apple Silicon hardware and a downloaded model. No unit tests; verify with a manual smoke test.

- [ ] **Step 1: Implement InferenceEngine**

  ```swift
  // Sources/TypeAhead/Core/InferenceEngine.swift
  import Foundation
  import MLX
  import MLXLLM

  enum InferenceError: Error {
      case modelNotLoaded
      case inferenceTimeout
  }

  @MainActor
  final class InferenceEngine {
      private var llmModel: LLMModel?
      private var currentTask: Task<Void, Never>?
      private let modelDirectory: URL

      init() {
          modelDirectory = FileManager.default
              .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
              .appendingPathComponent("TypeAhead/Models")
      }

      func loadModel(config: ModelConfig) async throws {
          let modelURL = modelDirectory.appendingPathComponent(config.id)
          guard FileManager.default.fileExists(atPath: modelURL.path) else {
              throw InferenceError.modelNotLoaded
          }
          llmModel = try await LLMModel.load(from: modelURL)
      }

      func unloadModel() {
          llmModel = nil
          MLX.GPU.clearCache()
      }

      // Streams tokens; calls onToken for each until maxTokens or EOS.
      func complete(
          prompt: String,
          maxTokens: Int,
          onToken: @escaping @Sendable (String) -> Void,
          onComplete: @escaping @Sendable () -> Void
      ) {
          currentTask?.cancel()
          guard let model = llmModel else {
              onComplete()
              return
          }
          currentTask = Task {
              var count = 0
              for await token in model.generate(prompt: prompt) {
                  if Task.isCancelled { break }
                  onToken(token)
                  count += 1
                  if count >= maxTokens { break }
              }
              if !Task.isCancelled { onComplete() }
          }
      }

      func cancelCurrent() {
          currentTask?.cancel()
          currentTask = nil
      }
  }
  ```

- [ ] **Step 2: Manual smoke test**

  After wiring the pipeline (Task 8), run the app in Xcode with a downloaded model. Type in TextEdit and verify:
  - Ghost text appears within 150ms after 120ms debounce
  - Tab accepts one word
  - Any other key dismisses the overlay

- [ ] **Step 3: Commit**

  ```bash
  git add Sources/TypeAhead/Core/InferenceEngine.swift
  git commit -m "feat: add InferenceEngine with MLXLLM streaming inference and cancel support"
  ```

---

### Task 7: CompletionOverlay — NSPanel Ghost Text

**Files:**
- Create: `Sources/TypeAhead/Overlay/CompletionOverlay.swift`
- Create: `Sources/TypeAhead/Overlay/OverlayPositioner.swift`

- [ ] **Step 1: Implement OverlayPositioner**

  ```swift
  // Sources/TypeAhead/Overlay/OverlayPositioner.swift
  import AppKit

  enum OverlayPositioner {
      static func panelOrigin(cursorRect: NSRect, panelSize: NSSize) -> NSPoint {
          // Position 8pt below the cursor rect, left-aligned
          let x = cursorRect.minX
          let y = cursorRect.minY - panelSize.height - 8
          // Clamp to screen bounds
          guard let screen = NSScreen.main else { return NSPoint(x: x, y: y) }
          let clamped = NSPoint(
              x: min(max(x, screen.visibleFrame.minX), screen.visibleFrame.maxX - panelSize.width),
              y: max(y, screen.visibleFrame.minY)
          )
          return clamped
      }
  }
  ```

- [ ] **Step 2: Write overlay positioner test**

  ```swift
  // Tests/TypeAheadTests/OverlayPositionerTests.swift
  import Testing
  @testable import TypeAhead
  import AppKit

  @Suite struct OverlayPositionerTests {
      @Test func originIsBelowCursorRect() {
          let cursorRect = NSRect(x: 200, y: 500, width: 2, height: 16)
          let panelSize = NSSize(width: 300, height: 32)
          let origin = OverlayPositioner.panelOrigin(cursorRect: cursorRect, panelSize: panelSize)
          // Panel top (origin.y + height) should be below cursor bottom (cursorRect.minY)
          #expect(origin.y + panelSize.height < cursorRect.minY)
      }

      @Test func originIsLeftAligned() {
          let cursorRect = NSRect(x: 300, y: 400, width: 2, height: 16)
          let panelSize = NSSize(width: 200, height: 32)
          let origin = OverlayPositioner.panelOrigin(cursorRect: cursorRect, panelSize: panelSize)
          #expect(origin.x == 300)
      }
  }
  ```

- [ ] **Step 3: Run positioner tests to verify they pass**

  ```bash
  swift test --filter OverlayPositionerTests
  ```
  Expected: Both tests PASS.

- [ ] **Step 4: Implement CompletionOverlay**

  ```swift
  // Sources/TypeAhead/Overlay/CompletionOverlay.swift
  import AppKit

  @MainActor
  final class CompletionOverlay {
      private let panel: NSPanel
      private let textField: NSTextField

      init() {
          panel = NSPanel(
              contentRect: NSRect(x: 0, y: 0, width: 400, height: 32),
              styleMask: [.nonactivatingPanel, .borderless],
              backing: .buffered,
              defer: false
          )
          panel.level = .floating
          panel.backgroundColor = NSColor(white: 0.12, alpha: 0.95)
          panel.isOpaque = false
          panel.hasShadow = true
          panel.cornerRadius = 6

          textField = NSTextField(frame: NSRect(x: 8, y: 4, width: 384, height: 24))
          textField.isEditable = false
          textField.isBordered = false
          textField.backgroundColor = .clear
          textField.textColor = NSColor.placeholderTextColor
          textField.font = NSFont.systemFont(ofSize: 14, weight: .regular)
          panel.contentView?.addSubview(textField)
      }

      func show(text: String, near cursorRect: NSRect) {
          textField.stringValue = text
          textField.sizeToFit()
          let panelWidth = min(textField.frame.width + 24, 500)
          let panelSize = NSSize(width: panelWidth, height: 32)
          let origin = OverlayPositioner.panelOrigin(cursorRect: cursorRect, panelSize: panelSize)
          panel.setFrame(NSRect(origin: origin, size: panelSize), display: false)
          panel.alphaValue = 0
          panel.orderFront(nil)
          NSAnimationContext.runAnimationGroup { ctx in
              ctx.duration = 0.06
              panel.animator().alphaValue = 1
          }
      }

      func update(text: String) {
          textField.stringValue = text
      }

      func hide() {
          NSAnimationContext.runAnimationGroup({ ctx in
              ctx.duration = 0.15
              panel.animator().alphaValue = 0
          }, completionHandler: {
              self.panel.orderOut(nil)
          })
      }
  }
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/TypeAhead/Overlay/ Tests/TypeAheadTests/OverlayPositionerTests.swift
  git commit -m "feat: add CompletionOverlay NSPanel and OverlayPositioner with tests"
  ```

---

### Task 8: KeyEventMonitor — Global Keystroke Capture

**Files:**
- Create: `Sources/TypeAhead/Core/KeyEventMonitor.swift`

- [ ] **Step 1: Implement KeyEventMonitor**

  ```swift
  // Sources/TypeAhead/Core/KeyEventMonitor.swift
  import AppKit
  import Carbon

  @MainActor
  final class KeyEventMonitor {
      private var globalMonitor: Any?
      private var localMonitor: Any?

      var onKeystroke: ((NSEvent) -> Void)?
      var onTabPressed: (() -> Void)?
      var onShiftTabPressed: (() -> Void)?
      var onDismiss: (() -> Void)?

      func start() {
          globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
              self?.handle(event: event)
          }
          localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
              return self?.handleLocal(event: event) ?? event
          }
      }

      func stop() {
          if let g = globalMonitor { NSEvent.removeMonitor(g) }
          if let l = localMonitor { NSEvent.removeMonitor(l) }
          globalMonitor = nil
          localMonitor = nil
      }

      private func handle(event: NSEvent) {
          guard event.keyCode != UInt16(kVK_Tab) else { return }
          onKeystroke?(event)
      }

      private func handleLocal(event: NSEvent) -> NSEvent? {
          switch event.keyCode {
          case UInt16(kVK_Tab):
              if event.modifierFlags.contains(.shift) {
                  onShiftTabPressed?()
              } else {
                  onTabPressed?()
              }
              return nil // consume Tab so it doesn't advance focus
          case UInt16(kVK_Escape):
              onDismiss?()
              return event
          default:
              onKeystroke?(event)
              return event
          }
      }
  }
  ```

- [ ] **Step 2: Commit**

  ```bash
  git add Sources/TypeAhead/Core/KeyEventMonitor.swift
  git commit -m "feat: add KeyEventMonitor for global keystroke capture and Tab acceptance"
  ```

---

### Task 9: CompletionPipeline — Wire It All Together

**Files:**
- Create: `Sources/TypeAhead/Core/CompletionPipeline.swift`
- Create: `Tests/TypeAheadTests/CompletionPipelineTests.swift`

- [ ] **Step 1: Write failing tests**

  ```swift
  // Tests/TypeAheadTests/CompletionPipelineTests.swift
  import Testing
  @testable import TypeAhead

  @Suite struct CompletionPipelineTests {
      @Test func doesNotFireBeforeDebounceExpires() async throws {
          let pipeline = CompletionPipeline.mock()
          pipeline.keystrokeReceived()
          try await Task.sleep(for: .milliseconds(50))
          #expect(pipeline.inferenceCallCount == 0)
      }

      @Test func firesAfterDebounceExpires() async throws {
          let pipeline = CompletionPipeline.mock(debounceInterval: 0.05)
          pipeline.keystrokeReceived()
          try await Task.sleep(for: .milliseconds(100))
          #expect(pipeline.inferenceCallCount == 1)
      }

      @Test func resetsDebouncerOnSubsequentKeystrokes() async throws {
          let pipeline = CompletionPipeline.mock(debounceInterval: 0.1)
          pipeline.keystrokeReceived()
          try await Task.sleep(for: .milliseconds(50))
          pipeline.keystrokeReceived()
          try await Task.sleep(for: .milliseconds(60))
          // Timer reset; should not have fired yet
          #expect(pipeline.inferenceCallCount == 0)
          try await Task.sleep(for: .milliseconds(80))
          // Now it should have fired once
          #expect(pipeline.inferenceCallCount == 1)
      }

      @Test func completionDisabledSkipsInference() async throws {
          let pipeline = CompletionPipeline.mock(debounceInterval: 0.05, enabled: false)
          pipeline.keystrokeReceived()
          try await Task.sleep(for: .milliseconds(100))
          #expect(pipeline.inferenceCallCount == 0)
      }
  }
  ```

- [ ] **Step 2: Run test to verify it fails**

  ```bash
  swift test --filter CompletionPipelineTests
  ```
  Expected: FAIL — `CompletionPipeline` not defined.

- [ ] **Step 3: Implement CompletionPipeline**

  ```swift
  // Sources/TypeAhead/Core/CompletionPipeline.swift
  import Foundation

  @MainActor
  final class CompletionPipeline {
      private var debounceTask: Task<Void, Never>?
      private let debounceInterval: TimeInterval
      var isEnabled: Bool

      // For testing — counts inference calls without real AX/MLX
      private(set) var inferenceCallCount = 0
      private let inferenceAction: () async -> Void

      init(
          debounceInterval: TimeInterval = 0.12,
          enabled: Bool = true,
          inferenceAction: @escaping () async -> Void
      ) {
          self.debounceInterval = debounceInterval
          self.isEnabled = enabled
          self.inferenceAction = inferenceAction
      }

      func keystrokeReceived() {
          guard isEnabled else { return }
          debounceTask?.cancel()
          debounceTask = Task {
              do {
                  try await Task.sleep(for: .seconds(debounceInterval))
              } catch { return }
              guard !Task.isCancelled else { return }
              await inferenceAction()
              inferenceCallCount += 1
          }
      }

      func cancel() {
          debounceTask?.cancel()
          debounceTask = nil
      }

      // Test factory — uses a no-op inference action
      static func mock(debounceInterval: TimeInterval = 0.12, enabled: Bool = true) -> CompletionPipeline {
          CompletionPipeline(debounceInterval: debounceInterval, enabled: enabled, inferenceAction: {})
      }
  }
  ```

- [ ] **Step 4: Run tests to verify they pass**

  ```bash
  swift test --filter CompletionPipelineTests
  ```
  Expected: All 4 tests PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/TypeAhead/Core/CompletionPipeline.swift Tests/TypeAheadTests/CompletionPipelineTests.swift
  git commit -m "feat: add CompletionPipeline with debounce timer and enable/disable control"
  ```

---

### Task 10: App Entry Point and AppDelegate

**Files:**
- Create: `Sources/TypeAhead/App/TypeAheadApp.swift`
- Create: `Sources/TypeAhead/App/AppDelegate.swift`
- Create: `Sources/TypeAhead/App/AppDependencies.swift`

- [ ] **Step 1: Implement AppDependencies**

  ```swift
  // Sources/TypeAhead/App/AppDependencies.swift
  import Foundation

  @MainActor
  final class AppDependencies {
      static let shared = AppDependencies()

      let settings = AppSettings()
      let accessibilityManager = AccessibilityManager()
      let inferenceEngine = InferenceEngine()
      let completionOverlay = CompletionOverlay()
      let historyStore = HistoryStore()
      lazy var personalizationEngine = PersonalizationEngine(historyStore: historyStore)
      lazy var completionPipeline = CompletionPipeline(
          debounceInterval: settings.completionDelay,
          enabled: settings.completionsEnabled,
          inferenceAction: { [weak self] in
              await self?.runCompletion()
          }
      )
      let keyMonitor = KeyEventMonitor()

      private func runCompletion() async {
          guard let context = accessibilityManager.readTextContext() else { return }
          let recentHistory = await historyStore.recentAcceptedPhrases(limit: 5)
          let clipboard = settings.useClipboardContext ? ClipboardContextProvider.current() : nil
          let prompt = ContextBuilder.buildPrompt(
              context: context,
              clipboard: clipboard,
              history: recentHistory,
              customInstructions: settings.customInstructions
          )
          var accumulated = ""
          let cursorRect = accessibilityManager.cursorScreenRect() ?? .zero
          inferenceEngine.complete(prompt: prompt, maxTokens: settings.completionLength.maxTokens) { token in
              accumulated += token
              Task { @MainActor in
                  self.completionOverlay.update(text: accumulated)
                  if accumulated.count == token.count {
                      self.completionOverlay.show(text: accumulated, near: cursorRect)
                  }
              }
          } onComplete: {}
      }
  }
  ```

- [ ] **Step 2: Implement AppDelegate**

  ```swift
  // Sources/TypeAhead/App/AppDelegate.swift
  import AppKit

  final class AppDelegate: NSObject, NSApplicationDelegate {
      private var statusBarMenu: StatusBarMenu?

      func applicationDidFinishLaunching(_ notification: Notification) {
          NSApp.setActivationPolicy(.accessory) // no Dock icon
          let deps = AppDependencies.shared
          statusBarMenu = StatusBarMenu(settings: deps.settings, pipeline: deps.completionPipeline)

          deps.keyMonitor.onKeystroke = { [weak deps] _ in
              deps?.completionPipeline.keystrokeReceived()
          }
          deps.keyMonitor.onTabPressed = { [weak deps] in
              deps?.inferenceEngine.cancelCurrent()
              // TODO Task 12: accept next word
          }
          deps.keyMonitor.onDismiss = { [weak deps] in
              deps?.inferenceEngine.cancelCurrent()
              deps?.completionOverlay.hide()
          }
          deps.keyMonitor.start()

          Task { @MainActor in
              let config = ModelConfig.recommended(availableRAMGB: Self.availableRAMGB())
              try? await deps.inferenceEngine.loadModel(config: config)
          }
      }

      func applicationWillTerminate(_ notification: Notification) {
          AppDependencies.shared.keyMonitor.stop()
          AppDependencies.shared.inferenceEngine.unloadModel()
      }

      private static func availableRAMGB() -> Int {
          let bytes = ProcessInfo.processInfo.physicalMemory
          return Int(bytes / (1024 * 1024 * 1024))
      }
  }
  ```

- [ ] **Step 3: Implement TypeAheadApp**

  ```swift
  // Sources/TypeAhead/App/TypeAheadApp.swift
  import SwiftUI

  @main
  struct TypeAheadApp: App {
      @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

      var body: some Scene {
          Settings {
              SettingsWindow()
                  .environment(AppDependencies.shared.settings)
          }
      }
  }
  ```

- [ ] **Step 4: Build and verify in Xcode**

  Build: ⌘B
  Expected: Build Succeeded. App runs as a menu bar app with no Dock icon.

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/TypeAhead/App/
  git commit -m "feat: add app entry point, AppDelegate, and AppDependencies wiring"
  ```

---

## Phase 2: System-Wide and Settings

### Task 11: ModelDownloader — Resumable HuggingFace Download

**Files:**
- Create: `Sources/TypeAhead/Models/ModelDownloader.swift`
- Create: `Tests/TypeAheadTests/ModelDownloaderTests.swift`

- [ ] **Step 1: Write failing tests**

  ```swift
  // Tests/TypeAheadTests/ModelDownloaderTests.swift
  import Testing
  @testable import TypeAhead

  @Suite struct ModelDownloaderTests {
      @Test func destinationURLMatchesModelID() {
          let config = ModelConfig.qwen3_1B
          let downloader = ModelDownloader(config: config)
          #expect(downloader.destinationURL.lastPathComponent == config.id)
      }

      @Test func isDownloadedReturnsFalseForMissingFile() {
          let config = ModelConfig.qwen3_1B
          let downloader = ModelDownloader(config: config)
          // Use temp dir that definitely doesn't have the model
          #expect(!downloader.isDownloaded)
      }

      @Test func progressStartsAtZero() {
          let config = ModelConfig.qwen3_1B
          let downloader = ModelDownloader(config: config)
          #expect(downloader.progress == 0.0)
      }
  }
  ```

- [ ] **Step 2: Run test to verify it fails**

  ```bash
  swift test --filter ModelDownloaderTests
  ```
  Expected: FAIL — `ModelDownloader` not defined.

- [ ] **Step 3: Implement ModelDownloader**

  ```swift
  // Sources/TypeAhead/Models/ModelDownloader.swift
  import Foundation

  @Observable
  final class ModelDownloader: NSObject {
      let config: ModelConfig
      private(set) var progress: Double = 0
      private(set) var isDownloading = false
      private(set) var error: Error?

      private var session: URLSession?
      private var downloadTask: URLSessionDownloadTask?

      init(config: ModelConfig) {
          self.config = config
      }

      var destinationURL: URL {
          FileManager.default
              .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
              .appendingPathComponent("TypeAhead/Models/\(config.id)")
      }

      var isDownloaded: Bool {
          FileManager.default.fileExists(atPath: destinationURL.path)
      }

      func start() async throws {
          guard !isDownloaded else { return }
          isDownloading = true
          error = nil
          let configuration = URLSessionConfiguration.background(withIdentifier: "app.typeahead.model.\(config.id)")
          session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
          let url = URL(string: "https://huggingface.co/\(config.huggingFaceRepo)/resolve/main/model.safetensors.index.json")!
          downloadTask = session?.downloadTask(with: url)
          downloadTask?.resume()
      }

      func cancel() {
          downloadTask?.cancel()
          isDownloading = false
      }
  }

  extension ModelDownloader: URLSessionDownloadDelegate {
      func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
          do {
              try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
              try FileManager.default.moveItem(at: location, to: destinationURL.appendingPathComponent("model.safetensors.index.json"))
          } catch {
              self.error = error
          }
          isDownloading = false
      }

      func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
          guard totalBytesExpectedToWrite > 0 else { return }
          DispatchQueue.main.async {
              self.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
          }
      }

      func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
          if let error {
              DispatchQueue.main.async {
                  self.error = error
                  self.isDownloading = false
              }
          }
      }
  }
  ```

- [ ] **Step 4: Run tests to verify they pass**

  ```bash
  swift test --filter ModelDownloaderTests
  ```
  Expected: All 3 tests PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/TypeAhead/Models/ModelDownloader.swift Tests/TypeAheadTests/ModelDownloaderTests.swift
  git commit -m "feat: add ModelDownloader with URLSession background download and progress"
  ```

---

### Task 12: ModelManager — Download State Machine

**Files:**
- Create: `Sources/TypeAhead/Models/ModelManager.swift`

- [ ] **Step 1: Implement ModelManager**

  ```swift
  // Sources/TypeAhead/Models/ModelManager.swift
  import Foundation
  import Observation

  enum ModelStatus {
      case notDownloaded, downloading(Double), downloaded, loading, active
  }

  @Observable
  @MainActor
  final class ModelManager {
      private(set) var statuses: [String: ModelStatus] = [:]
      private var downloaders: [String: ModelDownloader] = [:]
      private let inferenceEngine: InferenceEngine
      private let settings: AppSettings

      init(inferenceEngine: InferenceEngine, settings: AppSettings) {
          self.inferenceEngine = inferenceEngine
          self.settings = settings
          for config in ModelConfig.all {
              statuses[config.id] = FileManager.default.fileExists(
                  atPath: ModelDownloader(config: config).destinationURL.path
              ) ? .downloaded : .notDownloaded
          }
      }

      func download(config: ModelConfig) async {
          let downloader = ModelDownloader(config: config)
          downloaders[config.id] = downloader
          statuses[config.id] = .downloading(0)
          do {
              try await downloader.start()
              statuses[config.id] = .downloaded
          } catch {
              statuses[config.id] = .notDownloaded
          }
      }

      func activate(config: ModelConfig) async {
          guard statuses[config.id] == .downloaded else { return }
          statuses[config.id] = .loading
          do {
              inferenceEngine.unloadModel()
              try await inferenceEngine.loadModel(config: config)
              // Mark previous active model as downloaded
              for id in statuses.keys where statuses[id] == .active {
                  statuses[id] = .downloaded
              }
              statuses[config.id] = .active
              settings.activeModelID = config.id
          } catch {
              statuses[config.id] = .downloaded
          }
      }

      func status(for config: ModelConfig) -> ModelStatus {
          if let downloader = downloaders[config.id], case .downloading = statuses[config.id] {
              return .downloading(downloader.progress)
          }
          return statuses[config.id] ?? .notDownloaded
      }
  }
  ```

- [ ] **Step 2: Commit**

  ```bash
  git add Sources/TypeAhead/Models/ModelManager.swift
  git commit -m "feat: add ModelManager with download state machine and active model switching"
  ```

---

### Task 13: ClipboardContextProvider

**Files:**
- Create: `Sources/TypeAhead/Context/ClipboardContextProvider.swift`

- [ ] **Step 1: Implement ClipboardContextProvider**

  ```swift
  // Sources/TypeAhead/Context/ClipboardContextProvider.swift
  import AppKit

  enum ClipboardContextProvider {
      private static let maxChars = 400

      static func current() -> String? {
          guard let text = NSPasteboard.general.string(forType: .string),
                !text.isEmpty else { return nil }
          return String(text.prefix(maxChars))
      }
  }
  ```

- [ ] **Step 2: Write test**

  ```swift
  // Tests/TypeAheadTests/ClipboardContextProviderTests.swift
  import Testing
  @testable import TypeAhead

  @Suite struct ClipboardContextProviderTests {
      @Test func truncatesLongClipboard() {
          let result = ClipboardContextProvider.truncate(String(repeating: "a", count: 600))
          #expect(result.count == 400)
      }
  }
  ```

  Add the `truncate` helper to `ClipboardContextProvider`:

  ```swift
  static func truncate(_ text: String) -> String {
      String(text.prefix(maxChars))
  }
  ```

- [ ] **Step 3: Run test to verify it passes**

  ```bash
  swift test --filter ClipboardContextProviderTests
  ```
  Expected: PASS.

- [ ] **Step 4: Commit**

  ```bash
  git add Sources/TypeAhead/Context/ClipboardContextProvider.swift Tests/TypeAheadTests/ClipboardContextProviderTests.swift
  git commit -m "feat: add ClipboardContextProvider with 400-char limit"
  ```

---

### Task 14: StatusBarMenu

**Files:**
- Create: `Sources/TypeAhead/UI/StatusBar/StatusBarMenu.swift`

- [ ] **Step 1: Implement StatusBarMenu**

  ```swift
  // Sources/TypeAhead/UI/StatusBar/StatusBarMenu.swift
  import AppKit
  import Observation

  @MainActor
  final class StatusBarMenu {
      private let statusItem: NSStatusItem
      private let settings: AppSettings
      private let pipeline: CompletionPipeline

      init(settings: AppSettings, pipeline: CompletionPipeline) {
          self.settings = settings
          self.pipeline = pipeline
          statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
          statusItem.button?.image = NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: "TypeAhead")
          buildMenu()
      }

      private func buildMenu() {
          let menu = NSMenu()
          let toggleItem = NSMenuItem(
              title: settings.completionsEnabled ? "Completions: On" : "Completions: Off",
              action: #selector(toggleCompletions),
              keyEquivalent: ""
          )
          toggleItem.target = self
          menu.addItem(toggleItem)

          menu.addItem(.separator())

          let activeModel = ModelConfig.all.first { $0.id == settings.activeModelID }?.displayName ?? "Unknown"
          menu.addItem(NSMenuItem(title: "Model: \(activeModel)", action: nil, keyEquivalent: ""))

          menu.addItem(.separator())

          let settingsItem = NSMenuItem(title: "Open Settings…", action: #selector(openSettings), keyEquivalent: ",")
          settingsItem.target = self
          menu.addItem(settingsItem)

          let quitItem = NSMenuItem(title: "Quit TypeAhead", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
          menu.addItem(quitItem)

          statusItem.menu = menu
      }

      @objc private func toggleCompletions() {
          settings.completionsEnabled.toggle()
          pipeline.isEnabled = settings.completionsEnabled
          buildMenu()
      }

      @objc private func openSettings() {
          NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
          NSApp.activate(ignoringOtherApps: true)
      }
  }
  ```

- [ ] **Step 2: Commit**

  ```bash
  git add Sources/TypeAhead/UI/StatusBar/StatusBarMenu.swift
  git commit -m "feat: add StatusBarMenu with toggle and settings access"
  ```

---

### Task 15: Settings Window

**Files:**
- Create: `Sources/TypeAhead/UI/Settings/SettingsWindow.swift`
- Create: `Sources/TypeAhead/UI/Settings/GeneralView.swift`
- Create: `Sources/TypeAhead/UI/Settings/SetupView.swift`
- Create: `Sources/TypeAhead/UI/Settings/PersonalizationView.swift`
- Create: `Sources/TypeAhead/UI/Settings/StatisticsView.swift`
- Create: `Sources/TypeAhead/UI/Settings/AboutView.swift`

- [ ] **Step 1: Implement SettingsWindow shell**

  ```swift
  // Sources/TypeAhead/UI/Settings/SettingsWindow.swift
  import SwiftUI

  enum SettingsSection: String, CaseIterable, Identifiable {
      case setup, general, personalization, statistics, about
      var id: String { rawValue }
      var label: String {
          switch self {
          case .setup: "Setup"
          case .general: "General"
          case .personalization: "Personalization"
          case .statistics: "Statistics"
          case .about: "About"
          }
      }
      var icon: String {
          switch self {
          case .setup: "checkmark.shield"
          case .general: "slider.horizontal.3"
          case .personalization: "person.crop.circle"
          case .statistics: "chart.bar"
          case .about: "info.circle"
          }
      }
  }

  struct SettingsWindow: View {
      @Environment(AppSettings.self) private var settings
      @State private var selectedSection: SettingsSection = .general

      var body: some View {
          NavigationSplitView {
              List(SettingsSection.allCases, selection: $selectedSection) { section in
                  Label(section.label, systemImage: section.icon)
                      .tag(section)
              }
              .listStyle(.sidebar)
              .navigationSplitViewColumnWidth(min: 180, ideal: 200)
          } detail: {
              Group {
                  switch selectedSection {
                  case .setup:           SetupView()
                  case .general:         GeneralView()
                  case .personalization: PersonalizationView()
                  case .statistics:      StatisticsView()
                  case .about:           AboutView()
                  }
              }
              .frame(minWidth: 480, minHeight: 400)
          }
          .frame(minWidth: 680, minHeight: 460)
      }
  }
  ```

- [ ] **Step 2: Implement GeneralView**

  ```swift
  // Sources/TypeAhead/UI/Settings/GeneralView.swift
  import SwiftUI

  struct GeneralView: View {
      @Environment(AppSettings.self) private var settings

      var body: some View {
          @Bindable var s = settings
          Form {
              Section("Completions") {
                  Toggle("Enable Completions", isOn: $s.completionsEnabled)
                  Picker("Completion Length", selection: $s.completionLength) {
                      ForEach(CompletionLength.allCases, id: \.self) { length in
                          Text(length.displayName).tag(length)
                      }
                  }
                  VStack(alignment: .leading) {
                      Text("Trigger Delay: \(Int(s.completionDelay * 1000))ms")
                          .font(.caption)
                          .foregroundStyle(.secondary)
                      Slider(value: $s.completionDelay, in: 0.05...0.5, step: 0.01)
                  }
                  Toggle("Show in All Apps", isOn: $s.showInAllApps)
              }
              Section("Model") {
                  Picker("Active Model", selection: $s.activeModelID) {
                      ForEach(ModelConfig.all) { model in
                          Text(model.displayName).tag(model.id)
                      }
                  }
              }
              Section("Context") {
                  Toggle("Use Screenshot Context", isOn: $s.useScreenshotContext)
                  Toggle("Use Clipboard Context", isOn: $s.useClipboardContext)
              }
              Section("App") {
                  Toggle("Launch at Login", isOn: $s.launchAtLogin)
              }
          }
          .formStyle(.grouped)
          .navigationTitle("General")
      }
  }
  ```

- [ ] **Step 3: Implement SetupView (onboarding/permission checker)**

  ```swift
  // Sources/TypeAhead/UI/Settings/SetupView.swift
  import SwiftUI
  import ApplicationServices

  struct SetupView: View {
      @State private var accessibilityGranted = false
      @State private var screenRecordingGranted = false

      var body: some View {
          ScrollView {
              VStack(alignment: .leading, spacing: 24) {
                  Text("Setup").font(.largeTitle).bold()

                  permissionRow(
                      title: "Accessibility Permission",
                      subtitle: "Required. Allows TypeAhead to read and write text in any app.",
                      granted: accessibilityGranted,
                      action: { openAccessibilitySettings() }
                  )
                  permissionRow(
                      title: "Screen Recording",
                      subtitle: "Recommended. Captures the active window for richer context. Never stored.",
                      granted: screenRecordingGranted,
                      action: { openScreenRecordingSettings() }
                  )
              }
              .padding(32)
          }
          .navigationTitle("Setup")
          .onAppear { checkPermissions() }
      }

      private func permissionRow(title: String, subtitle: String, granted: Bool, action: @escaping () -> Void) -> some View {
          HStack(alignment: .top, spacing: 16) {
              Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                  .foregroundStyle(granted ? .green : .orange)
                  .font(.title2)
              VStack(alignment: .leading, spacing: 4) {
                  Text(title).fontWeight(.medium)
                  Text(subtitle).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if !granted {
                  Button("Grant Access", action: action)
              }
          }
          .padding()
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
      }

      private func checkPermissions() {
          accessibilityGranted = AXIsProcessTrusted()
          screenRecordingGranted = CGPreflightScreenCaptureAccess()
      }

      private func openAccessibilitySettings() {
          NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
      }

      private func openScreenRecordingSettings() {
          NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
      }
  }
  ```

- [ ] **Step 4: Stub remaining views**

  ```swift
  // Sources/TypeAhead/UI/Settings/PersonalizationView.swift
  import SwiftUI
  struct PersonalizationView: View {
      @Environment(AppSettings.self) private var settings
      var body: some View {
          @Bindable var s = settings
          Form {
              Section("Typing History") {
                  Toggle("Store Input History", isOn: $s.storeInputHistory)
              }
              Section("Word Choice") {
                  VStack(alignment: .leading) {
                      Text("Personalization Strength: \(Int(s.personalizationStrength * 100))%")
                          .font(.caption).foregroundStyle(.secondary)
                      Slider(value: $s.personalizationStrength, in: 0...1)
                  }
              }
              Section("Custom Instructions") {
                  TextEditor(text: $s.customInstructions)
                      .frame(minHeight: 100)
                  Text("Up to 500 words. Injected at the top of every prompt.")
                      .font(.caption).foregroundStyle(.secondary)
              }
          }
          .formStyle(.grouped)
          .navigationTitle("Personalization")
      }
  }
  ```

  ```swift
  // Sources/TypeAhead/UI/Settings/AboutView.swift
  import SwiftUI
  struct AboutView: View {
      var body: some View {
          VStack(spacing: 16) {
              Text("TypeAhead").font(.largeTitle).bold()
              Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                  .foregroundStyle(.secondary)
              Text("All AI inference runs on-device. No data ever leaves your Mac.")
                  .multilineTextAlignment(.center)
                  .foregroundStyle(.secondary)
          }
          .padding()
          .navigationTitle("About")
      }
  }
  ```

- [ ] **Step 5: Build and manually verify settings window opens**

  Run the app in Xcode → click menu bar icon → Open Settings.
  Expected: Two-panel settings window with sidebar and working form views.

- [ ] **Step 6: Commit**

  ```bash
  git add Sources/TypeAhead/UI/Settings/
  git commit -m "feat: add settings window with General, Setup, Personalization, and About views"
  ```

---

## Phase 3: Personalization and Statistics

### Task 16: HistoryStore — SwiftData Typing History

**Files:**
- Create: `Sources/TypeAhead/Persistence/HistoryRecord.swift`
- Create: `Sources/TypeAhead/Persistence/HistoryStore.swift`
- Create: `Tests/TypeAheadTests/HistoryStoreTests.swift`

- [ ] **Step 1: Write failing tests**

  ```swift
  // Tests/TypeAheadTests/HistoryStoreTests.swift
  import Testing
  import SwiftData
  @testable import TypeAhead

  @Suite struct HistoryStoreTests {
      @Test func insertsAndRetrievesRecord() async throws {
          let store = HistoryStore(inMemory: true)
          try await store.record(accepted: "hello world", appName: "Notes")
          let phrases = await store.recentAcceptedPhrases(limit: 10)
          #expect(phrases.contains("hello world"))
      }

      @Test func respectsLimit() async throws {
          let store = HistoryStore(inMemory: true)
          for i in 0..<10 {
              try await store.record(accepted: "phrase \(i)", appName: "Mail")
          }
          let phrases = await store.recentAcceptedPhrases(limit: 5)
          #expect(phrases.count == 5)
      }

      @Test func deletesAllHistory() async throws {
          let store = HistoryStore(inMemory: true)
          try await store.record(accepted: "test", appName: "Notes")
          try await store.deleteAll()
          let phrases = await store.recentAcceptedPhrases(limit: 10)
          #expect(phrases.isEmpty)
      }
  }
  ```

- [ ] **Step 2: Run test to verify it fails**

  ```bash
  swift test --filter HistoryStoreTests
  ```
  Expected: FAIL — `HistoryStore`, `HistoryRecord` not defined.

- [ ] **Step 3: Implement HistoryRecord and HistoryStore**

  ```swift
  // Sources/TypeAhead/Persistence/HistoryRecord.swift
  import SwiftData
  import Foundation

  @Model
  final class HistoryRecord {
      var acceptedText: String
      var appName: String
      var timestamp: Date

      init(acceptedText: String, appName: String, timestamp: Date = .now) {
          self.acceptedText = acceptedText
          self.appName = appName
          self.timestamp = timestamp
      }
  }
  ```

  ```swift
  // Sources/TypeAhead/Persistence/HistoryStore.swift
  import SwiftData
  import Foundation

  @MainActor
  final class HistoryStore {
      private let container: ModelContainer

      init(inMemory: Bool = false) {
          let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
          container = try! ModelContainer(for: HistoryRecord.self, configurations: config)
      }

      func record(accepted text: String, appName: String) async throws {
          let context = container.mainContext
          let record = HistoryRecord(acceptedText: text, appName: appName)
          context.insert(record)
          try context.save()
      }

      func recentAcceptedPhrases(limit: Int) async -> [String] {
          let context = container.mainContext
          var descriptor = FetchDescriptor<HistoryRecord>(
              sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
          )
          descriptor.fetchLimit = limit
          let records = try? context.fetch(descriptor)
          return records?.map(\.acceptedText) ?? []
      }

      func deleteAll() async throws {
          let context = container.mainContext
          try context.delete(model: HistoryRecord.self)
          try context.save()
      }
  }
  ```

- [ ] **Step 4: Run tests to verify they pass**

  ```bash
  swift test --filter HistoryStoreTests
  ```
  Expected: All 3 tests PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/TypeAhead/Persistence/ Tests/TypeAheadTests/HistoryStoreTests.swift
  git commit -m "feat: add HistoryStore with SwiftData persistence and in-memory test support"
  ```

---

### Task 17: PersonalizationEngine

**Files:**
- Create: `Sources/TypeAhead/Personalization/PersonalizationEngine.swift`
- Create: `Tests/TypeAheadTests/PersonalizationEngineTests.swift`

- [ ] **Step 1: Write failing tests**

  ```swift
  // Tests/TypeAheadTests/PersonalizationEngineTests.swift
  import Testing
  @testable import TypeAhead

  @Suite struct PersonalizationEngineTests {
      @Test func returnsEmptyAtZeroStrength() async {
          let engine = PersonalizationEngine(historyStore: HistoryStore(inMemory: true))
          let examples = await engine.examples(strength: 0.0, limit: 5)
          #expect(examples.isEmpty)
      }

      @Test func returnsExamplesAtNonZeroStrength() async throws {
          let store = HistoryStore(inMemory: true)
          try await store.record(accepted: "Therefore I am", appName: "Notes")
          let engine = PersonalizationEngine(historyStore: store)
          let examples = await engine.examples(strength: 0.5, limit: 5)
          #expect(!examples.isEmpty)
      }

      @Test func limitsExamplesByStrength() async throws {
          let store = HistoryStore(inMemory: true)
          for i in 0..<10 {
              try await store.record(accepted: "phrase \(i)", appName: "Mail")
          }
          let engine = PersonalizationEngine(historyStore: store)
          let atMax = await engine.examples(strength: 1.0, limit: 10)
          let atHalf = await engine.examples(strength: 0.5, limit: 10)
          #expect(atMax.count >= atHalf.count)
      }
  }
  ```

- [ ] **Step 2: Run test to verify it fails**

  ```bash
  swift test --filter PersonalizationEngineTests
  ```
  Expected: FAIL.

- [ ] **Step 3: Implement PersonalizationEngine**

  ```swift
  // Sources/TypeAhead/Personalization/PersonalizationEngine.swift
  import Foundation

  @MainActor
  final class PersonalizationEngine {
      private let historyStore: HistoryStore

      init(historyStore: HistoryStore) {
          self.historyStore = historyStore
      }

      // Returns few-shot example phrases scaled by strength (0 = none, 1 = max 10 examples)
      func examples(strength: Double, limit: Int) async -> [String] {
          guard strength > 0 else { return [] }
          let maxExamples = Int((Double(limit) * strength).rounded())
          return await historyStore.recentAcceptedPhrases(limit: maxExamples)
      }
  }
  ```

- [ ] **Step 4: Run tests to verify they pass**

  ```bash
  swift test --filter PersonalizationEngineTests
  ```
  Expected: All 3 tests PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/TypeAhead/Personalization/ Tests/TypeAheadTests/PersonalizationEngineTests.swift
  git commit -m "feat: add PersonalizationEngine with strength-scaled few-shot injection"
  ```

---

### Task 18: StatisticsCalculator and StatisticsView

**Files:**
- Create: `Sources/TypeAhead/Persistence/StatisticsCalculator.swift`
- Create: `Sources/TypeAhead/UI/Settings/StatisticsView.swift`
- Create: `Tests/TypeAheadTests/StatisticsCalculatorTests.swift`

- [ ] **Step 1: Write failing tests**

  ```swift
  // Tests/TypeAheadTests/StatisticsCalculatorTests.swift
  import Testing
  @testable import TypeAhead
  import Foundation

  @Suite struct StatisticsCalculatorTests {
      @Test func keystrokesSavedIsZeroForEmptyHistory() {
          #expect(StatisticsCalculator.keystrokesSaved(from: []) == 0)
      }

      @Test func keystrokesSavedSumsCharacterCounts() {
          let phrases = ["hello", "world"]
          // 5 + 5 = 10 keystrokes saved
          #expect(StatisticsCalculator.keystrokesSaved(from: phrases) == 10)
      }

      @Test func acceptanceRateReturnsZeroForNoShown() {
          #expect(StatisticsCalculator.acceptanceRate(shown: 0, accepted: 0) == 0)
      }

      @Test func acceptanceRateCalculatesCorrectly() {
          #expect(StatisticsCalculator.acceptanceRate(shown: 100, accepted: 65) == 0.65)
      }
  }
  ```

- [ ] **Step 2: Run test to verify it fails**

  ```bash
  swift test --filter StatisticsCalculatorTests
  ```
  Expected: FAIL.

- [ ] **Step 3: Implement StatisticsCalculator**

  ```swift
  // Sources/TypeAhead/Persistence/StatisticsCalculator.swift
  import Foundation

  enum StatisticsCalculator {
      static func keystrokesSaved(from acceptedPhrases: [String]) -> Int {
          acceptedPhrases.reduce(0) { $0 + $1.count }
      }

      static func acceptanceRate(shown: Int, accepted: Int) -> Double {
          guard shown > 0 else { return 0 }
          return Double(accepted) / Double(shown)
      }
  }
  ```

- [ ] **Step 4: Implement StatisticsView**

  ```swift
  // Sources/TypeAhead/UI/Settings/StatisticsView.swift
  import SwiftUI
  import Charts

  struct StatisticsView: View {
      @State private var keystrokesSaved = 0
      @State private var acceptanceRate = 0.0
      private let store = AppDependencies.shared.historyStore

      var body: some View {
          ScrollView {
              VStack(alignment: .leading, spacing: 20) {
                  HStack(spacing: 24) {
                      statCard(title: "Keystrokes Saved", value: "\(keystrokesSaved)")
                      statCard(title: "Acceptance Rate", value: String(format: "%.0f%%", acceptanceRate * 100))
                  }
              }
              .padding()
          }
          .navigationTitle("Statistics")
          .task {
              let phrases = await store.recentAcceptedPhrases(limit: 1000)
              keystrokesSaved = StatisticsCalculator.keystrokesSaved(from: phrases)
          }
      }

      private func statCard(title: String, value: String) -> some View {
          VStack(alignment: .leading, spacing: 4) {
              Text(title).font(.caption).foregroundStyle(.secondary)
              Text(value).font(.title2).bold()
          }
          .padding()
          .frame(minWidth: 120)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
      }
  }
  ```

- [ ] **Step 5: Run tests to verify they pass**

  ```bash
  swift test --filter StatisticsCalculatorTests
  ```
  Expected: All 4 tests PASS.

- [ ] **Step 6: Commit**

  ```bash
  git add Sources/TypeAhead/Persistence/StatisticsCalculator.swift Sources/TypeAhead/UI/Settings/StatisticsView.swift Tests/TypeAheadTests/StatisticsCalculatorTests.swift
  git commit -m "feat: add StatisticsCalculator and StatisticsView with keystrokes saved and acceptance rate"
  ```

---

### Task 19: TypoDetector — Local Spell-Check Autocorrect

**Files:**
- Create: `Sources/TypeAhead/Features/Autocorrect/TypoDetector.swift`
- Create: `Tests/TypeAheadTests/TypoDetectorTests.swift`

- [ ] **Step 1: Write failing tests**

  ```swift
  // Tests/TypeAheadTests/TypoDetectorTests.swift
  import Testing
  @testable import TypeAhead

  @Suite struct TypoDetectorTests {
      @Test func detectsSimpleTypo() {
          let result = TypoDetector.check(word: "teh")
          #expect(result != nil)
          #expect(result?.suggestion == "the")
      }

      @Test func returnsNilForCorrectWord() {
          let result = TypoDetector.check(word: "hello")
          #expect(result == nil)
      }

      @Test func returnsNilForEmptyString() {
          let result = TypoDetector.check(word: "")
          #expect(result == nil)
      }

      @Test func returnsNilForSingleLetter() {
          let result = TypoDetector.check(word: "a")
          #expect(result == nil)
      }
  }
  ```

- [ ] **Step 2: Run test to verify it fails**

  ```bash
  swift test --filter TypoDetectorTests
  ```
  Expected: FAIL.

- [ ] **Step 3: Implement TypoDetector**

  ```swift
  // Sources/TypeAhead/Features/Autocorrect/TypoDetector.swift
  import Foundation

  struct TypoFix: Sendable {
      let original: String
      let suggestion: String
  }

  enum TypoDetector {
      private static let checker = NSSpellChecker.shared

      static func check(word: String) -> TypoFix? {
          guard word.count > 1 else { return nil }
          let range = checker.checkSpelling(of: word, startingAt: 0)
          guard range.location != NSNotFound else { return nil }
          guard let guesses = checker.guesses(forWordRange: range, in: word, language: checker.language(), inSpellDocumentWithTag: 0),
                let first = guesses.first else { return nil }
          return TypoFix(original: word, suggestion: first)
      }
  }
  ```

- [ ] **Step 4: Run tests to verify they pass**

  ```bash
  swift test --filter TypoDetectorTests
  ```
  Expected: All 4 tests PASS. (Note: `teh` → `the` depends on system dictionary, may need adjustment.)

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/TypeAhead/Features/Autocorrect/ Tests/TypeAheadTests/TypoDetectorTests.swift
  git commit -m "feat: add TypoDetector using NSSpellChecker for zero-latency autocorrect"
  ```

---

### Task 20: EmojiSuggester — Colon-Trigger Emoji Completions

**Files:**
- Create: `Sources/TypeAhead/Features/Emoji/EmojiSuggester.swift`
- Create: `Tests/TypeAheadTests/EmojiSuggesterTests.swift`

- [ ] **Step 1: Write failing tests**

  ```swift
  // Tests/TypeAheadTests/EmojiSuggesterTests.swift
  import Testing
  @testable import TypeAhead

  @Suite struct EmojiSuggesterTests {
      @Test func detectsColonTrigger() {
          #expect(EmojiSuggester.isEmojiMode(textBeforeCursor: "Hello :wav") == true)
          #expect(EmojiSuggester.isEmojiMode(textBeforeCursor: "Hello world") == false)
      }

      @Test func extractsShortcode() {
          let code = EmojiSuggester.shortcode(from: "Hello :wave")
          #expect(code == "wave")
      }

      @Test func findsMatchingEmoji() {
          let results = EmojiSuggester.suggest(shortcode: "wave")
          #expect(results.contains("👋"))
      }

      @Test func returnsEmptyForNoMatch() {
          let results = EmojiSuggester.suggest(shortcode: "zzznomatch")
          #expect(results.isEmpty)
      }
  }
  ```

- [ ] **Step 2: Run test to verify it fails**

  ```bash
  swift test --filter EmojiSuggesterTests
  ```
  Expected: FAIL.

- [ ] **Step 3: Implement EmojiSuggester**

  ```swift
  // Sources/TypeAhead/Features/Emoji/EmojiSuggester.swift
  import Foundation

  enum EmojiSuggester {
      // Minimal shortcode → emoji map (extend as needed)
      private static let catalog: [(shortcode: String, emoji: String)] = [
          ("wave", "👋"), ("fire", "🔥"), ("heart", "❤️"), ("thumbsup", "+1"),
          ("thumbsup", "👍"), ("smile", "😊"), ("laugh", "😂"), ("cry", "😢"),
          ("tada", "🎉"), ("rocket", "🚀"), ("star", "⭐"), ("check", "✅"),
          ("x", "❌"), ("warning", "⚠️"), ("bulb", "💡"), ("clap", "👏"),
          ("pray", "🙏"), ("eyes", "👀"), ("muscle", "💪"), ("ok", "👌"),
      ]

      static func isEmojiMode(textBeforeCursor: String) -> Bool {
          guard let lastColon = textBeforeCursor.lastIndex(of: ":") else { return false }
          let afterColon = String(textBeforeCursor[textBeforeCursor.index(after: lastColon)...])
          return !afterColon.contains(" ") && !afterColon.isEmpty
      }

      static func shortcode(from textBeforeCursor: String) -> String? {
          guard let lastColon = textBeforeCursor.lastIndex(of: ":") else { return nil }
          let after = String(textBeforeCursor[textBeforeCursor.index(after: lastColon)...])
          return after.isEmpty ? nil : after
      }

      static func suggest(shortcode: String) -> [String] {
          catalog.filter { $0.shortcode.hasPrefix(shortcode.lowercased()) }.map(\.emoji)
      }
  }
  ```

- [ ] **Step 4: Run tests to verify they pass**

  ```bash
  swift test --filter EmojiSuggesterTests
  ```
  Expected: All 4 tests PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add Sources/TypeAhead/Features/Emoji/ Tests/TypeAheadTests/EmojiSuggesterTests.swift
  git commit -m "feat: add EmojiSuggester with colon-trigger shortcode matching"
  ```

---

## Phase 4: Distribution

### Task 21: Entitlements, Notarization, and Sparkle

**Files:**
- Modify: `Sources/TypeAhead/Resources/TypeAhead.entitlements`
- Create: `scripts/notarize.sh`

- [ ] **Step 1: Finalize entitlements**

  Confirm `TypeAhead.entitlements` contains:

  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
      <key>com.apple.security.automation.apple-events</key>
      <true/>
  </dict>
  </plist>
  ```

  **Important:** Do NOT include `com.apple.security.app-sandbox`. It will break AXUIElement.

- [ ] **Step 2: Add Sparkle updater to AppDelegate**

  In `AppDelegate.swift`, add to `applicationDidFinishLaunching`:

  ```swift
  import Sparkle

  // In AppDelegate, add property:
  private let updaterController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
  )
  ```

  Add a "Check for Updates…" menu item in `StatusBarMenu.swift`:

  ```swift
  let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
  updateItem.target = self

  @objc private func checkForUpdates() {
      // Sparkle handles this via SPUStandardUpdaterController
      NotificationCenter.default.post(name: NSNotification.Name("CheckForUpdates"), object: nil)
  }
  ```

- [ ] **Step 3: Create notarization script**

  ```bash
  #!/bin/bash
  # scripts/notarize.sh
  # Usage: ./scripts/notarize.sh path/to/TypeAhead.app
  set -e
  APP="$1"
  BUNDLE_ID="app.typeahead.TypeAhead"
  TEAM_ID="${APPLE_TEAM_ID:?Set APPLE_TEAM_ID env var}"
  APPLE_ID="${APPLE_ID:?Set APPLE_ID env var}"
  APP_PASSWORD="${APP_PASSWORD:?Set APP_PASSWORD env var}"

  echo "Creating zip for notarization…"
  ditto -c -k --keepParent "$APP" TypeAhead-notarize.zip

  echo "Submitting for notarization…"
  xcrun notarytool submit TypeAhead-notarize.zip \
      --apple-id "$APPLE_ID" \
      --password "$APP_PASSWORD" \
      --team-id "$TEAM_ID" \
      --wait

  echo "Stapling ticket…"
  xcrun stapler staple "$APP"
  rm TypeAhead-notarize.zip
  echo "Done."
  ```

  ```bash
  chmod +x scripts/notarize.sh
  ```

- [ ] **Step 4: Commit**

  ```bash
  git add Sources/TypeAhead/Resources/TypeAhead.entitlements scripts/notarize.sh
  git commit -m "feat: finalize entitlements and add notarization script"
  ```

---

### Task 22: Final Integration Smoke Test

- [ ] **Step 1: Run all unit tests**

  ```bash
  swift test
  ```
  Expected: All tests PASS, 0 failures.

- [ ] **Step 2: Build Release in Xcode**

  Xcode → Product → Archive
  Expected: Archive succeeds.

- [ ] **Step 3: Manual acceptance test checklist**

  - [ ] Open TextEdit — type a sentence — ghost text appears within 150ms
  - [ ] Press Tab — first word is accepted inline
  - [ ] Press Escape — overlay dismisses
  - [ ] Open 1Password — no overlay appears (excluded by default)
  - [ ] Menu bar icon visible — toggle off — no more completions — toggle on — completions resume
  - [ ] Settings → General → change model — model reloads (status bar brief loading indicator)
  - [ ] Settings → Setup — Accessibility shows green checkmark if permission granted
  - [ ] Type `:wave` — emoji suggestion appears
  - [ ] Type a deliberate typo like "teh " — strikethrough fix appears

- [ ] **Step 4: Final commit**

  ```bash
  git add -A
  git commit -m "feat: TypeAhead v1.0 — all phases complete, acceptance tests passing"
  ```

---

## Spec Coverage Check

| PRD Section | Covered by Task |
|-------------|-----------------|
| Sub-100ms latency target | Task 6 (InferenceEngine streaming), Task 9 (120ms debounce) |
| FIM prompt design | Task 4 (ContextBuilder) |
| All 5 models + RAM selection | Task 2 (ModelConfig) |
| Accessibility read/write | Task 5 (AccessibilityManager) |
| CompletionOverlay ghost text | Task 7 (CompletionOverlay) |
| Tab/Shift+Tab acceptance | Task 8 (KeyEventMonitor) |
| Debounce timer | Task 9 (CompletionPipeline) |
| Global keystroke monitor | Task 8 (KeyEventMonitor) |
| AppSettings + UserDefaults | Task 3 (AppSettings) |
| Per-app exception list | Task 3 (AppExceptionList) |
| Status bar menu | Task 14 (StatusBarMenu) |
| Model downloader (resumable) | Task 11 (ModelDownloader) |
| Model manager / switching | Task 12 (ModelManager) |
| Settings window (all sections) | Task 15 (SettingsWindow + views) |
| Onboarding/permission wizard | Task 15 (SetupView) |
| Clipboard context (400 char) | Task 13 (ClipboardContextProvider) |
| SwiftData history store | Task 16 (HistoryStore) |
| Personalization few-shot | Task 17 (PersonalizationEngine) |
| Statistics view | Task 18 (StatisticsCalculator + StatisticsView) |
| Typo detector (no-latency) | Task 19 (TypoDetector) |
| Emoji suggestions (:trigger) | Task 20 (EmojiSuggester) |
| Entitlements (no sandbox) | Task 1 + Task 21 |
| Sparkle auto-update | Task 21 |
| Notarization | Task 21 |
| App entry + lifecycle | Task 10 (AppDelegate, TypeAheadApp) |
| Screenshot context | Mentioned in AppDependencies (Task 10) — ScreenshotContextProvider.swift stub needed |

> **Gap:** `ScreenshotContextProvider.swift` — the context provider for CGWindowListCreateImage — is referenced in `AppDependencies` but not fully implemented. Add a task for it after Task 13 if screenshot context is required for v1.
