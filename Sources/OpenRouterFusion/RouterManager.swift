import Foundation

final class RouterManager: ObservableObject {
    struct Config: Decodable {
        let `default`: String
        let fallbackOrder: [String]
        let maxRetries: Int
        let timeoutSeconds: Int
    }

    let config: Config
    private let apiKeyKey = "OpenRouterAPIKey"

    init() {
        // Search multiple locations for ModelConfig.json
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

    // MARK: - Send with streaming callbacks

    func send(
        messages: [[String: String]],
        systemPrompt: String?,
        onChunk: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let candidates = [config.default] + config.fallbackOrder
        var attempt = 0

        func tryNext() {
            guard attempt < candidates.count && attempt < config.maxRetries else {
                completion(.failure(NSError(
                    domain: "Router",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "All models exhausted"]
                )))
                return
            }
            let model = candidates[attempt]
            attempt += 1

            request(model: model, messages: messages, systemPrompt: systemPrompt, onChunk: onChunk) { result in
                switch result {
                case .success(let txt):
                    completion(.success(txt))
                case .failure(let err):
                    print("⚠️ Model \(model) failed: \(err.localizedDescription); retrying…")
                    tryNext()
                }
            }
        }

        tryNext()
    }

    // MARK: - Low-level SSE streaming request

    private func request(
        model: String,
        messages: [[String: String]],
        systemPrompt: String?,
        onChunk: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let apiKey = KeychainHelper.shared.get(key: apiKeyKey) else {
            completion(.failure(NSError(
                domain: "Router",
                code: -2,
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

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(config.timeoutSeconds)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        var accumulated = ""
        let session = URLSession.shared

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                if !accumulated.isEmpty {
                    completion(.success(accumulated))
                } else {
                    completion(.failure(error))
                }
                return
            }

            guard let data = data else {
                if !accumulated.isEmpty {
                    completion(.success(accumulated))
                } else {
                    completion(.failure(NSError(
                        domain: "Router",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "No data received"]
                    )))
                }
                return
            }

            // Parse SSE data: lines starting with "data: "
            if let raw = String(data: data, encoding: .utf8) {
                let lines = raw.components(separatedBy: .newlines)
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("data: ") {
                        let jsonStr = String(trimmed.dropFirst(6))
                        if jsonStr == "[DONE]" { continue }
                        guard let jsonData = jsonStr.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String else {
                            continue
                        }
                        accumulated += content
                        onChunk(content)
                    }
                }
            }

            if !accumulated.isEmpty {
                completion(.success(accumulated))
            } else {
                // Fallback: try to parse as non-streaming JSON
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    completion(.failure(NSError(
                        domain: "Router",
                        code: -4,
                        userInfo: [NSLocalizedDescriptionKey: "Malformed response"]
                    )))
                    return
                }
                completion(.success(content))
            }
        }
        task.resume()
    }
}
