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

- [x] **A1 Land PR #22 on `main`.** WP-7/WP-8 (7 files) only reached the stale
      `feature/mirror-ghost-aggressive-suggestions` branch. This branch contains them; its PR
      to `main` lands them.
- [x] **A2 "Collect inputs for personalization" must stop collection.** `AppDelegate`'s Tab
      handler calls `historyStore.record` unconditionally; the toggle only stopped history
      being *used*. Gate the write on `ResolvedPolicy.recordHistory` (resolver-tested).
- [x] **A3 Global "Enable Completions" is a master switch.** `AppPolicyResolver` lets a
      per-app "On" override beat the global toggle, so turning TypeAhead off in Settings still
      leaves completions running in those apps. Global off wins; the override still beats the
      exclusion list (the CLAUDE.md rule).
- [x] **A4 "Launch at Login" actually registers a login item** (`SMAppService.mainApp`).
- [x] **A5 Remove the dead "Show in All Apps" toggle** (nothing reads it; per-app control
      lives in the Apps pane).
- [x] **A6 Trigger Delay slider applies immediately.** `CompletionPipeline.debounceInterval`
      is a `let` captured once at launch; make it live.
- [x] **A7 Shift+Tab accepts the whole suggestion** (it was swallowed with no handler).
- [x] **A8 Hide the permanently disabled "Check for Updates…" item** until Sparkle is linked.
- [x] **A9 The status menu's "Disable in ⟨App⟩" uses the per-app override,** the same state
      the Apps pane shows, instead of the legacy exclusion list it can be out of sync with.
- [x] **A10 Honor "Enable Emoji Suggestions".** Found during the work: nothing read it.
- [x] **A11 Tab works in TypeAhead's own Settings window.** Found during the work: the local
      key monitor swallowed every Tab, so Tab couldn't move between Settings fields.

## Track B — Cotypist parity (P1)

- [x] **B1 ⌥Tab sends a normal Tab.** Dismisses the ghost and lets the Tab through (indent,
      field navigation) without accepting.
- [x] **B2 Esc pauses briefly.** After Esc dismisses a ghost, no new suggestion for a short
      cooldown or until the next word boundary (pure `DismissCooldown`, tested).
- [x] **B3 ⌃⌥⌘\` toggles completions for the current app** (flips its per-app override).
- [x] **B4 Snooze choices:** 15 minutes / 1 hour / until tomorrow (pure deadline math, tested).
- [x] **B5 Per-app "Record typing history"** (`AppOverride.recordHistory`), resolved by
      `AppPolicyResolver`, honored by A2's policy, shown in the Apps pane.
- [x] **B6 "Add a space after accepted words" setting** (default on). When off, the final
      accepted word gets no trailing space; mid-suggestion spacing is unchanged.
- [x] **B7 Mid-line completions toggle** (default on). When off, no suggestion while there
      is text after the cursor on the same line (pure check, tested).
- [x] **B8 Content-based secure-field detection.** Also skip fields whose subrole is
      `AXSecureTextField`, whose title/placeholder/description says password/passcode/PIN/
      OTP/one-time code, or whose value is all mask characters (pure `SecureFieldClassifier`,
      tested). Strengthens the "never read password fields" rule.
- [x] **B9 Per-app "Improve compatibility"** (`AppOverride.compatibilityMode`): forces
      keystroke (CGEvent) insertion and the Vision/mirror caret path for that app, the
      user-editable counterpart to the built-in `AppInsertionPolicy` list.

## Track C — Docs (P2)

- [x] **C1** Update CLAUDE.md (test count, precedence rules, shortcuts), `docs/next-features.md`
      (pointer to this backlog), and project memory.

## Result

All items above are implemented on `feature/cotypist-parity`: 491 SPM tests (was 444), headless
compile-check clean. Runtime behavior still needs the owner's dogfood pass (see the PR checklist):
the new keys (⇧Tab, ⌥Tab, Esc pause, ⌃⌥⌘`), Launch at Login approval, and the secret-field
classifier on real password/OTP boxes.

## Definition of done (every item)

- Pure logic has SPM tests (`swift test` green).
- Headless compile-check succeeds (`-derivedDataPath /tmp/typeahead-compile-check`).
- One commit per item or tight group, then one PR to `main`.
- Runtime behavior the owner should confirm is listed in the PR's "Owner dogfood checklist".

## Round 2 — the previously deferred items

Branch `feature/deferred-backlog` → PR into `dev`.

- [x] **D1 Keep the KV cache across a Tab-accept.** Accepted text extends the prompt like
      typing; the WP-5 trim + strict-prefix check already reuse or rebuild correctly, so the
      invalidate-on-accept is gone (tests document both outcomes).
- [x] **D2 Secure Input notice.** The status menu says when macOS Secure Input is hiding
      keystrokes, instead of TypeAhead just going quiet.
- [x] **D3 British English.** Settings → General → English Spelling: Automatic (follow macOS) /
      American / British. Drives the spell-checker dictionary (typo fixes, instant word
      completion) and one static sentence of the model instruction.
- [x] **D4 Per-website rules in browsers.** Settings → Apps → Websites, and a "Turn Off
      Suggestions on ⟨site⟩" menu item when a browser is in front. Subdomains included; only
      sites you add are stored.
- [x] **D5 Word alternatives.** ⌥↓ on a suggestion lists up to 3 alternatives for its first word;
      1–3 inserts one. Also: identical prompts now replay the cache (`.replayLast`) instead of a
      full re-prefill.
- [x] **D6 Right-to-left scripts — closed, won't do.** Suggestions are English-only by the owner's
      request (WP-1: instruction + `GhostText.isLikelyEnglish` output gate), so Arabic/Hebrew
      layout has nothing to show. Revisit only if multilingual suggestions are wanted.
- [ ] **D7 Sparkle auto-update + notarized DMG — needs the owner.** Requires a paid Apple
      Developer ID certificate, notarization credentials, and a place to host the app and its
      update feed. Step-by-step guide: [`release.md`](release.md).

## Still open

Only D7 (owner action). Everything else in this backlog is implemented; runtime checks are in
the PR dogfood checklists.
