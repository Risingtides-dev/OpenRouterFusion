import Foundation

final class RouterManager: ObservableObject {
    struct Config: Decodable {
        let `default`: String
        let fallbackOrder: [String]
        let maxRetries: Int
        let timeoutSeconds: Int
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
            print("⚠️ ModelConfig.json not found at: \(searchedPaths). Using defaults.")
            config = Config(default: "openrouter/owl-alpha", fallbackOrder: [
                "openai/gpt-oss-120b:free", "google/gemma-4-31b-it:free",
                "nvidia/nemotron-3-super-120b-a12b:free", "qwen/qwen3-coder:free"
            ], maxRetries: 4, timeoutSeconds: 30)
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            print("⚠️ Could not read ModelConfig.json data. Using defaults.")
            config = Config(default: "openrouter/owl-alpha", fallbackOrder: [
                "openai/gpt-oss-120b:free", "google/gemma-4-31b-it:free",
                "nvidia/nemotron-3-super-120b-a12b:free", "qwen/qwen3-coder:free"
            ], maxRetries: 4, timeoutSeconds: 30)
            return
        }
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            print("⚠️ ModelConfig.json decode failed: \(error). Using defaults.")
            config = Config(default: "openrouter/owl-alpha", fallbackOrder: [
                "openai/gpt-oss-120b:free", "google/gemma-4-31b-it:free",
                "nvidia/nemotron-3-super-120b-a12b:free", "qwen/qwen3-coder:free"
            ], maxRetries: 4, timeoutSeconds: 30)
        }
    }

    // MARK: - Cancel current streaming task

    func cancel() {
        taskLock.lock()
        defer { taskLock.unlock() }
        currentTask?.cancel()
        currentTask = nil
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
        let candidates = [config.default] + config.fallbackOrder
        var attempt = 0
        var lastError: Error?

        func tryNext() {
            guard attempt < candidates.count && attempt < config.maxRetries else {
                completion(.failure(lastError ?? RouterError.allModelsExhausted))
                return
            }
            let model = candidates[attempt]
            attempt += 1

            streamRequest(
                model: model, messages: messages,
                systemPrompt: systemPrompt, tools: tools,
                onChunk: onChunk, onToolCall: onToolCall
            ) { [weak self] result in
                switch result {
                case .success(let txt):
                    self?.modelUsed = model
                    completion(.success(txt))
                case .failure(let err):
                    lastError = err
                    // Short-circuit for non-retryable errors (auth, API key, cancellation)
                    if let routerErr = err as? RouterError, !routerErr.isRetryable {
                        completion(.failure(routerErr))
                        return
                    }
                    print("⚠️ Model \(model) failed: \(err.localizedDescription); retrying…")
                    tryNext()
                }
            }
        }

        tryNext()
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

                for try await byte in bytes {
                    // Check if task has been cancelled
                    if Task.isCancelled {
                        safeComplete(.failure(RouterError.cancelled))
                        return
                    }

                    dataBuffer.append(byte)

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
                                if toolCalls[index] == nil {
                                    toolCalls[index] = [:]
                                }
                                if let id = deltaTool["id"] as? String {
                                    toolCalls[index]!["id"] = id
                                }
                                if let function = deltaTool["function"] as? [String: Any] {
                                    if let name = function["name"] as? String {
                                        toolCalls[index]!["name"] = name
                                    }
                                    if let args = function["arguments"] as? String {
                                        let existing = toolCalls[index]!["arguments"] as? String ?? ""
                                        toolCalls[index]!["arguments"] = existing + args
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
