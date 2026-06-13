import SwiftUI

// MARK: - Model display name helper

private func friendlyModelName(_ id: String) -> String {
    // Strip common prefixes/suffixes
    var name = id
        .replacingOccurrences(of: "openrouter/", with: "")
        .replacingOccurrences(of: "openai/", with: "")
        .replacingOccurrences(of: "google/", with: "")
        .replacingOccurrences(of: "nvidia/", with: "")
        .replacingOccurrences(of: "qwen/", with: "")
        .replacingOccurrences(of: "nex-agi/", with: "")
        .replacingOccurrences(of: "anthropic/", with: "")
        .replacingOccurrences(of: ":free", with: "")
        .replacingOccurrences(of: "-instruct", with: "")
        .replacingOccurrences(of: "-it", with: "")

    // Convert dashes/spaces to title case
    name = name.replacingOccurrences(of: "-", with: " ")
    name = name.capitalized

    // Truncate if still long
    if name.count > 28 {
        name = String(name.prefix(25)) + "…"
    }
    return name
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var store = ConversationStore()
    @StateObject private var router = RouterManager()

    @State private var userInput = ""
    @State private var systemPrompt = ""
    @State private var isStreaming = false
    @State private var selectedModel = ""
    @State private var currentStreamingContent = ""
    @State private var showingToolModal = false
    @State private var toolCommand = ""
    @State private var activeToolCalls: [ToolCallDisplay] = []
    @State private var sidebarVisible = true
    @State private var showingKeychainAlert = false
    @State private var keychainAlertMessage = ""

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                sidebar
                Divider().background(Color.lrmBorder)
            }
            chatArea
        }
        .background(
            ZStack {
                Color.lrmBackground
                LinearGradient.lrmBackgroundRadial.opacity(0.4)
            }
            .ignoresSafeArea()
        )
        .alert("Keychain Error", isPresented: $showingKeychainAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(keychainAlertMessage)
        }
        .sheet(isPresented: $showingToolModal) {
            ToolModalView(command: $toolCommand, onRun: runManualTool)
        }
        .onAppear {
            if let saved = UserDefaults.standard.string(forKey: "systemPrompt") {
                systemPrompt = saved
            } else {
                systemPrompt = "You are a helpful AI assistant running on a macOS machine. Your home directory is \(NSHomeDirectory())."
            }
            selectedModel = router.config.default

            if KeychainHelper.shared.get(key: "OpenRouterAPIKey") == nil,
               let apiKey = UserDefaults.standard.string(forKey: "openrouter_api_key"), !apiKey.isEmpty {
                let ok = KeychainHelper.shared.set(apiKey, for: "OpenRouterAPIKey")
                if !ok {
                    keychainAlertMessage = "Could not save API key to Keychain. It will only persist for this session."
                    showingKeychainAlert = true
                }
            }
        }
        .onChange(of: systemPrompt) {
            UserDefaults.standard.set(systemPrompt, forKey: "systemPrompt")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Sidebar header with collapse button
            HStack {
                MetalText("SETTINGS")
                Spacer()
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = false } }) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.lrmMuted)
                        .padding(6)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Hide sidebar")
            }
            .padding(.bottom, 4)

            // API Key
            MetalText("API KEY")
            LRMSecureField(text: Binding(
                get: { KeychainHelper.shared.get(key: "OpenRouterAPIKey") ?? "" },
                set: { newValue in
                    let ok = KeychainHelper.shared.set(newValue, for: "OpenRouterAPIKey")
                    if !ok && !newValue.isEmpty {
                        keychainAlertMessage = "Failed to save API key to Keychain."
                        showingKeychainAlert = true
                    }
                }
            ))
            .frame(height: 28)

            // System Prompt
            MetalText("SYSTEM PROMPT")
            LRMTextEditor(text: $systemPrompt, placeholder: "You are a helpful assistant…")
                .frame(minHeight: 60, maxHeight: 100)

            // Model Picker
            MetalText("MODEL")
            Picker("Model", selection: $selectedModel) {
                Text("Auto (\(friendlyModelName(router.config.default)))").tag("")
                ForEach(router.config.fallbackOrder, id: \.self) { model in
                    Text(friendlyModelName(model)).tag(model)
                }
            }
            .pickerStyle(.menu)
            .accentColor(.lrmAccent)

            MetalButton("Run Tool…", variant: .metal) {
                showingToolModal = true
            }

            Spacer()

            MetalButton("Clear Chat", variant: .ghost) {
                store.clear()
                activeToolCalls = []
            }
        }
        .padding(14)
        .frame(width: 260)
        .background(Color.lrmBackground2.opacity(0.6))
    }

    // MARK: - Chat Area

    private var chatArea: some View {
        VStack(spacing: 0) {
            // Show sidebar toggle when sidebar is hidden
            if !sidebarVisible {
                HStack {
                    Button(action: { withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = true } }) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.lrmMuted)
                            .padding(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Show sidebar")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.lrmBackground2.opacity(0.3))
            }

            if store.messages.isEmpty && !isStreaming {
                emptyState
            } else {
                chatLog
            }

            Divider().background(Color.lrmBorder)
            composer
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()

            // Logo
            Text("◉")
                .font(.system(size: 48, weight: .thin))
                .foregroundColor(.lrmAccent)

            VStack(spacing: 6) {
                Text("OpenRouterFusion")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundColor(.lrmTextStrong)

                Text("Multi-model AI chat · auto-routing · free models")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.lrmMuted)
            }

            VStack(spacing: 8) {
                Text("Quick start:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.lrmMuted.opacity(0.7))

                VStack(alignment: .leading, spacing: 4) {
                    quickStartRow(key: "Enter", action: "Send message")
                    quickStartRow(key: "⇧ Enter", action: "New line")
                    quickStartRow(key: "⌘ K", action: "Clear chat")
                    quickStartRow(key: "⌘ ⇧ S", action: "Toggle sidebar")
                }
            }
            .padding(.top, 12)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func quickStartRow(key: String, action: String) -> some View {
        HStack(spacing: 12) {
            Text(key)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.lrmAccent)
                .frame(width: 80, alignment: .trailing)
            Text(action)
                .font(.system(size: 12))
                .foregroundColor(.lrmMuted)
        }
    }

    // MARK: - Chat Log

    private var chatLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.messages) { msg in
                        ChatMessageView(message: msg)
                            .id(msg.id)
                    }

                    ForEach(activeToolCalls) { tc in
                        ToolCallIndicator(toolCall: tc)
                            .id("tool-\(tc.id)")
                    }

                    if isStreaming {
                        ChatMessageView(
                            message: ChatMessage(role: .assistant, content: currentStreamingContent)
                        )
                        .id("streaming")
                    }
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
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
            .onChange(of: activeToolCalls.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    if let last = activeToolCalls.last {
                        proxy.scrollTo("tool-\(last.id)", anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if userInput.isEmpty {
                    Text("Message…")
                        .foregroundColor(.lrmMuted.opacity(0.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $userInput)
                    .font(.system(size: 14))
                    .foregroundColor(.lrmText)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .frame(minHeight: 36, maxHeight: 120)
                    .onSubmit { sendMessage() }
            }
            .background(
                Color.lrmSurfaceStrong.clipShape(ChamferShape(cornerSize: 8))
            )
            .overlay(
                ChamferShape(cornerSize: 8).stroke(Color.lrmBorder, lineWidth: 1)
            )

            HStack(spacing: 8) {
                if isStreaming {
                    MetalButton("Stop", variant: .ghost) {
                        isStreaming = false
                        if !currentStreamingContent.isEmpty {
                            store.append(role: .assistant, content: currentStreamingContent)
                            currentStreamingContent = ""
                        }
                        activeToolCalls = []
                    }
                } else {
                    MetalButton("Send", variant: .primary) {
                        sendMessage()
                    }
                    .disabled(userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .padding(12)
        .background(Color.lrmSurface.opacity(0.3))
    }

    // MARK: - Messaging

    private func sendMessage() {
        let prompt = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        store.append(role: .user, content: prompt, modelUsed: nil)
        userInput = ""
        isStreaming = true
        currentStreamingContent = ""
        activeToolCalls = []

        let messagesArray = store.messages.map { msg in
            ["role": msg.role.rawValue, "content": msg.content]
        }
        let sysPrompt = systemPrompt.isEmpty ? nil : systemPrompt
        let tools: [[String: Any]]? = nil  // No tool calling for now

        router.send(
            messages: messagesArray,
            systemPrompt: sysPrompt,
            tools: tools,
            onChunk: { chunk in
                DispatchQueue.main.async {
                    currentStreamingContent += chunk
                }
            },
            onToolCall: { id, name, args in
                DispatchQueue.main.async {
                    if !activeToolCalls.contains(where: { $0.id == id }) {
                        activeToolCalls.append(ToolCallDisplay(id: id, name: name, arguments: args))
                    }
                    executeTool(id: id, name: name, arguments: args)
                }
            },
            completion: { result in
                DispatchQueue.main.async {
                    isStreaming = false
                    switch result {
                    case .success(let txt):
                        let finalText = txt.isEmpty ? currentStreamingContent : txt
                        if !finalText.isEmpty {
                            store.append(role: .assistant, content: finalText)
                        }
                    case .failure(let err):
                        store.append(role: .assistant, content: "❗️ Error: \(err.localizedDescription)")
                    }
                    currentStreamingContent = ""
                    activeToolCalls = []
                }
            }
        )
    }

    private func executeTool(id: String, name: String, arguments argsJSON: String) {
        ToolExecutor.run("/bin/bash", arguments: ["-c", argsJSON]) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let output):
                    let truncated = output.count > 2000 ? String(output.prefix(2000)) + "\n…(truncated)" : output
                    store.append(role: .assistant, content: "🛠 [\(name)] → \(truncated)")
                case .failure(let err):
                    store.append(role: .assistant, content: "🛠 [\(name)] failed: \(err.localizedDescription)")
                }
            }
        }
    }

    private func runManualTool(_ cmd: String) {
        ToolExecutor.run("/bin/bash", arguments: ["-c", cmd]) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let out):
                    store.append(role: .assistant, content: """
                    🛠 Tool output:
                    ```
                    \(out)
                    ```
                    """)
                case .failure(let err):
                    store.append(role: .assistant, content: "🛠 Tool failed: \(err.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Keyboard Shortcuts

extension ContentView {
    func clearChatShortcut() {
        store.clear()
        activeToolCalls = []
    }
}

// MARK: - Tool Call Display

struct ToolCallDisplay: Identifiable {
    let id: String
    let name: String
    let arguments: String
}

struct ToolCallIndicator: View {
    let toolCall: ToolCallDisplay

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape.fill")
                .foregroundColor(.lrmAccent)
                .font(.system(size: 12))
            Text(toolCall.name)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.lrmTextStrong)
            Text(summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.lrmMuted)
                .lineLimit(1)
            Spacer()
            PulsingDots()
                .frame(width: 16, height: 6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.lrmSurface.clipShape(ChamferShape(cornerSize: 6)))
        .overlay(ChamferShape(cornerSize: 6).stroke(Color.lrmAccent.opacity(0.3), lineWidth: 1))
        .clipShape(ChamferShape(cornerSize: 6))
        .padding(.horizontal, 16)
    }

    private var summary: String {
        let cleaned = toolCall.arguments.replacingOccurrences(of: "\n", with: " ")
        return cleaned.count > 60 ? String(cleaned.prefix(60)) + "…" : cleaned
    }
}
