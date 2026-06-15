import SwiftUI

// MARK: - ChatLogView
// Scrollable chat message list with auto-scroll, streaming indicator, and fusion session display

struct ChatLogView: View {
    @ObservedObject var vm: ChatViewModel
    let scrollDebouncer: Debouncer
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Message history
                    ForEach(vm.store.messages) { msg in
                        ChatMessageView(
                            message: msg,
                            onPreviewHTML: { html in vm.showPreview(html: html) }
                        )
                            .id(msg.id)
                    }
                    
                    // Active tool calls
                    ForEach(vm.activeToolCalls) { tc in
                        ToolCallIndicator(toolCall: tc)
                            .id("tool-\(tc.id)")
                    }

                    // Active fusion session (shown inline during fusion mode)
                    if let session = vm.fusionSession {
                        FusionSessionView(session: session)
                            .id("fusion-\(session.id)")
                    }
                    
                    // Non-fusion streaming content (fast/single mode)
                    if vm.isStreaming && vm.fusionSession == nil {
                        ChatMessageView(
                            message: ChatMessage(role: .assistant, content: vm.currentStreamingContent),
                            onPreviewHTML: nil
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
            // Scroll to fusion session when it appears or updates
            .onChange(of: vm.fusionSession?.panelResults.count) {
                if vm.fusionSession != nil {
                    scrollDebouncer.debounce {
                        withAnimation(.easeOut(duration: 0.2)) {
                            if let session = vm.fusionSession {
                                proxy.scrollTo("fusion-\(session.id)", anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .onChange(of: vm.fusionSession?.synthesisContent) {
                if vm.fusionSession != nil {
                    scrollDebouncer.debounce {
                        withAnimation(.easeOut(duration: 0.1)) {
                            if let session = vm.fusionSession {
                                proxy.scrollTo("fusion-\(session.id)", anchor: .bottom)
                            }
                        }
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
