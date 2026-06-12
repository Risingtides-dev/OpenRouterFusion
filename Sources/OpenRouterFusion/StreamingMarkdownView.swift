import SwiftUI

/// Progressive markdown rendering view.
/// Displays content as it streams in, with a pulsing "Thinking…" indicator when empty.
struct StreamingMarkdownView: View {
    let content: String

    var body: some View {
        if content.isEmpty {
            HStack(spacing: 6) {
                PulsingDots()
                Text("Thinking…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.lrmMuted)
            }
        } else {
            // Basic markdown rendering via AttributedString
            Text(renderedText)
                .font(.system(size: 14))
                .foregroundColor(.lrmText)
                .textSelection(.enabled)
        }
    }

    private var renderedText: AttributedString {
        // Attempt markdown parsing; fall back to plain text
        do {
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .inlineOnlyPreservingWhitespace
            return try AttributedString(markdown: content, options: options)
        } catch {
            return AttributedString(content)
        }
    }
}
