import SwiftUI

/// Native glass where the SDK supports it; a material surface on macOS 15.
struct ArkGlass: ViewModifier {
    var radius: CGFloat = 18
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color.surface, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.hairline))
        } else {
#if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular.interactive(interactive), in: RoundedRectangle(cornerRadius: radius))
            } else {
                material(content)
            }
#else
            material(content)
#endif
        }
    }

    private func material(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius).strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.06), .white.opacity(0.18)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
    }
}

extension View {
    func arkGlass(radius: CGFloat = 18, interactive: Bool = false) -> some View {
        modifier(ArkGlass(radius: radius, interactive: interactive))
    }
}

/// A code-native winged lens, inspired by Arkangel's investigator identity.
struct ArkangelEmblem: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle().stroke(.white.opacity(0.08), lineWidth: 1).padding(side * 0.04)
                Circle().stroke(.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [2, 8])).padding(side * 0.12)
                Canvas { context, size in
                    let w = size.width
                    let h = size.height
                    for direction in [-1.0, 1.0] {
                        for index in 0..<6 {
                            let step = Double(index)
                            var feather = Path()
                            feather.move(to: CGPoint(x: w * 0.5 + direction * w * 0.085, y: h * (0.52 + step * 0.025)))
                            feather.addQuadCurve(to: CGPoint(x: w * 0.5 + direction * w * (0.31 - step * 0.026), y: h * (0.22 + step * 0.087)),
                                                 control: CGPoint(x: w * 0.5 + direction * w * 0.28, y: h * (0.53 + step * 0.03)))
                            feather.addQuadCurve(to: CGPoint(x: w * 0.5 + direction * w * 0.1, y: h * (0.66 + step * 0.018)),
                                                 control: CGPoint(x: w * 0.5 + direction * w * (0.35 - step * 0.024), y: h * (0.63 + step * 0.045)))
                            feather.closeSubpath()
                            context.fill(feather, with: .linearGradient(Gradient(colors: [.white.opacity(0.9 - step * 0.09), Color.info.opacity(0.4)]), startPoint: .zero, endPoint: CGPoint(x: w, y: h)))
                        }
                    }
                }
                Image(systemName: "magnifyingglass")
                    .font(.system(size: side * 0.19, weight: .ultraLight))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(-18))
                Circle().fill(.white.opacity(0.8)).frame(width: 4, height: 4).offset(y: -side * 0.38)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityHidden(true)
    }
}

struct AgentIdentityPanel: View {
    let connected: Bool
    let monitoring: Bool
    let investigating: Bool
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("ARKANGEL / 01").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(2)
                Spacer()
                Image(systemName: "sparkle").foregroundStyle(.white.opacity(0.6))
            }
            .foregroundStyle(.white.opacity(0.55))
            ArkangelEmblem().frame(width: 210, height: 210)
            VStack(spacing: 7) {
                Text(investigating ? "Siguiendo la evidencia" : "Tu investigador personal")
                    .font(.system(size: 21, weight: .medium, design: .serif))
                HStack(spacing: 7) {
                    StatusDot(color: investigating ? .info : connected && monitoring ? .success : .white.opacity(0.5))
                    Text(investigating ? "Investigación en curso" : connected ? (monitoring ? "Vigilancia local activa" : "Vigilancia en pausa") : "Listo para conectar")
                        .font(.caption)
                }.foregroundStyle(.white.opacity(0.65))
            }
            Hairline().opacity(0.45).padding(.top, 6)
            Label("Observa. Comprende. Decide.", systemImage: "lock.shield")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                Color(red: 0.035, green: 0.08, blue: 0.16)
                Ellipse().fill(Color.info.opacity(0.28)).blur(radius: 45).offset(x: 100, y: -100)
                Ellipse().fill(Color.cyan.opacity(0.10)).blur(radius: 60).offset(x: -100, y: 100)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.03), .white.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}
