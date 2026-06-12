import SwiftUI

// MARK: - LRM Color Tokens
// From liquid-razor-metal-ui CSS design tokens

extension Color {
    static let lrmBackground       = Color(red: 0.043, green: 0.051, blue: 0.063)  // #0b0d10
    static let lrmBackground2      = Color(red: 0.047, green: 0.067, blue: 0.094)  // #0c1118
    static let lrmSurface          = Color(red: 0.075, green: 0.086, blue: 0.102, opacity: 0.72)  // rgba(19,22,26,0.72)
    static let lrmSurfaceStrong    = Color(red: 0.078, green: 0.102, blue: 0.133, opacity: 0.88)  // rgba(20,26,34,0.88)
    static let lrmText             = Color(red: 0.753, green: 0.776, blue: 0.800)  // #c0c6cc
    static let lrmTextStrong       = Color(red: 0.933, green: 0.953, blue: 0.969)  // #eef3f7
    static let lrmMuted            = Color(red: 0.408, green: 0.443, blue: 0.471)  // #687178
    static let lrmBorder           = Color(red: 0.753, green: 0.776, blue: 0.800, opacity: 0.12)
    static let lrmBorderStrong     = Color(red: 0.753, green: 0.776, blue: 0.800, opacity: 0.28)
    static let lrmAccent           = Color(red: 0.541, green: 0.518, blue: 1.0)     // #8a84ff
    static let lrmMetal            = Color(red: 0.847, green: 0.878, blue: 0.910)  // #d8e0e8
    static let lrmMetalMid         = Color(red: 0.545, green: 0.580, blue: 0.620)  // #8b949e
    static let lrmMetalDark        = Color(red: 0.188, green: 0.220, blue: 0.271)  // #303845
    static let lrmDanger           = Color(red: 0.984, green: 0.443, blue: 0.510)  // #fb7185
}

// MARK: - LRM Gradients

extension LinearGradient {
    /// Radial-like background: dark center → darker edges
    static let lrmBackgroundRadial = LinearGradient(
        colors: [
            Color(red: 0.063, green: 0.075, blue: 0.090),
            Color.lrmBackground,
            Color.lrmBackground2
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Metal button gradient: bright metal → mid metal
    static let lrmMetalButton = LinearGradient(
        colors: [Color.lrmMetal, Color.lrmMetalMid],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Accent gradient for active elements
    static let lrmAccentGradient = LinearGradient(
        colors: [Color.lrmAccent, Color.lrmAccent.opacity(0.6)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// User avatar gradient (blue)
    static let lrmUserGradient = LinearGradient(
        colors: [Color.blue, Color.blue.opacity(0.5)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Assistant avatar gradient (accent purple)
    static let lrmAssistantGradient = LinearGradient(
        colors: [Color.lrmAccent, Color.purple.opacity(0.6)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Chamfer Shape (replaces CSS clip-path)

struct ChamferShape: Shape {
    let cornerSize: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = min(cornerSize, min(rect.width, rect.height) / 2)
        p.move(to: CGPoint(x: c, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - c))
        p.addLine(to: CGPoint(x: rect.maxX - c, y: rect.maxY))
        p.addLine(to: CGPoint(x: 0, y: rect.maxY))
        p.addLine(to: CGPoint(x: 0, y: c))
        p.closeSubpath()
        return p
    }
}

// MARK: - View Modifiers

struct LiquidSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                ChamferShape(cornerSize: 6)
                    .fill(Color.lrmSurfaceStrong)
            )
            .overlay(
                ChamferShape(cornerSize: 6)
                    .stroke(Color.lrmBorder, lineWidth: 1)
            )
    }
}

struct MetalSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                ChamferShape(cornerSize: 4)
                    .fill(Color.lrmMetalDark)
            )
            .overlay(
                ChamferShape(cornerSize: 4)
                    .stroke(Color.lrmBorderStrong, lineWidth: 1)
            )
    }
}

struct LRMBorderModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay(
                ChamferShape(cornerSize: 4)
                    .stroke(Color.lrmBorder, lineWidth: 1)
            )
    }
}

extension View {
    func liquidSurface() -> some View {
        modifier(LiquidSurfaceModifier())
    }

    func metalSurface() -> some View {
        modifier(MetalSurfaceModifier())
    }

    func lrmBorder() -> some View {
        modifier(LRMBorderModifier())
    }
}
