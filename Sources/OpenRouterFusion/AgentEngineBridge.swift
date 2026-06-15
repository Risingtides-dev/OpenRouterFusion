import Foundation

// MARK: - AgentEvent

/// Events from the agent engine subprocess.
enum AgentEvent {
    case textDelta(String)
    case toolStart(name: String, input: String)
    case toolResult(name: String, output: String)
    case done(text: String)
    case error(String)
    case ready(tools: [String])
}

// MARK: - AgentBridge

/// Manages the Node.js agent engine subprocess.
/// Spawns engine.mjs, sends chat requests via stdin, receives events via stdout.
final class AgentEngineBridge {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private(set) var isRunning = false
    private var readyTools: [String] = []
    private var onEvent: ((AgentEvent) -> Void)?
    private let queue = DispatchQueue(label: "agent-engine", qos: .userInitiated)

    /// Path to the agent engine script
    private let enginePath: String

    init(enginePath: String? = nil) {
        if let customPath = enginePath {
            self.enginePath = customPath
        } else {
            let candidates: [String?] = [
                Bundle.main.resourceURL?.appendingPathComponent("engine.mjs").path,
                Bundle.main.resourceURL?.appendingPathComponent("agent-engine/engine.mjs").path,
                NSString(string: "~/dev/OpenRouterFusion/agent-engine/engine.mjs").expandingTildeInPath,
                NSString(string: "~/.openrtr/engine.mjs").expandingTildeInPath,
            ]
            self.enginePath = candidates.compactMap { $0 }.first { path in
                FileManager.default.fileExists(atPath: path)
            } ?? ""
        }
    }

    // MARK: - Lifecycle

    func start(onEvent: @escaping (AgentEvent) -> Void) {
        guard !isRunning else { return }
        self.onEvent = onEvent

        guard !enginePath.isEmpty, FileManager.default.fileExists(atPath: enginePath) else {
            onEvent(AgentEvent.error("Agent engine not found at: \(enginePath)"))
            return
        }

        let proc = Process()
        let nodePath = findNode()

        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = [enginePath]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let str = String(data: data, encoding: .utf8) {
                self?.processStdout(str)
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let str = String(data: data, encoding: .utf8), !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NSLog("[agent-engine stderr] %@", str.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        proc.terminationHandler = { [weak self] _ in
            self?.isRunning = false
            NSLog("[agent-engine] Process terminated")
        }

        do {
            try proc.run()
            isRunning = true
            NSLog("[agent-engine] Started with path: %@", enginePath)
        } catch {
            onEvent(AgentEvent.error("Failed to start agent engine: \(error.localizedDescription)"))
        }
    }

    func stop() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        isRunning = false
    }

    func sendChat(
        messages: [(role: String, content: String)],
        model: String,
        apiKey: String,
        systemPrompt: String?
    ) {
        guard isRunning else {
            onEvent?(AgentEvent.error("Agent engine not running"))
            return
        }

        let payload: [String: Any] = [
            "type": "chat",
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "model": model,
            "apiKey": apiKey,
            "systemPrompt": systemPrompt ?? "",
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            onEvent?(AgentEvent.error("Failed to serialize chat request"))
            return
        }

        let line = json + "\n"
        stdinPipe?.fileHandleForWriting.write(line.data(using: .utf8) ?? Data())
    }

    // MARK: - Stdout Parsing

    private var stdoutBuffer = ""

    private func processStdout(_ chunk: String) {
        stdoutBuffer += chunk
        while let newlineRange = stdoutBuffer.range(of: "\n") {
            let line = String(stdoutBuffer[stdoutBuffer.startIndex..<newlineRange.lowerBound])
            stdoutBuffer = String(stdoutBuffer[newlineRange.upperBound...])

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            guard let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                continue
            }

            let event: AgentEvent?
            switch type {
            case "ready":
                let tools = json["tools"] as? [String] ?? []
                self.readyTools = tools
                event = .ready(tools: tools)
            case "text_delta":
                event = (json["content"] as? String).map { .textDelta($0) }
            case "tool_start":
                let name = json["name"] as? String ?? "unknown"
                let input = json["input"]
                let inputStr: String
                if let input {
                    inputStr = (try? JSONSerialization.data(withJSONObject: input))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? String(describing: input)
                } else {
                    inputStr = ""
                }
                event = .toolStart(name: name, input: inputStr)
            case "tool_result":
                let name = json["name"] as? String ?? "unknown"
                let output = json["output"] as? String ?? ""
                event = .toolResult(name: name, output: output)
            case "done":
                event = .done(text: json["text"] as? String ?? "")
            case "error":
                event = .error(json["message"] as? String ?? "Unknown error")
            default:
                event = nil
            }

            if let event {
                DispatchQueue.main.async { [weak self] in
                    self?.onEvent?(event)
                }
            }
        }
    }

    // MARK: - Helpers

    private func findNode() -> String {
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        if let result = try? Process.shell("which node"), !result.isEmpty {
            return result
        }
        return "/opt/homebrew/bin/node"
    }
}

private extension Process {
    @discardableResult
    static func shell(_ command: String) throws -> String {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-c", command]
        proc.standardOutput = pipe
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
