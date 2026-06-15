import Foundation

final class RouterManager: ObservableObject {
    struct Config: Decodable {
        let `default`: String
        let fallbackOrder: [String]
        let maxRetries: Int
        let timeoutSeconds: Int
        let fastModel: String
        let fusionPanel: [String]
        let fusionJudgeModel: String

        enum CodingKeys: String, CodingKey {
            case `default`
            case fallbackOrder
            case maxRetries
            case timeoutSeconds
            case fastModel
            case fusionPanel
            case fusionJudgeModel
        }

        init(
            default: String,
            fallbackOrder: [String],
            maxRetries: Int,
            timeoutSeconds: Int,
            fastModel: String = "openrouter/free",
            fusionPanel: [String]? = nil,
            fusionJudgeModel: String = "openrouter/owl-alpha"
        ) {
            self.default = `default`
            self.fallbackOrder = fallbackOrder
            self.maxRetries = maxRetries
            self.timeoutSeconds = timeoutSeconds
            self.fastModel = fastModel
            self.fusionPanel = fusionPanel ?? Config.defaultFusionPanel(primary: `default`, fallbacks: fallbackOrder)
            self.fusionJudgeModel = fusionJudgeModel
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let primary = try container.decodeIfPresent(String.self, forKey: .default) ?? "openrouter/owl-alpha"
            let fallbacks = try container.decodeIfPresent([String].self, forKey: .fallbackOrder) ?? [
                "openai/gpt-oss-120b:free",
                "google/gemma-4-31b-it:free",
                "nvidia/nemotron-3-super-120b-a12b:free",
                "qwen/qwen3-coder:free"
            ]

            self.default = primary
            self.fallbackOrder = fallbacks
            self.maxRetries = try container.decodeIfPresent(Int.self, forKey: .maxRetries) ?? 4
            self.timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 60
            self.fastModel = try container.decodeIfPresent(String.self, forKey: .fastModel) ?? "openrouter/free"
            self.fusionPanel = try container.decodeIfPresent([String].self, forKey: .fusionPanel)
                ?? Config.defaultFusionPanel(primary: primary, fallbacks: fallbacks)
            self.fusionJudgeModel = try container.decodeIfPresent(String.self, forKey: .fusionJudgeModel) ?? "openrouter/owl-alpha"
        }

        static func fallback() -> Config {
            Config(
                default: "openrouter/owl-alpha",
                fallbackOrder: [
                    "openai/gpt-oss-120b:free",
                    "google/gemma-4-31b-it:free",
                    "nvidia/nemotron-3-super-120b-a12b:free",
                    "qwen/qwen3-coder:free"
                ],
                maxRetries: 4,
                timeoutSeconds: 60,
                fastModel: "openrouter/free",
                fusionJudgeModel: "openrouter/owl-alpha"
            )
        }

        private static func defaultFusionPanel(primary: String, fallbacks: [String]) -> [String] {
            dedupe([primary] + fallbacks).filter { model in
                model == "openrouter/free" || model.contains(":free") || model == "openrouter/owl-alpha"
            }
        }

        private static func dedupe(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }
        }
    }

    enum ChatMode: String, CaseIterable {
        case fast = "fast"
        case fusion = "fusion"
        case single = "single"
        case agent = "agent"

        var displayName: String {
            switch self {
            case .fast: return "Fast"
            case .fusion: return "Fusion"
            case .single: return "Single"
            case .agent: return "Agent"
            }
        }

        var icon: String {
            switch self {
            case .fast: return "bolt.fill"
            case .fusion: return "sparkles"
            case .single: return "cpu"
            case .agent: return "terminal"
            }
        }

        var helpText: String {
            switch self {
            case .fast: return "One random free model via openrouter/free."
            case .fusion: return "Our custom free model council: parallel panel + local/free judge synthesis."
            case .single: return "One explicit model from the picker."
            case .agent: return "Tool-using agent with file system access. Writes files, runs commands, previews HTML."
            }
        }
    }

    struct FusionPanelResult {
        let model: String
        let content: String?
        let error: String?
        let elapsedSeconds: Double
        var toolCallsMade: Int = 0

        var succeeded: Bool {
            if let content { return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return false
        }
    }

    // MARK: - Context-aware tool call limits

    /// Known context windows for models in our fusion panel.
    /// Update this when adding new models.
    private static let knownContextWindows: [String: Int] = [
        "openrouter/owl-alpha": 1_000_000,
        "openai/gpt-oss-120b:free": 256_000,
        "google/gemma-4-31b-it:free": 131_072,
        "nvidia/nemotron-3-super-120b-a12b:free": 131_072,
        "qwen/qwen3-coder:free": 262_144,
        "google/gemma-4-26b-a4b-it:free": 131_072,
        "nex-agi/nex-n2-pro:free": 131_072,
        "openrouter/free": 128_000,
    ]

    /// Max tool calls a panel model can make, based on its context window.
    ///  1M+     → 7
    ///  200k-999k → 3
    ///  sub-200k  → 2
    func maxToolCalls(for model: String) -> Int {
        let ctx = RouterManager.knownContextWindows[model] ?? 200_000
        if ctx >= 1_000_000 { return 7 }
        if ctx >= 200_000 { return 3 }
        return 2
    }

    // MARK: - Fusion Event Stream

    enum FusionEvent {
        case panelStarted(models: [String])
        case panelResult(model: String, content: String?, error: String?, elapsedSeconds: Double)
        case synthesisChunk(String)
        case synthesisModel(String)
        case finished(text: String, modelUsed: String)
        case failed(Error)
    }

    enum RouterError: LocalizedError {
        case configNotFound(String)
        case configDecodeFailed(Error)
        case serializationFailed(Error)
        case invalidResponse
        case httpError(statusCode: Int, body: String)
        case unauthorized
        case cancelled
        case apiKeyMissing
        case allModelsExhausted

        /// Whether this error should trigger a retry with the next model
        var isRetryable: Bool {
            switch self {
            case .httpError(let code, _):
                return code != 401 && code != 403
            case .unauthorized, .cancelled, .apiKeyMissing:
                return false
            default:
                return true
            }
        }

        var errorDescription: String? {
            switch self {
            case .configNotFound(let paths):
                return "ModelConfig.json not found. Searched: \(paths)"
            case .configDecodeFailed(let err):
                return "Failed to decode ModelConfig.json: \(err.localizedDescription)"
            case .serializationFailed(let err):
                return "Failed to serialize request body: \(err.localizedDescription)"
            case .invalidResponse:
                return "Invalid response from server"
            case .httpError(let code, let body):
                let bodyPreview = body.count > 200 ? String(body.prefix(200)) + "…" : body
                return "HTTP \(code) — \(bodyPreview)"
            case .unauthorized:
                return "Invalid API key — check your OpenRouter key in Settings"
            case .cancelled:
                return "Request cancelled by user"
            case .apiKeyMissing:
                return "OpenRouter API key missing"
            case .allModelsExhausted:
                return "All models exhausted"
            }
        }
    }

    let config: Config
    @Published var modelUsed: String = ""
    private let apiKeyKey = "OpenRouterAPIKey"

    /// Current top-level Task handle (for cancellation)
    private var currentTask: Task<Void, Never>?
    private let taskLock = NSLock()
    /// Guard against concurrent sends — only one request/council at a time
    @Published private(set) var inFlight = false

    init() {
        // Search multiple locations for ModelConfig.json (bundle app vs swift package)
        let candidates = [
            Bundle.main.url(forResource: "ModelConfig", withExtension: "json"),
            Bundle.main.url(forResource: "ModelConfig", withExtension: "json", subdirectory: "Resources"),
            Bundle.main.resourceURL?.appendingPathComponent("ModelConfig.json"),
            Bundle.main.resourceURL?.appendingPathComponent("Resources/ModelConfig.json"),
        ]
        let searchedPaths = candidates.compactMap { $0?.path }
        guard let url = candidates.compactMap({ $0 }).first else {
            NSLog("⚠️ ModelConfig.json not found at: \(searchedPaths). Using defaults.")
            config = Config.fallback()
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            NSLog("⚠️ Could not read ModelConfig.json data: \(error.localizedDescription). Using defaults.")
            config = Config.fallback()
            return
        }
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            NSLog("⚠️ ModelConfig.json decode failed: \(error). Using defaults.")
            config = Config.fallback()
        }
    }

    // MARK: - Cancel current task

    func cancel() {
        taskLock.lock()
        defer { taskLock.unlock() }
        currentTask?.cancel()
        currentTask = nil
        inFlight = false
    }

    // MARK: - Public send modes

    func sendFast(
        messages: [[String: Any]],
        systemPrompt: String?,
        onChunk: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        send(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: nil,
            preferredModel: config.fastModel,
            onChunk: onChunk,
            onToolCall: { _, _, _ in },
            completion: completion
        )
    }

    func send(
        messages: [[String: Any]],
        systemPrompt: String?,
        tools: [[String: Any]]?,
        preferredModel: String? = nil,
        onChunk: @escaping (String) -> Void,
        onToolCall: @escaping (String, String, String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard beginInFlight() else {
            completion(.failure(RouterError.allModelsExhausted))
            return
        }

        // Launch retry loop in a Task (non-blocking, allows send() to remain non-async)
        let task = Task { [weak self] in
            guard let self else { return }
            let primary = (preferredModel?.isEmpty == false) ? preferredModel! : self.config.default
            let candidates = self.dedupe([primary] + self.config.fallbackOrder)
            var attempt = 0
            var lastError: Error?

            /// Iterative retry loop — avoids unbounded recursion on deep fallback chains
            while attempt < candidates.count && attempt < self.config.maxRetries {
                let model = candidates[attempt]
                attempt += 1

                let shouldContinue: Bool = await withCheckedContinuation { continuation in
                    self.streamRequest(
                        model: model,
                        messages: messages,
                        systemPrompt: systemPrompt,
                        tools: tools,
                        onChunk: onChunk,
                        onToolCall: onToolCall
                    ) { [weak self] result in
                        switch result {
                        case .success(let txt):
                            self?.modelUsed = model
                            self?.finishInFlight()
                            completion(.success(txt))
                            continuation.resume(returning: false) // stop loop
                        case .failure(let err):
                            lastError = err
                            // Short-circuit for non-retryable errors (auth, API key, cancellation)
                            if let routerErr = err as? RouterError, !routerErr.isRetryable {
                                self?.finishInFlight()
                                completion(.failure(routerErr))
                                continuation.resume(returning: false) // stop loop
                                return
                            }
                            NSLog("⚠️ Model \(model) failed: \(err.localizedDescription); retrying…")
                            continuation.resume(returning: true) // continue loop
                        }
                    }
                }

                if !shouldContinue {
                    return
                }
            }

            // All candidates exhausted or maxRetries reached
            self.finishInFlight()
            completion(.failure(lastError ?? RouterError.allModelsExhausted))
        }

        taskLock.lock()
        currentTask = task
        taskLock.unlock()
    }

    // MARK: - Custom fusion internals

    /// Event-driven fusion: yields discrete events the UI can react to in real time.
    /// Accepts the full judge conversation for iterative, multi-turn fusion.
    func sendFusionEvents(
        messages: [[String: Any]],
        systemPrompt: String?
    ) -> AsyncStream<FusionEvent> {
        sendIterativeFusionEvents(judgeConversation: messages, systemPrompt: systemPrompt)
    }

    /// Iterative fusion: the judge is an agent that can request panel passes.
    /// Pass the full conversation history (including prior panel results and synthesis).
    func sendIterativeFusionEvents(
        judgeConversation: [[String: Any]],
        systemPrompt: String?
    ) -> AsyncStream<FusionEvent> {
        AsyncStream { continuation in
            // Auto-cancel stale in-flight request
            if self.inFlight {
                NSLog("⚠️ Previous fusion still in flight — auto-cancelling")
                self.cancel()
            }
            guard self.beginInFlight() else {
                continuation.yield(.failed(RouterError.allModelsExhausted))
                continuation.finish()
                return
            }

            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                let panel = self.freeFusionPanel()
                NSLog("🧠 Fusion: asking \(panel.count) free models in parallel: \(panel.joined(separator: ", "))")
                continuation.yield(.panelStarted(models: panel))

                // Phase 1: Run panel models in parallel, yield each result as it arrives
                let panelResults = await self.runFusionPanelStreaming(
                    models: panel,
                    messages: judgeConversation,
                    systemPrompt: systemPrompt
                ) { result in
                    continuation.yield(.panelResult(
                        model: result.model,
                        content: result.content,
                        error: result.error,
                        elapsedSeconds: result.elapsedSeconds
                    ))
                }

                if Task.isCancelled {
                    self.finishInFlight()
                    continuation.yield(.failed(RouterError.cancelled))
                    continuation.finish()
                    return
                }

                let successes = panelResults.filter(\.succeeded)
                guard !successes.isEmpty else {
                    self.finishInFlight()
                    continuation.yield(.failed(RouterError.httpError(
                        statusCode: 502,
                        body: self.failureSummary(panelResults)
                    )))
                    continuation.finish()
                    return
                }

                // Phase 2: Stream judge synthesis
                let synthesis = await self.synthesizeFusionStreaming(
                    messages: judgeConversation,
                    panelResults: panelResults,
                    onChunk: { chunk in
                        continuation.yield(.synthesisChunk(chunk))
                    },
                    onModel: { model in
                        continuation.yield(.synthesisModel(model))
                    }
                )

                if Task.isCancelled {
                    self.finishInFlight()
                    continuation.yield(.failed(RouterError.cancelled))
                    continuation.finish()
                    return
                }

                self.modelUsed = synthesis.modelUsed
                self.finishInFlight()
                continuation.yield(.finished(text: synthesis.text, modelUsed: synthesis.modelUsed))
                continuation.finish()
            }

            taskLock.lock()
            currentTask = task
            taskLock.unlock()

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func runFusionPanelStreaming(
        models: [String],
        messages: [[String: Any]],
        systemPrompt: String?,
        onResult: @escaping (FusionPanelResult) -> Void
    ) async -> [FusionPanelResult] {
        await withTaskGroup(of: FusionPanelResult.self) { group in
            for model in models {
                group.addTask { [weak self] in
                    let started = Date()
                    guard let self else {
                        return FusionPanelResult(model: model, content: nil, error: "Router deallocated", elapsedSeconds: 0)
                    }
                    let maxCalls = self.maxToolCalls(for: model)
                    let result = await self.completionWithTools(
                        model: model,
                        messages: messages,
                        systemPrompt: systemPrompt,
                        maxCalls: maxCalls
                    )
                    let elapsed = Date().timeIntervalSince(started)
                    switch result {
                    case .success(let (text, callsMade)):
                        NSLog("🧠 Panel model \(model) answered (\(callsMade) tool calls)")
                        return FusionPanelResult(model: model, content: text, error: nil, elapsedSeconds: elapsed, toolCallsMade: callsMade)
                    case .failure(let error):
                        NSLog("⚠️ Fusion panel model \(model) failed: \(error.localizedDescription)")
                        return FusionPanelResult(model: model, content: nil, error: error.localizedDescription, elapsedSeconds: elapsed)
                    }
                }
            }

            var results: [FusionPanelResult] = []
            for await result in group {
                results.append(result)
                // Yield each result as it arrives (out of order, but real-time)
                onResult(result)
            }
            let order = Dictionary(uniqueKeysWithValues: models.enumerated().map { ($0.element, $0.offset) })
            return results.sorted { (order[$0.model] ?? Int.max) < (order[$1.model] ?? Int.max) }
        }
    }

    private func synthesizeFusionStreaming(
        messages: [[String: Any]],
        panelResults: [FusionPanelResult],
        onChunk: @escaping (String) -> Void,
        onModel: @escaping (String) -> Void
    ) async -> (text: String, modelUsed: String) {
        let successful = panelResults.filter(\.succeeded)
        let judgeMessages = buildJudgeMessages(originalMessages: messages, successfulResults: successful)
        let judgeCandidates = dedupe([config.fusionJudgeModel, config.fastModel, "openrouter/free"])

        for judgeModel in judgeCandidates {
            if Task.isCancelled { break }

            onModel(judgeModel)

            let result: String? = await withCheckedContinuation { continuation in
                var accumulated = ""
                self.streamRequest(
                    model: judgeModel,
                    messages: judgeMessages,
                    systemPrompt: nil,
                    tools: nil,
                    onChunk: { chunk in
                        accumulated += chunk
                        onChunk(chunk)
                    },
                    onToolCall: { _, _, _ in }
                ) { result in
                    switch result {
                    case .success:
                        continuation.resume(returning: accumulated)
                    case .failure(let error):
                        NSLog("⚠️ Fusion judge \(judgeModel) failed: \(error.localizedDescription)")
                        continuation.resume(returning: nil)
                    }
                }
            }

            if let text = result {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return (trimmed, "custom-fusion → \(judgeModel)")
                }
            }
        }

        // All judges failed — local fallback
        let fallback = localFusionFallback(panelResults)
        onChunk(fallback)
        return (fallback, "custom-fusion-local")
    }

    private func buildJudgeMessages(
        originalMessages: [[String: Any]],
        successfulResults: [FusionPanelResult]
    ) -> [[String: Any]] {
        let latestUserPrompt = originalMessages.reversed().first { ($0["role"] as? String) == "user" }?["content"] as? String ?? ""
        let panelText = successfulResults.map { result in
            """
            ### \(result.model) (answered in \(String(format: "%.1fs", result.elapsedSeconds)))
            \(truncate(result.content ?? "", limit: 7_000))
            """
        }.joined(separator: "\n\n---\n\n")

        let judgeMessages: [[String: Any]] = [
            [
                "role": "system",
                "content": """
                You are the synthesis judge for a client-side multi-model fusion engine.

                You receive the user's original prompt and several independent responses from different AI models (the "panel"). Your job is to produce ONE final answer that is BETTER than any individual panel response.

                ## Rules

                1. **You MUST use the panel outputs.** Read every panel response carefully. Extract the best ideas, code patterns, and insights from each.
                2. **You MUST cite contributions.** When a specific insight or code pattern comes from a panel model, mention which model contributed it (e.g., "Based on Nemotron's approach to...").
                3. **Resolve contradictions.** If panel models disagree, explain which approach you chose and why.
                4. **For code tasks: produce a SINGLE, SELF-CONTAINED HTML FILE.** Everything (HTML, CSS, JS) must be in one file that can be opened directly in a browser. Do NOT output separate files. Do NOT use external dependencies unless loading from CDN.
                5. **The output must actually work.** If the task involves code (Three.js, Canvas, WebGL, etc.), the result must be a complete, runnable file. Test your logic mentally — would this actually render?
                6. **Do NOT just rewrite from scratch.** Your job is to synthesize the panel's work, not replace it. If you're producing code that looks nothing like any panel response, you're doing it wrong.
                7. **Be concise in explanations, complete in code.** Short explanation, full working code.
                """
            ],
            [
                "role": "user",
                "content": """
                Original user prompt:
                \(latestUserPrompt)

                ---

                Independent panel responses (\(successfulResults.count) models answered):

                \(panelText)

                ---

                Now produce the fused final answer. Remember:
                - Use the panel's work as your foundation
                - Cite which model contributed what
                - For code: output ONE self-contained HTML file that works in a browser
                """
            ]
        ]

        // Debug: log the judge prompt so we can verify it sees the panel outputs
        NSLog("🧠 Judge prompt: \(successfulResults.count) panel responses, \(panelText.count) chars of panel text")
        for result in successfulResults {
            NSLog("   ✅ \(result.model): \(result.content?.count ?? 0) chars")
        }

        return judgeMessages
    }

    private func localFusionFallback(_ panelResults: [FusionPanelResult]) -> String {
        let successful = panelResults.filter(\.succeeded)
        let failed = panelResults.filter { !$0.succeeded }
        var output = """
        # Fusion Result

        The free judge model was unavailable, so this is a deterministic local fusion fallback. At least one panel model answered successfully.

        ## Successful panel outputs
        """

        for result in successful {
            output += "\n\n### \(result.model) · \(String(format: "%.1fs", result.elapsedSeconds))\n\n"
            output += truncate(result.content ?? "", limit: 10_000)
        }

        if !failed.isEmpty {
            output += "\n\n## Panel failures tolerated\n"
            for result in failed {
                output += "\n- `\(result.model)`: \(result.error ?? "unknown error")"
            }
        }

        return output
    }

    private func failureSummary(_ panelResults: [FusionPanelResult]) -> String {
        if panelResults.isEmpty { return "Fusion panel was empty." }
        return panelResults.map { result in
            "\(result.model): \(result.error ?? "empty response")"
        }.joined(separator: "\n")
    }

    private func freeFusionPanel() -> [String] {
        let bannedServerFusionRouters = Set(["openrouter/" + "fusion", "openrouter:" + "fusion"])
        let filtered = config.fusionPanel.filter { model in
            // Explicitly ban the server-side OpenRouter Fusion router/plugin alias.
            !bannedServerFusionRouters.contains(model) &&
            (model == "openrouter/free" || model == "openrouter/owl-alpha" || model.contains(":free"))
        }
        return dedupe(filtered).isEmpty ? Config.fallback().fusionPanel : dedupe(filtered)
    }

    // MARK: - Read-only tools for panel models

    /// Tool definitions panel models can use to gather local context.
    /// Read-only: no file writes, no destructive commands.
    private var panelToolDefinitions: [[String: Any]] {
        [
            [
                "type": "function",
                "function": [
                    "name": "read_file",
                    "description": "Read a file from disk. Returns the content as text.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": ["type": "string", "description": "Absolute file path to read"]
                        ],
                        "required": ["path"]
                    ] as [String: Any]
                ] as [String: Any]
            ],
            [
                "type": "function",
                "function": [
                    "name": "list_dir",
                    "description": "List files and directories at a given path.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": ["type": "string", "description": "Directory path to list"]
                        ],
                        "required": ["path"]
                    ] as [String: Any]
                ] as [String: Any]
            ],
            [
                "type": "function",
                "function": [
                    "name": "run_command",
                    "description": "Run a read-only shell command (ls, cat, head, tail, wc, grep, find, etc.). Do NOT use for writes or destructive operations.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "command": ["type": "string", "description": "Shell command to execute"]
                        ],
                        "required": ["command"]
                    ] as [String: Any]
                ] as [String: Any]
            ]
        ]
    }

    /// Execute a tool call from a panel model and return the result string.
    private func executePanelTool(name: String, arguments: [String: Any]) -> String {
        switch name {
        case "read_file":
            guard let path = arguments["path"] as? String else { return "Error: missing path parameter" }
            do {
                let content = try String(contentsOfFile: path, encoding: .utf8)
                let lines = content.components(separatedBy: "\n").count
                // Truncate large files
                if content.count > 50_000 {
                    return String(content.prefix(50_000)) + "\n...[truncated at 50KB, \(lines) total lines]"
                }
                return content
            } catch {
                return "Error reading file: \(error.localizedDescription)"
            }

        case "list_dir":
            guard let path = arguments["path"] as? String else { return "Error: missing path parameter" }
            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: path)
                return contents.sorted().joined(separator: "\n")
            } catch {
                return "Error listing directory: \(error.localizedDescription)"
            }

        case "run_command":
            guard let command = arguments["command"] as? String else { return "Error: missing command parameter" }
            let proc = Process()
            let pipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-c", command]
            proc.standardOutput = pipe
            proc.standardError = pipe
            proc.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                return output.count > 20_000 ? String(output.prefix(20_000)) + "\n...[truncated]" : output
            } catch {
                return "Error running command: \(error.localizedDescription)"
            }

        default:
            return "Error: unknown tool '\(name)'"
        }
    }

    /// Completion request with tool-calling loop.
    /// The model can call tools up to `maxCalls` times before getting a final text response.
    private func completionWithTools(
        model: String,
        messages: [[String: Any]],
        systemPrompt: String?,
        maxCalls: Int
    ) async -> Result<(text: String, toolCallsMade: Int), Error> {
        var conversation = messages
        var callsMade = 0

        while callsMade < maxCalls {
            if Task.isCancelled { return .failure(RouterError.cancelled) }

            // Make raw request to get full message including tool_calls
            let rawResult = await rawCompletionRequest(
                model: model,
                messages: conversation,
                systemPrompt: systemPrompt,
                tools: panelToolDefinitions
            )

            switch rawResult {
            case .failure(let error):
                // If tools aren't supported, retry without
                if callsMade == 0 {
                    let fallback = await completionRequest(
                        model: model,
                        messages: conversation,
                        systemPrompt: systemPrompt,
                        tools: nil
                    )
                    switch fallback {
                    case .success(let text): return .success((text, 0))
                    case .failure(let err): return .failure(err)
                    }
                }
                return .failure(error)

            case .success(let message):
                let content = message["content"] as? String ?? ""
                let toolCalls = message["tool_calls"] as? [[String: Any]] ?? []

                if toolCalls.isEmpty {
                    // No tool calls — final text response
                    return .success((content, callsMade))
                }

                // Execute tool calls
                callsMade += 1
                // Append assistant message with tool calls
                conversation.append(["role": "assistant", "content": content, "tool_calls": toolCalls] as [String: Any])

                for tc in toolCalls {
                    let tcId = tc["id"] as? String ?? UUID().uuidString
                    let function = tc["function"] as? [String: Any] ?? [:]
                    let name = function["name"] as? String ?? "unknown"
                    let argsStr = function["arguments"] as? String ?? "{}"
                    let args = (try? JSONSerialization.jsonObject(with: argsStr.data(using: .utf8) ?? Data())) as? [String: Any] ?? [:]

                    let output = executePanelTool(name: name, arguments: args)
                    conversation.append([
                        "role": "tool",
                        "tool_call_id": tcId,
                        "content": output
                    ] as [String: Any])
                }
            }
        }

        // Max calls hit — final request without tools
        let final = await completionRequest(
            model: model,
            messages: conversation,
            systemPrompt: systemPrompt,
            tools: nil
        )
        switch final {
        case .success(let text): return .success((text, callsMade))
        case .failure(let error): return .failure(error)
        }
    }

    /// Raw completion request — returns the full message object (including tool_calls).
    private func rawCompletionRequest(
        model: String,
        messages: [[String: Any]],
        systemPrompt: String?,
        tools: [[String: Any]]?
    ) async -> Result<[String: Any], Error> {
        do {
            let request = try makeRequest(
                model: model,
                messages: messages,
                systemPrompt: systemPrompt,
                tools: tools,
                stream: false
            )
            let (data, response) = try await URLSession(configuration: .default).data(for: request)
            guard let httpResp = response as? HTTPURLResponse else {
                return .failure(RouterError.invalidResponse)
            }
            guard 200..<300 ~= httpResp.statusCode else {
                let body = String(data: data, encoding: .utf8) ?? ""
                if httpResp.statusCode == 401 || httpResp.statusCode == 403 {
                    return .failure(RouterError.unauthorized)
                }
                return .failure(RouterError.httpError(statusCode: httpResp.statusCode, body: body))
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any]
            else {
                return .failure(RouterError.invalidResponse)
            }
            return .success(message)
        } catch is CancellationError {
            return .failure(RouterError.cancelled)
        } catch let routerError as RouterError {
            return .failure(routerError)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Tool call extraction (unused — rawCompletionRequest handles this now)

    // MARK: - Completion request (non-streaming)

    private func completionRequest(
        model: String,
        messages: [[String: Any]],
        systemPrompt: String?,
        tools: [[String: Any]]?
    ) async -> Result<String, Error> {
        do {
            let request = try makeRequest(
                model: model,
                messages: messages,
                systemPrompt: systemPrompt,
                tools: tools,
                stream: false
            )
            let (data, response) = try await URLSession(configuration: .default).data(for: request)
            guard let httpResp = response as? HTTPURLResponse else {
                return .failure(RouterError.invalidResponse)
            }
            guard 200..<300 ~= httpResp.statusCode else {
                let body = String(data: data, encoding: .utf8) ?? ""
                if httpResp.statusCode == 401 || httpResp.statusCode == 403 {
                    return .failure(RouterError.unauthorized)
                }
                return .failure(RouterError.httpError(statusCode: httpResp.statusCode, body: body))
            }
            let text = try parseCompletionContent(from: data)
            return .success(text)
        } catch is CancellationError {
            return .failure(RouterError.cancelled)
        } catch let routerError as RouterError {
            return .failure(routerError)
        } catch {
            return .failure(error)
        }
    }

    private func parseCompletionContent(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any]
        else {
            throw RouterError.invalidResponse
        }

        if let content = message["content"] as? String {
            return content
        }

        // Some providers return multimodal-style content arrays.
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { part -> String? in
                if let text = part["text"] as? String { return text }
                if let content = part["content"] as? String { return content }
                return nil
            }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }

        throw RouterError.invalidResponse
    }

    // MARK: - True SSE streaming via URLSession.bytes(for:)

    func streamRequest(
        model: String,
        messages: [[String: Any]],
        systemPrompt: String?,
        tools: [[String: Any]]?,
        onChunk: @escaping (String) -> Void,
        onToolCall: @escaping (String, String, String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let request: URLRequest
        do {
            request = try makeRequest(
                model: model,
                messages: messages,
                systemPrompt: systemPrompt,
                tools: tools,
                stream: true
            )
        } catch let routerError as RouterError {
            completion(.failure(routerError))
            return
        } catch {
            completion(.failure(error))
            return
        }

        let session = URLSession(configuration: .default)
        var accumulated = ""
        var toolCalls: [Int: [String: Any]] = [:]
        var completed = false
        let lock = NSLock()

        /// Thread-safe single-fire completion helper
        func safeComplete(_ result: Result<String, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return }
            completed = true
            Task { @MainActor in
                completion(result)
            }
        }

        /// Fire accumulated tool calls on MainActor
        @MainActor
        func fireToolCalls() {
            for (_, tc) in toolCalls.sorted(by: { $0.key < $1.key }) {
                if let id = tc["id"] as? String,
                   let name = tc["name"] as? String,
                   let args = tc["arguments"] as? String {
                    onToolCall(id, name, args)
                }
            }
        }

        let task = Task { [weak self] in
            do {
                let (bytes, response) = try await session.bytes(for: request)

                guard let httpResp = response as? HTTPURLResponse else {
                    throw RouterError.invalidResponse
                }
                guard 200..<300 ~= httpResp.statusCode else {
                    // Read error body for diagnostic details (typically short JSON)
                    var errorBody = ""
                    for try await line in bytes.lines {
                        errorBody += line
                    }
                    if httpResp.statusCode == 401 || httpResp.statusCode == 403 {
                        throw RouterError.unauthorized
                    }
                    throw RouterError.httpError(statusCode: httpResp.statusCode, body: errorBody)
                }

                var dataBuffer = Data()
                let maxBufferSize = 65536 // 64KB max line length

                for try await byte in bytes {
                    // Check if task has been cancelled
                    if Task.isCancelled {
                        safeComplete(.failure(RouterError.cancelled))
                        return
                    }

                    dataBuffer.append(byte)

                    // Guard against unbounded buffer growth (malformed data without newlines)
                    if dataBuffer.count > maxBufferSize {
                        NSLog("⚠️ SSE buffer exceeded limit (\(dataBuffer.count) bytes); discarding malformed stream")
                        dataBuffer = Data()
                        continue
                    }

                    // Process complete lines
                    while let newlineIdx = dataBuffer.firstIndex(of: 0x0A) {
                        let lineData = dataBuffer.subdata(in: dataBuffer.startIndex..<newlineIdx)
                        let remainingStart = dataBuffer.index(after: newlineIdx)
                        dataBuffer = remainingStart < dataBuffer.endIndex
                            ? dataBuffer.subdata(in: remainingStart..<dataBuffer.endIndex)
                            : Data()

                        guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespaces)
                        else { continue }
                        if !line.hasPrefix("data: ") { continue }

                        let jsonStr = String(line.dropFirst(6))
                        if jsonStr == "[DONE]" {
                            await fireToolCalls()
                            safeComplete(.success(accumulated))
                            self?.clearCurrentTask()
                            return
                        }

                        guard let jsonData = jsonStr.data(using: .utf8) else { continue }
                        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }
                        guard let choices = json["choices"] as? [[String: Any]] else { continue }
                        guard let delta = choices.first?["delta"] as? [String: Any] else { continue }

                        // Text content — fire onChunk immediately for each token
                        if let content = delta["content"] as? String, !content.isEmpty {
                            accumulated += content
                            await MainActor.run {
                                onChunk(content)
                            }
                        }

                        // Tool calls (streamed incrementally)
                        if let deltaTools = delta["tool_calls"] as? [[String: Any]] {
                            for deltaTool in deltaTools {
                                let index = deltaTool["index"] as? Int ?? 0
                                // Ensure the dictionary exists for this index
                                if toolCalls[index] == nil {
                                    toolCalls[index] = [:]
                                }
                                // Safe optional chaining: we just ensured the key exists above
                                guard toolCalls[index] != nil else { continue }

                                if let id = deltaTool["id"] as? String {
                                    toolCalls[index]?["id"] = id
                                }
                                if let function = deltaTool["function"] as? [String: Any] {
                                    if let name = function["name"] as? String {
                                        toolCalls[index]?["name"] = name
                                    }
                                    if let args = function["arguments"] as? String {
                                        let existing = (toolCalls[index]?["arguments"] as? String) ?? ""
                                        toolCalls[index]?["arguments"] = existing + args
                                    }
                                }
                            }
                        }

                        // Check for finish_reason
                        if let finishReason = choices.first?["finish_reason"] as? String,
                           finishReason == "stop" || finishReason == "length" {
                            await fireToolCalls()
                            safeComplete(.success(accumulated))
                            self?.clearCurrentTask()
                            return
                        }
                    }
                }

                // Stream ended without [DONE]
                await fireToolCalls()
                safeComplete(.success(accumulated))
                self?.clearCurrentTask()

            } catch is CancellationError {
                safeComplete(.failure(RouterError.cancelled))
                self?.clearCurrentTask()
            } catch {
                safeComplete(.failure(error))
                self?.clearCurrentTask()
            }
        }

        // Store the task so we can cancel it later
        taskLock.lock()
        defer { taskLock.unlock() }
        currentTask = task
    }

    // MARK: - Request helpers

    private func makeRequest(
        model: String,
        messages: [[String: Any]],
        systemPrompt: String?,
        tools: [[String: Any]]?,
        stream: Bool
    ) throws -> URLRequest {
        guard let apiKey = KeychainHelper.shared.get(key: apiKeyKey), !apiKey.isEmpty else {
            throw RouterError.apiKeyMissing
        }

        var payloadMessages = messages
        if let sys = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !sys.isEmpty {
            payloadMessages.insert(["role": "system", "content": sys], at: 0)
        }

        var body: [String: Any] = [
            "model": model,
            "messages": payloadMessages,
            "stream": stream
        ]
        if let tools = tools { body["tools"] = tools }

        guard let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            throw RouterError.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(config.timeoutSeconds)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("OpenRouterFusion", forHTTPHeaderField: "X-Title")
        request.addValue("https://github.com/risingtidesdev/OpenRouterFusion", forHTTPHeaderField: "HTTP-Referer")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw RouterError.serializationFailed(error)
        }
        return request
    }

    private func beginInFlight() -> Bool {
        taskLock.lock()
        defer { taskLock.unlock() }
        guard !inFlight else { return false }
        inFlight = true
        return true
    }

    private func finishInFlight() {
        taskLock.lock()
        currentTask = nil
        inFlight = false
        taskLock.unlock()
    }

    private func clearCurrentTask() {
        taskLock.lock()
        currentTask = nil
        taskLock.unlock()
    }

    private func dedupe(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n…[truncated]"
    }
}
