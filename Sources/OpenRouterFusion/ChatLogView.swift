import SwiftUI

// MARK: - ChatLogView
// Scrollable chat message list with auto-scroll and streaming indicator

struct ChatLogView: View {
    @ObservedObject var vm: ChatViewModel
    let scrollDebouncer: Debouncer
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Message history
                    ForEach(vm.store.messages) { msg in
                        ChatMessageView(message: msg)
                            .id(msg.id)
                    }
                    
                    // Active tool calls
                    ForEach(vm.activeToolCalls) { tc in
                        ToolCallIndicator(toolCall: tc)
                            .id("tool-\(tc.id)")
                    }
                    
                    // Streaming content (in-progress assistant response)
                    if vm.isStreaming {
                        ChatMessageView(
                            message: ChatMessage(role: .assistant, content: vm.currentStreamingContent)
                        )
                        .id("streaming")
                    }
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: vm.store.messages.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    if let last = vm.store.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: vm.currentStreamingContent) {
                // Debounce scroll updates during streaming to avoid excessive layout passes
                scrollDebouncer.debounce {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("streaming", anchor: .bottom)
                    }
                }
            }
            .onChange(of: vm.activeToolCalls.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    if let last = vm.activeToolCalls.last {
                        proxy.scrollTo("tool-\(last.id)", anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ChatLogView_Previews: PreviewProvider {
    static var previews: some View {
        ChatLogView(
            vm: {
                let vm = ChatViewModel()
                vm.store.append(role: .user, content: "Hello!")
                vm.store.append(role: .assistant, content: "Hi there! How can I help?")
                return vm
            }(),
            scrollDebouncer: Debouncer(delay: 0.05)
        )
        .background(Color.lrmBackground)
        .frame(width: 600, height: 400)
    }
}
#endif
