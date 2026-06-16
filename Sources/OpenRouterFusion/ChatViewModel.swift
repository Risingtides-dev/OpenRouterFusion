import SwiftUI

// MARK: - Fusion Session Model

/// Tracks a single panel model's result during a fusion run.
@MainActor
final class PanelResult: ObservableObject, Identifiable {
    let id = UUID()
    let model: String
    @Published var content: String?
    @Published var error: String?
    @Published var elapsedSeconds: Double = 0
    @Published var status: Status = .running

    enum Status {
        case running, done, failed
    }

    init(model: String) {
        self.model = model
    }
}

/// Tracks the full lifecycle of a fusion session: panel results + judge synthesis.
@MainActor
final class FusionSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published var panelResults: [PanelResult] = []
    @Published var synthesisContent: String = ""
    @Published var synthesisModel: String = ""
    @Published var isSynthesisStreaming: Bool = false
    @Published var phase: Phase = .panel

    enum Phase {
        case panel, synthesis, done, failed
    }

    var isRunning: Bool {
        phase == .panel || phase == .synthesis
    }

    var hasSynthesis: Bool {
        !synthesisContent.isEmpty
    }
}

// MARK: - ChatViewModel

/// Owns all business logic and mutable state for the chat UI.
/// Views bind via `@ObservedObject var vm: ChatViewModel`.
@MainActor
final class ChatViewModel: ObservableObject {

    // MARK: - Owned services

    let store: ConversationStore
    let router: RouterManager

    // MARK: - Published state

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

    /// Preview panel state
    @Published var previewHTML: String?
    @Published var previewTitle: String = "Preview"
    @Published var showingPreview: Bool = false

    /// Active fusion session (shown inline in chat log while running)
    @Published var fusionSession: FusionSession?

    /// Model catalog and preset management
    let catalog = ModelCatalog()
    let presetStore = PresetStore()
    @Published var showingRosterBuilder = false
    @Published var activePreset: FusionPreset?

    /// Agent engine state
    private let agentEngine = AgentEngineBridge()
    @Published var agentTools: [String] = []

    // MARK: - Scroll debouncer for streaming content

    private let scrollDebouncer = Debouncer(delay: 0.05)

    // MARK: - Init

    init(store: ConversationStore = ConversationStore(), router: RouterManager = RouterManager()) {
        self.store = store
        self.router = router
    }

    // MARK: - Lifecycle

    func onAppear() {
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

        // Fetch model catalog
        Task {
            let apiKey = KeychainHelper.shared.get(key: "OpenRouterAPIKey")
            await catalog.fetch(apiKey: apiKey)
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
        activeToolCalls = []

        let messagesArray = store.messages.map { msg in
            ["role": msg.role.rawValue, "content": msg.content]
        }
        let sysPrompt = systemPrompt.isEmpty ? nil : systemPrompt

        switch chatMode {
        case .fusion:
            sendFusionEventDriven(messages: messagesArray, systemPrompt: sysPrompt)

        case .fast:
            isStreaming = true
            currentStreamingContent = ""
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
            isStreaming = true
            currentStreamingContent = ""
            let tools: [[String: Any]]? = nil
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

        case .agent:
            sendAgentMessage(messages: store.messages.map { (role: $0.role.rawValue, content: $0.content) }, systemPrompt: sysPrompt)
        }
    }

    // MARK: - Event-driven Fusion

    private func sendFusionEventDriven(messages: [[String: Any]], systemPrompt: String?) {
        let session = FusionSession()
        fusionSession = session
        isStreaming = true

        Task { [weak self] in
            guard let self else { return }
            let eventStream = self.router.sendFusionEvents(
                messages: messages,
                systemPrompt: systemPrompt,
                panelModels: self.activePreset?.models,
                judgeModel: self.activePreset?.judgeModel
            )

            for await event in eventStream {
                switch event {
                case .panelStarted(let models):
                    session.panelResults = models.map { PanelResult(model: $0) }

                case .panelResult(let model, let content, let error, let elapsed):
                    if let panel = session.panelResults.first(where: { $0.model == model }) {
                        panel.content = content
                        panel.error = error
                        panel.elapsedSeconds = elapsed
                        panel.status = (content != nil) ? .done : .failed
                    }

                case .synthesisChunk(let chunk):
                    if session.phase != .synthesis {
                        session.phase = .synthesis
                        session.isSynthesisStreaming = true
                    }
                    session.synthesisContent += chunk

                case .synthesisModel(let model):
                    session.synthesisModel = model

                case .finished(let text, let modelUsed):
                    session.phase = .done
                    session.isSynthesisStreaming = false
                    self.fusionSession = nil
                    self.isStreaming = false
                    self.router.modelUsed = modelUsed
                    // Store the final synthesis as a regular message
                    if !text.isEmpty {
                        self.store.append(role: .assistant, content: text, modelUsed: modelUsed)
                    }
                    self.currentStreamingContent = ""

                case .failed(let error):
                    session.phase = .failed
                    session.isSynthesisStreaming = false
                    self.fusionSession = nil
                    self.isStreaming = false
                    // Preserve partial synthesis if we had any
                    if !session.synthesisContent.isEmpty {
                        self.store.append(role: .assistant, content: session.synthesisContent + "\n\n❗️ Error: \(error.localizedDescription)")
                    } else {
                        self.store.append(role: .assistant, content: "❗️ Fusion Error: \(error.localizedDescription)")
                    }
                    self.currentStreamingContent = ""
                }
            }
        }
    }

    // MARK: - Agent Mode

    private func sendAgentMessage(messages: [(role: String, content: String)], systemPrompt: String?) {
        isStreaming = true
        currentStreamingContent = ""
        activeToolCalls = []

        // Start the engine if not running
        if !agentEngine.isRunning {
            agentEngine.start { [weak self] event in
                DispatchQueue.main.async {
                    self?.handleAgentEvent(event)
                }
            }
        }

        let apiKey = KeychainHelper.shared.get(key: "OpenRouterAPIKey") ?? ""
        guard !apiKey.isEmpty else {
            isStreaming = false
            store.append(role: .assistant, content: "❗️ API key missing. Set it in Settings.")
            return
        }

        let model = selectedModel.isEmpty ? router.config.default : selectedModel
        agentEngine.sendChat(
            messages: messages,
            model: model,
            apiKey: apiKey,
            systemPrompt: systemPrompt
        )
    }

    private func handleAgentEvent(_ event: AgentEvent) {
        switch event {
        case .ready(let tools):
            agentTools = tools
            NSLog("[agent] Ready with tools: %@", tools.joined(separator: ", "))

        case .textDelta(let content):
            currentStreamingContent += content

        case .toolStart(let name, let input):
            let id = UUID().uuidString
            activeToolCalls.append(ToolCallDisplay(id: id, name: name, arguments: input))

        case .toolResult(let name, let output):
            // Update existing tool call or add result
            if let idx = activeToolCalls.firstIndex(where: { $0.name == name && $0.result == nil }) {
                activeToolCalls[idx] = ToolCallDisplay(
                    id: activeToolCalls[idx].id,
                    name: name,
                    arguments: activeToolCalls[idx].arguments,
                    result: output
                )
            }

            // Check if this was a preview_html or file_write for an HTML file
            if name == "preview_html" || (name == "file_write" && output.contains(".html")) {
                // Try to extract path and load preview
                if let data = output.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let path = json["path"] as? String {
                    if let html = try? String(contentsOfFile: path, encoding: .utf8) {
                        showPreview(html: html, title: URL(fileURLWithPath: path).lastPathComponent)
                    }
                }
            }

        case .done(let text):
            isStreaming = false
            let finalText = text.isEmpty ? currentStreamingContent : text
            if !finalText.isEmpty {
                store.append(role: .assistant, content: finalText, modelUsed: "agent → \(router.modelUsed.isEmpty ? selectedModel : router.modelUsed)")
            }
            currentStreamingContent = ""
            activeToolCalls = []

        case .error(let message):
            isStreaming = false
            if !currentStreamingContent.isEmpty {
                store.append(role: .assistant, content: currentStreamingContent + "\n\n❗️ Agent error: \(message)")
            } else {
                store.append(role: .assistant, content: "❗️ Agent error: \(message)")
            }
            currentStreamingContent = ""
            activeToolCalls = []
        }
    }

    // MARK: - Non-fusion completion handler

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
                case .agent: modeLabel = router.modelUsed.isEmpty ? "agent" : router.modelUsed
                }
                store.append(role: .assistant, content: finalText, modelUsed: modeLabel)
            }
        case .failure(let err):
            if !currentStreamingContent.isEmpty {
                store.append(role: .assistant, content: currentStreamingContent + "\n\n❗️ \(errorPrefix.isEmpty ? "" : "\(errorPrefix) ")Error: \(err.localizedDescription)")
            } else {
                let prefix = errorPrefix.isEmpty ? "" : "\(errorPrefix) "
                store.append(role: .assistant, content: "❗️ \(prefix)Error: \(err.localizedDescription)")
            }
        }
        currentStreamingContent = ""
        activeToolCalls = []
    }

    // MARK: - Stop / Clear

    func stopStreaming() {
        router.cancel()
        agentEngine.stop()
        isStreaming = false

        // If there's an active fusion session, save partial state
        if let session = fusionSession {
            if !session.synthesisContent.isEmpty {
                store.append(role: .assistant, content: session.synthesisContent + "\n\n⚠️ Stopped by user")
            }
            fusionSession = nil
        }

        // Also handle non-fusion streaming
        if !currentStreamingContent.isEmpty {
            store.append(role: .assistant, content: currentStreamingContent)
            currentStreamingContent = ""
        }
        activeToolCalls = []
    }

    func clearChat() {
        store.clear()
        activeToolCalls = []
        fusionSession = nil
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

    // MARK: - Preview Panel

    func showPreview(html: String, title: String = "Preview") {
        previewHTML = html
        previewTitle = title
        showingPreview = true
        // Auto-collapse left sidebar to give chat + preview room
        sidebarVisible = false
    }

    func closePreview() {
        showingPreview = false
        previewHTML = nil
    }
}

// NOTE: ToolCallDisplay is defined in ContentView.swift for now.
// It will move here once ContentView is slimmed down.
