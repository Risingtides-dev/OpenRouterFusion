import SwiftUI

// MARK: - ChatMessageView

struct ChatMessageView: View {
    let message: ChatMessage
    var isStreaming: Bool = false

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
        let attributed: AttributedString = {
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

// MARK: - Preview

#if DEBUG
extension ChatMessage {
    static func preview(role: Role, content: String, modelUsed: String? = nil) -> ChatMessage {
        var msg = ChatMessage(role: role, content: content)
        msg.modelUsed = modelUsed
        return msg
    }
}

struct ChatMessageView_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            VStack(spacing: 16) {
                ChatMessageView(
                    message: .preview(role: .user, content: "Hello! How are you?")
                )
                ChatMessageView(
                    message: .preview(
                        role: .assistant,
                        content: "I'm doing well! Here's **bold**, *italic*, and `code`.",
                        modelUsed: "openrouter/auto"
                    )
                )
                ChatMessageView(
                    message: .preview(role: .assistant, content: "", modelUsed: "anthropic/claude"),
                    isStreaming: true
                )
            }
            .padding(.vertical, 20)
        }
        .background(Color.lrmBackground)
        .frame(width: 600, height: 700)
    }
}
#endif
