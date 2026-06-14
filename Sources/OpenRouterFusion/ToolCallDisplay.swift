import SwiftUI

// MARK: - ToolCallDisplay
// Represents an active tool call in the UI

struct ToolCallDisplay: Identifiable {
    let id: String
    let name: String
    let arguments: String
}

// MARK: - ToolCallIndicator
// Visual indicator for an active tool call

struct ToolCallIndicator: View {
    let toolCall: ToolCallDisplay

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape.fill")
                .foregroundColor(.lrmAccent)
                .font(.system(size: 12))
            Text(toolCall.name)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.lrmTextStrong)
            Text(summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.lrmMuted)
                .lineLimit(1)
            Spacer()
            PulsingDots()
                .frame(width: 16, height: 6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.lrmSurface.clipShape(ChamferShape(cornerSize: 6)))
        .overlay(ChamferShape(cornerSize: 6).stroke(Color.lrmAccent.opacity(0.3), lineWidth: 1))
        .clipShape(ChamferShape(cornerSize: 6))
        .padding(.horizontal, 16)
    }

    private var summary: String {
        let cleaned = toolCall.arguments.replacingOccurrences(of: "\n", with: " ")
        return cleaned.count > 60 ? String(cleaned.prefix(60)) + "…" : cleaned
    }
}
