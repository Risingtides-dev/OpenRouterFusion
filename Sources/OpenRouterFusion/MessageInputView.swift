import SwiftUI
import AppKit

// MARK: - MessageInputView
// A custom NSTextView wrapper that properly handles Return (send) vs Shift+Return (newline)
// This replaces the broken .onSubmit { } on TextEditor which doesn't work on macOS

struct MessageInputView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = NSColor(Color.lrmText)
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.textContainer?.lineFragmentPadding = 4
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        
        // Set up placeholder
        context.coordinator.placeholderTextView = createPlaceholderView(
            in: scrollView,
            text: placeholder
        )
        
        // Insert newlines by default (Shift+Return will send)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text {
            textView.string = text
        }
        
        // Update placeholder visibility
        context.coordinator.updatePlaceholderVisibility(isEmpty: text.isEmpty)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    private func createPlaceholderView(in scrollView: NSScrollView, text: String) -> NSTextField {
        let placeholder = NSTextField(labelWithString: text)
        placeholder.font = NSFont.systemFont(ofSize: 14)
        placeholder.textColor = NSColor(Color.lrmMuted.opacity(0.5))
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        
        scrollView.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 8),
            placeholder.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 8)
        ])
        
        return placeholder
    }
    
    // MARK: - Coordinator
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageInputView
        var placeholderTextView: NSTextField?
        
        init(_ parent: MessageInputView) {
            self.parent = parent
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            
            // Update placeholder
            updatePlaceholderVisibility(isEmpty: textView.string.isEmpty)
        }
        
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Check if Shift is held
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                let shiftHeld = flags.contains(.shift)
                
                if shiftHeld {
                    // Shift+Return: insert newline
                    textView.insertNewline(nil)
                    return true
                } else {
                    // Return: submit
                    parent.onSubmit()
                    return true
                }
            }
            return false
        }
        
        func updatePlaceholderVisibility(isEmpty: Bool) {
            placeholderTextView?.isHidden = !isEmpty
        }
    }
}

// MARK: - Preview

#if DEBUG
struct MessageInputView_Previews: PreviewProvider {
    @State static var text = ""
    
    static var previews: some View {
        MessageInputView(
            text: $text,
            placeholder: "Message…",
            onSubmit: { print("Submit: \(text)") }
        )
        .frame(width: 400, height: 100)
        .padding()
    }
}
#endif
