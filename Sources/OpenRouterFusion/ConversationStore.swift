import Foundation

struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    var role: Role
    var content: String
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
        messages = (try? JSONDecoder().decode([ChatMessage].self, from: data)) ?? []
    }
    func save() {
        try? JSONEncoder().encode(messages).write(to: fileURL, options: .atomic)
    }
    func append(role: ChatMessage.Role, content: String) {
        messages.append(ChatMessage(role: role, content: content))
        save()
    }
    func clear() { messages.removeAll(); save() }
}
