import Foundation

final class RouterManager: ObservableObject {
    struct Config: Decodable {
        let `default`: String
        let fallbackOrder: [String]
        let maxRetries: Int
        let timeoutSeconds: Int
    }

    let config: Config
    @Published var modelUsed: String = ""
    private let apiKeyKey = "OpenRouterAPIKey"

    init() {
        // Search multiple locations for ModelConfig.json (bundle app vs swift package)
        let candidates = [
            Bundle.main.url(forResource: "ModelConfig", withExtension: "json"),
            Bundle.main.url(forResource: "ModelConfig", withExtension: "json", subdirectory: "Resources"),
            Bundle.main.resourceURL?.appendingPathComponent("ModelConfig.json"),
            Bundle.main.resourceURL?.appendingPathComponent("Resources/ModelConfig.json"),
        ]
        guard let url = candidates.compactMap({ $0 }).first,
              let data = try? Data(contentsOf: url) else {
            fatalError("ModelConfig.json not found in bundle resources. Searched: \(candidates.compactMap { $0?.path })")
        }
        config = try! JSONDecoder().decode(Config.self, from: data)
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
                completion(.failure(lastError ?? NSError(
                    domain: "Router", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "All models exhausted"]
                )))
                return
            }
            let model = candidates[attempt]
            attempt += 1

            streamRequest(model: model, messages: messages, systemPrompt: systemPrompt, tools: tools, onChunk: onChunk, onToolCall: onToolCall) { [weak self] result in
                switch result {
                case .success(let txt):
                    self?.modelUsed = model
                    completion(.success(txt))
                case .failure(let err):
                    print("⚠️ Model \(model) failed: \(err.localizedDescription); retrying…")
                    lastError = err
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
        guard let apiKey = KeychainHelper.shared.get(key: apiKeyKey) else {
            completion(.failure(NSError(
                domain: "Router", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "OpenRouter API key missing"]
            )))
            return
        }

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true
        ]
        if let sys = systemPrompt { body["system"] = sys }
        if let tools = tools { body["tools"] = tools }

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(config.timeoutSeconds)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let session = URLSession(configuration: .default)
        var accumulated = ""
        var toolCalls: [Int: [String: Any]] = [:]
        var completed = false

        Task {
            do {
                let (bytes, response) = try await session.bytes(for: request)

                guard let httpResp = response as? HTTPURLResponse else {
                    throw NSError(domain: "Router", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
                }
                guard 200..<300 ~= httpResp.statusCode else {
                    throw NSError(domain: "Router", code: -httpResp.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResp.statusCode)"])
                }

                var dataBuffer = Data()

                for try await byte in bytes {
                    dataBuffer.append(byte)

                    // Process complete lines
                    while let newlineIdx = dataBuffer.firstIndex(of: 0x0A) {
                        let lineData = dataBuffer.subdata(in: dataBuffer.startIndex..<newlineIdx)
                        let remainingStart = dataBuffer.index(after: newlineIdx)
                        dataBuffer = remainingStart < dataBuffer.endIndex
                            ? dataBuffer.subdata(in: remainingStart..<dataBuffer.endIndex)
                            : Data()

                        guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespaces) else { continue }
                        if !line.hasPrefix("data: ") { continue }

                        let jsonStr = String(line.dropFirst(6))
                        if jsonStr == "[DONE]" {
                            completed = true
                            await finish()
                            return
                        }

                        guard let jsonData = jsonStr.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any] else { continue }

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
                                if toolCalls[index] == nil { toolCalls[index] = [:] }
                                if let id = deltaTool["id"] { toolCalls[index]!["id"] = id }
                                if let function = deltaTool["function"] as? [String: Any] {
                                    if let name = function["name"] { toolCalls[index]!["name"] = name }
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
                            completed = true
                            finishToolCalls()
                            await finish()
                            return
                        }
                    }
                }

                // Stream ended
                if !completed {
                    completed = true
                    finishToolCalls()
                    await finish()
                }

            } catch {
                if !completed {
                    completed = true
                    await MainActor.run {
                        completion(.failure(error))
                    }
                }
            }

            @MainActor
            func finish() {
                completion(accumulated.isEmpty ? .success("") : .success(accumulated))
            }

            func finishToolCalls() {
                for (_, tc) in toolCalls.sorted(by: { $0.key < $1.key }) {
                    if let id = tc["id"] as? String,
                       let name = tc["name"] as? String,
                       let args = tc["arguments"] as? String {
                        Task { @MainActor in onToolCall(id, name, args) }
                    }
                }
            }
        }
    }
}
