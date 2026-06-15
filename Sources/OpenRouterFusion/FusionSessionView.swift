import SwiftUI

// MARK: - FusionSessionView
// Renders an active fusion session: panel grid + streaming synthesis

struct FusionSessionView: View {
    @ObservedObject var session: FusionSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Panel grid
            panelGrid

            // Synthesis streaming area
            if session.hasSynthesis || session.isSynthesisStreaming {
                synthesisView
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Panel Grid

    private var panelGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.lrmAccent)
                Text("FUSION PANEL")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(.lrmMuted)
                Spacer()
                Text(panelProgress)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.lrmMuted)
            }

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 6),
                GridItem(.flexible(), spacing: 6)
            ], spacing: 6) {
                ForEach(session.panelResults, id: \.model) { panel in
                    FusionPanelCard(panel: panel)
                }
            }
        }
    }

    private var panelProgress: String {
        let done = session.panelResults.filter { $0.status != .running }.count
        let total = session.panelResults.count
        return "\(done)/\(total)"
    }

    // MARK: - Synthesis View

    private var synthesisView: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 6) {
                if session.isSynthesisStreaming {
                    PulsingDots()
                        .frame(width: 16, height: 6)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                }
                Text(session.isSynthesisStreaming ? "SYNTHESIZING…" : "SYNTHESIS")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(session.isSynthesisStreaming ? .lrmAccent : .lrmMuted)
                if !session.synthesisModel.isEmpty {
                    Text("· \(ModelNamer.friendlyName(session.synthesisModel))")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.lrmMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }

            // Content
            if session.isSynthesisStreaming && session.synthesisContent.isEmpty {
                // Waiting for first token
                HStack(spacing: 6) {
                    PulsingDots()
                        .frame(width: 20, height: 8)
                    Text("Waiting for judge…")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.lrmMuted)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.lrmSurface.opacity(0.5)
                        .clipShape(ChamferShape(cornerSize: 8))
                )
            } else {
                // Rendered synthesis content
                synthesisContent
            }
        }
    }

    @ViewBuilder
    private var synthesisContent: some View {
        let attributed = parseMarkdown(session.synthesisContent)
        Text(attributed)
            .font(.system(size: 14))
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack {
                    LinearGradient.lrmBackgroundRadial
                    RadialGradient(
                        colors: [Color.lrmAccent.opacity(0.05), .clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 200
                    )
                }
                .clipShape(ChamferShape(cornerSize: 10))
            )
            .overlay(
                ChamferShape(cornerSize: 10)
                    .stroke(Color.lrmBorder, lineWidth: 0.5)
            )
            .clipShape(ChamferShape(cornerSize: 10))
    }

    private func parseMarkdown(_ text: String) -> AttributedString {
        do {
            var options = AttributedString.MarkdownParsingOptions()
            options.allowsExtendedAttributes = true
            var parsed = try AttributedString(markdown: text, options: options)
            parsed.foregroundColor = Color.lrmText
            return parsed
        } catch {
            var fallback = AttributedString(text)
            fallback.foregroundColor = Color.lrmText
            return fallback
        }
    }
}

// MARK: - FusionPanelCard

struct FusionPanelCard: View {
    @ObservedObject var panel: PanelResult

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            statusIcon

            // Model info
            VStack(alignment: .leading, spacing: 2) {
                Text(ModelNamer.friendlyName(panel.model))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.lrmText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(statusText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(statusColor)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Color.lrmSurface.opacity(0.7)
                .clipShape(ChamferShape(cornerSize: 6))
        )
        .overlay(
            HStack(spacing: 0) {
                ChamferShape(cornerSize: 6)
                    .fill(statusColor.opacity(0.8))
                    .frame(width: 3)
                Spacer()
            }
            .clipShape(ChamferShape(cornerSize: 6))
        )
        .overlay(
            ChamferShape(cornerSize: 6)
                .stroke(Color.lrmBorder, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch panel.status {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 14, height: 14)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.lrmDanger)
        }
    }

    private var statusText: String {
        switch panel.status {
        case .running:
            return "Running…"
        case .done:
            let time = panel.elapsedSeconds > 0 ? String(format: "%.1fs", panel.elapsedSeconds) : ""
            let preview = responsePreview
            if !preview.isEmpty {
                return time.isEmpty ? preview : "\(time) · \(preview)"
            }
            return time.isEmpty ? "Done" : "Done · \(time)"
        case .failed:
            return panel.error ?? "Failed"
        }
    }

    private var responsePreview: String {
        guard let content = panel.content, !content.isEmpty else { return "" }
        let firstLine = content.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let preview = firstLine.trimmingCharacters(in: .whitespaces)
        return preview.count > 60 ? String(preview.prefix(60)) + "…" : preview
    }

    private var statusColor: Color {
        switch panel.status {
        case .running: return .lrmAccent
        case .done: return .green
        case .failed: return .lrmDanger
        }
    }
}

// MARK: - Preview

#if DEBUG
struct FusionSessionView_Previews: PreviewProvider {
    static var previews: some View {
        let session = FusionSession()
        session.panelResults = [
            { let p = PanelResult(model: "openai/gpt-oss-120b:free"); p.status = .done; p.elapsedSeconds = 3.2; p.content = "The answer is 42 because of the fundamental theorem."; return p }(),
            { let p = PanelResult(model: "google/gemma-4-31b-it:free"); p.status = .done; p.elapsedSeconds = 4.1; p.content = "Based on my analysis, the answer is 42."; return p }(),
            { let p = PanelResult(model: "nvidia/nemotron-3-super-120b-a12b:free"); p.status = .running; return p }(),
            { let p = PanelResult(model: "qwen/qwen3-coder:free"); p.status = .failed; p.error = "Timeout"; return p }(),
        ]
        session.synthesisContent = "The consensus answer across the panel is **42**. Here's why:\n\n1. Both GPT-OSS and Gemma agree on the core answer\n2. The reasoning differs slightly — GPT references the fundamental theorem while Gemma uses a more direct analytical approach\n\nThe key insight is that this value emerges from the convergence of multiple independent analyses."
        session.isSynthesisStreaming = false

        return FusionSessionView(session: session)
            .padding()
            .background(Color.lrmBackground)
            .frame(width: 600)
    }
}
#endif
