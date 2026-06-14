import SwiftUI

// MARK: - EmptyStateView
// Displayed when the chat is empty — shows logo, tagline, and quick-start keyboard shortcuts

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // Logo
            Text("◉")
                .font(.system(size: 48, weight: .thin))
                .foregroundColor(.lrmAccent)

            VStack(spacing: 6) {
                Text("OpenRouterFusion")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundColor(.lrmTextStrong)

                Text("Multi-model AI chat · auto-routing · free models")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.lrmMuted)
            }

            VStack(spacing: 8) {
                Text("Quick start:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.lrmMuted.opacity(0.7))

                VStack(alignment: .leading, spacing: 4) {
                    quickStartRow(key: "Enter", action: "Send message")
                    quickStartRow(key: "⇧ Enter", action: "New line")
                    quickStartRow(key: "⌘ K", action: "Clear chat")
                    quickStartRow(key: "⌘ ⇧ S", action: "Toggle sidebar")
                }
            }
            .padding(.top, 12)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func quickStartRow(key: String, action: String) -> some View {
        HStack(spacing: 12) {
            Text(key)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.lrmAccent)
                .frame(width: 80, alignment: .trailing)
            Text(action)
                .font(.system(size: 12))
                .foregroundColor(.lrmMuted)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct EmptyStateView_Previews: PreviewProvider {
    static var previews: some View {
        EmptyStateView()
            .background(Color.lrmBackground)
            .frame(width: 600, height: 400)
    }
}
#endif
