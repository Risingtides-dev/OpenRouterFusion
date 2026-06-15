import SwiftUI

// MARK: - Content Segments

/// A parsed segment of message content: either prose text or a fenced code block.
enum ContentSegment: Identifiable {
    case text(String)
    case codeBlock(language: String?, code: String, isComplete: Bool)

    var id: String {
        switch self {
        case .text(let t): return "text-\(t.hashValue)"
        case .codeBlock(_, let c, _): return "code-\(c.hashValue)"
        }
    }
}

/// Parses markdown content into text and code block segments.
func parseContentSegments(_ content: String) -> [ContentSegment] {
    var segments: [ContentSegment] = []
    var currentText = ""
    let lines = content.components(separatedBy: "\n")
    var inCodeBlock = false
    var codeLanguage: String? = nil
    var codeLines: [String] = []

    for line in lines {
        if !inCodeBlock {
            if line.hasPrefix("```") {
                // Start of code block
                if !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.text(currentText))
                    currentText = ""
                }
                let lang = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                codeLanguage = lang.isEmpty ? nil : lang
                codeLines = []
                inCodeBlock = true
            } else {
                currentText += line + "\n"
            }
        } else {
            if line == "```" || line == "```\r" {
                // End of code block
                let code = codeLines.joined(separator: "\n")
                segments.append(.codeBlock(language: codeLanguage, code: code, isComplete: true))
                inCodeBlock = false
                codeLanguage = nil
                codeLines = []
            } else {
                codeLines.append(line)
            }
        }
    }

    // Flush remaining content
    if inCodeBlock {
        // Unclosed code block (still streaming or truncated)
        let code = codeLines.joined(separator: "\n")
        segments.append(.codeBlock(language: codeLanguage, code: code, isComplete: false))
    } else if !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        segments.append(.text(currentText))
    }

    return segments
}

// MARK: - ChatMessageView

struct ChatMessageView: View {
    let message: ChatMessage
    var isStreaming: Bool = false
    var onPreviewHTML: ((String) -> Void)? = nil

    @State private var cachedSegments: [ContentSegment] = []
    @State private var lastParsedContent: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .assistant {
                avatarView
            } else {
                Spacer().frame(width: 32)
            }

            bubbleContent

            if message.role == .user {
                avatarView
            } else {
                Spacer().frame(width: 32)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .onAppear {
            if message.role == .assistant {
                cachedSegments = parseContentSegments(message.content)
                lastParsedContent = message.content
            }
        }
        .onChange(of: message.content) { _, newContent in
            if message.role == .assistant && newContent != lastParsedContent {
                cachedSegments = parseContentSegments(newContent)
                lastParsedContent = newContent
            }
        }
    }

    // MARK: Avatar

    @ViewBuilder
    private var avatarView: some View {
        Text(initials)
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .frame(width: 32, height: 32)
            .background(Circle().fill(avatarGradient))
            .overlay(Circle().stroke(Color.lrmBorderStrong, lineWidth: 0.5))
            .accessibilityLabel(message.role == .user ? "User avatar" : "Assistant avatar")
            .accessibilityHidden(true)
    }

    private var initials: String {
        switch message.role {
        case .user: return "U"
        case .assistant:
            if let model = message.modelUsed, !model.isEmpty {
                return String(model.prefix(1)).uppercased()
            }
            return "A"
        }
    }

    private var avatarGradient: LinearGradient {
        switch message.role {
        case .user: return LinearGradient.lrmUserGradient
        case .assistant: return LinearGradient.lrmAssistantGradient
        }
    }

    // MARK: Bubble Content

    @ViewBuilder
    private var bubbleContent: some View {
        if message.role == .user {
            userBubble
        } else {
            assistantBubble
        }
    }

    // MARK: User Bubble

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(message.content)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    LinearGradient.lrmUserGradient
                        .clipShape(ChamferShape(cornerSize: 10))
                )
                .overlay(
                    ChamferShape(cornerSize: 10)
                        .stroke(Color.lrmBorder, lineWidth: 0.5)
                )
                .clipShape(ChamferShape(cornerSize: 10))
        }
        .frame(minWidth: 60, maxWidth: 720, alignment: .trailing)
    }

    // MARK: Assistant Bubble

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if message.content.isEmpty && isStreaming {
                streamingIndicator
            } else {
                richContent
            }

            if let model = message.modelUsed, !model.isEmpty {
                StatusBadge(model, isStreaming: isStreaming && message.content.isEmpty)
            }
        }
        .frame(minWidth: 60, maxWidth: 720, alignment: .leading)
    }

    // MARK: - Rich Content (segmented rendering)

    @ViewBuilder
    private var richContent: some View {
        let segments = cachedSegments.isEmpty ? parseContentSegments(message.content) : cachedSegments

        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    Text(parseMarkdown(text))
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            ZStack {
                                LinearGradient.lrmBackgroundRadial
                                RadialGradient(
                                    colors: [Color.lrmAccent.opacity(0.05), .clear],
                                    center: .topLeading,
                                    startRadius: 0,
                                    endRadius: 200
                                )
                            }
                            .clipShape(ChamferShape(cornerSize: 10))
                        )
                        .overlay(
                            ChamferShape(cornerSize: 10)
                                .stroke(Color.lrmBorder, lineWidth: 0.5)
                        )
                        .clipShape(ChamferShape(cornerSize: 10))

                case .codeBlock(let language, let code, let isComplete):
                    CodeBlockView(
                        language: language,
                        code: code,
                        isComplete: isComplete,
                        isStreaming: isStreaming,
                        onPreview: (language?.lowercased() == "html" && isComplete)
                            ? { onPreviewHTML?(code) }
                            : nil
                    )
                }
            }
        }
    }

    private func parseMarkdown(_ text: String) -> AttributedString {
        do {
            var options = AttributedString.MarkdownParsingOptions()
            options.allowsExtendedAttributes = true
            var parsed = try AttributedString(markdown: text, options: options)
            parsed.foregroundColor = Color.lrmText
            return parsed
        } catch {
            var fallback = AttributedString(text)
            fallback.foregroundColor = Color.lrmText
            return fallback
        }
    }

    private var streamingIndicator: some View {
        HStack(spacing: 6) {
            PulsingDots()
                .frame(width: 20, height: 8)
            Text("Thinking")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.lrmMuted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient.lrmBackgroundRadial
                .clipShape(ChamferShape(cornerSize: 10))
        )
        .overlay(
            ChamferShape(cornerSize: 10)
                .stroke(Color.lrmBorder, lineWidth: 0.5)
        )
        .clipShape(ChamferShape(cornerSize: 10))
    }
}

// MARK: - CodeBlockView

struct CodeBlockView: View {
    let language: String?
    let code: String
    let isComplete: Bool
    var isStreaming: Bool = false
    var onPreview: (() -> Void)? = nil

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            header

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.lrmText)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 400)

            // Footer with actions (when complete)
            if isComplete {
                footer
            }
        }
        .background(Color(red: 0.06, green: 0.07, blue: 0.09))
        .clipShape(ChamferShape(cornerSize: 8))
        .overlay(
            ChamferShape(cornerSize: 8)
                .stroke(Color.lrmBorder, lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            // Language badge
            if let lang = language {
                Text(lang.uppercased())
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(.lrmAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.lrmAccent.opacity(0.15).clipShape(RoundedRectangle(cornerRadius: 3)))
            }

            if !isComplete {
                Text(isStreaming ? "writing…" : "truncated")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.lrmMuted)
            }

            Spacer()

            // Copy button
            Button(action: copyCode) {
                HStack(spacing: 3) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9, weight: .semibold))
                    Text(copied ? "Copied" : "Copy")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                }
                .foregroundColor(copied ? .green : .lrmMuted)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Copy code to clipboard")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.lrmSurface.opacity(0.4))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // Line count
            let lineCount = code.components(separatedBy: "\n").count
            Text("\(lineCount) lines")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.lrmMuted)

            Spacer()

            // Preview button (HTML only)
            if let preview = onPreview {
                Button(action: preview) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Preview")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.lrmAccent.clipShape(ChamferShape(cornerSize: 5)))
                }
                .buttonStyle(PlainButtonStyle())
                .help("Render this HTML in the preview panel")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.lrmSurface.opacity(0.3))
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        withAnimation(.easeInOut(duration: 0.2)) {
            copied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeInOut(duration: 0.2)) {
                copied = false
            }
        }
    }
}
