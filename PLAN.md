# OpenRouterFusion — LRM SwiftUI Build Plan

## Goal
Build a native SwiftUI macOS chat app with Liquid Razor Metal UI. The gpt-oss-120b foundation is in place (RouterManager, ConversationStore, KeychainHelper, ToolExecutor, ToolModalView). Now we need to replace the basic SwiftUI UI with full LRM aesthetic and restore true streaming.

## Current State
- `Package.swift` — Swift 5.9, macOS 13, executable
- `App.swift` — minimal SwiftUI App
- `ContentView.swift` — basic sidebar+chat, WebView fallback, MetalButtonStyle
- `RouterManager.swift` — uses dataTask (non-streaming), needs async streaming
- `ConversationStore.swift` — JSON persistence, ChatMessage has role+content
- `KeychainHelper.swift` — Keychain wrapper
- `ToolExecutor.swift` — shell command runner
- `ToolModalView.swift` — basic tool modal
- `Resources/ModelConfig.json` — all free models
- `Resources/openrtr-owl/index.html` — LRM HTML reference

## LRM Design Tokens (from liquid-razor-metal-ui CSS)

### Colors
```
--lrm-bg:           #0b0d10  (red:0.043 green:0.051 blue:0.063)
--lrm-bg-2:         #0c1118  (red:0.047 green:0.067 blue:0.094)
--lrm-surface:      rgba(19,22,26,0.72)
--lrm-surface-strong: rgba(20,26,34,0.88)
--lrm-text:         #c0c6cc  (red:0.753 green:0.776 blue:0.800)
--lrm-text-strong:  #eef3f7  (red:0.933 green:0.953 blue:0.969)
--lrm-muted:        #687178  (red:0.408 green:0.443 blue:0.471)
--lrm-border:       rgba(192,198,204,0.12)
--lrm-border-strong:rgba(192,198,204,0.28)
--lrm-accent:       #8a84ff  (red:0.541 green:0.518 blue:1.0)
--lrm-metal:        #d8e0e8  (red:0.847 green:0.878 blue:0.910)
--lrm-metal-mid:    #8b949e  (red:0.545 green:0.580 blue:0.620)
--lrm-metal-dark:   #303845  (red:0.188 green:0.220 blue:0.271)
--lrm-danger:       #fb7185  (red:0.984 green:0.443 blue:0.510)
```

### Chamfer Shape (replaces CSS clip-path)
```swift
struct ChamferShape: Shape {
    let cornerSize: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = min(cornerSize, min(rect.width, rect.height) / 2)
        p.move(to: CGPoint(x: c, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - c))
        p.addLine(to: CGPoint(x: rect.maxX - c, y: rect.maxY))
        p.addLine(to: CGPoint(x: 0, y: rect.maxY))
        p.addLine(to: CGPoint(x: 0, y: c))
        p.closeSubpath()
        return p
    }
}
```

## Files to CREATE

### 1. LRMTheme.swift
- All Color extensions
- ChamferShape
- View modifiers: `.liquidSurface()`, `.metalSurface()`, `.lrmBorder()`
- Gradient definitions

### 2. LRMComponents.swift
- `MetalButton` — ButtonStyle with gradient, chamfer, hover sweep
- `LiquidPanel` — View wrapper with liquid surface
- `StatusBadge` — Small pill for model name / streaming
- `LRMTextEditor` — Styled TextEditor
- `LRMSecureField` — Styled SecureField

### 3. ChatMessageView.swift
- Single chat bubble with LRM styling
- Avatar circle (user=blue gradient, assistant=accent gradient)
- Bubble: liquid surface for user, metal panel for assistant
- Model badge below assistant bubbles
- Markdown rendering via AttributedString

### 4. StreamingMarkdownView.swift
- Progressive markdown rendering
- "Thinking…" pulsing animation when empty

## Files to MODIFY

### 5. ContentView.swift — Complete rewrite
- Remove WebChatView, useEmbeddedWeb toggle
- LRM sidebar with LiquidPanel
- Native chat log with ChatMessageView
- LRM-styled composer
- Model picker from RouterManager.config

### 6. RouterManager.swift — Restore streaming
- Replace dataTask with URLSession.bytes(for:) async streaming
- Parse SSE chunks in real-time
- Track which model actually responded
- Send streaming callbacks to ContentView

### 7. ConversationStore.swift — Add model tracking
- Add `modelUsed: String?` to ChatMessage
- Add `activeModel: String` tracking

### 8. App.swift — Polish
- Add `.windowStyle(.hiddenTitleBar)` for native feel
- Set default window size

### 9. Package.swift — Bump to macOS 14
- Needed for better SwiftUI features

## Files to KEEP (no changes)
- KeychainHelper.swift
- ToolExecutor.swift
- ToolModalView.swift (minor LRM styling only)
- Resources/ModelConfig.json

## Build Script
Create `build-app.sh` at project root (reference floating-terminal pattern)

## View Hierarchy
```
OpenRouterFusionApp
└── ContentView (LRM background)
    ├── Sidebar (LiquidPanel, 280pt)
    │   ├── "API KEY" label (MetalText)
    │   ├── LRMSecureField
    │   ├── "SYSTEM PROMPT" label
    │   ├── LRMTextEditor
    │   ├── "MODEL" label
    │   ├── Model Picker
    │   ├── MetalButton("Run Tool…", .metal)
    │   ├── Spacer
    │   └── MetalButton("Clear Chat", .ghost)
    └── ChatArea
        ├── ScrollView + LazyVStack
        │   └── ChatMessageView per message
        │       ├── Avatar (circle, gradient)
        │       ├── VStack(bubble + modelBadge)
        │       └── StreamingMarkdownView
        └── Composer (LiquidPanel)
            ├── LRMTextEditor (auto-grow)
            └── HStack { Send/Stop buttons }
```

## Acceptance Criteria
1. `swift build` — zero errors
2. App launches with LRM dark gunmetal background
3. Sidebar: API key, system prompt, model picker, clear chat, run tool
4. Chat: native streaming (tokens appear progressively)
5. Model badge shows which model responded
6. Markdown renders (bold, code, lists)
7. `bash build-app.sh` produces working `.app`
