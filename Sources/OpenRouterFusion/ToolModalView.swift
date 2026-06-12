import SwiftUI

struct ToolModalView: View {
    @Binding var command: String
    var onRun: (String) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Text("Run a Shell Tool")
                .font(.system(size: 16, weight: .bold, design: .default))
                .foregroundColor(.lrmTextStrong)

            LRMTextEditor(text: $command, placeholder: "Enter shell command…")
                .frame(minHeight: 100, maxHeight: 200)

            HStack {
                MetalButton("Cancel", variant: .ghost) {
                    dismiss()
                }
                Spacer()
                MetalButton("Run", variant: .metal) {
                    onRun(command)
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 240)
        .background(Color.lrmBackground2)
    }
}
