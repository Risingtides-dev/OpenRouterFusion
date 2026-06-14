import SwiftUI

// MARK: - ComposerView
// Message input area with Send/Stop buttons and keyboard handling

struct ComposerView: View {
    @ObservedObject var vm: ChatViewModel
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // Message input
            inputField
            
            // Send/Stop buttons
            actionButtons
        }
        .padding(12)
        .background(Color.lrmSurface.opacity(0.3))
    }
    
    // MARK: - Input Field
    
    private var inputField: some View {
        ZStack(alignment: .topLeading) {
            MessageInputView(
                text: $vm.userInput,
                placeholder: "Message…",
                onSubmit: { vm.sendMessage() }
            )
            .frame(minHeight: 36, maxHeight: 120)
        }
        .background(
            Color.lrmSurfaceStrong.clipShape(ChamferShape(cornerSize: 8))
        )
        .overlay(
            ChamferShape(cornerSize: 8).stroke(Color.lrmBorder, lineWidth: 1)
        )
    }
    
    // MARK: - Action Buttons
    
    private var actionButtons: some View {
        HStack(spacing: 8) {
            if vm.isStreaming {
                MetalButton("Stop", variant: .ghost) {
                    vm.stopStreaming()
                }
            } else {
                MetalButton("Send", variant: .primary) {
                    vm.sendMessage()
                }
                .disabled(vm.userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [])
                .accessibilityLabel("Send message")
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ComposerView_Previews: PreviewProvider {
    static var previews: some View {
        ComposerView(vm: ChatViewModel())
            .background(Color.lrmBackground)
            .frame(width: 600)
    }
}
#endif
