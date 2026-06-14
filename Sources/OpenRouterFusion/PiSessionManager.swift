import Foundation
import AppKit

// MARK: - Project-local Pi session support

struct PiSessionRecord: Identifiable, Hashable {
    let id: String
    let fileURL: URL
    let cwd: String
    let title: String
    let createdAt: Date?
    let modifiedAt: Date
    let messageCount: Int
    let resumeCommand: String

    var fileName: String { fileURL.lastPathComponent }
}

@MainActor
final class PiSessionManager: ObservableObject {
    static let shared = PiSessionManager()

    @Published private(set) var sessions: [PiSessionRecord] = []
    @Published private(set) var lastError: String?

    let sandboxRoot: URL
    let sandboxHomeDirectory: URL
    let privateAgentDirectory: URL
    let sessionDirectory: URL

    var newSessionCommand: String {
        isolatedPiCommand("--name \"OpenRouterFusion isolated session\"")
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let root = appSupport
            .appendingPathComponent("OpenRouterFusion", isDirectory: true)
            .appendingPathComponent("isolated-pi", isDirectory: true)
        self.sandboxRoot = root
        self.sandboxHomeDirectory = root.appendingPathComponent("home", isDirectory: true)
        self.privateAgentDirectory = sandboxHomeDirectory
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
        self.sessionDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        bootstrapDirectories()
        refresh()
    }

    func refresh() {
        do {
            bootstrapDirectories()
            let files = try FileManager.default.contentsOfDirectory(
                at: sessionDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "jsonl" }

            let parsed = files.compactMap { parseSessionFile($0) }
                .sorted { lhs, rhs in lhs.modifiedAt > rhs.modifiedAt }

            sessions = parsed
            lastError = nil
        } catch {
            sessions = []
            lastError = error.localizedDescription
        }
    }

    func copyResumeCommand(for session: PiSessionRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.resumeCommand, forType: .string)
    }

    func revealSessionDirectory() {
        bootstrapDirectories()
        NSWorkspace.shared.activateFileViewerSelecting([sessionDirectory])
    }

    func copyNewSessionCommand() {
        bootstrapDirectories()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(newSessionCommand, forType: .string)
    }

    private func bootstrapDirectories() {
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: privateAgentDirectory, withIntermediateDirectories: true)
        writePrivateSettingsIfNeeded()
    }

    private func writePrivateSettingsIfNeeded() {
        let settingsURL = privateAgentDirectory.appendingPathComponent("settings.json")
        guard !FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let settings = """
        {
          \"extensions\": [],
          \"skills\": [],
          \"memory\": {
            \"enabled\": false
          },
          \"messenger\": {
            \"enabled\": false
          }
        }
        """
        try? settings.write(to: settingsURL, atomically: true, encoding: .utf8)
    }

    private func isolatedPiCommand(_ trailingArgs: String) -> String {
        let home = shellQuote(sandboxHomeDirectory.path)
        let sessions = shellQuote(sessionDirectory.path)
        return "HOME=\(home) PI_OFFLINE=1 pi --session-dir \(sessions) --no-extensions --no-skills --no-context-files --no-prompt-templates --no-themes --no-approve \(trailingArgs)"
    }

    private func resumeCommand(for fileURL: URL) -> String {
        isolatedPiCommand("--session \(shellQuote(fileURL.path))")
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func parseSessionFile(_ url: URL) -> PiSessionRecord? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let modifiedAt = (attrs[.modificationDate] as? Date) ?? Date.distantPast
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var sessionId = url.deletingPathExtension().lastPathComponent
        var cwd = "Project-local"
        var createdAt: Date?
        var messageCount = 0
        var firstUserText: String?
        var explicitName: String?

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = raw["type"] as? String else { continue }

            if type == "session" {
                if let id = raw["id"] as? String { sessionId = id }
                if let sessionCwd = raw["cwd"] as? String { cwd = sessionCwd }
                if let timestamp = raw["timestamp"] as? String {
                    createdAt = ISO8601DateFormatter().date(from: timestamp)
                }
            } else if type == "session_name" || type == "name_change" {
                explicitName = raw["name"] as? String ?? raw["title"] as? String
            } else if type == "message" {
                messageCount += 1
                if firstUserText == nil,
                   let message = raw["message"] as? [String: Any],
                   let role = message["role"] as? String,
                   role == "user" {
                    firstUserText = extractText(from: message["content"])
                }
            }
        }

        let title = explicitName
            ?? firstUserText?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyPrefix(max: 72)
            ?? url.deletingPathExtension().lastPathComponent

        return PiSessionRecord(
            id: sessionId,
            fileURL: url,
            cwd: cwd,
            title: title,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            messageCount: messageCount,
            resumeCommand: resumeCommand(for: url)
        )
    }

    private func extractText(from content: Any?) -> String? {
        if let string = content as? String { return string }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { part in
                guard let type = part["type"] as? String, type == "text" else { return nil }
                return part["text"] as? String
            }.joined(separator: "\n")
        }
        return nil
    }
}

private extension String {
    func nonEmptyPrefix(max: Int) -> String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= max { return trimmed }
        return String(trimmed.prefix(max - 1)) + "…"
    }
}
