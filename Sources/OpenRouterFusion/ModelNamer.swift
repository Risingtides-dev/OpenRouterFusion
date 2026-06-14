import Foundation

// MARK: - ModelNamer
// Converts model IDs (like "openai/gpt-4") to friendly display names (like "Gpt 4")

struct ModelNamer {
    /// Convert a model ID to a human-friendly display name
    static func friendlyName(_ id: String) -> String {
        // Strip common prefixes/suffixes
        var name = id
            .replacingOccurrences(of: "openrouter/", with: "")
            .replacingOccurrences(of: "openai/", with: "")
            .replacingOccurrences(of: "google/", with: "")
            .replacingOccurrences(of: "nvidia/", with: "")
            .replacingOccurrences(of: "qwen/", with: "")
            .replacingOccurrences(of: "nex-agi/", with: "")
            .replacingOccurrences(of: "anthropic/", with: "")
            .replacingOccurrences(of: ":free", with: "")
            .replacingOccurrences(of: "-instruct", with: "")
            .replacingOccurrences(of: "-it", with: "")

        // Convert dashes/spaces to title case
        name = name.replacingOccurrences(of: "-", with: " ")
        name = name.capitalized

        // Truncate if still long
        if name.count > 28 {
            name = String(name.prefix(25)) + "…"
        }
        return name
    }
}
