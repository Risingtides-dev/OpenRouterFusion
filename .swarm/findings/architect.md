# OpenRouterFusion — Architecture Review

**Date:** 2026-06-13
**Reviewer:** OWL (Architect role)
**Scope:** All `.swift` files in `Sources/OpenRouterFusion/`, `Package.swift`, `Resources/`, and build output

---

## 1. Architecture Overview

### File Inventory (10 Swift files)

| File | Lines | Role |
|------|-------|------|
| `App.swift` | ~42 | App entry point, window config, keyboard shortcut commands |
| `ContentView.swift` | ~330 | Main view: sidebar, chat log, composer, messaging, tool execution |
| `ConversationStore.swift` | ~48 | Data model + JSON persistence for chat messages |
| `RouterManager.swift` | ~210 | Networking: SSE streaming, model fallback, HTTP parsing |
| `KeychainHelper.swift` | ~40 | Keychain read/write/delete for API key |
| `ToolExecutor.swift` | ~30 | Shell command execution with timeout |
| `ToolModalView.swift` | ~40 | Modal sheet for manual tool input |
| `ChatMessageView.swift` | ~180 | Chat bubble with avatar, markdown, streaming indicator |
| `StreamingMarkdownView.swift` | ~45 | Progressive markdown rendering (mostly unused) |
| `LRMComponents.swift` | ~290 | Reusable UI: MetalButton, PulsingDots, LRMTextEditor, LRMSecureField, StatusBadge |
| `LRMTheme.swift` | ~120 | Design tokens: Color extensions, gradients, ChamferShape, view modifiers |

### Dependency Graph

```
App.swift
  └── ContentView
        ├── ConversationStore (data + persistence)
        ├── RouterManager (networking + streaming)
        │     └── KeychainHelper (API key)
        ├── ToolExecutor (shell commands)
        ├── ToolModalView (tool UI)
        ├── ChatMessageView (message rendering)
        │     └── LRMComponents (UI primitives)
        ├── StreamingMarkdownView (unused markdown renderer)
        └── LRMTheme (design tokens)
```

---

## 2. Separation of Concerns Analysis

### What's Well-Separated

1. **Theme system is excellent.** `LRMTheme.swift` cleanly isolates all design tokens (colors, gradients, shapes, view modifiers). No view directly hardcodes a color value — everything goes through `Color.lrmAccent`, `LinearGradient.lrmAccentGradient`, etc. This is textbook design-token architecture.

2. **KeychainHelper is a clean wrapper.** Single-responsibility, stateless, no business logic. The `shared` singleton pattern is appropriate for a keychain utility.

3. **ToolExecutor is isolated.** Shell execution is completely separate from UI. The completion-handler API is clean. No UI code leaks in.

4. **ModelConfig.json externalization.** Model routing config is externalized to a JSON file, not hardcoded. This is good — adding/removing models requires zero code changes.

### What's Tangled

1. **ContentView is a 330-line God View.** It owns:
   - Sidebar UI (API key, system prompt, model picker, clear button)
   - Chat log (scroll view, message list, streaming indicator)
   - Composer (text input, send/stop buttons)
   - Empty state (logo, quick-start guide)
   - Messaging logic (`sendMessage()`)
   - Tool execution (`executeTool()`, `runManualTool()`)
   - Keyboard shortcut handling (`clearChatShortcut()`)
   - `ToolCallDisplay` model + `ToolCallIndicator` view
   - `friendlyModelName()` utility function

   This is the single biggest architectural problem. ContentView is simultaneously a view, a view model, a network coordinator, and a tool runner.

2. **Markdown rendering is duplicated.** `ChatMessageView.markdownContent` (lines ~115–128) and `StreamingMarkdownView.renderedText` (lines ~28–35) both parse markdown via `AttributedString(markdown:)` with different options. `StreamingMarkdownView` is defined but never actually used in the view hierarchy — `ChatMessageView` renders its own markdown inline. This is dead code that creates confusion.

3. **RouterManager mixes networking with retry logic.** The `send()` method handles both SSE streaming *and* model fallback orchestration. The `streamRequest()` method handles both HTTP request construction *and* byte-level SSE parsing. These are three distinct responsibilities (request building, SSE parsing, retry orchestration) in two methods.

4. **ConversationStore mixes model and persistence.** `ChatMessage` (the model) is defined inside `ConversationStore.swift` (the persistence layer). The model should be independently importable. Other files that reference `ChatMessage` must import the store, creating a false dependency.

5. **ToolCallDisplay is in ContentView.** This model type and its `ToolCallIndicator` view are defined at the bottom of `ContentView.swift` (lines ~340–380). They're not reusable and should live in their own file or alongside `ToolExecutor`.

---

## 3. Data Flow Analysis

### Current Flow

```
User types message → ContentView.sendMessage()
  → store.append(user message)
  → router.send(messages, systemPrompt, tools,
      onChunk: { currentStreamingContent += chunk },
      onToolCall: { executeTool(...) },
      completion: { store.append(assistant message) }
    )
    → RouterManager.streamRequest(model, messages, ...)
      → URLSession.bytes(for: request)
      → parse SSE chunks byte-by-byte
      → fire onChunk/onToolCall/completion callbacks
  → ContentView.executeTool(id, name, args)
    → ToolExecutor.run("/bin/bash", ["-c", args])
    → store.append(tool result)
```

### Data Flow Problems

1. **No unidirectional data flow.** `ContentView` mutates its own `@State` variables (`currentStreamingContent`, `isStreaming`, `activeToolCalls`) from callbacks fired by `RouterManager`. The store is mutated from multiple places (sendMessage, completion handler, tool execution). There's no single source of truth — `currentStreamingContent` is ephemeral state that duplicates what should be in the store.

2. **Callbacks create tight coupling.** `RouterManager.send()` takes three escaping closures (`onChunk`, `onToolCall`, `completion`) that directly mutate `ContentView`'s state. This makes `RouterManager` impossible to test in isolation and creates a retain cycle risk (confirmed in REVIEW.md C-1).

3. **No async/await pattern.** The entire networking layer uses completion-handler callbacks instead of Swift concurrency (`AsyncSequence`, `async/throw`). This is the older pattern and makes the code harder to reason about, especially with the recursive `tryNext()` fallback logic.

---

## 4. State Management Analysis

### State Ownership

| State | Owner | Type | Problem |
|-------|-------|------|---------|
| `messages` | `ConversationStore` | `@Published` | Correct |
| `modelUsed` | `RouterManager` | `@Published` | Only set after completion, not during streaming |
| `userInput` | `ContentView` | `@State` | Correct |
| `systemPrompt` | `ContentView` | `@State` | Persisted to UserDefaults on every keystroke (REVIEW.md M-12) |
| `isStreaming` | `ContentView` | `@State` | Duplicated — could be derived from store/router state |
| `selectedModel` | `ContentView` | `@State` | Correct |
| `currentStreamingContent` | `ContentView` | `@State` | Ephemeral duplicate of streaming state |
| `activeToolCalls` | `ContentView` | `@State` | Should be in a dedicated tool state |
| `sidebarVisible` | `ContentView` | `@State` | Correct |
| `showingToolModal` | `ContentView` | `@State` | Correct |

### State Management Problems

1. **No centralized state.** There's no `AppState` or `ViewModel` that owns the conversation + streaming + tool state. Everything is split across `ContentView`'s `@State`, `ConversationStore`, and `RouterManager`.

2. **Streaming state is ephemeral.** `currentStreamingContent` lives only in `ContentView.@State`. If the view is recreated (e.g., by a parent re-render), this state is lost. The streaming text should be stored in `ConversationStore` as a "pending assistant message" that gets finalized on completion.

3. **No cancellation state.** `isStreaming` is a boolean that doesn't actually cancel anything. The `Task` inside `RouterManager.streamRequest` has no handle stored, so it can't be cancelled (REVIEW.md M-1).

---

## 5. Networking Layer Analysis

### RouterManager Design

**Strengths:**
- True SSE streaming via `URLSession.bytes(for:)` — the correct modern approach
- Byte-by-line parsing with proper `[DONE]` detection
- Model fallback with configurable retry count
- Thread-safe completion via `NSLock` + `completed` flag
- Tool call streaming support (incremental argument assembly)

**Weaknesses:**
- No `Task` handle stored — impossible to cancel in-flight requests
- No `async/await` — uses completion-handler callbacks throughout
- No request deduplication — rapid sends create concurrent streams
- Non-200 HTTP responses discard the error body (REVIEW.md M-4)
- 401/403 errors trigger full model fallback instead of short-circuiting
- `try!` on JSON decode will crash on malformed config (REVIEW.md M-9)

### API Key Handling

The keychain-first approach is correct, but the UserDefaults fallback in `ContentView.onAppear` (lines ~82–89) is a security concern (REVIEW.md C-3). The key should be purged from UserDefaults after successful keychain migration.

---

## 6. UI Layer Analysis

### View Hierarchy

```
ContentView
├── Sidebar (inline, 260pt)
│   ├── MetalText + LRMSecureField + LRMTextEditor + Picker + MetalButtons
├── ChatArea
│   ├── EmptyState (inline)
│   ├── ChatLog (ScrollView + LazyVStack)
│   │   ├── ChatMessageView (per message)
│   │   │   ├── Avatar (circle)
│   │   │   ├── Bubble (markdown via AttributedString)
│   │   │   └── StatusBadge
│   │   ├── ToolCallIndicator (per active tool)
│   │   └── ChatMessageView (streaming, id="streaming")
│   └── Composer (inline)
│       ├── TextEditor + placeholder
│       └── MetalButton (Send/Stop)
```

### UI Strengths

1. **LRM design system is cohesive.** Every visual element uses the theme tokens. The ChamferShape, gradients, and color palette create a distinctive identity.

2. **LazyVStack for chat log.** Correct choice for a potentially long list of messages — only visible messages are rendered.

3. **ScrollViewReader for auto-scroll.** Proper use of `proxy.scrollTo()` with animation for new messages and streaming content.

4. **Custom components are reusable.** `MetalButton`, `LRMTextEditor`, `LRMSecureField`, `StatusBadge`, and `PulsingDots` are well-designed, parameterized components.

### UI Weaknesses

1. **ContentView is not decomposable.** The sidebar, chat log, composer, and empty state are all inline computed properties. They should be separate `View` structs.

2. **No accessibility.** Zero `.accessibilityLabel`, `.accessibilityHint`, or `@ScaledMetric` usage anywhere (REVIEW.md m-1, m-2, m-3).

3. **Keyboard shortcuts don't work.** `.onReceive` observers for `.clearChat` and `.toggleSidebar` notifications are never registered (REVIEW.md m-9).

4. **TextEditor newline/submit conflict.** `.onSubmit` on `TextEditor` doesn't properly distinguish Enter vs Shift+Enter (REVIEW.md C-2).

5. **Markdown parsing in view body.** `ChatMessageView.markdownContent` parses `AttributedString(markdown:)` inside a `@ViewBuilder`, re-executing on every render (REVIEW.md M-6).

---

## 7. Structural Improvement Proposals

### Improvement 1: Decompose ContentView into Focused Subviews

**Problem:** `ContentView.swift` is a 330-line God View that owns sidebar, chat log, composer, empty state, messaging logic, tool execution, keyboard shortcuts, and the `ToolCallIndicator` view. It's untestable, unreadable, and violates single-responsibility.

**Solution:** Extract into focused subviews and a dedicated view model:

```
Sources/OpenRouterFusion/
├── ContentView.swift              (thin coordinator, ~80 lines)
├── SidebarView.swift              (API key, system prompt, model picker, clear)
├── ChatLogView.swift              (scroll view, messages, streaming, tool indicators)
├── ComposerView.swift             (text input, send/stop buttons)
├── EmptyStateView.swift           (logo, quick-start guide)
├── ToolCallIndicatorView.swift    (move ToolCallDisplay + ToolCallIndicator here)
└── Utilities/
    └── ModelNamer.swift           (move friendlyModelName here)
```

**Files changed:**
- `ContentView.swift` — reduced from ~330 to ~80 lines, owns only subview composition and keyboard shortcut observers
- `SidebarView.swift` — new, owns all sidebar UI and state bindings
- `ChatLogView.swift` — new, owns scroll view, message list, streaming indicator, tool indicators
- `ComposerView.swift` — new, owns text input + send/stop with `onSend` callback
- `EmptyStateView.swift` — new, owns empty state presentation
- `ToolCallIndicatorView.swift` — new, moved from bottom of ContentView
- `Utilities/ModelNamer.swift` — new, moved from ContentView free function

**Impact:** HIGH. This is the single most impactful structural change. It makes every view independently testable, readable, and modifiable. It also eliminates the need for `ToolCallDisplay` to live in ContentView.

---

### Improvement 2: Introduce a ChatViewModel to Coordinate State

**Problem:** State is scattered across `ContentView.@State`, `ConversationStore.@Published`, and `RouterManager.@Published`. Callbacks from `RouterManager` directly mutate `ContentView` state, creating tight coupling and retain cycle risks. Streaming text (`currentStreamingContent`) is ephemeral view state that can be lost.

**Solution:** Create an `ChatViewModel: ObservableObject` that owns all chat coordination:

```swift
@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage]        // from ConversationStore
    @Published var isStreaming: Bool = false
    @Published var streamingContent: String = ""   // persisted, not ephemeral
    @Published var activeToolCalls: [ToolCallDisplay] = []
    @Published var modelUsed: String = ""

    private let store: ConversationStore
    private let router: RouterManager

    func sendMessage(_ text: String, systemPrompt: String) async { ... }
    func cancelStreaming() async { ... }
    func clearChat() { ... }
    func executeTool(command: String) async { ... }
}
```

Key changes:
- `ChatViewModel` owns the `sendMessage` logic currently in `ContentView`
- `RouterManager` uses `AsyncSequence`/async-await instead of callbacks — the view model iterates the stream
- `streamingContent` is owned by the view model, not by the view's `@State`
- `cancelStreaming()` cancels the underlying `Task` handle stored in `RouterManager`

**Files changed:**
- `ChatViewModel.swift` — new, ~150 lines, owns all chat coordination
- `ContentView.swift` — becomes a thin view that reads from `ChatViewModel`
- `RouterManager.swift` — replace callback-based `send()` with `async throws` streaming method returning `AsyncThrowingStream<StreamEvent, Error>`
- `ConversationStore.swift` — unchanged, used by view model

**Impact:** HIGH. This eliminates the callback-based coupling, makes the streaming state persistent, enables proper cancellation, and makes the chat logic independently testable.

---

### Improvement 3: Extract ChatMessage into an Independent Model File

**Problem:** `ChatMessage` (the core data model) is defined inside `ConversationStore.swift` (the persistence layer). Any file that needs to reference `ChatMessage` must import the store, creating a false dependency. The model can't be imported without also importing persistence logic.

**Solution:** Move `ChatMessage` and its `Role` enum to a standalone file:

```swift
// Models/ChatMessage.swift
struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    var role: Role
    var content: String
    var modelUsed: String?
    enum Role: String, Codable { case user, assistant }
}
```

Update `ConversationStore.swift` to import and use the model from the new file. Add new model files as needed:

```
Sources/OpenRouterFusion/Models/
├── ChatMessage.swift              (moved from ConversationStore.swift)
├── ToolCallDisplay.swift          (moved from ContentView.swift)
└── StreamEvent.swift              (new: .chunk(String), .toolCall(id:name:args), .done)
```

**Files changed:**
- `Models/ChatMessage.swift` — new, moved from `ConversationStore.swift`
- `Models/ToolCallDisplay.swift` — new, moved from `ContentView.swift`
- `Models/StreamEvent.swift` — new, enum for streaming events
- `ConversationStore.swift` — remove `ChatMessage` definition, import from Models
- `ContentView.swift` — import `ToolCallDisplay` from Models
- `ChatMessageView.swift` — import `ChatMessage` from Models

**Impact:** MEDIUM. This is a foundational cleanup that makes the dependency graph correct. It enables the view model extraction (Improvement 2) and makes models independently testable.

---

### Improvement 4: Replace Callback-Based Streaming with AsyncSequence

**Problem:** `RouterManager.send()` takes three escaping closures (`onChunk`, `onToolCall`, `completion`) that create tight coupling with `ContentView`, prevent cancellation, and make the code harder to reason about. The recursive `tryNext()` fallback logic is especially difficult to follow with completion handlers.

**Solution:** Replace with `AsyncThrowingStream`:

```swift
// RouterManager.swift
enum StreamEvent {
    case chunk(String)
    case toolCall(id: String, name: String, arguments: String)
    case done
}

func stream(
    messages: [[String: Any]],
    systemPrompt: String?,
    tools: [[String: Any]]?
) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            // ... existing streaming logic ...
            // Call continuation.yield(.chunk(text)) instead of onChunk
            // Call continuation.finish() instead of completion
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

// ChatViewModel.swift
func sendMessage(_ text: String) async {
    let stream = router.stream(messages: ..., systemPrompt: ..., tools: ...)
    for try await event in stream {
        switch event {
        case .chunk(let text): streamingContent += text
        case .toolCall(let id, let name, let args): ...
        case .done: ...
        }
    }
}
```

**Files changed:**
- `RouterManager.swift` — replace `send()` with `stream()`, remove callback parameters, return `AsyncThrowingStream<StreamEvent, Error>`
- `RouterManager.swift` — store `Task` handle for cancellation, add `cancel()` method
- `ChatViewModel.swift` — iterate stream with `for try await` instead of callbacks
- `ContentView.swift` — remove all callback-based coordination

**Impact:** HIGH. This is the modern Swift concurrency pattern. It eliminates retain cycles, enables structured cancellation, makes the code linear and readable, and is the prerequisite for proper stop/cancel behavior.

---

### Improvement 5: Consolidate Markdown Rendering into a Single Component

**Problem:** `StreamingMarkdownView` (45 lines) is defined but never used in the view hierarchy. `ChatMessageView` has its own inline markdown parsing in the `markdownContent` computed property (lines ~115–128) that uses different `AttributedString.MarkdownParsingOptions`. Two implementations of the same concern with different behavior — one dead, one potentially slow (parsed on every `body` evaluation).

**Solution:** Make `StreamingMarkdownView` the single markdown renderer, fix its options, and use it everywhere:

```swift
// StreamingMarkdownView.swift — the ONE markdown renderer
struct MarkdownView: View {
    let content: String
    var isStreaming: Bool = false

    var body: some View {
        if content.isEmpty && isStreaming {
            streamingIndicator
        } else {
            Text(parsedMarkdown)
                .textSelection(.enabled)
        }
    }

    private var parsedMarkdown: AttributedString {
        // Single parsing logic, consistent options
        do {
            var options = AttributedString.MarkdownParsingOptions()
            options.allowsExtendedAttributes = true
            var result = try AttributedString(markdown: content, options: options)
            result.foregroundColor = Color.lrmText
            return result
        } catch {
            var fallback = AttributedString(content)
            fallback.foregroundColor = Color.lrmText
            return fallback
        }
    }
}
```

Use it in `ChatMessageView` (replacing the inline `markdownContent` computed property) and remove the duplicate parsing.

**Files changed:**
- `StreamingMarkdownView.swift` — rename to `MarkdownView`, add `isStreaming` parameter, use consistent options
- `ChatMessageView.swift` — replace inline `markdownContent` with `MarkdownView(content: message.content, isStreaming: isStreaming)`
- Remove the duplicate `AttributedString(markdown:)` parsing from `ChatMessageView`

**Impact:** MEDIUM. Eliminates dead code, ensures consistent markdown rendering across the app, and fixes the performance issue of re-parsing markdown on every view body evaluation.

---

## 8. Additional Feature Recommendations

### Conversation History / Multi-Session Support
**Priority:** HIGH
Currently there's a single `conversation.json`. Add a `ConversationList` view that shows past sessions, allows creating new conversations, and switching between them. Store each session as `conversations/{uuid}.json` in Application Support.

### Search
**Priority:** MEDIUM
Add a search bar that filters messages by content. With `ConversationStore` owning the messages, this is a simple `filter` operation. For large conversations, consider indexing with `NSPredicate` or a lightweight full-text index.

### Export
**Priority:** MEDIUM
Add export to Markdown, PDF, and plain text. This is straightforward with the existing `ChatMessage` model — iterate messages and format. Use `NSSharingService` for native share sheet integration.

### SwiftUI Performance Wins
**Priority:** MEDIUM
1. **Fix `onChange` with `ScrollViewReader`.** The current `onChange(of: store.messages.count)` and `onChange(of: currentStreamingContent)` both trigger `proxy.scrollTo()` with animation. During streaming, this fires for *every token*, causing layout thrashing. Throttle to at most once per 100ms.
2. **Cache parsed markdown.** Store the `AttributedString` result in a cache keyed by content hash to avoid re-parsing unchanged messages during scroll.
3. **Use `EquatableView` for chat bubbles.** Prevent unnecessary re-rendering of messages that haven't changed by conforming `ChatMessageView` to `Equatable`.
4. **Fix PulsingDots timer.** Replace `Timer.publish(autoconnect())` with `withAnimation(.repeatForever())` in `.onAppear` to eliminate the timer leak (REVIEW.md M-2).

---

## 9. Proposed Final File Structure

```
Sources/OpenRouterFusion/
├── App.swift                          (unchanged, ~42 lines)
├── ContentView.swift                  (thin coordinator, ~80 lines)
│
├── ViewModels/
│   └── ChatViewModel.swift            (NEW: coordinates chat state, ~150 lines)
│
├── Views/
│   ├── SidebarView.swift              (NEW: sidebar UI, ~120 lines)
│   ├── ChatLogView.swift              (NEW: message list, ~100 lines)
│   ├── ComposerView.swift             (NEW: text input + send, ~80 lines)
│   ├── EmptyStateView.swift           (NEW: welcome screen, ~60 lines)
│   ├── ToolCallIndicatorView.swift    (NEW: moved from ContentView, ~40 lines)
│   └── ToolModalView.swift            (unchanged, ~40 lines)
│
├── Models/
│   ├── ChatMessage.swift              (MOVED from ConversationStore.swift)
│   ├── ToolCallDisplay.swift          (MOVED from ContentView.swift)
│   └── StreamEvent.swift              (NEW: .chunk, .toolCall, .done)
│
├── Services/
│   ├── RouterManager.swift            (REFACTORED: async streaming, ~200 lines)
│   ├── ConversationStore.swift        (CLEANED: persistence only, ~35 lines)
│   ├── ToolExecutor.swift             (unchanged, ~30 lines)
│   └── KeychainHelper.swift           (unchanged, ~40 lines)
│
├── UI/
│   ├── LRMTheme.swift                 (unchanged, ~120 lines)
│   ├── LRMComponents.swift            (unchanged, ~290 lines)
│   ├── ChatMessageView.swift          (SIMPLIFIED: uses MarkdownView, ~120 lines)
│   └── MarkdownView.swift             (RENAMED from StreamingMarkdownView, ~50 lines)
│
└── Utilities/
    └── ModelNamer.swift               (MOVED from ContentView, ~30 lines)
```

**Total:** 18 files (up from 10), but each file is focused, under 200 lines, and independently testable.

---

## 10. Summary of Architectural Health

| Dimension | Rating | Notes |
|-----------|--------|-------|
| **File Organization** | ⚠️ Fair | All 10 files in a single flat directory. No grouping by role (Models/Services/Views). |
| **Separation of Concerns** | ⚠️ Fair | Theme system is excellent. ContentView is a God View. Networking mixes retry + streaming + parsing. |
| **Data Flow** | ⚠️ Fair | Callback-based, bidirectional, no unidirectional pattern. Ephemeral streaming state. |
| **State Management** | ⚠️ Weak | Scattered across 3 owners. No centralized view model. No cancellation support. |
| **Networking** | ✅ Good | True SSE streaming, byte-level parsing, model fallback. Needs async/await and cancellation. |
| **UI Layer** | ✅ Good | Cohesive design system, reusable components, proper LazyVStack. Needs decomposition. |
| **Testability** | ⚠️ Weak | No unit-testable view models. Free functions. Tight coupling via callbacks. |
| **Accessibility** | ❌ Missing | Zero accessibility labels, no Dynamic Type, color-only indicators. |
| **Security** | ⚠️ Fair | Keychain is correct. UserDefaults fallback is a concern. Tool execution is unsanitized. |
| **Performance** | ⚠️ Fair | Timer leak, markdown re-parsing, main-thread saves, scroll thrashing during streaming. |

**Overall:** The app has a solid foundation — the LRM design system is excellent, the SSE streaming is well-implemented, and the model fallback pattern is smart. The primary architectural debt is the God View (ContentView), callback-based coupling, and lack of a view model layer. The five improvements above, applied in order, would transform this from a prototype into a well-architected macOS app.
