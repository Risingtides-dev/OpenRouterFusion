import SwiftUI
import WebKit

struct ContentView: View {
    @StateObject private var store = ConversationStore()
    @StateObject private var router = RouterManager()
    @State private var userInput = ""
    @State private var systemPrompt = ""
    @State private var isStreaming = false
    @State private var selectedModel = ""
    @State private var showingToolModal = false
    @State private var toolCommand = ""
    @State private var useEmbeddedWeb = true // toggle to pure SwiftUI if desired
    
    var body: some View {
        HStack(spacing: 0) {
            // MARK: Sidebar ----------------------------------------------------
            VStack(alignment: .leading, spacing: 16) {
                // API key field (Keychain)
                SecureField("OpenRouter API key", text: Binding(
                    get: { KeychainHelper.shared.get(key: "OpenRouterAPIKey") ?? "" },
                    set: { KeychainHelper.shared.set($0, for: "OpenRouterAPIKey") }
                ))
                .textFieldStyle(.roundedBorder)
                
                // System prompt editor
                TextEditor(text: $systemPrompt)
                    .frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
                
                // Model picker (default + fallbacks)
                Picker("Model", selection: $selectedModel) {
                    Text("Default (\(router.config.default))").tag("")
                    ForEach(router.config.fallbackOrder, id: \ .self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)
                
                // Tool runner button
                Button("Run Tool…") { showingToolModal = true }
                    .buttonStyle(MetalButtonStyle())
                
                Spacer()
                Button("Clear Chat") { store.clear() }
                    .foregroundColor(.red)
            }
            .padding()
            .frame(minWidth: 260)
            .background(Color.black.opacity(0.1))
            
            Divider()
            
            // MARK: Main chat area --------------------------------------------
            if useEmbeddedWeb {
                // Embedded the original liquid‑metal HTML UI via WebView
                WebChatView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(store.messages) { msg in
                                    HStack {
                                        if msg.role == .assistant {
                                            Image(systemName: "sparkles")
                                                .foregroundColor(.purple)
                                        } else {
                                            Image(systemName: "person.fill")
                                                .foregroundColor(.blue)
                                        }
                                        Text(msg.content)
                                            .padding(8)
                                            .background(msg.role == .assistant ? Color.purple.opacity(0.15) : Color.blue.opacity(0.1))
                                            .cornerRadius(8)
                                    }
                                    .frame(maxWidth: .infinity, alignment: msg.role == .assistant ? .leading : .trailing)
                                    .id(msg.id)
                                }
                                if isStreaming {
                                    HStack {
                                        ProgressView()
                                        Text("Thinking…")
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding()
                        }
                        .onChange(of: store.messages.count) { _ in
                            withAnimation { proxy.scrollTo(store.messages.last?.id, anchor: .bottom) }
                        }
                    }
                    // Composer
                    HStack {
                        TextEditor(text: $userInput)
                            .frame(minHeight: 40, maxHeight: 120)
                            .border(Color.gray.opacity(0.3), width: 1)
                            .cornerRadius(6)
                        Button(isStreaming ? "Stop" : "Send") {
                            guard !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            sendMessage()
                        }
                        .buttonStyle(MetalButtonStyle())
                        .disabled(isStreaming)
                    }
                    .padding()
                }
            }
        }
        .sheet(isPresented: $showingToolModal) {
            ToolModalView(command: $toolCommand, onRun: runTool)
        }
        .onAppear {
            if let saved = UserDefaults.standard.string(forKey: "systemPrompt") { systemPrompt = saved }
            selectedModel = router.config.default
        }
        .onChange(of: systemPrompt) { UserDefaults.standard.set($0, forKey: "systemPrompt") }
    }
    // MARK: Messaging --------------------------------------------------------
    private func sendMessage() {
        let prompt = userInput
        store.append(role: .user, content: prompt)
        userInput = ""
        isStreaming = true
        let messagesArray = store.messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        router.send(messages: messagesArray, systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt) { result in
            DispatchQueue.main.async {
                isStreaming = false
                switch result {
                case .success(let txt):
                    store.append(role: .assistant, content: txt)
                case .failure(let err):
                    store.append(role: .assistant, content: "❗️ Error: \(err.localizedDescription)")
                }
            }
        }
    }
    // MARK: Tool execution ---------------------------------------------------
    private func runTool(_ cmd: String) {
        ToolExecutor.run("/bin/bash", arguments: ["-c", cmd]) { res in
            DispatchQueue.main.async {
                switch res {
                case .success(let out):
                    let toolOutput = """
🛠 Tool output:
```
\(out)
```
"""
store.append(role: .assistant, content: toolOutput)
                case .failure(let err):
                    store.append(role: .assistant, content: "🛠 Tool failed: \(err.localizedDescription)")
                }
            }
        }
    }
}

// MARK: Embedded WebView ---------------------------------------------------
struct WebChatView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let wk = WKWebView()
        let bundle = Bundle.main
        if let url = bundle.url(forResource: "index", withExtension: "html", subdirectory: "Resources/openrtr-owl") {
            wk.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return wk
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: Metal button style -------------------------------------------------
struct MetalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    LinearGradient(gradient: Gradient(colors: [Color(#colorLiteral(red: 0.49, green: 0.22, blue: 1, alpha: 1)),
                                                               Color(#colorLiteral(red: 0.33, green: 0.67, blue: 1, alpha: 1))]),
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                }
            )
            .foregroundColor(.white)
            .cornerRadius(6)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}
