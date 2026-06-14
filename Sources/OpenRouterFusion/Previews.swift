import SwiftUI

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
