import Foundation

struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    var role: Role
    var content: String
    var modelUsed: String?
    enum Role: String, Codable { case user, assistant }
}

final class ConversationStore: ObservableObject {
    @Published var messages: [ChatMessage] = []

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("OpenRouterFusion")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("conversation.json")
    }()

    init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) else {
            // Corrupted file — back it up and start fresh
            let backup = fileURL.appendingPathExtension("bak")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            print("⚠️ conversation.json was corrupted, backed up to \(backup.lastPathComponent)")
            return
        }
        messages = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func append(role: ChatMessage.Role, content: String, modelUsed: String? = nil) {
        messages.append(ChatMessage(role: role, content: content, modelUsed: modelUsed))
        save()
    }

    func clear() {
        messages.removeAll()
        save()
    }
}
