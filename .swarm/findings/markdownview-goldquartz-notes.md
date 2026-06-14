# MarkdownView Integration Notes — GoldQuartz

**Date:** 2026-06-14  
**Status:** Reverted — YoungLion taking over task-35

## What I Did

1. Added `LiYanan2004/MarkdownView` (from: "2.0.0") to Package.swift as a dependency
2. Replaced `AttributedString(markdown:)` parsing in ChatMessageView with `MarkdownView(message.content)`
3. Build fetched all dependencies successfully (resolved at 2.7.0)

## What Failed

My initial API usage was wrong. I assumed standard SwiftUI modifiers work directly on `MarkdownView`:
```swift
MarkdownView(message.content)
    .textColor(Color.lrmText)        // ❌ doesn't exist
    .font(.system(size: 14))         // ❌ not a standard View modifier
    .markdownStyle(.init(theme: ...)) // ❌ wrong API
```

## Correct API (from source inspection)

`MarkdownView` uses **environment-based configuration**, not chained modifiers:

- `@Environment(\.markdownRendererConfiguration)` — main config
- `@Environment(\.markdownElementRenderers)` — custom element renderers
- `@Environment(\.markdownViewStyle)` — view style
- `@Environment(\.markdownFontGroup.body)` — font group

### Styling approach:
```swift
// Font group
MarkdownView(content)
    .markdownFontGroup(.lrmCustom)  // custom MarkdownFontGroup

// Foreground colors
    .markdownForegroundStyle(.lrmColors)  // custom ForegroundStyleGroup

// Code block style
    .markdownCodeBlockStyle(.default)  // or custom

// Block quote style  
    .markdownBlockQuoteStyle(.default)  // or custom

// Table style
    .markdownTableStyle(.default)  // or GithubMarkdownTableStyle
```

### Key types to implement for LRM theme:
- `MarkdownFontGroup` protocol — defines heading, body, code, link fonts
- `MarkdownForegroundStyleGroup` protocol — defines text colors per element
- `MarkdownCodeBlockStyle` protocol — code block background/border
- `MarkdownBlockQuoteStyle` protocol — quote bar color/background

## Streaming Behavior

MarkdownView 2.x renders on the **main thread** to avoid blinking (per release notes). This is good for streaming — content updates should be smooth. However, for very long responses, there may be performance concerns with full re-render on each chunk.

**Recommendation:** Keep a plain `Text()` fallback for the streaming placeholder (when content is still accumulating), and switch to MarkdownView once the message is finalized. This avoids re-parsing partial markdown on every token.

## Dependencies Pulled In

MarkdownView 2.7.0 pulls in:
- `swift-markdown` 0.8.0 (Apple's swiftlang parser)
- `swift-cmark` 0.8.0 (C markdown parser)
- `SwiftDraw` 0.27.0 (SVG rendering)
- `MathJaxSwift` 3.5.0 (LaTeX math)
- `LaTeXSwiftUI` 1.5.0 (math rendering)
- `Highlightr` 2.3.0 (code syntax highlighting)
- `HTMLEntities` 4.0.1

**Note:** This is a heavy dependency tree. If the team wants lighter weight, consider using `swift-markdown` directly with a custom AST→SwiftUI renderer.

## Files Modified (now reverted)

- `Package.swift` — added MarkdownView dependency
- `Sources/OpenRouterFusion/ChatMessageView.swift` — replaced AttributedString with MarkdownView

## Build Status

Build fetched dependencies successfully but failed at compilation due to wrong API usage. All errors were in ChatMessageView.swift — the rest of the project compiled fine.
