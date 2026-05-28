# Inline Ghost Text + MLX Inference Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the floating dark panel with inline ghost text at the cursor, wire up real MLX inference via MLXLLM, and eliminate stale completion flicker.

**Architecture:** `CompletionOverlay` becomes a zero-chrome transparent `NSPanel` positioned at cursor right-edge with font-size-matched grey text. `InferenceEngine` swaps `FoundationModels` for `MLXLLM.ChatSession.streamResponse(to:)`. Stale completions are hidden instantly (no fade) on keystroke.

**Tech Stack:** Swift 6, AppKit, MLXLLM (mlx-swift-examples 2.29.1), MLXLMCommon, mlx-swift, HubApi (bundled with swift-transformers)

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `TypeAhead/TypeAhead.xcodeproj/project.pbxproj` | Modify | Link MLXLLM + MLXLMCommon to the target |
| `TypeAhead/TypeAhead/Core/InferenceEngine.swift` | Rewrite | MLXLLM ChatSession streaming, HubApi download |
| `TypeAhead/TypeAhead/Overlay/CompletionOverlay.swift` | Rewrite | Zero-chrome inline ghost text NSPanel |
| `TypeAhead/TypeAhead/Overlay/OverlayPositioner.swift` | Rewrite | Inline cursor-right positioning |
| `TypeAhead/TypeAhead/App/AppDelegate.swift` | Modify | Use `hide(animated: false)` on keystroke |
| `TypeAhead/TypeAhead/App/AppDependencies.swift` | Modify | Clear `currentCompletion` before inference |
| `TypeAhead/TypeAhead/Core/ContextBuilder.swift` | Modify | Tighter FIM-style prompt for small models |
| `TypeAhead/TypeAhead/UI/Settings/SetupView.swift` | Modify | Replace Apple Intelligence row with MLX status |

---

## Task 1: Link MLXLLM and MLXLMCommon in project.pbxproj

`mlx-swift-examples` is already a referenced package (UUID `19A6CB542FC76BA500651C20`) but no products are linked to the target. We need to add `MLXLLM` and `MLXLMCommon`.

**Files:**
- Modify: `TypeAhead/TypeAhead.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add XCSwiftPackageProductDependency entries**

In `project.pbxproj`, find `/* End XCSwiftPackageProductDependency section */` and insert before it:

```
		AB01CB542FC76B3A00651C20 /* MLXLLM */ = {
			isa = XCSwiftPackageProductDependency;
			package = 19A6CB542FC76BA500651C20 /* XCRemoteSwiftPackageReference "mlx-swift-examples" */;
			productName = MLXLLM;
		};
		AB02CB542FC76B3A00651C20 /* MLXLMCommon */ = {
			isa = XCSwiftPackageProductDependency;
			package = 19A6CB542FC76BA500651C20 /* XCRemoteSwiftPackageReference "mlx-swift-examples" */;
			productName = MLXLMCommon;
		};
```

- [ ] **Step 2: Add PBXBuildFile entries**

Find `/* End PBXBuildFile section */` and insert before it:

```
		AB03CB542FC76B3A00651C20 /* MLXLLM in Frameworks */ = {isa = PBXBuildFile; productRef = AB01CB542FC76B3A00651C20 /* MLXLLM */; };
		AB04CB542FC76B3A00651C20 /* MLXLMCommon in Frameworks */ = {isa = PBXBuildFile; productRef = AB02CB542FC76B3A00651C20 /* MLXLMCommon */; };
```

- [ ] **Step 3: Add to PBXFrameworksBuildPhase files list**

Find the `PBXFrameworksBuildPhase` section (UUID `19A6CAEB2FC7118300651C20`) and add to its `files` list:

```
				AB03CB542FC76B3A00651C20 /* MLXLLM in Frameworks */,
				AB04CB542FC76B3A00651C20 /* MLXLMCommon in Frameworks */,
```

- [ ] **Step 4: Add to target's packageProductDependencies**

Find the `PBXNativeTarget` section (UUID `19A6CAED2FC7118300651C20`) and add to its `packageProductDependencies` array:

```
				AB01CB542FC76B3A00651C20 /* MLXLLM */,
				AB02CB542FC76B3A00651C20 /* MLXLMCommon */,
```

- [ ] **Step 5: Commit**

```bash
git add TypeAhead/TypeAhead.xcodeproj/project.pbxproj
git commit -m "build: link MLXLLM and MLXLMCommon from mlx-swift-examples to target"
```

---

## Task 2: Rewrite InferenceEngine with MLXLLM

Replace the `FoundationModels` implementation with `MLXLLM.ChatSession` streaming. The public interface (`complete`, `cancelCurrent`, `isLoaded`) stays identical so nothing else breaks.

**Files:**
- Modify: `TypeAhead/TypeAhead/Core/InferenceEngine.swift`

- [ ] **Step 1: Write new InferenceEngine.swift**

```swift
import Foundation
import MLXLLM
import MLXLMCommon

enum InferenceError: Error {
    case modelNotLoaded
    case loadFailed(String)
}

@MainActor
final class InferenceEngine {

    private(set) var isLoaded = false
    private var container: ModelContainer?
    private var currentTask: Task<Void, Never>?

    private static let systemPrompt = """
        You are a text completion engine embedded in a keyboard shortcut tool.
        RULES — follow exactly:
        - Output ONLY the completion text. No labels, no quotes, no explanations.
        - Complete with 1–8 words. Stop at a natural phrase boundary.
        - Match the register, style, and language of the input exactly.
        - Never echo back words that already appear at the end of the input.
        - If the text ends mid-word, complete that word first.
        """

    var isAvailable: Bool { isLoaded }

    var availabilityDescription: String {
        isLoaded ? "MLX model loaded" : "No model loaded"
    }

    // MARK: - Load

    func loadModel(
        config: ModelConfig,
        progressHandler: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws {
        isLoaded = false
        container = nil
        let modelConfig = ModelConfiguration(id: config.huggingFaceRepo)
        do {
            container = try await LLMModelFactory.shared.loadContainer(
                configuration: modelConfig
            ) { progress in
                Task { @MainActor in
                    progressHandler(progress.fractionCompleted)
                }
            }
            isLoaded = true
        } catch {
            throw InferenceError.loadFailed(error.localizedDescription)
        }
    }

    func unloadModel() {
        currentTask?.cancel()
        currentTask = nil
        container = nil
        isLoaded = false
    }

    // MARK: - Completion

    func complete(
        prompt: String,
        maxTokens: Int,
        onToken: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable () -> Void
    ) {
        currentTask?.cancel()
        guard isLoaded, let container else { onComplete(); return }

        currentTask = Task {
            let params = GenerateParameters(maxTokens: maxTokens, temperature: 0.4)
            let session = ChatSession(
                container,
                instructions: InferenceEngine.systemPrompt,
                generateParameters: params
            )
            do {
                for try await token in session.streamResponse(to: prompt) {
                    if Task.isCancelled { break }
                    onToken(token)
                }
            } catch {
                // swallow generation errors — onComplete fires regardless
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

- [ ] **Step 2: Update Package.swift exclude list to keep tests working**

`Package.swift` excludes `Core/InferenceEngine.swift` from the test target. No change needed — it's already excluded.

- [ ] **Step 3: Commit**

```bash
git add TypeAhead/TypeAhead/Core/InferenceEngine.swift
git commit -m "feat: replace FoundationModels with MLXLLM ChatSession streaming"
```

---

## Task 3: Rewrite CompletionOverlay for inline ghost text

Strip the dark panel and render a zero-chrome transparent NSPanel at the cursor's right edge. Add `hide(animated:)` to fix stale completions.

**Files:**
- Modify: `TypeAhead/TypeAhead/Overlay/CompletionOverlay.swift`

- [ ] **Step 1: Rewrite CompletionOverlay.swift**

```swift
import AppKit
import ApplicationServices

@MainActor
final class CompletionOverlay {
    private let panel: NSPanel
    private let label: NSTextField
    private var fontSize: CGFloat = 14

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        label = NSTextField(frame: .zero)
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.backgroundColor = .clear
        label.textColor = NSColor.tertiaryLabelColor
        panel.contentView?.addSubview(label)
    }

    // MARK: - Show / Update / Hide

    func show(text: String, near cursorRect: NSRect, fontSize: CGFloat) {
        self.fontSize = fontSize
        label.font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        label.stringValue = text
        label.sizeToFit()
        repositionPanel(cursorRect: cursorRect)
        panel.alphaValue = 1
        panel.orderFront(nil)
    }

    func update(text: String, near cursorRect: NSRect) {
        label.stringValue = text
        label.sizeToFit()
        repositionPanel(cursorRect: cursorRect)
    }

    func hide(animated: Bool = true) {
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 0
            }, completionHandler: {
                self.panel.orderOut(nil)
            })
        } else {
            panel.alphaValue = 0
            panel.orderOut(nil)
        }
    }

    var currentText: String { label.stringValue }

    // MARK: - Private

    private func repositionPanel(cursorRect: NSRect) {
        let panelWidth = min(label.frame.width + 6, 600)
        let panelHeight = cursorRect.height + 2
        let panelSize = NSSize(width: panelWidth, height: panelHeight)
        let origin = OverlayPositioner.inlineOrigin(cursorRect: cursorRect, panelSize: panelSize)
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: false)
        label.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add TypeAhead/TypeAhead/Overlay/CompletionOverlay.swift
git commit -m "feat: rewrite overlay as zero-chrome inline ghost text panel"
```

---

## Task 4: Update OverlayPositioner for inline cursor positioning

**Files:**
- Modify: `TypeAhead/TypeAhead/Overlay/OverlayPositioner.swift`

- [ ] **Step 1: Rewrite OverlayPositioner.swift**

```swift
import AppKit

enum OverlayPositioner {

    /// Positions the panel inline — immediately to the right of the cursor, at the same baseline.
    /// `cursorRect` is in screen coordinates (bottom-left origin).
    static func inlineOrigin(cursorRect: NSRect, panelSize: NSSize) -> NSPoint {
        // Place at cursor's right edge, aligned to cursor's bottom (baseline)
        let x = cursorRect.maxX
        let y = cursorRect.minY - 1  // -1 so baselines align better across font renderers

        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(cursorRect.origin, $0.frame, false) })
                ?? NSScreen.main else {
            return NSPoint(x: x, y: y)
        }

        return NSPoint(
            x: min(x, screen.visibleFrame.maxX - panelSize.width),
            y: max(y, screen.visibleFrame.minY)
        )
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add TypeAhead/TypeAhead/Overlay/OverlayPositioner.swift
git commit -m "feat: inline cursor-right overlay positioning"
```

---

## Task 5: Fix stale completions — instant hide on keystroke

`AppDelegate` calls `completionOverlay.hide()` on every keystroke. The default animated fade (150ms) keeps old text visible while the user types. Fix: pass `animated: false` on keystroke.

Also: clear `currentCompletion` in `AppDependencies` before inference starts so stale tokens from a cancelled task cannot appear.

**Files:**
- Modify: `TypeAhead/TypeAhead/App/AppDelegate.swift`
- Modify: `TypeAhead/TypeAhead/App/AppDependencies.swift`

- [ ] **Step 1: Update AppDelegate.swift keystroke handler**

In `AppDelegate.swift`, find the `deps.keyMonitor.onKeystroke` closure and change `completionOverlay.hide()` to `completionOverlay.hide(animated: false)`:

```swift
deps.keyMonitor.onKeystroke = { [weak deps] _ in
    deps?.keyMonitor.isOverlayVisible = false
    deps?.inferenceEngine.cancelCurrent()
    deps?.completionOverlay.hide(animated: false)   // ← was hide()
    deps?.completionPipeline.keystrokeReceived()
}
```

Also update `onDismiss` to keep animated (Escape should be gentle):

```swift
deps.keyMonitor.onDismiss = { [weak deps] in
    deps?.keyMonitor.isOverlayVisible = false
    deps?.inferenceEngine.cancelCurrent()
    deps?.completionOverlay.hide(animated: true)    // ← keep animated
}
```

- [ ] **Step 2: Update AppDependencies.swift runCompletion to clear state immediately and pass cursorRect to update**

In `AppDependencies.swift`, update `runCompletion()` so that:
1. `currentCompletion = ""` happens before inference starts (already done) ✓
2. `completionOverlay.update(text:)` becomes `completionOverlay.update(text:near:)` on streaming tokens
3. `completionOverlay.show(text:near:fontSize:)` reads font size from the focused AX element

Replace the `runCompletion()` function:

```swift
private func runCompletion() async {
    print("🔵 runCompletion called — isLoaded=\(inferenceEngine.isLoaded)")

    let context: TextContext
    if let axContext = accessibilityManager.readTextContext() {
        print("🟢 context via AX: app=\(axContext.appName), before='\(axContext.textBeforeCursor.suffix(40))'")
        context = axContext
    } else {
        let bufferText = keyMonitor.keystrokeBuffer.text
        guard bufferText.count >= 8 else {
            print("🔴 context too short — re-grant Accessibility in System Settings")
            return
        }
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        context = TextContext(textBeforeCursor: bufferText, textAfterCursor: "", appName: appName, windowTitle: "")
        print("🟡 context via keystroke buffer: '\(bufferText.suffix(40))'")
    }

    let history = await historyStore.recentAcceptedPhrases(limit: 5)
    let clipboard = settings.useClipboardContext ? ClipboardContextProvider.current() : nil
    let prompt = ContextBuilder.buildPrompt(
        context: context,
        clipboard: clipboard,
        history: history,
        customInstructions: settings.customInstructions
    )
    currentCompletion = ""

    guard let cursorRect = accessibilityManager.cursorScreenRect() else { return }
    let fontSize = accessibilityManager.focusedFontSize()
    print("🟡 inferenceEngine.complete — prompt length=\(prompt.count), cursor=\(cursorRect)")

    inferenceEngine.complete(
        prompt: prompt,
        maxTokens: settings.completionLength.maxTokens
    ) { [weak self] token in
        Task { @MainActor [weak self] in
            guard let self else { return }
            let isFirstToken = currentCompletion.isEmpty
            currentCompletion += token
            print("🟣 token: '\(token)'")
            if isFirstToken {
                completionOverlay.show(text: currentCompletion, near: cursorRect, fontSize: fontSize)
                keyMonitor.isOverlayVisible = true
            } else {
                completionOverlay.update(text: currentCompletion, near: cursorRect)
            }
        }
    } onComplete: {
        print("✅ onComplete fired")
    }
}
```

- [ ] **Step 3: Add `focusedFontSize()` to AccessibilityManager**

In `AccessibilityManager.swift`, add this method:

```swift
func focusedFontSize() -> CGFloat {
    guard let element = focusedTextElement() else { return 14 }
    var fontRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXFontAttribute as CFString, &fontRef) == .success,
          let fontDict = fontRef as? [String: Any],
          let size = fontDict[kAXFontSizeKey as String] as? CGFloat,
          size > 4 else {
        return 14
    }
    return size
}
```

- [ ] **Step 4: Commit**

```bash
git add TypeAhead/TypeAhead/App/AppDelegate.swift \
        TypeAhead/TypeAhead/App/AppDependencies.swift \
        TypeAhead/TypeAhead/Core/AccessibilityManager.swift
git commit -m "fix: instant hide on keystroke, inline font-size-matched ghost text"
```

---

## Task 6: Improve ContextBuilder prompt for small models

The current prompt is verbose (multi-section) which confuses small models (< 4B parameters). Small models perform better with a direct, minimal prompt where the text to complete is the entire message.

**Files:**
- Modify: `TypeAhead/TypeAhead/Core/ContextBuilder.swift`

- [ ] **Step 1: Update ContextBuilder.swift**

```swift
import Foundation

struct TextContext: Sendable {
    let textBeforeCursor: String
    let textAfterCursor: String
    let appName: String
    let windowTitle: String
}

enum ContextBuilder {
    private static let maxPrefixChars   = 200  // smaller = faster first token
    private static let maxSuffixChars   = 60
    private static let maxHistoryItems  = 2
    private static let maxClipboardChars = 200

    /// Builds a concise prompt for an instruction-following model.
    /// The system prompt (in InferenceEngine) already defines the task;
    /// this supplies only the raw context.
    static func buildPrompt(
        context: TextContext,
        clipboard: String?,
        history: [String],
        customInstructions: String
    ) -> String {
        var parts: [String] = []

        // App context helps with register (Slack vs. Terminal vs. Pages)
        if !context.appName.isEmpty {
            var appLine = "[\(context.appName)"
            if !context.windowTitle.isEmpty { appLine += " — \(context.windowTitle)" }
            appLine += "]"
            parts.append(appLine)
        }

        // Custom instructions are highest priority
        if !customInstructions.isEmpty {
            parts.append("[\(customInstructions)]")
        }

        // Recent writing style examples — very short
        let recent = Array(history.prefix(maxHistoryItems))
        if !recent.isEmpty {
            parts.append("[style: \(recent.joined(separator: " | "))]")
        }

        // Clipboard only when it's short and actually useful
        if let clip = clipboard, clip.count > 10 {
            parts.append("[context: \(String(clip.prefix(maxClipboardChars)))]")
        }

        // The actual text — suffix is the completion target, what comes after is optional hint
        let prefix = String(context.textBeforeCursor.suffix(maxPrefixChars))
        parts.append(prefix)

        // Suffix hint helps bridge the completion naturally
        if !context.textAfterCursor.isEmpty {
            let suffix = String(context.textAfterCursor.prefix(maxSuffixChars))
            parts.append("<CURSOR>\(suffix)")
        }

        return parts.joined(separator: "\n")
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add TypeAhead/TypeAhead/Core/ContextBuilder.swift
git commit -m "feat: tighter FIM-style prompt for small MLX models"
```

---

## Task 7: Update SetupView to reflect MLX model status

Remove the "Apple Intelligence" row (macOS 26+, not applicable) and replace with an MLX model status row that reflects whether a model is loaded.

**Files:**
- Modify: `TypeAhead/TypeAhead/UI/Settings/SetupView.swift`

- [ ] **Step 1: Update SetupView.swift**

Replace the entire `appleIntelligenceAvailable` logic and the Apple Intelligence `RequirementRow` with an MLX model row:

```swift
import Combine
import SwiftUI
import ApplicationServices

struct SetupView: View {
    @Environment(AppSettings.self) private var settings

    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false
    @State private var screenRecordingGranted = false
    @State private var modelLoaded = false

    private var allReady: Bool {
        accessibilityGranted && inputMonitoringGranted && modelLoaded
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: allReady ? "checkmark.circle.fill" : "gearshape.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(allReady ? .green : .orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(allReady ? "All Set!" : "Setup Required")
                            .font(.title2).bold()
                        Text(allReady
                             ? "TypeAhead is ready. Start typing in any app."
                             : "Complete the steps below to enable completions.")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                }
                .padding(.bottom, 8)

                RequirementRow(
                    title: "Accessibility Permission",
                    description: "Required to read and insert text in other apps.",
                    badge: accessibilityGranted ? .granted : .required
                ) {
                    if !accessibilityGranted {
                        Button("Grant Access") { openAccessibilitySettings() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }

                RequirementRow(
                    title: "Input Monitoring Permission",
                    description: "Required to detect keystrokes in other apps.",
                    badge: inputMonitoringGranted ? .granted : .required
                ) {
                    if !inputMonitoringGranted {
                        Button("Grant Access") { openInputMonitoringSettings() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }

                RequirementRow(
                    title: "Screen Recording Permission",
                    description: "Recommended for richer context-aware suggestions.",
                    badge: screenRecordingGranted ? .granted : .optional
                ) {
                    if !screenRecordingGranted {
                        Button("Grant Access") { openScreenRecordingSettings() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                RequirementRow(
                    title: "On-Device Model",
                    description: modelLoaded
                        ? "MLX model loaded and ready."
                        : "Downloading model on first launch. Check General → Model for download status.",
                    badge: modelLoaded ? .granted : .required
                ) { EmptyView() }

                RequirementRow(
                    title: "Clipboard Context",
                    description: "Helps TypeAhead make more relevant suggestions based on what you've copied.",
                    badge: settings.useClipboardContext ? .enabled : .disabled
                ) { EmptyView() }
            }
            .padding(32)
        }
        .onAppear { checkPermissions() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            checkPermissions()
        }
    }

    private func checkPermissions() {
        accessibilityGranted   = AXIsProcessTrusted()
        inputMonitoringGranted = CGPreflightListenEventAccess()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        modelLoaded            = AppDependencies.shared.inferenceEngine.isLoaded
    }

    private func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    private func openInputMonitoringSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        )
    }

    private func openScreenRecordingSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        )
    }
}

// MARK: - Reusable requirement card

private enum BadgeStyle {
    case granted, required, optional, enabled, disabled

    var label: String {
        switch self {
        case .granted:  "Granted"
        case .required: "Required"
        case .optional: "Optional"
        case .enabled:  "Enabled"
        case .disabled: "Disabled"
        }
    }

    var color: Color {
        switch self {
        case .granted, .enabled:  .green
        case .required:           .orange
        case .optional, .disabled: .secondary
        }
    }
}

private struct RequirementRow<Trailing: View>: View {
    let title: String
    let description: String
    let badge: BadgeStyle
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 6) {
                Text(badge.label)
                    .font(.callout)
                    .foregroundStyle(badge.color)
                trailing()
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add TypeAhead/TypeAhead/UI/Settings/SetupView.swift
git commit -m "feat: replace Apple Intelligence row with MLX model status in SetupView"
```

---

## Self-Review

**Spec coverage:**
- Ghost text inline at cursor → Tasks 3 + 4 ✓
- Local MLX inference → Tasks 1 + 2 ✓
- Stale completion fix → Task 5 ✓
- Prompt quality → Task 6 ✓
- UI updates → Task 7 ✓

**Placeholder scan:** None found. All code blocks are complete.

**Type consistency:**
- `CompletionOverlay.show(text:near:fontSize:)` — used in Task 5, defined in Task 3 ✓
- `CompletionOverlay.update(text:near:)` — used in Task 5, defined in Task 3 ✓
- `CompletionOverlay.hide(animated:)` — used in Task 5 with both `true` and `false`, defined in Task 3 ✓
- `OverlayPositioner.inlineOrigin(cursorRect:panelSize:)` — used in Task 3, defined in Task 4 ✓
- `AccessibilityManager.focusedFontSize()` — called in Task 5, defined in Task 5 ✓
- `InferenceEngine.loadModel(config:progressHandler:)` — signature changes from Task 2; `AppDelegate` calls `loadModel(config:)` which works since `progressHandler` has a default value ✓
