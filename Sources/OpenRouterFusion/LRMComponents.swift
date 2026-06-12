import SwiftUI

// MARK: - MetalButton

enum MetalButtonVariant {
    case primary
    case ghost
    case metal
}

enum MetalButtonSize {
    case sm, md, lg

    var height: CGFloat {
        switch self {
        case .sm: return 2.18 * 16  // ≈ 34.9pt
        case .md: return 2.75 * 16  // ≈ 44pt
        case .lg: return 3.35 * 16  // ≈ 53.6pt
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .sm: return 12
        case .md: return 18
        case .lg: return 24
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .sm: return 12
        case .md: return 14
        case .lg: return 16
        }
    }
}

struct MetalButton: View {
    let title: String
    let variant: MetalButtonVariant
    let size: MetalButtonSize
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    init(
        _ title: String,
        variant: MetalButtonVariant = .primary,
        size: MetalButtonSize = .md,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.variant = variant
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: size.fontSize, weight: .bold, design: .default))
                .foregroundColor(foregroundColor)
                .frame(height: size.height)
                .padding(.horizontal, size.horizontalPadding)
                .background(backgroundView)
                .scaleEffect(isPressed ? 0.96 : 1.0)
                .brightness(isHovered && !isPressed ? 0.12 : 0.0)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
                .animation(.easeInOut(duration: 0.08), value: isPressed)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in isHovered = hovering }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    private var foregroundColor: Color {
        switch variant {
        case .primary: return .white
        case .ghost:   return .lrmText
        case .metal:   return .lrmTextStrong
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch variant {
        case .primary:
            ZStack {
                LinearGradient.lrmAccentGradient
                LinearGradient(
                    colors: [.white.opacity(isHovered ? 0.18 : 0.08), .clear],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .clipShape(ChamferShape(cornerSize: 8))
            .overlay(
                ChamferShape(cornerSize: 8)
                    .stroke(Color.lrmBorderStrong, lineWidth: 1)
            )

        case .ghost:
            ZStack {
                Color.clear
            }
            .overlay(
                ChamferShape(cornerSize: 8)
                    .stroke(Color.lrmBorderStrong, lineWidth: 1)
            )
            .clipShape(ChamferShape(cornerSize: 8))

        case .metal:
            ZStack {
                LinearGradient.lrmMetalButton
                LinearGradient(
                    colors: [.white.opacity(isHovered ? 0.15 : 0.06), .clear, .white.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .clipShape(ChamferShape(cornerSize: 8))
            .overlay(
                ChamferShape(cornerSize: 8)
                    .stroke(Color.lrmBorderStrong, lineWidth: 1)
            )
        }
    }
}

// MARK: - StatusBadge

struct StatusBadge: View {
    let text: String
    let isStreaming: Bool

    init(_ text: String, isStreaming: Bool = false) {
        self.text = text
        self.isStreaming = isStreaming
    }

    var body: some View {
        HStack(spacing: 4) {
            if isStreaming {
                PulsingDots()
                    .frame(width: 16, height: 6)
            }
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.lrmMuted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Color.lrmSurface
                .clipShape(ChamferShape(cornerSize: 4))
        )
        .overlay(
            ChamferShape(cornerSize: 4)
                .stroke(Color.lrmBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - PulsingDots

struct PulsingDots: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.lrmAccent)
                    .frame(width: 3, height: 3)
                    .opacity(phase == i ? 1.0 : 0.3)
            }
        }
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}

// MARK: - LRMTextEditor

struct LRMTextEditor: View {
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty && !placeholder.isEmpty {
                Text(placeholder)
                    .foregroundColor(.lrmMuted.opacity(0.6))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.lrmText)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
        }
        .background(
            ZStack {
                Color.lrmSurfaceStrong
                // Metal inset shadow effect
                LinearGradient(
                    colors: [.black.opacity(0.3), .clear, .white.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .clipShape(ChamferShape(cornerSize: 8))
        )
        .overlay(
            ChamferShape(cornerSize: 8)
                .stroke(Color.lrmBorder, lineWidth: 1)
        )
        .clipShape(ChamferShape(cornerSize: 8))
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
                    .foregroundColor(.lrmMuted.opacity(0.6))
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
                LinearGradient(
                    colors: [.black.opacity(0.3), .clear, .white.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .clipShape(ChamferShape(cornerSize: 8))
        )
        .overlay(
            ChamferShape(cornerSize: 8)
                .stroke(Color.lrmBorder, lineWidth: 1)
        )
        .clipShape(ChamferShape(cornerSize: 8))
    }
}

// MARK: - MetalText

struct MetalText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .black, design: .monospaced))
            .foregroundColor(.lrmMetal)
            .tracking(0.12)
            .textCase(.uppercase)
    }
}

// MARK: - LiquidPanel

struct LiquidPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .liquidSurface()
    }
}

// MARK: - MetalPanel

struct MetalPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .metalSurface()
    }
}

// MARK: - Preview

#if DEBUG
struct LRMComponents_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            MetalButton("Primary", variant: .primary) {}
            MetalButton("Ghost", variant: .ghost) {}
            MetalButton("Metal", variant: .metal) {}
            MetalButton("Small", variant: .primary, size: .sm) {}
            MetalButton("Large", variant: .primary, size: .lg) {}
            StatusBadge("openrouter/auto")
            StatusBadge("streaming", isStreaming: true)
            MetalText("Section Label")
        }
        .padding()
        .background(Color.lrmBackground)
        .previewLayout(.sizeThatFits)
    }
}
#endif
