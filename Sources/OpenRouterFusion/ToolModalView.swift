import SwiftUI

struct ToolModalView: View {
    @Binding var command: String
    var onRun: (String) -> Void
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(spacing: 12) {
            Text("Run a shell tool")
                .font(.headline)
            TextEditor(text: $command)
                .frame(minHeight: 80)
                .border(Color.gray.opacity(0.3))
                .cornerRadius(6)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Run") {
                    onRun(command)
                    dismiss()
                }
                .buttonStyle(MetalButtonStyle())
            }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 200)
    }
}
