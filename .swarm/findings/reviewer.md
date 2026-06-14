# Code Review Report — OpenRouterFusion

**Reviewer:** Knox (Code Quality)  
**Date:** 2026-06-14  
**Scope:** All 10 Swift files in `Sources/OpenRouterFusion/`

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 2 |
| MAJOR | 8 |
| MINOR | 10 |

---

## Findings

### CRITICAL

### [CRITICAL] Missing `[weak self]` in closure → retain cycle | ToolExecutor.swift:30 | `DispatchQueue.global().asyncAfter` captures `proc` strongly; the closure also implicitly captures `completion`. If the caller stores a completion handler that captures `self`, the object is never freed. More importantly, `proc` is not terminated on cancel and there is no way to cancel the work.

**Impact:** If the caller dismisses the tool modal while a command is running, the `Process` keeps executing in the background. `proc.terminate()` fires after timeout but cannot be cancelled on demand. The `completion` closure is never called on cancel, which can leave the UI in a stale state.

**Suggested Fix:**
```swift
// Make run() return a cancellable handle
final class ToolExecutor {
    static func run(..., completion: @escaping (Result<String, Error>) -> Void) -> Cancellable {
        let proc = Process()
        ...
        let workItem = DispatchWorkItem {
            if proc.isRunning { proc.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: workItem)
        ...
        return Cancellable { workItem.cancel(); proc.terminate() }
    }
}
```

---

### [CRITICAL] ToolExecutor never called on Main Thread, but UI code assumes it | ContentView.swift:250 | `executeTool` uses `ToolExecutor.run` with a `@escaping` completion closure. Although `completion` dispatches to `DispatchQueue.main.async`, the `ToolExecutor.run` call itself can be (and is) invoked from a **background** route — but the completion closure uses `DispatchQueue.main.async` correctly. However, `ToolExecutor.run` **never dispatches to** main. The `DispatchQueue.global().asyncAfter` at ToolExecutor.swift:29 means the timeout timer fires on a global queue; `proc.waitUntilExit()` blocks that background thread.

**Impact:** If the `ToolExecutor.run` completion closure captures UI state directly (which it does via `store` and the `DispatchQueue.main.async` wrapper), the pattern is *currently safe* because of the `DispatchQueue.main.async` hop. However, the intermediate parsing of `proc.terminationStatus` happens on a global queue, and `proc.waitUntilExit()` blocks a thread from the cooperative pool. Under load this can exhaust the thread pool.

**Suggested Fix:** Replace `waitUntilExit()` with an `async`-based await. Use `Process` terminationHandler or wrap in an actor.

---

### MAJOR

### [MAJOR] `AttributedString` markdown parsing in `body {}` — runs on every re-render | ChatMessageView.swift:118-131 | `markdownContent` is a `@ViewBuilder` computed property whose body executes `try AttributedString(markdown: ...)` on every view re-evaluation. AttributedString parsing is expensive (Markdown → AST → AttributedString) and is called every time SwiftUI re-evaluates the body.

**Impact:** Chatting with long messages causes noticeable CPU spikes and frame drops. Each keystroke during streaming triggers a full re-render of all `ChatMessageView`s in the `LazyVStack`, each one re-parsing markdown.

**Suggested Fix:**
```swift
// Pre-compute in the model or a view model
private var attributedContent: AttributedString {
    // cache this — compute once when content changes
}
```
Or move parsing into `ChatMessage` as a lazy var, or use `.task(id:)` to parse off the main thread:

```swift
.task(id: message.content) {
    attributedContent = parseMarkdown(message.content)
}
```

---

### [MAJOR] `router.send()` completion called from background, but `[weak self]` can cause `modelUsed` to never be set | RouterManager.swift:111-112 | In `send(onChunk:onToolCall:completion:)`, `tryNext()` calls `streamRequest(completion:)` which dispatches `completion` on `MainActor` via `safeComplete`. But in `tryNext()`, the `[weak self]` capture in `streamRequest`'s completion closure means `self?.modelUsed = model` is skipped if `self` has been deallocated.

**Impact:** If the user closes the window while streaming, `modelUsed` is silently not updated. This is *correct* behavior for a deallocated UI, but the real issue is the `[weak self]` in `fireToolCalls()` at RouterManager.swift:103 — if `self` is nil, tool calls silently vanish.

**Suggested Fix:** This is acceptable for now, but add a `didSet` on `modelUsed` or ensure `fireToolCalls()` doesn't require `self`. The `@MainActor` isolation should be applied to the entire `RouterManager`.

---

### [MAJOR] RouterManager not `@MainActor`-isolated; `@Published` updates from background | RouterManager.swift:14 @Published var modelUsed` is set inside `safeComplete` via `Task { @MainActor in ... }`. But other state mutations (e.g., `currentTask` assignment) are unprotected. The `send()` method is called from main but `streamRequest` completion can race.

**Impact:** `@Published` KVO notifications must come on the main thread. The current `Task { @MainActor in completion(result) }` is safe, but `self?.modelUsed = model` at line 111 executes on a background actor context inside `tryNext()`. Since `RouterManager` is `@ObservableObject` and not `@MainActor`, the `modelUsed` setter fires KVO from whatever thread `tryNext()` is executing on.

**Suggested Fix:**
```swift
@MainActor
final class RouterManager: ObservableObject {
    ...
}
```
This guarantees all `@Published` mutations happen on main. Then `safeComplete` can use `completion(result)` directly instead of the `Task { @MainActor in }` wrapper.

---

### [MAJOR] `ToolExecutor.readDataToEndOfFile()` blocks cooperative thread | ToolExecutor.swift:32-33 | `readDataToEndOfFile()` is a synchronous blocking call on `FileHandle`. Called after `waitUntilExit()`, but the entire `run()` method executes on whatever queue it's called from. If called from main (via `onRun` → `ToolExecutor.run(...)` in ContentView.swift:260), this **blocks the main thread** until the shell command completes.

**Impact:** Running a long command (e.g., `find /`) from the Tool Modal **freezes the UI** for the duration of the command. This is the most likely cause of UI hangs.

**Suggested Fix:** Wrap the entire body in `Task.detached` or call from a background queue:
```swift
DispatchQueue.global().async {
    proc.waitUntilExit()
    let outData = ...
    DispatchQueue.main.async {
        completion(...)
    }
}
```

---

### [MAJOR] Redundant `.onChange(of:)` for `currentStreamingContent` — fires every character | ContentView.swift:199-203 | `.onChange(of: currentStreamingContent)` triggers a scroll-to-bottom animation on every appended chunk. Since tokens arrive at ~30-60/sec during streaming, this fires `withAnimation(.easeOut(duration: 0.1))` on every single character. SwiftUI coalesces the animations, but the repeated dispatch is wasteful.

**Impact:** Unnecessary work per token during streaming. Each `onChange` dispatch triggers a layout pass.

**Suggested Fix:** Remove `.onChange(of: currentStreamingContent)` and instead use `.onChange(of: store.messages.count)` (already present) for scroll-to-bottom. Or observe a separate "lastStreamingID" that only changes when a new assistant message starts.

---

### [MAJOR] Force-unwrap in `ConversationStore.fileURL` | ConversationStore.swift:14 | `urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]` assumes the array is non-empty. On rare system configurations (e.g. sandboxed apps with no Application Support directory), this crashes.

**Impact:** Fatal error in production if the Application Support directory lookup returns an empty array. Also `try? FileManager.default.createDirectory(...)` silently swallows errors.

**Suggested Fix:**
```swift
private let fileURL: URL = {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    let folder = support.appendingPathComponent("OpenRouterFusion")
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
        print("⚠️ Cannot create support dir: \(error)")
    }
    return folder.appendingPathComponent("conversation.json")
}()
```

---

### [MAJOR] NotificationCenter observers never removed | ContentView.swift:87-92 | Two `NotificationCenter.default.publisher(for:)` subscriptions are created in `.onReceive()`, which are correctly managed by SwiftUI's subscription lifecycle. **However**, the `Notification.Name` extensions in App.swift use raw string identifiers `"clearChat"` and `"toggleSidebar"`. If any other code posts these notifications (without the full module-qualified name), it causes silent conflicts.

**Impact:** Low risk currently, but string-based Notification names are a latent collision source.

**Suggested Fix:** Use a properly-scoped notification name or ensure uniqueness:
```swift
extension Notification.Name {
    static let orfClearChat = Notification.Name("org.openrouterfusion.clearChat")
    static let orfToggleSidebar = Notification.Name("org.openrouterfusion.toggleSidebar")
}
```

---

### MAJOR (additional)

### [MAJOR] `MetalButton` `onHover` deprecated on macOS in favor of `hoverEffect` | LRMComponents.swift:57 | `.onHover(perform:)` is deprecated starting macOS 12.4+. Still functional but generates deprecation warnings.

**Suggested Fix:** Use `.hoverEffect(.automatic)` or `onContinuousHover(_:)` for modern macOS.

---

### [MAJOR] `LRMTextEditor` `@FocusState` not reset when parent re-creates view | LRMComponents.swift:75 | `@FocusState private var isFocused` is not reset when the view is removed from the hierarchy (e.g., sheet dismissal). The focus state persists incorrectly on next appearance.

**Suggested Fix:** Accept a binding from parent, or use `@Environment(\.dismiss)` to reset on disappear:
```swift
.onDisappear { isFocused = false }
```

---

### MINOR

### [MINOR] Redundant `.clipShape` calls in ChatMessageView | ChatMessageView.swift:122-124,126 | `.background(...)` already applies `.clipShape(ChamferShape(...))`, then `.clipShape(ChamferShape(...))` is called again. This is a double-clip with no visual difference but adds render cost.

**Suggested Fix:** Remove the trailing `.clipShape` after the `.overlay`:
```swift
.background(gradient.clipShape(shape))
.overlay(shape.stroke(...))
// No second .clipShape needed — overlay draws on top
```

---

### [MINOR] `friendlyModelName` runs on every `body` evaluation | ContentView.swift:5-28 | This private free function is called inside the sidebar body for the "Auto" picker option label and for every `ForEach` iteration. It performs multiple `replacingOccurrences` and `capitalized` on every re-render.

**Impact:** Negligible for 5-10 models, but unnecessary. Models list doesn't change at runtime.

**Suggested Fix:** Cache the friendly names on `RouterManager` or compute once in the sidebar's body.

---

### [MINOR] `isStreaming` state managed manually alongside `currentStreamingContent` | ContentView.swift:40,178 | `isStreaming` is toggled independently of `currentStreamingContent`. If `isStreaming = true` but `currentStreamingContent` is empty, the streaming indicator shows. If `isStreaming = false` but `currentStreamingContent` has content, the message gets appended as a new assistant message. The relationship is invariant but not enforced.

**Suggested Fix:** Derive `isStreaming` from `!currentStreamingContent.isEmpty || activeToolCalls.isEmpty == false` and a separate streaming state enum:
```swift
enum StreamState { case idle, streaming, stopped }
```

---

### [MINOR] `saveQueue` with `.utility` QoS for potentially large JSON writes | ConversationStore.swift:18 | `DispatchQueue(label:qos: .utility)` means saves run at low priority. On macOS this is fine, but if the app is quit between `save()` and the `asyncAfter` executing, the save is lost. The 0.3s debounce window is a data-loss window.

**Suggested Fix:** Use `NotificationCenter` to observe `NSApplication.willTerminateNotification` and flush synchronously:
```swift
private func flushSave() {
    saveWorkItem?.cancel()
    let item = saveWorkItem
    item?.wait() // synchronously drain
}
```

---

### [MINOR] `ToolExecutor` does not sanitize or validate shell commands | ToolExecutor.swift:17 | User-entered commands are passed raw to `/bin/bash -c`. While this is by design (it's a shell tool), there is no logging, no output size limit, and no sandboxing.

**Security note:** This is a local macOS app, so the user already has shell access. But consider adding a 5MB output cap and logging executions.

**Suggested Fix:** Add `proc.standardInput = FileHandle.nullDevice` to prevent hung processes waiting for stdin. Add output truncation:
```swift
let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
let maxOutput = 100_000
if outData.count > maxOutput { /* truncate with warning */ }
```

---

### [MINOR] Empty `catch` body in `ConversationStore.load()` | ConversationStore.swift:21-23 | Decode failure is caught but only prints a warning and moves the file to backup. No user notification, no error recovery option.

**Suggested Fix:** Surface this to the UI via an `@Published` error string so the user can act.

---

### [MINOR] `safeComplete` in RouterManager uses `NSLock` where `actor` would be cleaner | RouterManager.swift:92-98 | `NSLock`-based synchronization works but is anachronistic in Swift 5.5+. The entire `RouterManager` should be an `actor` or `@MainActor` class.

**Suggested Fix:** Refactor `RouterManager` as a `@MainActor` class and remove the `NSLock`.

---

### [MINOR] `Mangaje` — Typo in parameter name? | ContentView.swift:256 | `executeTool(id: id, name: name, arguments: argsJSON)` — the parameter is named `id` which shadows `self` style naming conventions but is not a typo. No issue.

**[Not a finding — retracted]**

---

### [MINOR] `ToolModalView` does not validate empty command | ToolModalView.swift:22-26 | The "Run" button is always enabled (no `.disabled(command.isEmpty)` guard). If the user runs an empty command, `/bin/bash -c ""` exits immediately with status 0 and empty output — no tool output card is appended (output is empty, so the `appended` message has no meaningful content.

**Suggested Fix:** Disable the Run button when command is empty:
```swift
MetalButton("Run", variant: .metal) {
    onRun(command); dismiss()
}
.disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
```

---

### [MINOR] Preview helper leaks `ChatMessage.preview(role:)` without `_` as internal | ChatMessageView.swift:72 | The extension `static func preview(role:...)` is usable from any module via `public` access. Not a problem since it's `#if DEBUG`, but the naming suggests it's a debug-only helper.

**Suggested Fix:** Rename to `static func _preview(...)` or mark as `@_spi(Debug)` to signal internal use.

---

### [MINOR] `Spacer().frame(width: 32)` in ChatMessageView uses `Spacer` where `Color.clear` would be more efficient | ChatMessageView.swift:21,27 | `Spacer().frame(width: 32)` works but SwiftUI's layout engine must resolve the `Spacer`'s flexible intrinsic width, then clamp to 32pt. Using `Color.clear.frame(width:32)` or `Rectangle().fill(Color.clear).frame(width:32)` is marginally cheaper.

**Suggested Fix:** Low priority. Replace with `Color.clear.frame(width: 32)`.

---

## Architectural Observations

1. **State Management:** `ContentView` is a massive view (300+ lines) holding 14 `@State` properties. Consider extracting a `ConversationViewModel` or using the Observation framework (`@Observable`) to group related state.

2. **Model Architecture:** `ChatMessage` uses `var id = UUID()` with default initialization, meaning every new message gets a UUID at init, not from JSON. During `Codable` round-trip, the UUID is preserved — this is fine for persistence but means `Identifiable` conformance relies on server stability.

3. **Async/Await Migration:** `ToolExecutor` uses old-style `DispatchQueue` callbacks. The rest of the codebase uses `Swift Concurrency` (`Task { @MainActor in }`). Migrating `ToolExecutor` to `async/await` would unify error handling and cancellation.

4. **Error Handling Gaps:**
   - No HTTP status code detail surfaces to the user (just "HTTP code")
   - `ToolExecutor` failure includes stderr in error message — could leak config paths
   - No network connectivity check before sending requests

5. **Missing Accessibility:**
   - No `.accessibilityLabel` on any control
   - No VoiceOver support for chat messages
   - Colors defined as hardcoded RGB with no Dynamic Type support

6. **Testability:**
   - `ToolExecutor` is not injectable (hardcoded `Process`)
   - `RouterManager` init reads from disk — not mockable
   - `ConversationStore.fileURL` is hardcoded — not injectable for testing

---

## Recommended Priority Order

1. **`@MainActor` isolation on RouterManager** — eliminates threading bugs in one change
2. **Extract ContentView into ViewModel / `@Observable`** — massive view is untestable
3. **Move ToolExecutor to background queue** — main thread block is worst UX issue
4. **Cache AttributedString parsing in ChatMessageView** — biggest performance win
5. **Remove redundant `.clipShape` calls** — small render pass savings
6. **Add `.disabled(command.isEmpty)` on ToolModalView Run button** — trivial UX fix
