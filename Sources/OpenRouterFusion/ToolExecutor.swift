import Foundation

final class ToolExecutor {
    /// Run a shell command (bash) and capture its output (stdout+stderr).
    /// Returns the combined output via a Result.
    static func run(_ command: String,
                    arguments: [String] = [],
                    cwd: URL? = nil,
                    timeout: TimeInterval = 30,
                    completion: @escaping (Result<String, Error>) -> Void) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: command)
        proc.arguments = arguments
        if let cwd = cwd { proc.currentDirectoryURL = cwd }
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do { try proc.run() } catch { completion(.failure(error)); return }
        // Timeout handling
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if proc.isRunning { proc.terminate() }
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let outStr = String(decoding: outData, as: UTF8.self)
        let errStr = String(decoding: errData, as: UTF8.self)
        if proc.terminationStatus == 0 {
            completion(.success(outStr + (errStr.isEmpty ? "" : "\n"+errStr)))
        } else {
            let msg = "Exit \(proc.terminationStatus) – \(errStr)"
            completion(.failure(NSError(domain: "Tool", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg])))
        }
    }
}
