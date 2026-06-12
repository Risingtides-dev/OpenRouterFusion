import SwiftUI

struct ContentView: View {
    // MARK: - State Objects
    @StateObject private var store = ConversationStore()
    @StateObject private var router = RouterManager()

    // MARK: - Local State
    @State private var userInput = ""
    @State private var systemPrompt = ""
    @State private var isStreaming = false
    @State private var selectedModel = ""
    @State private var currentStreamingContent = ""
    @State private var showingToolModal = false
    @State private var toolCommand = ""

    var body: some View {
        HStack(spacing: 0) {
            // MARK: Sidebar ----------------------------------------------------
            sidebar

            Divider()
                .background(Color.lrmBorder)

            // MARK: Main Chat Area --------------------------------------------
            chatArea
        }
        .background(
            ZStack {
                Color.lrmBackground
                LinearGradient.lrmBackgroundRadial
                    .opacity(0.4)
            }
            .ignoresSafeArea()
        )
        .sheet(isPresented: $showingToolModal) {
            ToolModalView(command: $toolCommand, onRun: runTool)
        }
        .onAppear {
            if let saved = UserDefaults.standard.string(forKey: "systemPrompt") {
                systemPrompt = saved
            }
            selectedModel = router.config.default
        }
        .onChange(of: systemPrompt) {
            UserDefaults.standard.set(systemPrompt, forKey: "systemPrompt")
        }
    }

    // MARK: Sidebar View

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            // API Key
            MetalText("API KEY")
            LRMSecureField(text: Binding(
                get: { KeychainHelper.shared.get(key: "OpenRouterAPIKey") ?? "" },
                set: { _ = KeychainHelper.shared.set($0, for: "OpenRouterAPIKey") }
            ))
            .frame(height: 30)

            // System Prompt
            MetalText("SYSTEM PROMPT")
            LRMTextEditor(text: $systemPrompt, placeholder: "You are a helpful assistant…")
                .frame(minHeight: 80, maxHeight: 120)

            // Model Picker
            MetalText("MODEL")
            Picker("Model", selection: $selectedModel) {
                Text("Default (\(router.config.default))").tag("")
                ForEach(router.config.fallbackOrder, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.menu)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(.lrmText)
            .accentColor(.lrmAccent)
            .frame(height: 28)

            // Run Tool button
            MetalButton("Run Tool…", variant: .metal) {
                showingToolModal = true
            }

            Spacer()

            // Clear Chat
            MetalButton("Clear Chat", variant: .ghost) {
                store.clear()
            }
        }
        .padding(16)
        .frame(width: 280)
        .background(
            Color.lrmBackground2.opacity(0.5)
        )
    }

    // MARK: Chat Area

    private var chatArea: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.messages) { msg in
                            ChatMessageView(message: msg)
                                .id(msg.id)
                        }

                        // Streaming message (not yet in store)
                        if isStreaming {
                            ChatMessageView(
                                message: ChatMessage(role: .assistant, content: currentStreamingContent)
                            )
                            .id("streaming")
                        }
                    }
                    .padding(.vertical, 16)
                }
                .onChange(of: store.messages.count) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if let last = store.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: currentStreamingContent) {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("streaming", anchor: .bottom)
                    }
                }
            }

            Divider()
                .background(Color.lrmBorder)

            // Composer
            composer
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            LRMTextEditor(
                text: $userInput,
                placeholder: "Message… (Shift+Enter for newline)"
            )
                .frame(minHeight: 36, maxHeight: 120)
            .onSubmit {
                sendMessage()
            }

            HStack(spacing: 8) {
                if isStreaming {
                    MetalButton("Stop", variant: .ghost) {
                        // Stop streaming — in current implementation we can't cancel
                        // the URLSession task, but we mark as done
                        isStreaming = false
                        if !currentStreamingContent.isEmpty {
                            store.append(role: .assistant, content: currentStreamingContent)
                            currentStreamingContent = ""
                        }
                    }
                } else {
                    MetalButton("Send", variant: .primary) {
                        sendMessage()
                    }
                    .disabled(userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(12)
        .background(
            Color.lrmSurface.opacity(0.3)
        )
    }

    // MARK: Messaging

    private func sendMessage() {
        let prompt = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        store.append(role: .user, content: prompt)
        userInput = ""
        isStreaming = true
        currentStreamingContent = ""

        let messagesArray = store.messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        let sysPrompt = systemPrompt.isEmpty ? nil : systemPrompt

        router.send(
            messages: messagesArray,
            systemPrompt: sysPrompt,
            onChunk: { chunk in
                DispatchQueue.main.async {
                    currentStreamingContent += chunk
                }
            },
            completion: { result in
                DispatchQueue.main.async {
                    isStreaming = false
                    switch result {
                    case .success(let txt):
                        let finalText = txt.isEmpty ? currentStreamingContent : txt
                        store.append(role: .assistant, content: finalText)
                    case .failure(let err):
                        store.append(role: .assistant, content: "❗️ Error: \(err.localizedDescription)")
                    }
                    currentStreamingContent = ""
                }
            }
        )
    }

    // MARK: Tool Execution

    private func runTool(_ cmd: String) {
        ToolExecutor.run("/bin/bash", arguments: ["-c", cmd]) { res in
            DispatchQueue.main.async {
                switch res {
                case .success(let out):
                    let toolOutput = """
                    🛠 Tool output:
                    ```
                    \(out)
                    ```
                    """
                    store.append(role: .assistant, content: toolOutput)
                case .failure(let err):
                    store.append(role: .assistant, content: "🛠 Tool failed: \(err.localizedDescription)")
                }
            }
        }
    }
}
