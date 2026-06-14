import SwiftUI

// MARK: - ChatViewModel

/// Owns all business logic and mutable state for the chat UI.
/// Views bind via `@ObservedObject var vm: ChatViewModel`.
@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - Owned services

    let store: ConversationStore
    let router: RouterManager

    // MARK: - Published state (was @State in ContentView)

    @Published var userInput: String = ""
    @Published var systemPrompt: String = ""
    @Published var isStreaming: Bool = false
    @Published var selectedModel: String = ""
    @Published var chatMode: RouterManager.ChatMode = .fusion {
        didSet { UserDefaults.standard.set(chatMode.rawValue, forKey: "chatMode") }
    }
    @Published var currentStreamingContent: String = ""
    @Published var activeToolCalls: [ToolCallDisplay] = []
    @Published var sidebarVisible: Bool = true
    @Published var showingKeychainAlert: Bool = false
    @Published var keychainAlertMessage: String = ""
    @Published var showingToolModal: Bool = false
    @Published var toolCommand: String = ""

    // MARK: - Scroll debouncer for streaming content

    private let scrollDebouncer = Debouncer(delay: 0.05)

    // MARK: - Init

    init(store: ConversationStore = ConversationStore(), router: RouterManager = RouterManager()) {
        self.store = store
        self.router = router
    }

    // MARK: - Lifecycle

    func onAppear() {
        // Load saved system prompt or use default
        if let saved = UserDefaults.standard.string(forKey: "systemPrompt") {
            systemPrompt = saved
        } else {
            systemPrompt = "You are a helpful AI assistant running on a macOS machine. Your home directory is \(NSHomeDirectory())."
        }
        selectedModel = router.config.default
        if let rawMode = UserDefaults.standard.string(forKey: "chatMode"),
           let savedMode = RouterManager.ChatMode(rawValue: rawMode) {
            chatMode = savedMode
        } else {
            chatMode = .fusion
        }

        // One-time migration: move API key from UserDefaults → Keychain, then purge
        if KeychainHelper.shared.get(key: "OpenRouterAPIKey") == nil {
            if let legacyKey = UserDefaults.standard.string(forKey: "openrouter_api_key"), !legacyKey.isEmpty {
                let ok = KeychainHelper.shared.set(legacyKey, for: "OpenRouterAPIKey")
                if ok {
                    UserDefaults.standard.removeObject(forKey: "openrouter_api_key")
                } else {
                    keychainAlertMessage = "Could not migrate API key to Keychain. Please re-enter it in Settings."
                    showingKeychainAlert = true
                }
            }
        } else {
            // Keychain has the key — purge any stale plaintext copy
            if UserDefaults.standard.string(forKey: "openrouter_api_key") != nil {
                UserDefaults.standard.removeObject(forKey: "openrouter_api_key")
            }
        }
    }

    func saveSystemPrompt() {
        UserDefaults.standard.set(systemPrompt, forKey: "systemPrompt")
    }

    // MARK: - Message Actions

    func sendMessage() {
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

        switch chatMode {
        case .fusion:
            router.sendFusion(
                messages: messagesArray,
                systemPrompt: sysPrompt,
                onChunk: { [weak self] chunk in
                    DispatchQueue.main.async { self?.currentStreamingContent += chunk }
                },
                completion: { [weak self] result in
                    DispatchQueue.main.async { self?.handleSendCompletion(result, errorPrefix: "Fusion") }
                }
            )

        case .fast:
            router.sendFast(
                messages: messagesArray,
                systemPrompt: sysPrompt,
                onChunk: { [weak self] chunk in
                    DispatchQueue.main.async { self?.currentStreamingContent += chunk }
                },
                completion: { [weak self] result in
                    DispatchQueue.main.async { self?.handleSendCompletion(result, errorPrefix: "Fast") }
                }
            )

        case .single:
            router.send(
                messages: messagesArray,
                systemPrompt: sysPrompt,
                tools: tools,
                preferredModel: selectedModel.isEmpty ? nil : selectedModel,
                onChunk: { [weak self] chunk in
                    DispatchQueue.main.async { self?.currentStreamingContent += chunk }
                },
                onToolCall: { [weak self] id, name, args in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if !self.activeToolCalls.contains(where: { $0.id == id }) {
                            self.activeToolCalls.append(ToolCallDisplay(id: id, name: name, arguments: args))
                        }
                        self.executeTool(id: id, name: name, arguments: args)
                    }
                },
                completion: { [weak self] result in
                    DispatchQueue.main.async { self?.handleSendCompletion(result, errorPrefix: "") }
                }
            )
        }
    }

    private func handleSendCompletion(_ result: Result<String, Error>, errorPrefix: String) {
        isStreaming = false
        switch result {
        case .success(let txt):
            let finalText = txt.isEmpty ? currentStreamingContent : txt
            if !finalText.isEmpty {
                let modeLabel: String
                switch chatMode {
                case .fusion: modeLabel = router.modelUsed.isEmpty ? "custom-fusion" : router.modelUsed
                case .fast: modeLabel = router.modelUsed.isEmpty ? router.config.fastModel : router.modelUsed
                case .single: modeLabel = router.modelUsed.isEmpty ? selectedModel : router.modelUsed
                }
                store.append(role: .assistant, content: finalText, modelUsed: modeLabel)
            }
        case .failure(let err):
            let prefix = errorPrefix.isEmpty ? "" : "\(errorPrefix) "
            store.append(role: .assistant, content: "❗️ \(prefix)Error: \(err.localizedDescription)")
        }
        currentStreamingContent = ""
        activeToolCalls = []
    }

    func stopStreaming() {
        router.cancel()
        isStreaming = false
        if !currentStreamingContent.isEmpty {
            store.append(role: .assistant, content: currentStreamingContent)
            currentStreamingContent = ""
        }
        activeToolCalls = []
    }

    func clearChat() {
        store.clear()
        activeToolCalls = []
    }

    // MARK: - Tool Execution

    func executeTool(id: String, name: String, arguments argsJSON: String) {
        ToolExecutor.run("/bin/bash", arguments: ["-c", argsJSON]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let output):
                    let truncated = output.count > 2000 ? String(output.prefix(2000)) + "\n…(truncated)" : output
                    self.store.append(role: .assistant, content: "🛠 [\(name)] → \(truncated)")
                case .failure(let err):
                    self.store.append(role: .assistant, content: "🛠 [\(name)] failed: \(err.localizedDescription)")
                }
            }
        }
    }

    func runManualTool(_ cmd: String) {
        ToolExecutor.run("/bin/bash", arguments: ["-c", cmd]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let out):
                    self.store.append(role: .assistant, content: """
                    🛠 Tool output:
                    ```
                    \(out)
                    ```
                    """)
                case .failure(let err):
                    self.store.append(role: .assistant, content: "🛠 Tool failed: \(err.localizedDescription)")
                }
            }
        }
    }

    // MARK: - API Key Management

    func setAPIKey(_ key: String) -> Bool {
        let ok = KeychainHelper.shared.set(key, for: "OpenRouterAPIKey")
        if !ok && !key.isEmpty {
            keychainAlertMessage = "Failed to save API key to Keychain."
            showingKeychainAlert = true
        }
        return ok
    }

    func getAPIKey() -> String {
        KeychainHelper.shared.get(key: "OpenRouterAPIKey") ?? ""
    }

    // MARK: - Scroll Helper

    func debouncedScroll(_ action: @escaping () -> Void) {
        scrollDebouncer.debounce(action)
    }
}

// NOTE: ToolCallDisplay is defined in ContentView.swift for now.
// It will move here once ContentView is slimmed down.
