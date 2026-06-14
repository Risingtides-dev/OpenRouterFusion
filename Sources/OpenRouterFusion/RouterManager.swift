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

        var displayName: String {
            switch self {
            case .fast: return "Fast"
            case .fusion: return "Fusion"
            case .single: return "Single"
            }
        }

        var icon: String {
            switch self {
            case .fast: return "bolt.fill"
            case .fusion: return "sparkles"
            case .single: return "cpu"
            }
        }

        var helpText: String {
            switch self {
            case .fast: return "One random free model via openrouter/free."
            case .fusion: return "Our custom free model council: parallel panel + local/free judge synthesis."
            case .single: return "One explicit model from the picker."
            }
        }
    }

    struct FusionPanelResult {
        let model: String
        let content: String?
        let error: String?
        let elapsedSeconds: Double

        var succeeded: Bool {
            if let content { return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return false
        }
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

    func sendFusion(
        messages: [[String: Any]],
        systemPrompt: String?,
        onChunk: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard beginInFlight() else {
            completion(.failure(RouterError.allModelsExhausted))
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }

            let panel = self.freeFusionPanel()
            NSLog("🧠 Custom Fusion: asking \(panel.count) free models in parallel: \(panel.joined(separator: ", "))")

            let panelResults = await self.runFusionPanel(
                models: panel,
                messages: messages,
                systemPrompt: systemPrompt
            )

            if Task.isCancelled {
                self.finishInFlight()
                completion(.failure(RouterError.cancelled))
                return
            }

            let successes = panelResults.filter(\.succeeded)
            guard !successes.isEmpty else {
                self.finishInFlight()
                completion(.failure(RouterError.httpError(
                    statusCode: 502,
                    body: self.failureSummary(panelResults)
                )))
                return
            }

            let synthesis = await self.synthesizeFusion(
                messages: messages,
                panelResults: panelResults
            )

            if Task.isCancelled {
                self.finishInFlight()
                completion(.failure(RouterError.cancelled))
                return
            }

            self.modelUsed = synthesis.modelUsed
            self.finishInFlight()
            onChunk(synthesis.text)
            completion(.success(synthesis.text))
        }

        taskLock.lock()
        currentTask = task
        taskLock.unlock()
    }

    /// Streaming single-model send with fallback retry.
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

    private func runFusionPanel(
        models: [String],
        messages: [[String: Any]],
        systemPrompt: String?
    ) async -> [FusionPanelResult] {
        await withTaskGroup(of: FusionPanelResult.self) { group in
            for model in models {
                group.addTask { [weak self] in
                    let started = Date()
                    guard let self else {
                        return FusionPanelResult(model: model, content: nil, error: "Router deallocated", elapsedSeconds: 0)
                    }
                    let result = await self.completionRequest(
                        model: model,
                        messages: messages,
                        systemPrompt: systemPrompt,
                        tools: nil
                    )
                    let elapsed = Date().timeIntervalSince(started)
                    switch result {
                    case .success(let text):
                        return FusionPanelResult(model: model, content: text, error: nil, elapsedSeconds: elapsed)
                    case .failure(let error):
                        NSLog("⚠️ Fusion panel model \(model) failed: \(error.localizedDescription)")
                        return FusionPanelResult(model: model, content: nil, error: error.localizedDescription, elapsedSeconds: elapsed)
                    }
                }
            }

            var results: [FusionPanelResult] = []
            for await result in group {
                results.append(result)
            }
            let order = Dictionary(uniqueKeysWithValues: models.enumerated().map { ($0.element, $0.offset) })
            return results.sorted { (order[$0.model] ?? Int.max) < (order[$1.model] ?? Int.max) }
        }
    }

    private func synthesizeFusion(
        messages: [[String: Any]],
        panelResults: [FusionPanelResult]
    ) async -> (text: String, modelUsed: String) {
        let successful = panelResults.filter(\.succeeded)
        let judgeMessages = buildJudgeMessages(originalMessages: messages, successfulResults: successful)
        let judgeCandidates = dedupe([config.fusionJudgeModel, config.fastModel, "openrouter/free"])

        for judgeModel in judgeCandidates {
            if Task.isCancelled { break }
            let result = await completionRequest(model: judgeModel, messages: judgeMessages, systemPrompt: nil, tools: nil)
            switch result {
            case .success(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return (trimmed + "\n\n" + panelAudit(panelResults, judgeModel: judgeModel), "custom-fusion → \(judgeModel)")
                }
            case .failure(let error):
                NSLog("⚠️ Fusion judge \(judgeModel) failed: \(error.localizedDescription)")
                continue
            }
        }

        return (localFusionFallback(panelResults), "custom-fusion-local")
    }

    private func buildJudgeMessages(
        originalMessages: [[String: Any]],
        successfulResults: [FusionPanelResult]
    ) -> [[String: Any]] {
        let latestUserPrompt = originalMessages.reversed().first { ($0["role"] as? String) == "user" }?["content"] as? String ?? ""
        let panelText = successfulResults.map { result in
            """
            ### \(result.model)
            \(truncate(result.content ?? "", limit: 7_000))
            """
        }.joined(separator: "\n\n---\n\n")

        return [
            [
                "role": "system",
                "content": """
                You are the synthesis judge for a custom free-model fusion engine. You are given the user's prompt and several independent model answers. Produce one best answer.

                Rules:
                - Do not mention OpenRouter's fusion router/plugin. This is client-side fusion.
                - Preserve correct unique insights from individual models.
                - Resolve contradictions explicitly when important.
                - If the panel is uncertain, say what is uncertain.
                - Be concise but complete.
                - Do not invent sources or claim consensus where the panel did not provide it.
                """
            ],
            [
                "role": "user",
                "content": """
                Original user prompt:
                \(latestUserPrompt)

                Independent panel responses:
                \(panelText)

                Now produce the fused final answer.
                """
            ]
        ]
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

    private func panelAudit(_ panelResults: [FusionPanelResult], judgeModel: String) -> String {
        var lines = ["---", "### Fusion audit", "- Judge: `\(judgeModel)`"]
        for result in panelResults {
            if result.succeeded {
                lines.append("- ✅ `\(result.model)` answered in \(String(format: "%.1fs", result.elapsedSeconds))")
            } else {
                lines.append("- ⚠️ `\(result.model)` failed: \(result.error ?? "unknown error")")
            }
        }
        return lines.joined(separator: "\n")
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

    // MARK: - Non-streaming chat completion

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

    private func streamRequest(
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
