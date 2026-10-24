import SwiftUI

/// One shaped surface: the tint and reflection never paint outside the card.
struct EvidenceGlassSurface: ViewModifier {
    var radius: CGFloat = 16
    var accent: Color = .investigatorAccent
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            materialSurface(content)
        }
#else
        materialSurface(content)
#endif
    }

    private func materialSurface(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background {
                if reduceTransparency {
                    shape.fill(Color.surface)
                } else {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Color.surface.opacity(scheme == .dark ? 0.22 : 0.5))
                    shape.fill(LinearGradient(colors: [accent.opacity(scheme == .dark ? 0.025 : 0.015), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [
                    scheme == .dark ? Color.white.opacity(0.35) : Color.white.opacity(0.95),
                    Color.white.opacity(0.035),
                    Color.hairline.opacity(0.65)
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                shape.inset(by: 1).strokeBorder(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.09 : 0.4), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.22 : 0.04), radius: 20, y: 8)
    }
}

struct WorkspaceAtmosphere: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.canvas
                if !reduceTransparency {
                    Ellipse().fill(Color.investigatorAccent.opacity(0.09))
                        .frame(width: geometry.size.width * 0.85, height: 440)
                        .blur(radius: 110).offset(x: geometry.size.width * 0.3, y: -160)
                    Ellipse().fill(Color.info.opacity(0.055))
                        .frame(width: geometry.size.width * 0.65, height: 500)
                        .blur(radius: 100).offset(x: -geometry.size.width * 0.35, y: 190)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension Color {
    static let investigatorAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.32, green: 0.8, blue: 0.66, alpha: 1)
            : NSColor(srgbRed: 0.035, green: 0.46, blue: 0.36, alpha: 1)
    })
}

/// Amber lighting around the existing orb; the gradient is decorative, never a status indicator.
struct CommandAtmosphere: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(red: 0.025, green: 0.022, blue: 0.02), Color(red: 0.006, green: 0.008, blue: 0.012)], startPoint: .top, endPoint: .bottom)
                if !reduceTransparency {
                    RadialGradient(colors: [Color(red: 0.95, green: 0.42, blue: 0.1).opacity(0.32), Color(red: 0.44, green: 0.19, blue: 0.04).opacity(0.12), .clear], center: UnitPoint(x: 0.5, y: -0.06), startRadius: 0, endRadius: geometry.size.width * 0.62)
                    RadialGradient(colors: [Color(red: 1, green: 0.7, blue: 0.38).opacity(0.07), .clear], center: UnitPoint(x: 0.52, y: 0.38), startRadius: 0, endRadius: max(geometry.size.width, geometry.size.height) * 0.38)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
