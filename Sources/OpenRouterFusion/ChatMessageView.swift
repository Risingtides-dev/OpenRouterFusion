import SwiftUI

// MARK: - ChatMessageView

struct ChatMessageView: View {
    let message: ChatMessage
    var isStreaming: Bool = false

    // Cache parsed markdown to avoid re-parsing on every render
    @State private var cachedAttributedContent: AttributedString?
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
            // Pre-parse markdown once on first appearance
            if message.role == .assistant {
                cachedAttributedContent = parseMarkdown()
                lastParsedContent = message.content
            }
        }
        .onChange(of: message.content) { _, newContent in
            // Invalidate cache when content changes (e.g., during streaming)
            if message.role == .assistant && newContent != lastParsedContent {
                cachedAttributedContent = parseMarkdown()
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
            .accessibilityHidden(true) // Decorative, not informative
    }

    private var initials: String {
        switch message.role {
        case .user:
            return "U"
        case .assistant:
            if let model = message.modelUsed, !model.isEmpty {
                return String(model.prefix(1)).uppercased()
            }
            return "A"
        }
    }

    private var avatarGradient: LinearGradient {
        switch message.role {
        case .user:
            return LinearGradient.lrmUserGradient
        case .assistant:
            return LinearGradient.lrmAssistantGradient
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
        .frame(minWidth: 60, maxWidth: 520, alignment: .trailing)
    }

    // MARK: Assistant Bubble

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if message.content.isEmpty && isStreaming {
                streamingIndicator
            } else {
                markdownContent
            }

            if let model = message.modelUsed, !model.isEmpty {
                StatusBadge(model, isStreaming: isStreaming && message.content.isEmpty)
            }
        }
        .frame(minWidth: 60, maxWidth: 520, alignment: .leading)
    }

    @ViewBuilder
    private var markdownContent: some View {
        // Use cached AttributedString — guaranteed to be pre-parsed by onAppear/onChange
        let attributed: AttributedString = {
            if let cached = cachedAttributedContent {
                return cached
            }
            // Fallback for first render before .onAppear (rare)
            return parseMarkdown()
        }()

        Text(attributed)
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
    }

    private func parseMarkdown() -> AttributedString {
        do {
            var options = AttributedString.MarkdownParsingOptions()
            options.allowsExtendedAttributes = true
            let parsed = try AttributedString(
                markdown: message.content,
                options: options
            )
            var result = parsed
            result.foregroundColor = Color.lrmText
            return result
        } catch {
            var fallback = AttributedString(message.content)
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

// Preview moved to Previews.swift
