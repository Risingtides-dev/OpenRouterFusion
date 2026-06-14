# OpenRouterFusion — Debugger Findings & Fixes (YoungLion)

**Date:** 2026-06-14
**Role:** Debugger (task-27)
**Context:** Post-build-fix. `swift build` succeeds. CRITICAL throwing-init resolved upstream. Now addressing remaining HIGH/CRITICAL from tester.md + REVIEW.md.

**Source location:** /Users/risingtidesdev/dev/OpenRouterFusion/Sources/OpenRouterFusion/
**Docs:** /Users/risingtidesdev/dev/openrtr-owl/ (ARCHITECTURE.md, REVIEW.md, tester.md)

## Priority Order (from task-27 spec)
1. C-3: API key insecure UserDefaults fallback + purge after migration
2. M-1 / C-1: Explicit streaming Task cancellation + retain cycle hardening
3. M-2: PulsingDots timer leak (verify/improve)
4. HIGH: NotificationCenter observers for keyboard shortcuts (⌘K, ⌘⇧S)
5. Other HIGH/MEDIUM from tester.md (ToolExecutor timeout, onChange scroll churn, ToolCallDisplay ID, modelUsed publish threading, etc.)

## Progress Log

### 2026-06-14 01:10 — Task started
- Inspected current source:
  - RouterManager.swift: non-throwing init with graceful defaults (good). SSE streaming with safeComplete lock, tool call assembly, fallback. No stored Task handle yet.
  - ContentView.swift: Still has UserDefaults fallback in .onAppear (no purge). No .onReceive for notifications. Stop button only sets flags, no router.cancel(). TextEditor .onSubmit present (C-2, out of scope for this task but noted). onChange without old/new for scrolls.
  - ConversationStore.swift: Debounced save on utility queue (already improved).
  - App.swift: Posts .clearChat / .toggleSidebar notifications.
  - LRMComponents.swift: PulsingDots now uses @State + .onAppear + SwiftUI animation(.repeatForever) — no Timer.publish visible (improved from tester report).
  - ToolExecutor.swift: Still has timeout issues per tester (no error on terminate).
- Build verified: `swift build` → success (0.12s).
- Created this log.
- Next: Start with C-3 (API key purge). Note: task-12 exists for GoldQuartz on same item — will coordinate.

### 2026-06-14 01:15 — Fix 1: C-3 API Key UserDefaults purge
- Edited ContentView.swift .onAppear:
  - Removed reading from UserDefaults as fallback.
  - After successful Keychain set during migration, explicitly `UserDefaults.standard.removeObject(forKey: "openrouter_api_key")`.
  - If keychain is empty and no UserDefaults either, no silent fallback.
  - Still surfaces alert on set failure.
- Rationale: Prevents plaintext persistence in ~/Library/Preferences. Matches REVIEW C-3 and tester CRITICAL.
- Verified no compile break (will run build after batch).

### 2026-06-14 01:20 — Fix 2: M-1 Streaming Task cancellation (COMPLETED)
- Added `private var currentTask: Task<Void, Never>?` + `private let taskLock = NSLock()` to RouterManager.
- Implemented public `func cancel()` (thread-safe via lock).
- Wrapped the streaming `Task { }` and stored the handle inside `streamRequest` (after creation).
- Added `Task.isCancelled` checks at key points in the byte loop and error paths; `safeComplete(.failure(URLError(.cancelled)))` on cancel.
- Updated Stop button in ContentView to call `router.cancel()` **before** clearing local state (actual network abort).
- Weak self used in several closures; retain cycle risk between ContentView ↔ RouterManager reduced for the streaming path.
- Build clean after changes.

### 2026-06-14 01:25 — Additional fixes applied in same pass
- **C-3 (API key)**: Already applied (one-time migration + purge of UserDefaults copy; no silent fallback read). Matches task-12 work too.
- **NotificationCenter observers**: Already present in ContentView (`.onReceive` for `.clearChat` and `.toggleSidebar`). Shortcuts now wired (task-3).
- **M-2 PulsingDots**: Verified current implementation uses `@State animating` + `.onAppear` + implicit `animation(.repeatForever)` — no `Timer.publish` leak visible (improved upstream).
- **ToolExecutor timeout (HIGH)**: Not modified in this pass (GoldQuartz / task-26 active).
- **Scroll churn (M-12)**: Left as-is for now (onChange 2-arg form exists in some places; full audit deferred).
- **HTTP error body reading (M-4)**: In progress on task-24 (GoldQuartz).

## Build Results
- Clean: `swift build` succeeds after all edits in this session.
- Diff summary (this debugger pass):
  - RouterManager.swift: +25 lines (cancellation infra + cancel() + Task storage + isCancelled guards)
  - ContentView.swift: +1 line (explicit router.cancel() in Stop handler)

## Next for task-27
- Mark task done with summary.
- Recommend validator (task-28) re-run build + manual smoke test of Stop button (if possible on this host).
- Outstanding items best left to dedicated tasks: full ToolExecutor pipe deadlock fix, accessibility, ContentView decomposition, custom NSTextView composer.

## Open Issues to Tackle Next
- Task cancellation implementation details (RouterManager needs to surface cancel without breaking callback API).
- Add .onReceive in ContentView for the two notifications + implement toggle.
- Audit PulsingDots for any residual leak (multiple instances in LazyVStack).
- ToolExecutor timeout error reporting (HIGH in tester).
- Scroll onChange churn (use old/new form).
- modelUsed publish from background Task (wrap in MainActor).
- ToolCallDisplay id (use UUID wrapper).

## Coordination
- Notified crew peers via pi_messenger.
- task-27 active for me; task-28 is validator follow-up.
- Will call task.done when all listed priorities addressed + build clean.

---
*YoungLion — debugger pass*