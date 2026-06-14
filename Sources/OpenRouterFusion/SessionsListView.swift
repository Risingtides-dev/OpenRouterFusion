import SwiftUI
import AppKit

// MARK: - SessionsListView
// Project-local Pi sessions. Uses pi --session-dir so app sessions do not mutate ~/.pi.

struct SessionsListView: View {
    @StateObject private var manager = PiSessionManager.shared
    @Environment(\.dismiss) private var dismiss

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            directoryPanel
            content
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 480)
        .background(
            ZStack {
                Color.lrmBackground
                LinearGradient.lrmBackgroundRadial.opacity(0.35)
            }
        )
        .onAppear { manager.refresh() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pi Sessions")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundColor(.lrmTextStrong)
                Text("Sealed Pi sandbox: private HOME, private sessions, no global extensions, no Thoth memory.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.lrmMuted)
            }
            Spacer()
            MetalButton("Close", variant: .ghost, size: .sm) { dismiss() }
        }
    }

    private var directoryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            MetalText("ISOLATED PI ROOT")
            Text(manager.sandboxRoot.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.lrmText)
                .lineLimit(2)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.lrmSurface.clipShape(ChamferShape(cornerSize: 8)))
                .overlay(ChamferShape(cornerSize: 8).stroke(Color.lrmBorder, lineWidth: 1))

            HStack(spacing: 8) {
                MetalButton("Copy New Session Cmd", variant: .primary, size: .sm) {
                    manager.copyNewSessionCommand()
                }
                MetalButton("Reveal", variant: .metal, size: .sm) {
                    manager.revealSessionDirectory()
                }
                MetalButton("Refresh", variant: .ghost, size: .sm) {
                    manager.refresh()
                }
                Spacer()
            }
        }
        .padding(12)
        .background(Color.lrmSurfaceStrong.opacity(0.55).clipShape(ChamferShape(cornerSize: 12)))
        .overlay(ChamferShape(cornerSize: 12).stroke(Color.lrmBorder, lineWidth: 1))
    }

    @ViewBuilder
    private var content: some View {
        if let lastError = manager.lastError {
            errorPanel(lastError)
        } else if manager.sessions.isEmpty {
            emptyPanel
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(manager.sessions) { session in
                        sessionRow(session)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var emptyPanel: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.lrmMuted)
            Text("No app-local Pi sessions yet")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.lrmTextStrong)
            Text("Copy the new-session command above and run it in Terminal. It sets a private HOME and disables extensions/skills/context discovery so it will not load Thoth, pi-messenger, memories, or global Pi config.")
                .font(.system(size: 12))
                .foregroundColor(.lrmMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
        .background(Color.lrmSurface.opacity(0.5).clipShape(ChamferShape(cornerSize: 14)))
        .overlay(ChamferShape(cornerSize: 14).stroke(Color.lrmBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }

    private func errorPanel(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Could not load sessions")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.red.opacity(0.9))
            Text(message)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.lrmText)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08).clipShape(ChamferShape(cornerSize: 12)))
        .overlay(ChamferShape(cornerSize: 12).stroke(Color.red.opacity(0.3), lineWidth: 1))
    }

    private func sessionRow(_ session: PiSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.lrmTextStrong)
                        .lineLimit(2)
                    Text(session.cwd)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.lrmMuted)
                        .lineLimit(1)
                }
                Spacer()
                StatusBadge("\(session.messageCount) msgs")
            }

            HStack(spacing: 10) {
                Text("Modified \(dateFormatter.string(from: session.modifiedAt))")
                    .font(.system(size: 11))
                    .foregroundColor(.lrmMuted)
                Spacer()
                MetalButton("Copy Resume Cmd", variant: .metal, size: .sm) {
                    manager.copyResumeCommand(for: session)
                }
            }
        }
        .padding(12)
        .background(Color.lrmSurface.opacity(0.75).clipShape(ChamferShape(cornerSize: 12)))
        .overlay(ChamferShape(cornerSize: 12).stroke(Color.lrmBorder, lineWidth: 1))
    }
}

#if DEBUG
struct SessionsListView_Previews: PreviewProvider {
    static var previews: some View {
        SessionsListView()
    }
}
#endif
