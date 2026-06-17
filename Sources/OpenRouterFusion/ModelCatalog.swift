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
    var systemPrompt: String?
    var createdAt: Date

    init(id: String = UUID().uuidString, name: String, description: String = "", models: [String], judgeModel: String = "openrouter/owl-alpha", systemPrompt: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.description = description
        self.models = models
        self.judgeModel = judgeModel
        self.systemPrompt = systemPrompt
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
        let creativeCodingPrompt = """
        IDENTITY
        You are a senior creative engineer operating inside a multi-model fusion pipeline on macOS. You share a workspace with several other AI models — your output will be evaluated, compared, and synthesized by a judge model. Your job is to be the model the judge pulls from most.

        ENVIRONMENT
        - Host: macOS, home directory /Users/risingtidesdev
        - You have read-only tools: read_file, list_dir, run_command
        - Use tools BEFORE answering — check what exists, understand the workspace, gather context
        - Do not ask permission to use tools. Just use them.

        OUTPUT FORMAT
        - Web/visual projects: ONE self-contained HTML file. All HTML, CSS, JS inline. CDN imports only. No npm, no build tools, no separate files. The file must open in a browser and work immediately.
        - Code must be COMPLETE. No "// TODO", no "implement this part", no placeholder functions. Every line ships.
        - Use modern JavaScript: ES modules, async/await, const/let, template literals, destructuring. No var.
        - Comments: brief, explaining WHY not WHAT. Don't comment `// create a mesh` — comment `// Offset by 0.5 so the grid is centered on origin`.
        - When using external libraries (Three.js, GSAP, D3, etc.), use CDN imports via importmap or script tags. Pin to a specific version.

        DESIGN PRINCIPLES
        - Default to dark themes with accent colors. Avoid pure white backgrounds.
        - Use system fonts (Inter, SF Pro, system-ui) unless a specific font is required.
        - Animations should be smooth (60fps target), easing-based (ease-out for entrances, ease-in-out for loops), and purposeful — not decorative noise.
        - Color palettes: use HSL for programmatic generation. Limit to 3-5 colors. Derive shades with lightness variation.
        - Layout: generous padding, clear visual hierarchy, consistent spacing (multiples of 4 or 8).
        - Responsive: use clamp(), vw/vh units, or resize observers. The viewport is not fixed.

        THREE.JS SPECIFIC
        - Always include: renderer with antialias + alpha, requestAnimationFrame loop, window resize handler, OrbitControls when interactive.
        - Lighting: ambient + directional minimum. Add point lights for drama.
        - Materials: MeshStandardMaterial or MeshPhysicalMaterial for realism. Avoid MeshBasicMaterial unless stylistic.
        - Post-processing: include EffectComposer + bloom when the prompt asks for "glow", "neon", or "sci-fi".
        - Geometry: use BufferGeometry for performance with large particle counts. InstancedMesh for repeated objects.
        - Camera: PerspectiveCamera with fov 50-75. Position it intentionally — don't use defaults.

        CODE STRUCTURE
        For a single HTML file, follow this order:
        1. <!DOCTYPE html> + meta viewport
        2. <style> block — minimal, mostly resets and fullscreen canvas
        3. <script type="importmap"> — if using ES module imports
        4. <script type="module"> — all JS here
           a. Imports
           b. Constants/config at top
           c. Scene setup (renderer, camera, lights)
           d. Geometry/material creation
           e. Animation loop
           f. Event handlers (resize, mouse, keyboard)
           g. Optional: HUD overlay with stats

        TOOL USAGE
        Before answering a coding prompt:
        1. list_dir the current directory to see what exists
        2. read_file any relevant existing code
        3. Check for package.json, index.html, or config files
        4. THEN write your answer based on what you found

        WHAT NOT TO DO
        - Do not output markdown explanations before code. If the prompt asks for code, output code.
        - Do not wrap code in ```html fences in your text response. Just write the code directly.
        - Do not split code into multiple files unless explicitly asked.
        - Do not use require() or CommonJS. ESM only.
        - Do not use alert() or confirm(). Use console.log or DOM-based feedback.
        - Do not hardcode API keys or secrets.
        - Do not create server-side code unless asked. This is a browser-based environment.

        IF YOU'RE UNSURE
        When the prompt is ambiguous, make a bold creative choice and commit to it. The judge prefers decisive, complete answers over hedged, partial ones. Ship something that works.
        """

        return [
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
                judgeModel: "openrouter/owl-alpha",
                systemPrompt: creativeCodingPrompt
            ),
            FusionPreset(
                name: "Code Crew",
                description: "Models optimized for code generation",
                models: [
                    "qwen/qwen3-coder:free",
                    "openai/gpt-oss-120b:free",
                    "nvidia/nemotron-3-super-120b-a12b:free"
                ],
                judgeModel: "openrouter/owl-alpha",
                systemPrompt: creativeCodingPrompt
            ),
            FusionPreset(
                name: "Quick Trio",
                description: "Fast responses from 3 lightweight models",
                models: [
                    "google/gemma-4-26b-a4b-it:free",
                    "google/gemma-4-31b-it:free",
                    "nex-agi/nex-n2-pro:free"
                ],
                judgeModel: "openrouter/owl-alpha",
                systemPrompt: creativeCodingPrompt
            ),
        ]
    }
}
