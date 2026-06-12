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
        // Load ModelConfig.json from bundle resources
        guard let url = Bundle.main.url(forResource: "ModelConfig", withExtension: "json", subdirectory: "Resources") else {
            fatalError("ModelConfig.json not found in bundle resources")
        }
        let data = try! Data(contentsOf: url)
        config = try! JSONDecoder().decode(Config.self, from: data)
    }
    // Send messages with retry/fallback across models
    func send(messages: [[String: String]], systemPrompt: String?, completion: @escaping (Result<String, Error>) -> Void) {
        var candidates = [config.default] + config.fallbackOrder
        var attempt = 0
        func tryNext() {
            guard attempt < candidates.count && attempt < config.maxRetries else {
                completion(.failure(NSError(domain: "Router", code: -1, userInfo: [NSLocalizedDescriptionKey: "All models exhausted"])))
                return
            }
            let model = candidates[attempt]
            attempt += 1
            request(model: model, messages: messages, systemPrompt: systemPrompt) { result in
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
    // Low‑level streaming request
    private func request(model: String, messages: [[String: String]], systemPrompt: String?, completion: @escaping (Result<String, Error>) -> Void) {
        guard let apiKey = KeychainHelper.shared.get(key: apiKeyKey) else {
            completion(.failure(NSError(domain: "Router", code: -2, userInfo: [NSLocalizedDescriptionKey: "OpenRouter API key missing"])))
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
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // Use a streaming task
        let task = URLSession.shared.streamTask(with: request)
        task.resume()
        var accumulated = ""
        func readChunk() {
            task.readData(ofMinLength: 1, maxLength: 65536, timeout: config.timeoutSeconds) { data, atEOF, error in
                if let error = error { completion(.failure(error)); return }
                if let data = data, let chunk = String(data: data, encoding: .utf8) {
                    // Parse SSE lines
                    for line in chunk.split(separator: "\n") where line.hasPrefix("data:") {
                        let jsonPart = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if jsonPart == "[DONE]" { continue }
                        if let d = try? JSONSerialization.jsonObject(with: Data(jsonPart.utf8)) as? [String: Any],
                           let choices = d["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let content = delta["content"] as? String {
                            accumulated.append(content)
                        }
                    }
                }
                if atEOF {
                    completion(.success(accumulated))
                } else {
                    readChunk()
                }
            }
        }
        readChunk()
    }
}
