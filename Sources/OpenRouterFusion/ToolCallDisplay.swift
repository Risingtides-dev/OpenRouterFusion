import SwiftUI

// MARK: - ToolCallDisplay
// Represents a tool call in the UI (can be active or completed)

struct ToolCallDisplay: Identifiable {
    let id: String
    let name: String
    let arguments: String
    var result: String? = nil

    var isComplete: Bool { result != nil }
}

// MARK: - ToolCallIndicator
// Visual indicator for a tool call — shows running state or completed result

struct ToolCallIndicator: View {
    let toolCall: ToolCallDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                statusIcon
                Text(toolCall.name)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.lrmTextStrong)
                Text(summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.lrmMuted)
                    .lineLimit(1)
                Spacer()
                if !toolCall.isComplete {
                    PulsingDots()
                        .frame(width: 16, height: 6)
                }
            }

            // Show result preview when complete
            if let result = toolCall.result, !result.isEmpty {
                Text(resultPreview(result))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.lrmMuted)
                    .lineLimit(3)
                    .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.lrmSurface.clipShape(ChamferShape(cornerSize: 6)))
        .overlay(
            ChamferShape(cornerSize: 6)
                .stroke(toolCall.isComplete ? Color.green.opacity(0.3) : Color.lrmAccent.opacity(0.3), lineWidth: 1)
        )
        .clipShape(ChamferShape(cornerSize: 6))
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if toolCall.isComplete {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 12))
        } else {
            Image(systemName: "gearshape.fill")
                .foregroundColor(.lrmAccent)
                .font(.system(size: 12))
        }
    }

    private var summary: String {
        let cleaned = toolCall.arguments.replacingOccurrences(of: "\n", with: " ")
        return cleaned.count > 60 ? String(cleaned.prefix(60)) + "…" : cleaned
    }

    private func resultPreview(_ result: String) -> String {
        // Try to extract meaningful preview from JSON result
        if let data = result.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let path = json["path"] as? String {
                return "→ \(path)"
            }
            if let output = json["output"] as? String {
                let preview = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return preview.count > 120 ? String(preview.prefix(120)) + "…" : preview
            }
        }
        let preview = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.count > 120 ? String(preview.prefix(120)) + "…" : preview
    }
}
