# OpenRouterFusion — Implementation Plan

## Goal
Transform the gpt-oss-120b foundation into a polished native SwiftUI macOS chat app with Liquid Razor Metal UI aesthetic. Fix all compile errors. Build a `.app` bundle.

## Architecture

```
OpenRouterFusionApp (App.swift)
└── ContentView — Split view: Sidebar + ChatArea
    ├── Sidebar (LiquidPanel)
    │   ├── API Key (Keychain via SecureField)
    │   ├── System Prompt (TextEditor)
    │   ├── Model Picker (Picker from RouterManager.config)
    │   ├── Clear Chat (MetalButton ghost)
    │   └── Run Tool (MetalButton metal → opens ToolModalView)
    └── ChatArea
        ├── ChatLog (ScrollView + LazyVStack)
        │   └── ChatMessageView per message
        │       ├── ModelBadge (shows which model responded)
        │       ├── MarkdownText (AttributedString rendering)
        │       └── LRM bubble (user: blue gradient, assistant: liquid surface)
        └── Composer
            ├── TextEditor (LRM styled, auto-grow)
            └── Send/Stop (MetalButton primary)
```

## LRM Color Tokens → SwiftUI

```swift
extension Color {
    static let lrmBackground    = Color(red: 0.043, green: 0.051, blue: 0.063)   // #0b0d10
    static let lrmBackground2   = Color(red: 0.047, green: 0.067, blue: 0.094)   // #0c1118
    static let lrmSurface       = Color(red: 0.075, green: 0.086, blue: 0.102).opacity(0.72)
    static let lrmSurfaceStrong = Color(red: 0.078, green: 0.102, blue: 0.133).opacity(0.88)
    static let lrmText          = Color(red: 0.753, green: 0.776, blue: 0.800)   // #c0c6cc
    static let lrmTextStrong    = Color(red: 0.933, green: 0.953, blue: 0.969)   // #eef3f7
    static let lrmMuted         = Color(red: 0.408, green: 0.443, blue: 0.471)   // #687178
    static let lrmBorder        = Color(red: 0.753, green: 0.776, blue: 0.800).opacity(0.12)
    static let lrmBorderStrong  = Color(red: 0.753, green: 0.776, blue: 0.800).opacity(0.28)
    static let lrmAccent        = Color(red: 0.541, green: 0.518, blue: 1.0)     // #8a84ff
    static let lrmMetal         = Color(red: 0.847, green: 0.878, blue: 0.910)   // #d8e0e8
    static let lrmMetalMid      = Color(red: 0.545, green: 0.580, blue: 0.620)   // #8b949e
    static let lrmMetalDark     = Color(red: 0.188, green: 0.220, blue: 0.271)   // #303845
    static let lrmDanger        = Color(red: 0.984, green: 0.443, blue: 0.510)   // #fb7185
}
```

## Chamfer Shape (replaces CSS clip-path)

```swift
struct ChamferShape: Shape {
    let cornerSize: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = cornerSize
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

## Files to MODIFY

### Package.swift
- Fix: remove `.process("Resources")` since we only have JSON, use `.copy` or just bundle it
- Bump to macOS 14 for better SwiftUI support

### RouterManager.swift
- **Fix compile error**: Replace `URLSession.shared.streamTask(with: request)` with `URLSession.shared.data(for: request)` + manual SSE line parsing on the response data, OR use `URLSession` with `async/await` and `URLSession.bytes(for:)` for true streaming
- Recommended: Use `URLSession.bytes(for:)` with AsyncSequence for real streaming
- Add `modelUsed` tracking so we know which model actually responded

### ConversationStore.swift
- Add `modelUsed: String?` field to `ChatMessage`
- Add `activeModel: String` tracking

### ContentView.swift
- Complete rewrite with LRM UI
- Remove `WebChatView` (no more WebView embedding)
- Add native `ChatLog` with `LazyVStack`
- Add `ToolModalView` sheet

### App.swift
- Keep minimal, add `.windowStyle(.hiddenTitleBar)` for native macOS feel

## Files to CREATE

### LRMTheme.swift
- All Color extensions (above)
- ChamferShape (above)
- View modifiers: `.liquidSurface()`, `.metalSurface()`, `.lrmBorder()`
- Gradient definitions: `lrmLiquidGradient`, `lrmMetalGradient`, `lrmAccentGradient`

### LRMComponents.swift
- `MetalButton` — ButtonStyle with gradient background, chamfer clip, sweep animation on hover
- `LiquidPanel` — View wrapper with liquid surface treatment
- `MetalText` — Uppercase, letter-spaced, weight 850+ text style
- `StatusBadge` — Small pill badge for model name / streaming status
- `LRMTextField` — Styled TextField with LRM colors
- `LRMTextEditor` — Styled TextEditor with LRM colors

### ChatMessageView.swift
- Single chat bubble view
- Props: `message: ChatMessage`, `isStreaming: Bool`
- Layout: HStack with avatar + bubble
- Avatar: Circle with first letter, gradient background (user=blue, assistant=accent)
- Bubble: Liquid surface for user, metal/liquid panel for assistant
- Model badge: Small `StatusBadge` showing model name below assistant bubbles
- Markdown rendering via `AttributedString(markdown:)` on macOS 13+

### StreamingMarkdownView.swift
- Takes `@State var rawText: String`
- Renders as `Text(try! AttributedString(markdown: rawText))`
- Shows "Thinking…" with pulsing animation when empty

### ToolModalView.swift
- Modal sheet with command input + run button + output display
- LRM styled

## Build Script (build-app.sh)
Reference: `/Users/risingtidesdev/dev/floating-terminal/build-app.sh`
- `swift build -c release`
- Assemble `OpenRouterFusion.app` bundle
- Copy binary, Info.plist, ad-hoc codesign

## Acceptance Criteria
1. `swift build` compiles with zero errors
2. App launches with LRM dark gunmetal background
3. Sidebar shows API key field, system prompt, model picker, clear chat
4. Chat area shows messages with LRM-styled bubbles
5. Streaming works: tokens appear progressively in assistant bubbles
6. Model badge shows which model responded
7. Markdown renders (bold, code, lists, headers)
8. `bash build-app.sh` produces a working `OpenRouterFusion.app`
