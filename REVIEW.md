# OpenRouterFusion — Code Quality Review

**Date:** 2026-06-13  
**Reviewer:** OWL (Knox role)  
**Scope:** All `.swift` files in `Sources/OpenRouterFusion/`

---

## Summary

The codebase is a well-structured SwiftUI macOS app with a clear visual identity (LRM theme), SSE streaming, tool execution, and keychain-secured API keys. The architecture is straightforward: `ContentView` owns a `ConversationStore` and `RouterManager`, with chat bubbling handled by `ChatMessageView`. There are significant quality concerns around retain cycles, state management, API key handling, and some performance issues. Below is every issue found, organized by severity.

**Totals:** 3 CRITICAL · 12 MAJOR · 14 MINOR

---

## CRITICAL Issues

### C-1: `[weak self]` capture in `RouterManager.send()` → `streamRequest` retains `self` anyway
- **File:** `RouterManager.swift`, line ~108 (`streamRequest` completion closure)
- **Severity:** CRITICAL
- **Description:** Inside `RouterManager.send()`, the recursive `tryNext()` function references `self` directly via `self?.modelUsed = model` and passes `self` implicitly through the `onChunk`, `onToolCall`, and `completion` closures. Although the `streamRequest` completion handler uses `[weak self]`, the `Task {}` inside `streamRequest` calls `accumulated.isEmpty ? .success("") : .success(accumulated)` — but the real issue is that `send()` captures `onChunk`, `onToolCall`, and `completion` which are closures from `ContentView` that capture `store` and `router`. This creates a retain cycle: `ContentView` → `@StateObject router` → `RouterManager.send()` closure → `onChunk`/`completion` → `ContentView` (via `store` capture). If the stream is in-flight and the user dismisses/navigates away, neither `ContentView` nor `RouterManager` can be deallocated until the stream finishes or the `Task` is cancelled.
- **Suggested fix:** Add explicit `[weak self]` in the `Task {}` inside `streamRequest`, check for nil, and add a `Task`-based cancellation mechanism to `RouterManager`. Expose a `cancel()` method that sets a flag checked in the async loop. Also audit the callback chains from `send()`'s parameters.

### C-2: LRMTextEditor has a keyboard-submit / newline conflict
- **File:** `ContentView.swift`, line ~265 (`.onSubmit { sendMessage() }` inside `TextEditor`)
- **Severity:** CRITICAL
- **Description:** `.onSubmit { sendMessage() }` is attached to the `TextEditor` in the composer. Quick Help states that ⇧ Enter inserts a new line. However, `TextEditor` with `.onSubmit` attached on macOS **swallows the Return key entirely** — the modifier check (bare Return vs Shift+Return) is handled by the system for `TextEditor`, but attaching `.onSubmit` to `TextEditor` rather than a `TextField` is **not officially supported** on macOS and may behave unpredictably (either always submitting on Enter with no newline capability, or never submitting depending on SwiftUI version). The user cannot type multi-line messages.
- **Suggested fix:** Use a custom `UIViewRepresentable` wrapping `NSTextView` with proper `textView:doCommandBySelector:` delegate handling to detect bare Return (submit) vs Shift+Return (newline). Or, keep the current structure but wrap the `TextEditor` inside a `FocusState`-based approach where Enter without Shift triggers `sendMessage()` via a `TextInputFormatter` or by intercepting key events.

### C-3: API key fallback to UserDefaults is insecure and incomplete
- **File:** `ContentView.swift`, lines ~82–89 (`.onAppear`)
- **Severity:** CRITICAL
- **Description:** On line 82, the app checks `KeychainHelper.shared.get(key:)` — if nil, it falls back to reading `UserDefaults.standard.string(forKey: "openrouter_api_key")`. While the intention (migrate to keychain) is good, this means the API key is stored in plaintext in `~/Library/Preferences/<bundle>.plist` indefinitely if the keychain save fails silently. There's no mechanism to *remove* the key from `UserDefaults` after successfully saving to keychain, nor any warning to the user that this fallback is happening during normal operation (the alert only fires on save failure). An attacker with local access or a backup can exfiltrate the key trivially.
- **Suggested fix:** After a successful `KeychainHelper.shared.set(...)`, explicitly call `UserDefaults.standard.removeObject(forKey: "openrouter_api_key")`. Do **not** read from UserDefaults as a fallback at all — if the keychain returns nil, prompt the user to re-enter the key. The UserDefaults migration should happen once, then the value should be purged.

---

## MAJOR Issues

### M-1: No Task cancellation / no way to abort streaming
- **File:** `RouterManager.swift`, line ~86 (`Task { ... }` in `streamRequest`)
- **Severity:** MAJOR
- **Description:** The `Task {}` in `streamRequest` runs until the server closes the stream, the buffer is exhausted, or an error occurs. There is no `Task` handle stored anywhere. The "Stop" button in `ContentView` sets `isStreaming = false` but does **not** cancel the in-flight network request or the parsing `Task`. This means:
  1. Network bytes continue arriving and being parsed (wasting CPU/bandwidth).
  2. The completion closure still fires after the user has pressed Stop, potentially appending stale content to the store.
  3. `onChunk` callbacks continue to mutate `currentStreamingContent` state even after streaming is "stopped."
- **Suggested fix:** Store the `Task` handle in `RouterManager` (e.g., `private var currentTask: Task<Void, Never>?`). Add a `cancel()` method that calls `currentTask?.cancel()`. In the streaming loop, check `Task.isCancelled` periodically. In `ContentView`'s Stop action, call `router.cancel()`.

### M-2: Timer leak in PulsingDots
- **File:** `LRMComponents.swift`, lines ~210–222 (`PulsingDots`)
- **Severity:** MAJOR
- **Description:** `PulsingDots` creates `Timer.publish(every: 0.45, on: .main, in: .common).autoconnect()` as a stored property (line ~211). `autoconnect()` means the timer starts immediately and never stops — even when the view is offscreen or the streaming indicator isn't visible. Every time a `PulsingDots` instance is created (for each assistant bubble in streaming state, plus the "Thinking" indicator in `ChatMessageView`), a new timer fires forever. In a long conversation with dozens of messages, this accumulates many orphaned timers consuming CPU.
- **Suggested fix:** Use `.onAppear` to connect and `.onDisconnect` to cancel. Better yet, replace the timer approach with explicit SwiftUI implicit animation: `@State private var phase = 0` and use `withAnimation(.easeInOut(duration: 0.45).repeatForever())` triggered in `.onAppear`.

### M-3: `Data` buffer accumulation for SSE parsing causes unbounded memory growth
- **File:** `RouterManager.swift`, lines ~140–200
- **Severity:** MAJOR
- **Description:** The `dataBuffer` is a `Data` object that accumulates bytes until a newline is found. If the server sends malformed data without newlines (or extremely long lines), `dataBuffer` grows unboundedly. More critically, if the server sends a streaming response with many bytes before the first newline, the entire chunk sits in memory. While this is unlikely with OpenRouter's API, there's no cap or assertion on buffer size.
- **Suggested fix:** Add a buffer size check: if `dataBuffer.count > 65536` (64KB), discard the buffer and log a warning. Alternatively, use `AsyncSequence` line-by-byte parsing with a max line length.

### M-4: No error handling for non-200 HTTP responses in streaming
- **File:** `RouterManager.swift`, lines ~147–153
- **Severity:** MAJOR
- **Description:** When the server returns a non-200 status code, the error includes only `"HTTP \(httpResp.statusCode)"` — no body content is read. The OpenRouter API returns detailed error JSON in the response body (e.g., rate limit info, model availability). These are silently discarded. Additionally, `RouterManager`'s `send()` treats any failure as a signal to try the next model in `fallbackOrder`, which means a 401 (invalid API key) will exhaust all models before reporting the error, making the real cause invisible.
- **Suggested fix:** Read the response body for non-200 responses and include it in the error. Add a check for non-retryable status codes (401, 403) that should short-circuit the retry loop immediately.

### M-5: `@ObservedObject` should be `@StateObject` for owned references
- **File:** `ContentView.swift`, line ~14–15
- **Severity:** MAJOR
- **Description:** `store` and `router` are declared as `@StateObject`, which is correct. However, the code creates `ToolExecutor` calls that capture `store` in escaping closures. If SwiftUI ever recreates the `ContentView` (e.g., due to a parent re-render), the `@StateObject`s survive correctly — but any escaping closure that captured the *old* view's `store` reference before a re-render would still point to the old store. This is a subtle correctness issue. The actual issue is that `store` is passed into `@escaping` callbacks in `ToolExecutor.run` — these callbacks can outlive the view, meaning `store` is kept alive by the closure even after the view's lifecycle ends.
- **Suggested fix:** Ensure all escaping callbacks that use `store` capture it weakly: `[weak store] in`. Inside the callback, guard against nil: `guard let store = store else { return }`.

### M-6: Markdown parsing in `ChatMessageView` is done inside `body` (re-evaluated every render)
- **File:** `ChatMessageView.swift`, lines ~115–128 (the `attributed` computed var in `markdownContent`)
- **Severity:** MAJOR
- **Description:** The `attributed` variable is a computed property inside a `@ViewBuilder` that runs `AttributedString(markdown:)` parsing on every view body evaluation. SwiftUI may call `body` multiple times per frame. For long messages with complex markdown, this parses the entire string each time. With many messages in the list, this creates a performance problem during scrolling.
- **Suggested fix:** Parse the markdown once in an `@State` or lazy var, or compute it in `init`. Alternatively, move parsing into `StreamingMarkdownView` (which already parses) and remove the duplicate parsing path in `ChatMessageView`.

### M-7: `ConversationStore.save()` called after every single append — disk I/O on main thread
- **File:** `ConversationStore.swift`, lines ~35–37
- **Severity:** MAJOR
- **Description:** `save()` calls `JSONEncoder().encode()` and `Data.write(to:options:)` synchronously. This is invoked from `append()`, which is called:
  - Once for each streaming-complete assistant message
  - Once for each tool call result
  - For each human message
  - On `clear()`
  
  The `Data.write(to:options: .atomic)` is a filesystem operation that can block. If the app is saving a large conversation (hundreds of messages), this could cause a visible frame drop on the main thread.
- **Suggested fix:** Move encoding and writing to a background queue with debouncing (save at most once per second, or after a short delay). Use a dedicated `DispatchQueue(label: "save")` or an `actor`.

### M-8: `router.send()` does not use `[weak self]` in recursive closure — potential crash on dealloc
- **File:** `RouterManager.swift`, lines ~96–110
- **Severity:** MAJOR
- **Description:** The `tryNext()` function (nested inside `send()`) references `config.maxRetries` and `config` directly. After the `streamRequest` async Task fires its completion closure, `self` is accessed via `self?.modelUsed = model`. If `RouterManager` has been deallocated by then (unlikely in this app but architecturally wrong), `self` is nil and the assignment is silently skipped. But the `tryNext()` function also calls itself recursively after setting `lastError = err` — if the `send()` method has been called multiple times (e.g., rapid message sends), each call has its own `tryNext()` and `candidates` array access. There's no protection against concurrent calls.
- **Suggested fix:** Guard with an `inFlight` flag or use an actor-isolated state. Ensure only one `send()` is active at a time, queuing or rejecting additional requests.

### M-9: Force-unwrap of JSON decode in `RouterManager.init()`
- **File:** `RouterManager.swift`, line ~18
- **Severity:** MAJOR
- **Description:** `config = try! JSONDecoder().decode(Config.self, from: data)` will crash the app if `ModelConfig.json` is malformed. While the file is bundled with the app and unlikely to be corrupt, a bad merge, git conflict marker, or Xcode build issue could produce invalid JSON.
- **Suggested fix:** Replace with `do/catch` that provides a descriptive fatal error: `fatalError("ModelConfig.json decode failed: \(error)")`. Or better, provide sensible default config values as a fallback.

### M-10: Tool execution uses `/bin/bash -c` with unsanitized output — potential XSS in markdown
- **File:** `ContentView.swift`, lines ~293–307 (`executeTool`) and ~313–327 (`runManualTool`)
- **Severity:** MAJOR
- **Description:** Tool output is inserted directly into a markdown code block in the conversation: `` "🛠 [\(name)] → \(truncated)" ``. If tool output contains backticks (```), markdown syntax characters, or escape sequences, this could break the `AttributedString` markdown parser or produce garbled output. For a tool that dumps binary or special characters, this could crash the markdown renderer.
- **Suggested fix:** Sanitize or escape backticks in tool output before insertion. Consider rendering tool output in a plain `Text` view rather than through markdown parsing.

### M-11: `StreamingMarkdownView` duplicates markdown parsing logic
- **File:** `StreamingMarkdownView.swift`
- **Severity:** MAJOR
- **Description:** `StreamingMarkdownView` is defined but appears unused — `ChatMessageView` already has its own inline markdown rendering in the `markdownContent` computed property. Having two separate markdown rendering implementations means bugs must be fixed in two places. The `StreamingMarkdownView` uses `.inlineOnlyPreservingWhitespace` while `ChatMessageView` uses `.allowsExtendedAttributes = true` — they render the same content differently.
- **Suggested fix:** Remove `StreamingMarkdownView` or consolidate all markdown rendering into it. Make it the single source of truth, configured with the correct options.

### M-12: `onChange(of: systemPrompt)` saves on every keystroke
- **File:** `ContentView.swift`, line ~97
- **Severity:** MAJOR
- **Description:** `.onChange(of: systemPrompt) { UserDefaults.standard.set(systemPrompt, forKey: "systemPrompt") }` fires on every single keystroke in the system prompt text editor. `UserDefaults.synchronize()` is called implicitly and this creates unnecessary I/O, especially for long prompts.
- **Suggested fix:** Debounce the save using `onChange` with a `.debounce` operator (iOS 15+/macOS 12+ via Combine). Or save in `.onDisappear` / when the sidebar is hidden.

---

## MINOR Issues

### m-1: Accessibility — Missing labels on interactive elements
- **Files:** `ContentView.swift` (sidebar toggle buttons), `LRMComponents.swift` (MetalButton, PulsingDots), `ChatMessageView.swift` (avatars), `ToolModalView.swift`
- **Severity:** MINOR
- **Description:** No `.accessibilityLabel`, `.accessibilityHint`, or `.accessibilityIdentifier` modifiers anywhere. The sidebar collapse button has `.help("Hide sidebar")` (tooltip) but no accessibility label. The Send button has no label. `PulsingDots` has no "loading" accessibility description. Avatar circles with "U" and "A" have no labels. Screen reader users get no context.
- **Suggested fix:** Add `.accessibilityLabel("Send message")` to Send button, `.accessibilityLabel("Loading response")` to `PulsingDots`, `.accessibilityLabel("User avatar")` / `"Assistant avatar"`, etc.

### m-2: Accessibility — No Dynamic Type support
- **Files:** All views using `.system(size:)`
- **Severity:** MINOR
- **Description:** All fonts use `.system(size: N)` with hardcoded pixel sizes (e.g., `.system(size: 14)`, `.system(size: 10)`, `.system(size: 11)`). These do **not** scale with the user's Dynamic Type / Accessibility Size preference. Users who need larger text will be stuck with tiny fonts.
- **Suggested fix:** Use `.system(.body)`, `.system(.caption)`, `.system(.footnote)` etc., or at minimum use `Metrics` relative sizes via `@ScaledMetric`.

### m-3: Accessibility — Color-only status indicators
- **Files:** `LRMComponents.swift` (StatusBadge), `ContentView.swift` (ToolCallIndicator)
- **Severity:** MINOR
- **Description:** Streaming status is indicated solely by purple pulsing dots. Error messages use ❗️ emoji. Tool calls use a gear icon. None of these have text alternatives or accessibility traits. Color-blind users cannot distinguish the accent-colored elements from the background.
- **Suggested fix:** Add `.accessibilityElement(children: .combine)` to badges and indicators. Include text like "Streaming" or "Error" in accessibility labels.

### m-4: `ChamferShape` path is not chamfered — it's a rectangle with one corner cut
- **File:** `LRMTheme.swift`, lines ~108–118
- **Severity:** MINOR
- **Description:** The `ChamferShape` path cuts only the bottom-right corner (`rect.maxX - c, rect.maxY` → `rect.maxX, rect.maxY - c`). A true chamfer would cut all four corners. The name is misleading and the shape is inconsistent with what "chamfer" implies. This is a visual inconsistency — the CSS `clip-path: polygon(...)` it replaces likely cut all corners.
- **Suggested fix:** Either cut all four corners (add chamfer to top-left and bottom-left as well) or rename to `NotchedRectShape` / `CornerCutShape`.

### m-5: `MetalButton` uses `DragGesture` for press detection — conflicts with button tap
- **File:** `LRMComponents.swift`, lines ~56–62
- **Severity:** MINOR
- **Description:** `.simultaneousGesture(DragGesture(minimumDistance: 0))` is used to detect press state for the scale effect. This can interfere with the button's own tap handling, especially on trackpad where a "press" might be interpreted as a drag. The `isPressed` state is set to true on `.onChange` but only reset on `.onEnded` — if the user drags outside the button, `.onEnded` fires but the button action doesn't fire, leaving `isPressed` stuck at `true` until the next interaction.
- **Suggested fix:** Use a custom `ButtonStyle` with `isPressed` from the configuration, or use `.scaleEffect` with `.animation` triggered by the button's built-in press state.

### m-6: `friendlyModelName` is a free function, not testable
- **File:** `ContentView.swift`, lines ~5–22
- **Severity:** MINOR
- **Description:** `friendlyModelName` is a private free function at file scope. It cannot be unit tested independently. The string replacement chain is also fragile — it hardcodes provider prefixes that will drift as OpenRouter adds new providers.
- **Suggested fix:** Move to a `ModelNamer` struct or an extension on `String`, and add unit tests. Consider using the OpenRouter `/api/v1/models` endpoint to get display names.

### m-7: `ToolExecutor` timeout uses `proc.terminate()` — doesn't guarantee kill
- **File:** `ToolExecutor.swift`, lines ~18–19
- **Severity:** MINOR
- **Description:** `proc.terminate()` sends SIGTERM. If the spawned process has child processes (e.g., `bash -c "long_running_cmd"`), only the bash process is terminated — the child continues as an orphan. There's no escalation to SIGKILL.
- **Suggested fix:** After a grace period (e.g., 2 seconds), send `kill(-proc.processIdentifier, SIGKILL)` to the entire process group. Or use `Process` with a proper lifecycle manager.

### m-8: `ToolExecutor` reads stdout/stderr after `waitUntilExit()` — potential deadlock
- **File:** `ToolExecutor.swift`, lines ~22–23
- **Severity:** MINOR
- **Description:** `readDataToEndOfFile()` is called after `waitUntilExit()`. If the process fills the pipe buffer (64KB on macOS) before exiting, the process blocks on `write()` while `ToolExecutor` waits on `waitUntilExit()` — classic pipe deadlock. For tools that produce large output, this is a real risk.
- **Suggested fix:** Read data asynchronously *before* waiting, or use `readInBackgroundAndNotify()`, or read from the pipe concurrently.

### m-9: `NotificationCenter` for Clear Chat / Toggle Sidebar is fragile
- **File:** `App.swift`, lines ~20–28
- **Severity:** MINOR
- **Description:** `ContentView` listens for `.clearChat` and `.toggleSidebar` notifications but **never actually registers observers**. The `clearChatShortcut()` method exists as an extension but is never called. The keyboard shortcuts post notifications that no one handles. Pressing ⌘K does nothing.
- **Suggested fix:** Add `.onReceive(NotificationCenter.default.publisher(for: .clearChat)) { _ in clearChatShortcut() }` in `ContentView`. Same for `.toggleSidebar`.

### m-10: `ContentView` has ~330 lines — too large for a single view
- **File:** `ContentView.swift`
- **Severity:** MINOR
- **Description:** `ContentView` contains the sidebar, chat area, empty state, chat log, composer, messaging logic, tool execution, keyboard shortcuts, and the `ToolCallIndicator` view. This is a massive view that's hard to navigate and test.
- **Suggested fix:** Extract subviews: `SidebarView`, `ChatLogView`, `ComposerView`, `EmptyStateView`. Move `ToolCallDisplay` and `ToolCallIndicator` to their own file. Move `friendlyModelName` to a utility file.

### m-11: `ConversationStore` uses `try?` silently for save failures
- **File:** `ConversationStore.swift`, line ~36
- **Severity:** MINOR
- **Description:** `try? data.write(to: fileURL, options: .atomic)` silently discards write errors. If the disk is full or permissions change, the user loses their conversation with no warning.
- **Suggested fix:** Log the error at minimum. Consider surfacing a save-failure alert to the user.

### m-12: `KeychainHelper` uses `kSecAttrAccessibleAfterFirstUnlock` — not the most secure
- **File:** `KeychainHelper.swift`, line ~12
- **Severity:** MINOR
- **Description:** `kSecAttrAccessibleAfterFirstUnlock` means the keychain item is accessible after the first device unlock following a reboot. A background process or malware running between reboot and first unlock could access it. For an API key, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is more appropriate.
- **Suggested fix:** Change to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` to prevent access when the device is locked and to exclude the item from keychain backups/restores.

### m-13: `LRMTextEditor` and `LRMSecureField` duplicate styling code
- **File:** `LRMComponents.swift`, lines ~230–290
- **Severity:** MINOR
- **Description:** Both `LRMTextEditor` and `LRMSecureField` contain identical background styling code (the `ZStack` with `Color.lrmSurfaceStrong` and gradient overlay, plus the `ChamferShape` clip and stroke). This is copy-pasted.
- **Suggested fix:** Extract a shared `LRMTextFieldBackground` view modifier or `LRMTextFieldStyle` to eliminate duplication.

### m-14: Preview code left in production files
- **Files:** `ChatMessageView.swift` (lines ~155–180)
- **Severity:** MINOR
- **Description:** The `#if DEBUG` preview extension includes a `ChatMessage.preview(role:content:modelUsed:)` static factory that doesn't match the actual `ChatMessage` initializer (which uses `init(role:content:)`). This is fine for previews but the `preview` method is in the production target (albeit gated by `#if DEBUG`). The `ChatMessage` struct in `ConversationStore.swift` doesn't have this factory method — it's only in the preview extension.
- **Suggested fix:** This is acceptable as-is, but consider moving all preview code to a `Previews.swift` file for cleanliness.

---

## Positive Observations

1. **Clean visual identity.** The LRM theme system with `Color` extensions, `LinearGradient` presets, and `ChamferShape` creates a cohesive, distinctive look. The design tokens are well-organized.

2. **SSE streaming is well-implemented.** The byte-by-byte parsing with `URLSession.bytes(for:)` is the correct modern approach. The line buffering and `[DONE]` detection are handled properly.

3. **Keychain integration.** Storing the API key in Keychain (rather than UserDefaults) is the right call. The `KeychainHelper` is clean and minimal.

4. **Graceful degradation.** The fallback model routing in `RouterManager.send()` is a smart resilience pattern. If one model is down, the app tries the next.

5. **Atomic writes.** `ConversationStore.save()` uses `.atomic` option, preventing corruption if the app crashes mid-write.

6. **Corrupted file recovery.** The `load()` method in `ConversationStore` backs up corrupted JSON instead of silently deleting it.

7. **Tool execution architecture.** Separating `ToolExecutor` into its own class with async completion handlers is clean. The 30-second timeout is reasonable.

---

## Recommended Priority Order

1. **C-1** — Fix retain cycle in RouterManager (architectural)
2. **M-1** — Add Task cancellation for streaming stop
3. **C-3** — Remove UserDefaults API key fallback / purge after migration
4. **M-2** — Fix PulsingDots timer leak
5. **C-2** — Fix TextEditor newline vs submit conflict
6. **M-4** — Handle non-200 HTTP response bodies
7. **M-7** — Move ConversationStore save off main thread
8. **M-11** — Consolidate or remove StreamingMarkdownView
9. **m-1/m-2** — Add accessibility labels and Dynamic Type support
10. **M-10** — Refactor ContentView into subviews
