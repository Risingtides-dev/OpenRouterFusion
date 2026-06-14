# Architecture Review: OpenRouterFusion

**Date:** 2026-06-14  
**Reviewer:** crew-worker (task-9)  
**Scope:** File organization, separation of concerns, data flow, networking layer, UI layering  
**Based on:** REVIEW.md code quality assessment

---

## Current Architecture Summary

### Layer Stack

```
┌─────────────────────────────────────────────┐
│ Presentation Layer (SwiftUI Views)          │
│ ├─ App.swift (entry point, menus)           │
│ ├─ ContentView.swift (thin shell)           │
│ ├─ SidebarView, ChatLogView, ComposerView   │
│ ├─ ChatMessageView, EmptyStateView          │
│ └─ Supporting: ToolModalView, LRMComponents │
├─────────────────────────────────────────────┤
│ Business Logic Layer                        │
│ ├─ ChatViewModel (state & command routing)  │
│ └─ ToolExecutor (process execution)         │
├─────────────────────────────────────────────┤
│ Data/Service Layer                          │
│ ├─ RouterManager (OpenRouter API, SSE)      │
│ └─ ConversationStore (message persistence)  │
├─────────────────────────────────────────────┤
│ Infrastructure Layer                        │
│ ├─ KeychainHelper (secure storage)          │
│ ├─ LRMTheme (design tokens)                 │
│ └─ Utilities: Debouncer, ModelNamer         │
└─────────────────────────────────────────────┘
```

### Data Flow

```
User Input (TextEditor)
  ↓
ChatViewModel.sendMessage()
  ├─ Append to ConversationStore
  ├─ Publish to RouterManager.send()
  │   ├─ Streaming bytes via URLSession.bytes()
  │   ├─ SSE line parsing with data buffering
  │   └─ [weak self] closures (onChunk, onToolCall, completion)
  ├─ Stream callbacks mutate currentStreamingContent (@Published)
  └─ SwiftUI re-renders ChatLogView on state change
    ├─ ChatMessageView parses markdown on every render (M-6)
    └─ AttributedString(markdown:) called repeatedly
```

### File Organization

| Layer | Files | Lines | Purpose |
|-------|-------|-------|---------|
| Presentation | App.swift | 27 | Window setup, menu commands |
| | ContentView.swift | 73 | View composition (extracted subviews) |
| | SidebarView.swift | 99 | Model selection, system prompt |
| | ChatLogView.swift | 88 | Message list with scroll |
| | ChatMessageView.swift | 197 | Markdown rendering, role badges |
| | ComposerView.swift | 48 | Text input, send button |
| | EmptyStateView.swift | 67 | No-messages prompt |
| | ToolModalView.swift | 33 | Tool execution prompt |
| Business Logic | ChatViewModel.swift | 207 | Orchestration, state mutations |
| | ToolExecutor.swift | 45 | Subprocess execution |
| Networking | RouterManager.swift | 384 | SSE streaming, retries, error handling |
| Data | ConversationStore.swift | 54 | JSON persistence, debounced save |
| Infrastructure | KeychainHelper.swift | 41 | Secure credential storage |
| | LRMTheme.swift | 127 | Design system (colors, gradients) |
| | LRMComponents.swift | 255 | Reusable UI components (buttons, editors) |
| | ModelNamer.swift | 36 | Model name formatting |
| | Debouncer.swift | 22 | Debounce operator |
| | ToolCallDisplay.swift | 36 | Tool call data model |
| **TOTAL** | **20 files** | **~1,890 lines** | Full application |

### Key Observations

**Strengths:**
1. ✅ Clean separation of concerns — ViewModels own state, Views bind read-only
2. ✅ Consistent design system (LRM theme tokens reduce ad-hoc styling)
3. ✅ Async-first networking (URLSession.bytes) — modern SSE streaming
4. ✅ Secure credential storage (Keychain)
5. ✅ Background-threaded persistence (ConversationStore.save with debounce)
6. ✅ Graceful model fallback (RouterManager retries with next model)

**Weaknesses:**
1. ❌ **Retain cycle in RouterManager** (C-1) — [weak self] not used in streaming closures
2. ❌ **No Task cancellation** (M-1) — Stop button doesn't actually cancel network request
3. ❌ **Duplicated markdown rendering** (M-11) — StreamingMarkdownView vs ChatMessageView
4. ❌ **Markdown parsing on every render** (M-6) — AttributedString parsed in view body
5. ❌ **Notification-based command dispatch** (m-9) — Fragile, not composable
6. ❌ **Large ContentView** (m-10) — No longer applicable, now well-decomposed
7. ❌ **No concurrent-send guard** (M-8) — Multiple rapid sends could conflict
8. ❌ **Timer leak in PulsingDots** (M-2) — Timers never cancelled
9. ❌ **Unbounded SSE buffer** (M-3) — Data accumulation without cap
10. ❌ **HTTP error bodies discarded** (M-4) — No error details in logs

---

## 5 Structural Improvements

### 1. Introduce a `StreamingNetworkActor` for Thread-Safe Streaming

**Problem:** RouterManager is a class with mutable state (`modelUsed`, `inFlight`, `currentTask`). Multiple threads access these without synchronization. `[weak self]` in closures doesn't prevent retain cycles because the *caller* of `send()` captures the closures themselves.

**Solution:** Wrap RouterManager's streaming logic in an actor to guarantee serial execution:

```swift
@globalActor
actor StreamingNetworkActor {
    static let shared = StreamingNetworkActor()
}

final class RouterManager: ObservableObject {
    private var streamActor: StreamingNetworkActor = .shared
    
    @StreamingNetworkActor
    func send(messages: [[String: Any]], ..., completion: @escaping ...) {
        // Only one send() executes at a time
        // No concurrent access to currentTask, modelUsed, inFlight
        self.inFlight = true
        defer { self.inFlight = false }
        
        // Strong reference to Task for cancellation
        self.currentTask = Task { ... }
    }
    
    @StreamingNetworkActor
    func cancel() {
        currentTask?.cancel()
    }
}
```

**Benefits:**
- Eliminates M-1 (no Task cancellation) — currentTask is stored and cancelled on demand
- Eliminates M-8 (no concurrent-send guard) — actor serializes all sends
- Eliminates C-1 (retain cycle) — actor boundary prevents implicit closure captures
- Provides explicit error handling: non-retryable 401/403 short-circuits retries immediately

**Files Affected:** `RouterManager.swift`  
**Effort:** Medium (refactor async/await patterns, ensure Main thread marshalling)

---

### 2. Extract Markdown Rendering into a Cached `MarkdownService`

**Problem:**
- M-6: ChatMessageView parses markdown on every view body evaluation
- M-11: StreamingMarkdownView duplicates the parsing logic
- No caching — long messages parse repeatedly during scroll/animation

**Solution:** Create a singleton service that caches parsed AttributedStrings:

```swift
@MainActor
final class MarkdownService {
    static let shared = MarkdownService()
    
    private var cache = [String: AttributedString]()
    private let lock = NSLock()
    
    func parse(_ markdown: String) -> AttributedString {
        lock.lock()
        defer { lock.unlock() }
        
        if let cached = cache[markdown] {
            return cached
        }
        
        let parsed = try! AttributedString(markdown: markdown, options: .init(allowsExtendedAttributes: true))
        cache[markdown] = parsed
        return parsed
    }
    
    func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}
```

**Usage in ChatMessageView:**
```swift
@MainActor
struct ChatMessageView: View {
    var body: some View {
        Text(MarkdownService.shared.parse(message.content))
    }
}
```

**Remove:** Delete `StreamingMarkdownView.swift` entirely; move any special handling into `MarkdownService`.

**Benefits:**
- Eliminates M-6 (markdown parsing per render) — now O(1) after first parse
- Eliminates M-11 (duplicate implementations) — single source of truth
- Improves scroll performance during streaming
- Cache respects memory pressure (can be cleared on low memory)

**Files Affected:** `ChatMessageView.swift`, delete `StreamingMarkdownView.swift`  
**Effort:** Low (straightforward service pattern)

---

### 3. Create a Layered Error Handling Architecture

**Problem:** M-4 (no HTTP error body handling), M-8 (retries on non-retryable errors)

**Current flow:**
```
Non-200 HTTP → "HTTP 401" (no body) → Try next model (wrong!)
→ Exhaust all models → "All models exhausted" (real error hidden)
```

**Solution:** Define error layers and classification:

```swift
// Infrastructure error (network/HTTP/parsing)
enum NetworkError: LocalizedError {
    case httpError(statusCode: Int, body: String)
    case sseParseError(String)
    case timeout
    case connectionLost
}

// Domain error (business logic)
enum APIError: LocalizedError {
    case invalidAPIKey
    case modelUnavailable(String)
    case allModelsExhausted([String: NetworkError])
    case userCancelled
    
    var isRetryable: Bool {
        switch self {
        case .invalidAPIKey, .userCancelled: return false
        default: return true
        }
    }
}

// In RouterManager
private func handleHTTPError(_ code: Int, body: String) -> APIError {
    switch code {
    case 401, 403:
        return .invalidAPIKey  // Non-retryable → stop immediately
    case 429:
        return .modelUnavailable("Rate limited") // Retryable → try next
    case 500...599:
        return .modelUnavailable("Server error \(code)") // Retryable
    default:
        return .allModelsExhausted(["unknown": .httpError(code, body)])
    }
}
```

**Logging benefit:** Structured errors enable detailed logging/telemetry:
```swift
let logger = Logger(subsystem: "OpenRouterFusion", category: "networking")
logger.error("Network error: \(error.localizedDescription) [retryable=\(error.isRetryable)]")
```

**Benefits:**
- Eliminates M-4 (missing error bodies) — all HTTP responses logged with body
- Eliminates M-8 (wrong retry logic) — 401/403 stops immediately
- Testable error handling (unit tests for each error case)
- Structured logging for debugging

**Files Affected:** `RouterManager.swift`  
**Effort:** Low–Medium (error type definition + classification)

---

### 4. Separate Tool Execution into a Self-Contained `ToolsFeature` Module

**Problem:** Tool execution logic is scattered:
- `ToolExecutor.swift` — process execution (has m-7, m-8 bugs)
- `ToolModalView.swift` — UI for manual tool entry
- `ToolCallDisplay.swift` — data model
- `ChatViewModel.swift` — `executeTool()`, `runManualTool()` methods
- `ChatMessageView.swift` — tool call indicators

**Current coupling:**
```
ChatViewModel ← calls ToolExecutor
ChatViewModel ← owns activeToolCalls: [ToolCallDisplay]
ChatMessageView ← renders ToolCallDisplay
ChatViewModel ← presents ToolModalView
```

**Solution:** Extract to a cohesive module:

```
ToolsFeature/
├── ToolsService.swift       (owns ToolExecutor, manages lifecycle)
├── ToolsStore.swift         (@Published activeToolCalls, errors)
├── ToolCallView.swift       (render from ToolCallDisplay)
├── ToolModalView.swift      (moved)
└── ToolCallDisplay.swift    (moved)

// ChatViewModel now delegates:
func executeTool(id: String, name: String, args: String) {
    toolsService.execute(id: id, name: name, args: args) { result in
        // result: ToolsService.Result
    }
}
```

**Fixes included:**
- m-7: ToolExecutor uses SIGKILL escalation after grace period
- m-8: Pipes read concurrently before waitUntilExit

**Benefits:**
- Tool feature is independently testable
- ToolExecutor concerns (SIGKILL, pipe deadlock) isolated
- ChatViewModel is lighter (fewer methods)
- Easier to replace/mock ToolsService for testing
- Clear lifecycle management (service owns ToolExecutor)

**Files Affected:** Refactor `ToolExecutor.swift`, create `ToolsService.swift` and `ToolsStore.swift`  
**Effort:** Medium (requires moving code + ensuring callback chains work)

---

### 5. Replace Notification-Based Command Dispatch with View Composition

**Problem:** m-9 (NotificationCenter listeners are wired but keyboard shortcuts post notifications that aren't handled)

**Current architecture:**
```
App.swift posts .clearChat / .toggleSidebar notifications
    ↓
ContentView.onReceive() listens (but this is fragile — easy to forget)
    ↓
Calls vm.clearChat() / vm.sidebarVisible.toggle()
```

**Issues:**
- Keyboard shortcuts are global, not scoped to views
- Easy to forget `.onReceive` in a view
- Notification names are string-based (typo-prone)
- No clear responsibility flow
- Testing requires mocking NotificationCenter

**Solution:** Use a command-based composition at the App level:

```swift
// Define all commands
protocol AppCommand {
    @MainActor
    func execute(on viewModel: ChatViewModel)
}

struct ClearChatCommand: AppCommand {
    @MainActor
    func execute(on vm: ChatViewModel) { vm.clearChat() }
}

struct ToggleSidebarCommand: AppCommand {
    @MainActor
    func execute(on vm: ChatViewModel) { 
        withAnimation { vm.sidebarVisible.toggle() }
    }
}

// In App.swift — keyboard shortcut directly triggers command
@main
struct OpenRouterFusionApp: App {
    @StateObject private var vm = ChatViewModel()
    
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: vm)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Clear Chat") { ClearChatCommand().execute(on: vm) }
                    .keyboardShortcut("k", modifiers: .command)
                
                Button("Toggle Sidebar") { ToggleSidebarCommand().execute(on: vm) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }
}
```

**Benefits:**
- No NotificationCenter — type-safe, composable
- Commands are testable (inject mock ChatViewModel)
- Keyboard shortcuts are directly wired (no async notification propagation)
- Easy to add/remove commands (no listeners to wire)
- Commands can be reused from multiple UI entry points

**Files Affected:** `App.swift`, `ContentView.swift` (remove .onReceive), create `Commands.swift`  
**Effort:** Low–Medium (straightforward refactor, improves testability)

---

## Summary Table

| Improvement | Addresses | Effort | Impact | Priority |
|-------------|-----------|--------|--------|----------|
| 1. StreamingNetworkActor | C-1, M-1, M-8 | Medium | High | Critical |
| 2. MarkdownService | M-6, M-11 | Low | Medium | High |
| 3. Layered Errors | M-4, M-8 | Low–Med | Medium | High |
| 4. ToolsFeature Module | m-7, m-8, m-10 | Medium | Medium | Medium |
| 5. Command Composition | m-9 | Low–Med | Low–Med | Low |

---

## Implementation Order

1. **First:** Improvement #1 (StreamingNetworkActor) — fixes critical retain cycle and Task cancellation
2. **Then:** Improvement #2 (MarkdownService) — low effort, immediate scroll performance win
3. **Then:** Improvement #3 (Layered Errors) — improves debuggability, unblocks retry logic fix
4. **Parallel:** Improvement #4 (ToolsFeature) — medium effort, good team parallelization
5. **Last:** Improvement #5 (Command Composition) — refactoring, improves testability but not urgent

---

## Testing Recommendations

After implementing each improvement:
- **StreamingNetworkActor:** Unit test concurrent send() calls (should queue, not error)
- **MarkdownService:** Cache hit/miss tests, verify AttributedString parsing
- **Layered Errors:** Test retry logic for 401 vs 5xx, verify error messages in logs
- **ToolsFeature:** Test ToolExecutor with SIGKILL escalation, pipe deadlock scenario
- **Command Composition:** Test keyboard shortcuts → command execution path, mock viewModel

---

## Risk Assessment

| Risk | Mitigation |
|------|-----------|
| Actor reentrant issues | Use @StreamingNetworkActor sparingly; keep send() non-async |
| Markdown cache memory bloat | Implement LRU eviction or max size cap |
| Command composition scope creep | Define command boundaries upfront (no side effects) |
| ToolsFeature refactor breaks tool calls | Maintain identical callback signatures during move |

---

## Conclusion

The current architecture is well-structured and follows MVVM patterns cleanly. The five improvements above address the critical issues identified in REVIEW.md while maintaining the existing code organization. **StreamingNetworkActor** is the highest-priority improvement as it fixes a critical retain cycle and allows proper task cancellation. **MarkdownService** provides immediate performance benefits. Together, these improvements bring the codebase to production-ready quality.
