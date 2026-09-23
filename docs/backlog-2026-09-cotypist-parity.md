# TypeAhead — Backlog: integrity fixes + Cotypist parity (2026-09-23)

Branch: `feature/cotypist-parity` (cut from `feature/instant-word-completion-latency`, so it
also carries the stranded PR #22 work — see A1).

## How this backlog was built

1. **Docs vs. code review.** Read `docs/next-features.md` (#1–#13), the product-overhaul spec
   (WS1–WS6), the KV-cache findings, the AutoComp research, run log and memory, then checked
   each claim against the current source.
2. **Cotypist comparison.** Cotypist (cotypist.app) is the closest commercial reference:
   on-device, Apple Silicon, inline ghost text, Tab = next word. Its documented surface
   (Knowledge Base: tips, personalization, troubleshooting) was listed and compared
   feature-by-feature with TypeAhead.

### Status of the existing roadmap

| Item | Status |
|------|--------|
| next-features #1–#13 | All shipped or absorbed (PRs #2–#22). |
| Overhaul WS1–WS6 | Shipped in PR #20. Two WS1 goals regressed (see A2, A3, A4, A5). |
| PR #22 (WP-7 instant dictionary, WP-8 latency) | **Not on `main`.** Merged into its stacked base *after* that base was squash-merged, so the work is stranded (see A1). |

### Cotypist vs. TypeAhead

| Cotypist feature | TypeAhead before this backlog |
|---|---|
| Tab accepts next word | ✅ |
| Accept the **whole** suggestion (key above Tab) | ❌ Shift+Tab is swallowed and does nothing |
| ⌥Tab sends a normal Tab | ❌ (⌥Tab accepts) |
| Esc dismisses **and briefly pauses** | ⚠️ dismisses only; next key re-triggers |
| ⌃⌥⌘\` toggles completions for the current app | ❌ |
| Global pause / snooze | ⚠️ 1 hour only |
| Setting: trailing space after an accepted word | ❌ always adds a space |
| Mid-line completions as a choice | ❌ always on |
| Inline typo fix, emoji after `:` | ✅ |
| Typing history on/off, word-choice slider, custom instructions | ⚠️ the on/off toggle doesn't stop recording (A2) |
| Per-app: on/off, Tab disable, instructions | ✅ |
| Per-app: turn off history recording | ❌ |
| Per-app: "Improve compatibility" | ❌ (built-in list only) |
| Password fields ignored | ⚠️ only `AXPasswordField` role; custom password widgets aren't caught |
| Statistics | ✅ |
| Launch at login | ❌ the toggle does nothing (A4) |
| Per-domain rules in browsers, word alternatives, RTL | ❌ deferred (see bottom) |

---

## Track A — Integrity & honesty (P0)

- [ ] **A1 Land PR #22 on `main`.** WP-7/WP-8 (7 files) only reached the stale
      `feature/mirror-ghost-aggressive-suggestions` branch. This branch contains them; its PR
      to `main` lands them.
- [ ] **A2 "Collect inputs for personalization" must stop collection.** `AppDelegate`'s Tab
      handler calls `historyStore.record` unconditionally; the toggle only stopped history
      being *used*. Gate the write (pure `HistoryRecordingPolicy`, tested).
- [ ] **A3 Global "Enable Completions" is a master switch.** `AppPolicyResolver` lets a
      per-app "On" override beat the global toggle, so turning TypeAhead off in Settings still
      leaves completions running in those apps. Global off wins; the override still beats the
      exclusion list (the CLAUDE.md rule).
- [ ] **A4 "Launch at Login" actually registers a login item** (`SMAppService.mainApp`).
- [ ] **A5 Remove the dead "Show in All Apps" toggle** (nothing reads it; per-app control
      lives in the Apps pane).
- [ ] **A6 Trigger Delay slider applies immediately.** `CompletionPipeline.debounceInterval`
      is a `let` captured once at launch; make it live.
- [ ] **A7 Shift+Tab accepts the whole suggestion** (it was swallowed with no handler).
- [ ] **A8 Hide the permanently disabled "Check for Updates…" item** until Sparkle is linked.
- [ ] **A9 The status menu's "Disable in ⟨App⟩" uses the per-app override,** the same state
      the Apps pane shows, instead of the legacy exclusion list it can be out of sync with.

## Track B — Cotypist parity (P1)

- [ ] **B1 ⌥Tab sends a normal Tab.** Dismisses the ghost and lets the Tab through (indent,
      field navigation) without accepting.
- [ ] **B2 Esc pauses briefly.** After Esc dismisses a ghost, no new suggestion for a short
      cooldown or until the next word boundary (pure `DismissCooldown`, tested).
- [ ] **B3 ⌃⌥⌘\` toggles completions for the current app** (flips its per-app override).
- [ ] **B4 Snooze choices:** 15 minutes / 1 hour / until tomorrow (pure deadline math, tested).
- [ ] **B5 Per-app "Record typing history"** (`AppOverride.recordHistory`), resolved by
      `AppPolicyResolver`, honored by A2's policy, shown in the Apps pane.
- [ ] **B6 "Add a space after accepted words" setting** (default on). When off, the final
      accepted word gets no trailing space; mid-suggestion spacing is unchanged.
- [ ] **B7 Mid-line completions toggle** (default on). When off, no suggestion while there
      is text after the cursor on the same line (pure check, tested).
- [ ] **B8 Content-based secure-field detection.** Also skip fields whose subrole is
      `AXSecureTextField`, whose title/placeholder/description says password/passcode/PIN/
      OTP/one-time code, or whose value is all mask characters (pure `SecureFieldClassifier`,
      tested). Strengthens the "never read password fields" rule.
- [ ] **B9 Per-app "Improve compatibility"** (`AppOverride.compatibilityMode`): forces
      keystroke (CGEvent) insertion and the Vision/mirror caret path for that app, the
      user-editable counterpart to the built-in `AppInsertionPolicy` list.

## Track C — Docs (P2)

- [ ] **C1** Update CLAUDE.md (test count, precedence rules, shortcuts), `docs/next-features.md`
      (pointer to this backlog), and project memory.

## Definition of done (every item)

- Pure logic has SPM tests (`swift test` green).
- Headless compile-check succeeds (`-derivedDataPath /tmp/typeahead-compile-check`).
- One commit per item or tight group, then one PR to `main`.
- Runtime behavior the owner should confirm is listed in the PR's "Owner dogfood checklist".

## Deferred (documented, not in scope for this backlog)

- **Per-domain rules in browsers** (needs AXURL reads per browser; runtime-validation heavy).
- **Word alternatives** (Cotypist Labs: numbered alternatives list; needs n-best generation + new overlay mode).
- **Secure Input notification** (when another app holds Secure Event Input, the tap sees nothing).
- **Sparkle auto-update + notarized DMG** (needs the owner's Developer ID + hosting).
- **Keep the KV cache across a Tab-accept** (accepted text = generated tokens; needs model-runtime validation).
- **British English / RTL scripts.**
