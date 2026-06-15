import Foundation

// MARK: - OpenRouterModel

/// A model from the OpenRouter catalog.
struct OpenRouterModel: Identifiable, Codable, Hashable, Equatable {
    let id: String
    let name: String
    let contextLength: Int?
    let pricing: Pricing?
    let architecture: Architecture?

    struct Pricing: Codable, Hashable {
        let prompt: String?
        let completion: String?

        var isFree: Bool {
            let promptPrice = Double(prompt ?? "0") ?? 0
            let completionPrice = Double(completion ?? "0") ?? 0
            return promptPrice == 0 && completionPrice == 0
        }
    }

    struct Architecture: Codable, Hashable {
        let modality: String?
        let tokenizer: String?
    }

    var contextWindow: Int {
        contextLength ?? 128_000
    }

    var isFree: Bool {
        pricing?.isFree ?? false
    }

    var contextTier: String {
        if contextWindow >= 1_000_000 { return "1M+" }
        if contextWindow >= 200_000 { return "200k+" }
        return "<200k"
    }

    var friendlyName: String {
        // Remove provider prefix, clean up
        let parts = id.split(separator: "/")
        let slug = parts.count > 1 ? String(parts[1]) : id
        return slug
            .replacingOccurrences(of: ":free", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

// MARK: - FusionPreset

/// A saved fusion panel configuration.
struct FusionPreset: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var description: String
    var models: [String]  // model IDs
    var judgeModel: String
    var createdAt: Date

    init(id: String = UUID().uuidString, name: String, description: String = "", models: [String], judgeModel: String = "openrouter/owl-alpha", createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.description = description
        self.models = models
        self.judgeModel = judgeModel
        self.createdAt = createdAt
    }
}

// MARK: - ModelCatalog

/// Fetches and caches the OpenRouter model catalog.
@MainActor
final class ModelCatalog: ObservableObject {
    @Published var models: [OpenRouterModel] = []
    @Published var isLoading = false
    @Published var error: String?

    private let cacheKey = "OpenRouterModelCatalog"
    private let cacheExpiryKey = "OpenRouterModelCatalogExpiry"
    private let cacheDuration: TimeInterval = 3600 // 1 hour

    // MARK: - Fetch

    func fetch(apiKey: String? = nil) async {
        // Check cache first
        if let cached = loadFromCache(), !isCacheExpired() {
            self.models = cached
            return
        }

        isLoading = true
        error = nil

        guard let url = URL(string: "https://openrouter.ai/api/v1/models") else {
            error = "Invalid URL"
            isLoading = false
            return
        }

        var request = URLRequest(url: url)
        if let key = apiKey, !key.isEmpty {
            request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession(configuration: .default).data(for: request)
            guard let httpResp = response as? HTTPURLResponse, 200..<300 ~= httpResp.statusCode else {
                error = "Failed to fetch models"
                isLoading = false
                return
            }

            let catalog = try parseModels(from: data)
            self.models = catalog
            saveToCache(catalog)
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
            // Fall back to cache if available
            if let cached = loadFromCache() {
                self.models = cached
            }
        }
    }

    // MARK: - Filtering

    var freeModels: [OpenRouterModel] {
        models.filter { $0.isFree }.sorted { $0.name < $1.name }
    }

    var allModelsSorted: [OpenRouterModel] {
        models.sorted { $0.name < $1.name }
    }

    func search(_ query: String) -> [OpenRouterModel] {
        guard !query.isEmpty else { return allModelsSorted }
        let lower = query.lowercased()
        return models.filter {
            $0.id.lowercased().contains(lower) ||
            $0.name.lowercased().contains(lower)
        }.sorted { $0.name < $1.name }
    }

    // MARK: - Parsing

    private func parseModels(from data: Data) throws -> [OpenRouterModel] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            throw NSError(domain: "ModelCatalog", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
        }

        return dataArray.compactMap { dict -> OpenRouterModel? in
            guard let id = dict["id"] as? String else { return nil }
            let name = dict["name"] as? String ?? id
            let contextLength = dict["context_length"] as? Int

            var pricing: OpenRouterModel.Pricing?
            if let pricingDict = dict["pricing"] as? [String: Any] {
                pricing = OpenRouterModel.Pricing(
                    prompt: pricingDict["prompt"] as? String,
                    completion: pricingDict["completion"] as? String
                )
            }

            var architecture: OpenRouterModel.Architecture?
            if let archDict = dict["architecture"] as? [String: Any] {
                architecture = OpenRouterModel.Architecture(
                    modality: archDict["modality"] as? String,
                    tokenizer: archDict["tokenizer"] as? String
                )
            }

            return OpenRouterModel(
                id: id,
                name: name,
                contextLength: contextLength,
                pricing: pricing,
                architecture: architecture
            )
        }
    }

    // MARK: - Cache

    private func saveToCache(_ models: [OpenRouterModel]) {
        guard let data = try? JSONEncoder().encode(models) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheExpiryKey)
    }

    private func loadFromCache() -> [OpenRouterModel]? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode([OpenRouterModel].self, from: data)
    }

    private func isCacheExpired() -> Bool {
        let expiry = UserDefaults.standard.double(forKey: cacheExpiryKey)
        return Date().timeIntervalSince1970 - expiry > cacheDuration
    }
}

// MARK: - PresetStore

/// Manages saved fusion presets.
@MainActor
final class PresetStore: ObservableObject {
    @Published var presets: [FusionPreset] = []

    private let storageKey = "FusionPresets"

    init() {
        load()
        if presets.isEmpty {
            // Seed with default presets
            presets = defaultPresets()
            save()
        }
    }

    // MARK: - CRUD

    func save(_ preset: FusionPreset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
        } else {
            presets.append(preset)
        }
        save()
    }

    func delete(_ preset: FusionPreset) {
        presets.removeAll { $0.id == preset.id }
        save()
    }

    func rename(_ preset: FusionPreset, to name: String) {
        var updated = preset
        updated.name = name
        save(updated)
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        presets = (try? JSONDecoder().decode([FusionPreset].self, from: data)) ?? []
    }

    // MARK: - Default Presets

    private func defaultPresets() -> [FusionPreset] {
        [
            FusionPreset(
                name: "Free Fusion",
                description: "All available free models — maximum diversity",
                models: [
                    "openrouter/owl-alpha",
                    "openai/gpt-oss-120b:free",
                    "google/gemma-4-31b-it:free",
                    "nvidia/nemotron-3-super-120b-a12b:free",
                    "qwen/qwen3-coder:free",
                    "google/gemma-4-26b-a4b-it:free",
                    "nex-agi/nex-n2-pro:free"
                ],
                judgeModel: "openrouter/owl-alpha"
            ),
            FusionPreset(
                name: "Code Crew",
                description: "Models optimized for code generation",
                models: [
                    "qwen/qwen3-coder:free",
                    "openai/gpt-oss-120b:free",
                    "nvidia/nemotron-3-super-120b-a12b:free"
                ],
                judgeModel: "openrouter/owl-alpha"
            ),
            FusionPreset(
                name: "Quick Trio",
                description: "Fast responses from 3 lightweight models",
                models: [
                    "google/gemma-4-26b-a4b-it:free",
                    "google/gemma-4-31b-it:free",
                    "nex-agi/nex-n2-pro:free"
                ],
                judgeModel: "openrouter/owl-alpha"
            ),
        ]
    }
}
