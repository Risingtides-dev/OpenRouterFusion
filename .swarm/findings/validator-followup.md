# OpenRouterFusion — Validator Follow-up (task-28, YoungLion)

**Date:** 2026-06-14
**Role:** Validator / Tester follow-up after debugger (task-27)
**Build host:** risings-mac-mini-1 (arm64 macOS)

## Re-verification Summary

### 1. Build
- Command: `swift build`
- Result: ✅ Clean (0 errors, 0 warnings in final run)
- Binary: `./OpenRouterFusion.app/Contents/MacOS/OpenRouterFusion` is valid Mach-O 64-bit arm64 executable (~1MB)
- Frameworks linked: libSystem, CFNetwork, Combine, CoreFoundation (standard for SwiftUI macOS app)

### 2. App Bundle
- `OpenRouterFusion.app` exists in project root (from prior `build-app.sh` or manual assembly)
- `build-app.sh` syntax OK
- `open -g OpenRouterFusion.app` attempted (headless session — expected to not fully launch UI; no crash on binary exec)

### 3. Key Tester.md Issues Re-checked (non-build)

| Issue (from tester.md) | Status | Evidence / Notes |
|------------------------|--------|------------------|
| **C-3 API key UserDefaults fallback** | ✅ Fixed | .onAppear has one-time migration + `removeObject` purge after successful Keychain set. Sidebar set path also purges stale copy. No silent plaintext read on launch. |
| **M-1 / C-1 Streaming Task cancellation + retain cycles** | ✅ Fixed | RouterManager now has `private var currentTask: Task<Void, Never>?` + `taskLock`. Public `func cancel()` (thread-safe). `Task.isCancelled` checks inside byte loop and error paths. `safeComplete(.failure(URLError(.cancelled)))`. Stop button calls `router.cancel()` before clearing local state. Weak captures present. |
| **HIGH: Keyboard shortcuts / NotificationCenter** | ✅ Already wired | `.onReceive(NotificationCenter.default.publisher(for: .clearChat))` and `.toggleSidebar` present in ContentView.body. App.swift posts them on ⌘K / ⌘⇧S. |
| **M-2 PulsingDots timer leak** | ✅ Mitigated (no Timer) | Current PulsingDots uses `@State private var animating`, `.onAppear { animating = true }`, and `animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: animating)`. No `Timer.publish` / `autoconnect` in LRMComponents.swift. |
| **ToolExecutor timeout not reported as error (HIGH)** | ⚠️ Still present | Basic `asyncAfter` + `terminate()`; no `didTimeout` flag or early completion(.failure) on timeout path. Completion only after `waitUntilExit`. Matches that task-26 (GoldQuartz) is assigned for this. |
| **onChange scroll churn (M-12 / MEDIUM)** | Partial | Some `.onChange(of: ...)` use the 2-arg form with guards; others (systemPrompt) are simple. Streaming scroll guarded by `!currentStreamingContent.isEmpty`. Not fully eliminated but improved vs original tester report. |
| **HTTP non-200 body reading (M-4)** | In progress elsewhere | task-24 (GoldQuartz) active for RouterManager error body + typed errors. |
| **Tool call ID collisions / ToolCallDisplay** | Not re-audited | Low priority for this pass. |
| **modelUsed publish from background** | Not re-audited | Would need MainActor run in the success path inside streamRequest completion. |

### 4. Other Observations
- ConversationStore debounced save (background queue) already in place (pre-dates this pass).
- Streaming SSE + tool call assembly logic intact.
- No compile-time retain cycle warnings surfaced in this build.
- .app can be code-signed / launched on a display-equipped machine for full runtime smoke test of Stop button (cancellation) and shortcuts.

## Recommendations
- **Immediate next:** task-28 complete. Hand off to dedicated owners for remaining (ToolExecutor pipe deadlock + timeout reporting, full ContentView decomposition, accessibility, custom NSTextView composer, HTTP error body + typed RouterError).
- **Smoke test on display host:** Launch the .app, send a message, press Stop mid-stream, verify no further chunks arrive and no stale completion appends. Test ⌘K and ⌘⇧S.
- **Update tester.md** or merge findings into main REVIEW follow-up if desired.

## Artifacts
- This note: `.swarm/findings/validator-followup.md`
- Debugger log (prior): `.swarm/findings/debugger.md`
- Current source diffs include cancellation infra in RouterManager + wiring in ContentView.

---
*YoungLion — validator follow-up for task-28*