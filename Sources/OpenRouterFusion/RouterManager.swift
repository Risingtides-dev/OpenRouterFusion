import Foundation

final class RouterManager: ObservableObject {
    struct Config: Decodable {
        let `default`: String
        let fallbackOrder: [String]
        let maxRetries: Int
        let timeoutSeconds: Int
        let fusion: FusionConfig?
    }

    struct FusionConfig: Decodable {
        let enabled: Bool
        let panelModels: [String]
        let plannerModel: String?
        let judgeModel: String?
        let maxTasks: Int?
        let maxParallelRequests: Int?
        let responseTimeoutSeconds: Int?
    }

    struct FusionTask: Identifiable, Sendable {
        let id = UUID()
        let title: String
        let prompt: String
    }

    struct FusionPanelResult: Identifiable, Sendable {
        let id = UUID()
        let model: String
        let taskTitle: String?
        let content: String?
        let errorDescription: String?

        init(model: String, taskTitle: String? = nil, content: String?, errorDescription: String?) {
            self.model = model
            self.taskTitle = taskTitle
            self.content = content
            self.errorDescription = errorDescription
        }

        var succeeded: Bool {
            guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return errorDescription == nil
        }
    }

    enum ChatMode: String, CaseIterable {
        case fast = "fast"
        case fusion = "fusion"
        case solo = "solo"

        var displayName: String {
            switch self {
            case .fast: return "Fast"
            case .fusion: return "Fusion"
            case .solo: return "Solo"
            }
        }

        var icon: String {
            switch self {
            case .fast: return "bolt.fill"
            case .fusion: return "sparkles"
            case .solo: return "person.fill"
            }
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

    /// Current streaming Task handle (for cancellation)
    private var currentTask: Task<Void, Never>?
    private let taskLock = NSLock()
    /// Guard against concurrent sends — only one stream at a time
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
            config = Config(default: "openrouter/owl-alpha", fallbackOrder: [
                "openai/gpt-oss-120b:free", "google/gemma-4-31b-it:free",
                "nvidia/nemotron-3-super-120b-a12b:free", "qwen/qwen3-coder:free"
            ], maxRetries: 4, timeoutSeconds: 30, fusion: nil)
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            NSLog("⚠️ Could not read ModelConfig.json data: \(error.localizedDescription). Using defaults.")
            config = Config(default: "openrouter/owl-alpha", fallbackOrder: [
                "openai/gpt-oss-120b:free", "google/gemma-4-31b-it:free",
                "nvidia/nemotron-3-super-120b-a12b:free", "qwen/qwen3-coder:free"
            ], maxRetries: 4, timeoutSeconds: 30, fusion: nil)
            return
        }
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            NSLog("⚠️ ModelConfig.json decode failed: \(error). Using defaults.")
            config = Config(default: "openrouter/owl-alpha", fallbackOrder: [
                "openai/gpt-oss-120b:free", "google/gemma-4-31b-it:free",
                "nvidia/nemotron-3-super-120b-a12b:free", "qwen/qwen3-coder:free"
            ], maxRetries: 4, timeoutSeconds: 30, fusion: nil)
        }
    }

    // MARK: - Cancel current streaming task

    func cancel() {
        taskLock.lock()
        defer { taskLock.unlock() }
        currentTask?.cancel()
        currentTask = nil
        inFlight = false
    }

    // MARK: - Send with streaming + optional tool calling

    func send(
        messages: [[String: Any]],
        systemPrompt: String?,
        tools: [[String: Any]]?,
        onChunk: @escaping (String) -> Void,
        onToolCall: @escaping (String, String, String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        // Guard against concurrent sends
        taskLock.lock()
        guard !inFlight else {
            taskLock.unlock()
            completion(.failure(RouterError.allModelsExhausted))
            return
        }
        inFlight = true
        taskLock.unlock()

        // Launch retry loop in a Task (non-blocking, allows send() to remain non-async)
        Task { [weak self] in
            let candidates = [self?.config.default ?? "openrouter/owl-alpha"] + (self?.config.fallbackOrder ?? [])
            var attempt = 0
            var lastError: Error?

            /// Iterative retry loop — avoids unbounded recursion on deep fallback chains
            while attempt < candidates.count && attempt < (self?.config.maxRetries ?? 4) {
                let model = candidates[attempt]
                attempt += 1

                let shouldContinue: Bool = await withCheckedContinuation { continuation in
                    self?.streamRequest(
                        model: model, messages: messages,
                        systemPrompt: systemPrompt, tools: tools,
                        onChunk: onChunk, onToolCall: onToolCall
                    ) { [weak self] result in
                        switch result {
                        case .success(let txt):
                            self?.modelUsed = model
                            self?.inFlight = false
                            completion(.success(txt))
                            continuation.resume(returning: false) // stop loop
                        case .failure(let err):
                            lastError = err
                            // Short-circuit for non-retryable errors (auth, API key, cancellation)
                            if let routerErr = err as? RouterError, !routerErr.isRetryable {
                                self?.inFlight = false
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
            self?.inFlight = false
            completion(.failure(lastError ?? RouterError.allModelsExhausted))
        }
    }

    // MARK: - Solo mode: one explicit model

    func sendSolo(
        model selectedModel: String?,
        messages: [[String: Any]],
        systemPrompt: String?,
        tools: [[String: Any]]?,
        onChunk: @escaping (String) -> Void,
        onToolCall: @escaping (String, String, String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        taskLock.lock()
        guard !inFlight else {
            taskLock.unlock()
            completion(.failure(RouterError.allModelsExhausted))
            return
        }
        inFlight = true
        taskLock.unlock()

        let model = selectedModel?.isEmpty == false ? selectedModel! : config.default
        streamRequest(
            model: model,
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            onChunk: onChunk,
            onToolCall: onToolCall,
            completion: { [weak self] result in
                self?.inFlight = false
                if case .success = result {
                    self?.modelUsed = model
                }
                completion(result)
            }
        )
    }

    // MARK: - Fast mode: openrouter/free (random free model)

    func sendFast(
        messages: [[String: Any]],
        systemPrompt: String?,
        onChunk: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        // Override candidates to only use openrouter/free
        taskLock.lock()
        guard !inFlight else {
            taskLock.unlock()
            completion(.failure(RouterError.allModelsExhausted))
            return
        }
        inFlight = true
        taskLock.unlock()

        Task { [weak self] in
            guard let self = self else { return }
            self.streamRequest(
                model: "openrouter/free",
                messages: messages,
                systemPrompt: systemPrompt,
                tools: nil,
                onChunk: onChunk,
                onToolCall: { _, _, _ in },
                completion: { [weak self] result in
                    self?.inFlight = false
                    if case .success = result {
                        self?.modelUsed = "openrouter/free"
                    }
                    completion(result)
                }
            )
        }
    }

    // MARK: - Fusion mode: custom task router + synthesis

    func sendFusion(
        messages: [[String: Any]],
        systemPrompt: String?,
        onChunk: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let fusionConfig = config.fusion, fusionConfig.enabled, !fusionConfig.panelModels.isEmpty else {
            NSLog("⚠️ Fusion Router not configured, falling back to solo model")
            send(messages: messages, systemPrompt: systemPrompt, tools: nil,
                 onChunk: onChunk, onToolCall: { _, _, _ in }, completion: completion)
            return
        }

        taskLock.lock()
        guard !inFlight else {
            taskLock.unlock()
            completion(.failure(RouterError.allModelsExhausted))
            return
        }
        inFlight = true
        taskLock.unlock()

        let task = Task { [weak self] in
            guard let self = self else { return }
            defer {
                self.taskLock.lock()
                self.inFlight = false
                self.currentTask = nil
                self.taskLock.unlock()
            }

            do {
                var seenModels = Set<String>()
                let panelModels = fusionConfig.panelModels.filter { seenModels.insert($0).inserted }
                let maxTasks = max(1, min(fusionConfig.maxTasks ?? panelModels.count, panelModels.count))
                let timeout = fusionConfig.responseTimeoutSeconds ?? self.config.timeoutSeconds

                await MainActor.run {
                    onChunk("🧭 **Fusion Router** — decomposing prompt into routed tasks…\n\n")
                }

                let fusionTasks = await self.planFusionTasks(
                    messages: messages,
                    systemPrompt: systemPrompt,
                    fusionConfig: fusionConfig,
                    maxTasks: maxTasks,
                    timeoutSeconds: timeout
                )

                if Task.isCancelled {
                    completion(.failure(RouterError.cancelled))
                    return
                }

                await MainActor.run {
                    for (index, task) in fusionTasks.enumerated() {
                        let model = panelModels[index % panelModels.count]
                        onChunk("`\(index + 1).` **\(task.title)** → \(ModelNamer.friendlyName(model))\n")
                    }
                    onChunk("\n⚗️ Running free-model task panel…\n\n")
                }

                let results = await self.runFusionTaskPanel(
                    tasks: fusionTasks,
                    models: panelModels,
                    originalMessages: messages,
                    systemPrompt: systemPrompt,
                    timeoutSeconds: timeout
                )

                if Task.isCancelled {
                    completion(.failure(RouterError.cancelled))
                    return
                }

                let successes = results.filter(\.succeeded)
                let failures = results.filter { !$0.succeeded }
                await MainActor.run {
                    for result in results {
                        let taskLabel = result.taskTitle.map { "\($0) · " } ?? ""
                        if result.succeeded {
                            onChunk("✅ `\(taskLabel)\(ModelNamer.friendlyName(result.model))` complete\n")
                        } else {
                            let error = result.errorDescription ?? "empty response"
                            onChunk("⚠️ `\(taskLabel)\(ModelNamer.friendlyName(result.model))` skipped: \(error)\n")
                        }
                    }
                    onChunk("\n---\n\n")
                }

                guard !successes.isEmpty else {
                    let details = failures.map { "- `\($0.taskTitle ?? "Task")` / `\($0.model)`: \($0.errorDescription ?? "empty response")" }.joined(separator: "\n")
                    completion(.failure(RouterError.httpError(statusCode: 502, body: "No fusion routed tasks returned usable content.\n\(details)")))
                    return
                }

                let fused = await self.synthesizeFusionResult(
                    successes: successes,
                    failures: failures,
                    originalMessages: messages,
                    systemPrompt: systemPrompt,
                    judgeModel: fusionConfig.judgeModel
                )

                if Task.isCancelled {
                    completion(.failure(RouterError.cancelled))
                    return
                }

                self.modelUsed = "Fusion Router (\(successes.count)/\(fusionTasks.count))"
                await MainActor.run { onChunk(fused) }
                completion(.success(fused))
            } catch is CancellationError {
                completion(.failure(RouterError.cancelled))
            } catch {
                completion(.failure(error))
            }
        }

        taskLock.lock()
        currentTask = task
        taskLock.unlock()
    }

    private func planFusionTasks(
        messages: [[String: Any]],
        systemPrompt: String?,
        fusionConfig: FusionConfig,
        maxTasks: Int,
        timeoutSeconds: Int
    ) async -> [FusionTask] {
        let plannerCandidates = [fusionConfig.plannerModel, fusionConfig.judgeModel, "openrouter/owl-alpha", "openrouter/free"]
            .compactMap { $0 }
            .reduce(into: [String]()) { acc, model in
                if !acc.contains(model) { acc.append(model) }
            }

        let prompt = buildFusionPlanningPrompt(messages: messages, maxTasks: maxTasks)
        let plannerMessages: [[String: Any]] = [["role": "user", "content": prompt]]

        for planner in plannerCandidates {
            if Task.isCancelled { return fallbackFusionTasks(messages: messages, maxTasks: maxTasks) }
            do {
                let rawPlan = try await completionRequest(
                    model: planner,
                    messages: plannerMessages,
                    systemPrompt: systemPrompt ?? "You are a routing planner. Decompose prompts into concise, non-overlapping analysis tasks.",
                    timeoutSeconds: timeoutSeconds
                )
                let tasks = parseFusionTasks(from: rawPlan, maxTasks: maxTasks)
                if !tasks.isEmpty {
                    NSLog("🧭 Fusion planner \(planner) produced \(tasks.count) tasks")
                    return tasks
                }
            } catch {
                NSLog("⚠️ Fusion planner \(planner) failed: \(error.localizedDescription)")
                continue
            }
        }

        return fallbackFusionTasks(messages: messages, maxTasks: maxTasks)
    }

    private func runFusionTaskPanel(
        tasks: [FusionTask],
        models: [String],
        originalMessages: [[String: Any]],
        systemPrompt: String?,
        timeoutSeconds: Int
    ) async -> [FusionPanelResult] {
        await withTaskGroup(of: FusionPanelResult.self) { group in
            for (index, task) in tasks.enumerated() {
                let model = models[index % models.count]
                group.addTask { [weak self] in
                    guard let self = self else {
                        return FusionPanelResult(model: model, taskTitle: task.title, content: nil, errorDescription: "router released")
                    }
                    do {
                        let taskMessages = self.buildFusionTaskMessages(
                            task: task,
                            originalMessages: originalMessages
                        )
                        let content = try await self.completionRequest(
                            model: model,
                            messages: taskMessages,
                            systemPrompt: systemPrompt,
                            timeoutSeconds: timeoutSeconds
                        )
                        return FusionPanelResult(model: model, taskTitle: task.title, content: content, errorDescription: nil)
                    } catch is CancellationError {
                        return FusionPanelResult(model: model, taskTitle: task.title, content: nil, errorDescription: RouterError.cancelled.localizedDescription)
                    } catch {
                        return FusionPanelResult(model: model, taskTitle: task.title, content: nil, errorDescription: error.localizedDescription)
                    }
                }
            }

            var ordered: [FusionPanelResult] = []
            for await result in group {
                ordered.append(result)
            }
            return tasks.compactMap { task in
                ordered.first { $0.taskTitle == task.title }
            }
        }
    }

    private func synthesizeFusionResult(
        successes: [FusionPanelResult],
        failures: [FusionPanelResult],
        originalMessages: [[String: Any]],
        systemPrompt: String?,
        judgeModel: String?
    ) async -> String {
        let judgeCandidates = [judgeModel, "openrouter/owl-alpha", "openrouter/free"]
            .compactMap { $0 }
            .reduce(into: [String]()) { acc, model in
                if !acc.contains(model) { acc.append(model) }
            }

        let prompt = buildFusionJudgePrompt(successes: successes, failures: failures, originalMessages: originalMessages)
        let judgeMessages: [[String: Any]] = [["role": "user", "content": prompt]]

        for judge in judgeCandidates {
            if Task.isCancelled { return localFusionSummary(successes: successes, failures: failures, judgeError: RouterError.cancelled.localizedDescription) }
            do {
                let synthesized = try await completionRequest(
                    model: judge,
                    messages: judgeMessages,
                    systemPrompt: systemPrompt ?? "You are a synthesis compiler. Merge routed task results into one answer.",
                    timeoutSeconds: config.timeoutSeconds
                )
                let trimmed = synthesized.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return "## Fusion Synthesis\n\n\(trimmed)\n\n---\n\n`Judge: \(ModelNamer.friendlyName(judge)) · Routed tasks: \(successes.count) succeeded, \(failures.count) failed`"
                }
            } catch {
                NSLog("⚠️ Fusion judge \(judge) failed: \(error.localizedDescription)")
                continue
            }
        }

        return localFusionSummary(successes: successes, failures: failures, judgeError: "judge models unavailable")
    }

    private func buildFusionPlanningPrompt(messages: [[String: Any]], maxTasks: Int) -> String {
        let conversation = compactConversation(messages)
        return """
        You are the planner for a custom Fusion Router.

        Decompose the user's request into up to \(maxTasks) non-overlapping tasks/angles that can be answered independently by different free LLMs, then later synthesized.

        Rules:
        - If the request is simple, return 1 task.
        - Use specialized angles only when useful: direct answer, implementation, risks, alternatives, verification, edge cases.
        - Each task prompt must be self-contained and actionable.
        - Return JSON only. No markdown fences.

        Schema:
        {"tasks":[{"title":"short title","prompt":"specific task prompt"}]}

        Conversation:
        \(conversation)
        """
    }

    private func buildFusionTaskMessages(task: FusionTask, originalMessages: [[String: Any]]) -> [[String: Any]] {
        let conversation = compactConversation(originalMessages)
        return [[
            "role": "user",
            "content": """
            You are one worker in a custom Fusion Router. Complete only the assigned task. Be concise, concrete, and flag uncertainty.

            # Original conversation
            \(conversation)

            # Assigned task
            \(task.title)

            \(task.prompt)
            """
        ]]
    }

    private func buildFusionJudgePrompt(
        successes: [FusionPanelResult],
        failures: [FusionPanelResult],
        originalMessages: [[String: Any]]
    ) -> String {
        let conversation = compactConversation(originalMessages)

        let routedText = successes.map { result in
            """
            ## Task: \(result.taskTitle ?? "General")
            Model: \(result.model)

            \(result.content ?? "")
            """
        }.joined(separator: "\n\n---\n\n")

        let failureText = failures.isEmpty ? "None" : failures.map {
            "- \($0.taskTitle ?? "Task") / \($0.model): \($0.errorDescription ?? "empty response")"
        }.joined(separator: "\n")

        return """
        You are the synthesis compiler for a custom Fusion Router.

        The user's request was decomposed into tasks, routed to free models, and the successful task outputs are below. Compile them into ONE best answer.

        Rules:
        - Answer the original user directly first.
        - Integrate useful details across task outputs.
        - Remove duplication and low-confidence noise.
        - Mention contradictions/caveats only when they change the answer.
        - Do not over-explain the routing process.

        # Original conversation
        \(conversation)

        # Successful routed task outputs
        \(routedText)

        # Failed/skipped routed tasks
        \(failureText)
        """
    }

    private func localFusionSummary(
        successes: [FusionPanelResult],
        failures: [FusionPanelResult],
        judgeError: String
    ) -> String {
        let rawAnswers = successes.map { result in
            """
            ### \(result.taskTitle ?? ModelNamer.friendlyName(result.model))
            `\(ModelNamer.friendlyName(result.model))`

            \(result.content ?? "")
            """
        }.joined(separator: "\n\n---\n\n")

        let failureBlock = failures.isEmpty ? "" : """

        ## Skipped tasks
        \(failures.map { "- `\($0.taskTitle ?? "Task")` / `\($0.model)`: \($0.errorDescription ?? "empty response")" }.joined(separator: "\n"))
        """

        return """
        ## Fusion Router Results

        The synthesis step was unavailable (`\(judgeError)`), so here are the successful routed task outputs.

        ## Successful routed outputs

        \(rawAnswers)
        \(failureBlock)

        ---

        `Fusion Router · \(successes.count) succeeded, \(failures.count) failed`
        """
    }

    private func parseFusionTasks(from raw: String, maxTasks: Int) -> [FusionTask] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonCandidate = extractJSONObject(from: trimmed) ?? trimmed
        guard let data = jsonCandidate.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let taskObjects = root["tasks"] as? [[String: Any]] else {
            return []
        }

        return taskObjects.prefix(maxTasks).compactMap { object in
            guard let title = object["title"] as? String,
                  let prompt = object["prompt"] as? String else { return nil }
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTitle.isEmpty, !cleanPrompt.isEmpty else { return nil }
            return FusionTask(title: cleanTitle, prompt: cleanPrompt)
        }
    }

    private func fallbackFusionTasks(messages: [[String: Any]], maxTasks: Int) -> [FusionTask] {
        let latestUser = latestUserMessage(from: messages) ?? compactConversation(messages)
        let defaults = [
            FusionTask(title: "Direct answer", prompt: "Answer the user's request directly and practically. User request:\n\(latestUser)"),
            FusionTask(title: "Critical check", prompt: "Review the request for hidden assumptions, risks, edge cases, or missing constraints. User request:\n\(latestUser)"),
            FusionTask(title: "Action plan", prompt: "Produce a concrete implementation or action plan for the user's request. User request:\n\(latestUser)"),
            FusionTask(title: "Alternatives", prompt: "Identify viable alternative approaches and tradeoffs for the user's request. User request:\n\(latestUser)")
        ]
        return Array(defaults.prefix(maxTasks))
    }

    private func compactConversation(_ messages: [[String: Any]]) -> String {
        messages.compactMap { msg -> String? in
            guard let role = msg["role"] as? String,
                  let content = msg["content"] as? String else { return nil }
            return "\(role.uppercased()): \(content)"
        }.joined(separator: "\n\n")
    }

    private func latestUserMessage(from messages: [[String: Any]]) -> String? {
        messages.reversed().compactMap { msg -> String? in
            guard let role = msg["role"] as? String, role == "user",
                  let content = msg["content"] as? String else { return nil }
            return content
        }.first
    }

    private func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else { return nil }
        return String(text[start...end])
    }

    private func completionRequest(
        model: String,
        messages: [[String: Any]],
        systemPrompt: String?,
        timeoutSeconds: Int
    ) async throws -> String {
        guard let apiKey = KeychainHelper.shared.get(key: apiKeyKey), !apiKey.isEmpty else {
            throw RouterError.apiKeyMissing
        }
        if Task.isCancelled { throw RouterError.cancelled }

        var requestMessages = messages
        if let sys = systemPrompt, !sys.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            requestMessages.insert(["role": "system", "content": sys], at: 0)
        }

        let body: [String: Any] = [
            "model": model,
            "messages": requestMessages,
            "stream": false
        ]

        guard let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            throw RouterError.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(timeoutSeconds)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResp = response as? HTTPURLResponse else {
            throw RouterError.invalidResponse
        }
        guard 200..<300 ~= httpResp.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if httpResp.statusCode == 401 || httpResp.statusCode == 403 {
                throw RouterError.unauthorized
            }
            throw RouterError.httpError(statusCode: httpResp.statusCode, body: body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first else {
            throw RouterError.invalidResponse
        }

        if let message = first["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        if let text = first["text"] as? String {
            return text
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
        guard let apiKey = KeychainHelper.shared.get(key: apiKeyKey), !apiKey.isEmpty else {
            completion(.failure(RouterError.apiKeyMissing))
            return
        }

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true
        ]
        if let sys = systemPrompt { body["system"] = sys }
        if let tools = tools { body["tools"] = tools }

        guard let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            completion(.failure(RouterError.invalidResponse))
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(config.timeoutSeconds)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(RouterError.serializationFailed(error)))
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
                            self?.currentTask = nil
                            return
                        }

                        guard let jsonData = jsonStr.data(using: .utf8) else { continue }
                        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }
                        guard let choices = json["choices"] as? [[String: Any]] else { continue }
                        guard let delta = choices.first?["delta"] as? [String: Any] else { continue }

                        // Text content — fire onChunk immediately for each token
                        if let content = delta["content"] as? String, !content.isEmpty {
                            accumulated += content
                            await MainActor.run { [weak self] in
                                guard self != nil else { return }
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
                            self?.currentTask = nil
                            return
                        }
                    }
                }

                // Stream ended without [DONE]
                await fireToolCalls()
                safeComplete(.success(accumulated))
                self?.currentTask = nil

            } catch is CancellationError {
                safeComplete(.failure(RouterError.cancelled))
                self?.currentTask = nil
            } catch {
                safeComplete(.failure(error))
                self?.currentTask = nil
            }
        }

        // Store the task so we can cancel it later
        taskLock.lock()
        defer { taskLock.unlock() }
        currentTask = task
    }
}
