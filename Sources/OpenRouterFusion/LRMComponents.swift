import SwiftUI

// MARK: - MetalButton

enum MetalButtonVariant {
    case primary, ghost, metal
}

enum MetalButtonSize {
    case sm, md, lg
    var height: CGFloat {
        switch self { case .sm: return 32; case .md: return 40; case .lg: return 50 }
    }
    var hPadding: CGFloat {
        switch self { case .sm: return 10; case .md: return 16; case .lg: return 22 }
    }
    var fontSize: CGFloat {
        switch self { case .sm: return 11; case .md: return 13; case .lg: return 15 }
    }
}

struct MetalButton: View {
    let title: String
    let variant: MetalButtonVariant
    let size: MetalButtonSize
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    init(_ title: String, variant: MetalButtonVariant = .primary, size: MetalButtonSize = .md, action: @escaping () -> Void) {
        self.title = title; self.variant = variant; self.size = size; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: size.fontSize, weight: .bold))
                .foregroundColor(foregroundColor)
                .frame(height: size.height)
                .padding(.horizontal, size.hPadding)
                .background(backgroundView)
                .scaleEffect(isPressed ? 0.97 : 1.0)
                .brightness(isHovered && !isPressed ? 0.12 : 0.0)
                .animation(.easeInOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    private var foregroundColor: Color {
        switch variant { case .primary: return .white; case .ghost: return .lrmText; case .metal: return .lrmTextStrong }
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch variant {
        case .primary:
            ZStack {
                LinearGradient.lrmAccentGradient
                LinearGradient(colors: [.white.opacity(isHovered ? 0.2 : 0.08), .clear], startPoint: .top, endPoint: .bottom)
            }
            .clipShape(ChamferShape(cornerSize: 8))
            .overlay(ChamferShape(cornerSize: 8).stroke(Color.lrmBorderStrong, lineWidth: 1))
        case .ghost:
            Color.clear
                .overlay(ChamferShape(cornerSize: 8).stroke(Color.lrmBorderStrong, lineWidth: 1))
                .clipShape(ChamferShape(cornerSize: 8))
        case .metal:
            ZStack {
                LinearGradient.lrmMetalButton
                LinearGradient(colors: [.white.opacity(isHovered ? 0.18 : 0.06), .clear, .white.opacity(0.04)], startPoint: .top, endPoint: .bottom)
            }
            .clipShape(ChamferShape(cornerSize: 8))
            .overlay(ChamferShape(cornerSize: 8).stroke(Color.lrmBorderStrong, lineWidth: 1))
        }
    }
}

// MARK: - StatusBadge

struct StatusBadge: View {
    let text: String
    let isStreaming: Bool

    init(_ text: String, isStreaming: Bool = false) {
        self.text = text; self.isStreaming = isStreaming
    }

    var body: some View {
        HStack(spacing: 4) {
            if isStreaming {
                PulsingDots().frame(width: 16, height: 6)
            }
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.lrmMuted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.lrmSurface.clipShape(ChamferShape(cornerSize: 4)))
        .overlay(ChamferShape(cornerSize: 4).stroke(Color.lrmBorder, lineWidth: 0.5))
    }
}

// MARK: - PulsingDots

struct PulsingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.lrmAccent)
                    .frame(width: 4, height: 4)
                    .opacity(animating ? 0.3 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.6)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.2),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

// MARK: - LRMTextEditor

struct LRMTextEditor: View {
    @Binding var text: String
    var placeholder: String = ""
    var maxHeight: CGFloat = .infinity
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty && !placeholder.isEmpty {
                Text(placeholder)
                    .foregroundColor(.lrmMuted.opacity(0.5))
                    .font(.system(size: 14))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 14))
                .foregroundColor(.lrmText)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .focused($isFocused)
        }
        .frame(maxHeight: maxHeight)
        .background(
            ZStack {
                Color.lrmSurfaceStrong
                LinearGradient(
                    colors: [.black.opacity(0.25), .clear, .white.opacity(0.03)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .clipShape(ChamferShape(cornerSize: 8))
        )
        .overlay(
            ChamferShape(cornerSize: 8)
                .stroke(isFocused ? Color.lrmAccent.opacity(0.5) : Color.lrmBorder,
                        lineWidth: isFocused ? 1.5 : 1)
        )
        .clipShape(ChamferShape(cornerSize: 8))
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - LRMSecureField

struct LRMSecureField: View {
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty && !placeholder.isEmpty {
                Text(placeholder)
                    .foregroundColor(.lrmMuted.opacity(0.5))
                    .padding(.horizontal, 8)
                    .allowsHitTesting(false)
            }
            SecureField("", text: $text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.lrmText)
                .textFieldStyle(PlainTextFieldStyle())
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .background(
            ZStack {
                Color.lrmSurfaceStrong
                LinearGradient(colors: [.black.opacity(0.25), .clear, .white.opacity(0.03)], startPoint: .top, endPoint: .bottom)
            }
            .clipShape(ChamferShape(cornerSize: 8))
        )
        .overlay(ChamferShape(cornerSize: 8).stroke(Color.lrmBorder, lineWidth: 1))
        .clipShape(ChamferShape(cornerSize: 8))
    }
}

// MARK: - MetalText

struct MetalText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .foregroundColor(.lrmMetal)
            .tracking(0.1)
            .textCase(.uppercase)
    }
}
