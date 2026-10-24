import SceneKit
import SwiftUI

// MARK: 3D scene

struct DefenseState: Equatable {
    enum Level: Equatable { case normal, fresh, threat, cited }
    struct Node: Equatable {
        let key: String
        let kind: String
        let level: Level
    }
    var nodes: [Node]
    var investigating: Bool
    var alert: Bool
}

/// Esfera de partículas con parches rojos para las señales y etiquetas ancladas a cada parche.
struct DefenseSceneView: View {
    let state: DefenseState
    var onSelect: ((String) -> Void)? = nil
    @State private var holder = DefenseSceneHolder()

    var body: some View {
        DefenseSceneCanvas(scene: holder.scene, state: state, onSelect: onSelect)
            .background { OrbBackdrop(alert: state.alert && !state.investigating) }
            .overlay {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                    OrbCallouts(anchors: holder.scene.anchors(), onSelect: onSelect)
                }
            }
    }
}

@MainActor
private final class DefenseSceneHolder {
    lazy var scene = DefenseScene()
}

private struct DefenseSceneCanvas: NSViewRepresentable {
    let scene: DefenseScene
    let state: DefenseState
    let onSelect: ((String) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene.scene
        scene.view = view
        scene.selectionHandler.onSelect = onSelect
        view.addGestureRecognizer(NSClickGestureRecognizer(target: scene.selectionHandler, action: #selector(OrbSelectionHandler.selectNode(_:))))
        view.pointOfView = scene.camera
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.defaultCameraController.minimumVerticalAngle = -65
        view.defaultCameraController.maximumVerticalAngle = 65
        view.allowsCameraControl = true
        view.rendersContinuously = !reduceMotion
        view.scene?.isPaused = reduceMotion
        scene.apply(state)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        scene.selectionHandler.onSelect = onSelect
        scene.apply(state)
        view.rendersContinuously = !reduceMotion
        view.scene?.isPaused = reduceMotion
    }
}

@MainActor
final class OrbSelectionHandler: NSObject {
    var onSelect: ((String) -> Void)?
    @objc func selectNode(_ recognizer: NSClickGestureRecognizer) {
        guard let view = recognizer.view as? SCNView else { return }
        let options: [SCNHitTestOption: Any] = [.categoryBitMask: DefenseScene.hitCategory]
        for result in view.hitTest(recognizer.location(in: view), options: options) {
            var node: SCNNode? = result.node
            while let candidate = node {
                if let name = candidate.name, name.hasPrefix("evidence:") {
                    onSelect?(String(name.dropFirst("evidence:".count)))
                    return
                }
                node = candidate.parent
            }
        }
    }
}

/// Posición en pantalla de un parche de señal, para colocar su etiqueta.
struct OrbAnchor: Identifiable {
    let id: String
    let index: Int
    let point: CGPoint
    let visibility: Double
    var kind: String { String(id.prefix { $0 != "|" }) }
    var entity: String { id.split(separator: "|", maxSplits: 1).last.map(String.init) ?? id }
}

/// El Mac es una esfera de partículas; la evidencia vive en su superficie y las señales la marcan con parches rojos.
@MainActor
final class DefenseScene {
    static let hitCategory = 2
    static let radius: Float = 1.9
    private static let maxCallouts = 4

    let scene = SCNScene()
    let selectionHandler = OrbSelectionHandler()
    let camera = SCNNode()
    weak var view: SCNView?
    private let orbit = SCNNode()
    private let scanner: SCNNode
    private var nodes: [String: (node: SCNNode, level: DefenseState.Level)] = [:]
    private var calloutKeys: [String] = []
    private var applied: DefenseState?

    init() {
        scene.background.contents = NSColor.clear

        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 40
        camera.camera?.wantsHDR = true
        camera.camera?.wantsExposureAdaptation = false
        camera.camera?.bloomIntensity = 0.55
        camera.camera?.bloomThreshold = 0.7
        camera.camera?.bloomBlurRadius = 7
        camera.position = SCNVector3(0, 1.1, 7.6)
        camera.look(at: SCNVector3(0, 0.05, 0))
        scene.rootNode.addChildNode(camera)

        scene.rootNode.addChildNode(orbit)
        orbit.eulerAngles.x = 0.08
        orbit.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 120)))

        // Solo escribe profundidad: oculta el hemisferio trasero sin dibujar un disco opaco.
        let occluder = SCNNode(geometry: SCNSphere(radius: CGFloat(Self.radius * 0.965)))
        let mask = SCNMaterial()
        mask.colorBufferWriteMask = []
        occluder.geometry?.firstMaterial = mask
        occluder.renderingOrder = -10
        occluder.categoryBitMask = 1 | Self.hitCategory
        orbit.addChildNode(occluder)

        var random = SeededRandom(state: 0xA5C0_FFEE)
        let shell = SCNNode(geometry: Self.cloud(Self.shellParticles(count: 14_000, using: &random), size: 0.026, maxPixels: 2.4))
        orbit.addChildNode(shell)
        let dust = SCNNode(geometry: Self.cloud(Self.dustParticles(count: 900, using: &random), size: 0.018, maxPixels: 1.6))
        dust.runAction(.repeatForever(.rotateBy(x: 0, y: -.pi * 2, z: 0, duration: 210)))
        scene.rootNode.addChildNode(dust)

        let halo = SCNNode(geometry: SCNTorus(ringRadius: CGFloat(Self.radius) * 1.34, pipeRadius: 0.003))
        (halo.geometry as? SCNTorus)?.ringSegmentCount = 160
        halo.geometry?.firstMaterial = Self.glow(NSColor(white: 1, alpha: 0.07))
        halo.eulerAngles = SCNVector3(0.22, 0, -0.18)
        scene.rootNode.addChildNode(halo)

        let scannerShape = SCNTorus(ringRadius: CGFloat(Self.radius) * 1.03, pipeRadius: 0.006)
        scannerShape.ringSegmentCount = 160
        scanner = SCNNode(geometry: scannerShape)
        scanner.geometry?.firstMaterial = Self.glow(NSColor(srgbRed: 1, green: 0.86, blue: 0.6, alpha: 0.85))
        scanner.runAction(.repeatForever(.rotateBy(x: .pi * 2, y: 0, z: .pi, duration: 3.2)))
        orbit.addChildNode(scanner)
    }

    func apply(_ state: DefenseState) {
        guard state != applied else { return }
        applied = state
        scanner.isHidden = !state.investigating

        let wanted = Dictionary(state.nodes.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, entry) in nodes where wanted[key] == nil {
            entry.node.removeFromParentNode()
            nodes[key] = nil
        }
        for item in state.nodes {
            if let existing = nodes[item.key], existing.level == item.level { continue }
            nodes[item.key]?.node.removeFromParentNode()
            let node = Self.evidenceNode(item)
            orbit.addChildNode(node)
            nodes[item.key] = (node, item.level)
        }
        calloutKeys = Array(state.nodes.filter { $0.level == .threat }.map(\.key).prefix(Self.maxCallouts))
    }

    /// Proyecta los parches de señal a la vista; los que quedan detrás de la esfera se desvanecen.
    func anchors() -> [OrbAnchor] {
        guard let view, view.bounds.height > 0, let eye = view.pointOfView?.presentation.simdWorldPosition else { return [] }
        return calloutKeys.enumerated().compactMap { index, key in
            guard let node = nodes[key]?.node else { return nil }
            let position = node.presentation.simdWorldPosition
            let facing = simd_dot(simd_normalize(position), simd_normalize(eye - position))
            let projected = view.projectPoint(SCNVector3(position))
            return OrbAnchor(id: key, index: index + 1,
                             point: CGPoint(x: projected.x, y: view.bounds.height - projected.y),
                             visibility: Double(min(max((facing - 0.08) / 0.25, 0), 1)))
        }
    }

    private static func evidenceNode(_ item: DefenseState.Node) -> SCNNode {
        let hash = fnv(item.key)
        let y = Float(hash % 10_000) / 10_000 * 1.6 - 0.8
        let longitude = Float((hash >> 20) % 3_600) / 3_600 * .pi * 2
        let ring = (1 - y * y).squareRoot()
        let direction = SIMD3<Float>(ring * cos(longitude), y, ring * sin(longitude))

        // El contenedor apunta su eje +Y hacia afuera, así el parche se construye como un casquete local.
        let container = SCNNode()
        container.name = "evidence:" + item.key
        container.simdPosition = direction * radius
        container.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: direction)

        let red = NSColor(srgbRed: 1, green: 0.2, blue: 0.17, alpha: 1)
        let gold = NSColor(srgbRed: 1, green: 0.8, blue: 0.42, alpha: 1)
        switch item.level {
        case .normal, .fresh:
            let color = kindColor(item.kind).withAlphaComponent(item.level == .fresh ? 0.95 : 0.55)
            container.addChildNode(dot(radius: item.level == .fresh ? 0.026 : 0.018, color: color))
        case .threat:
            var random = SeededRandom(state: hash)
            let patch = SCNNode(geometry: cloud(patchParticles(count: 380, cap: 0.27, tint: SIMD3(1, 0.16, 0.13), using: &random),
                                                size: 0.03, maxPixels: 2.8, blend: .alpha))
            patch.renderingOrder = 5
            let breathe = SCNAction.sequence([.fadeOpacity(to: 0.6, duration: 1.1), .fadeOpacity(to: 1, duration: 1.1)])
            breathe.timingMode = .easeInEaseOut
            patch.runAction(.repeatForever(breathe))
            container.addChildNode(patch)
            container.addChildNode(dot(radius: 0.05, color: red))
            container.addChildNode(pulse(color: red))
        case .cited:
            var random = SeededRandom(state: hash)
            let patch = SCNNode(geometry: cloud(patchParticles(count: 90, cap: 0.12, tint: SIMD3(1, 0.78, 0.4), using: &random),
                                                size: 0.026, maxPixels: 2.4))
            container.addChildNode(patch)
            container.addChildNode(dot(radius: 0.04, color: gold))
        }
        return container
    }

    private static func dot(radius: CGFloat, color: NSColor) -> SCNNode {
        let node = SCNNode(geometry: SCNSphere(radius: radius))
        node.geometry?.firstMaterial = glow(color)
        node.categoryBitMask = 1 | hitCategory
        return node
    }

    /// Onda tangente a la superficie que se expande desde la señal.
    private static func pulse(color: NSColor) -> SCNNode {
        let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.11, pipeRadius: 0.004))
        ring.geometry?.firstMaterial = glow(color)
        ring.position.y = 0.01
        let wave = SCNAction.sequence([
            .group([.scale(to: 2.8, duration: 1.8), .fadeOut(duration: 1.8)]),
            .scale(to: 1, duration: 0), .fadeOpacity(to: 0.9, duration: 0)
        ])
        ring.runAction(.repeatForever(wave))
        return ring
    }

    // MARK: Particles

    private typealias Particle = (position: SIMD3<Float>, color: SIMD4<Float>)

    /// Distribución de Fibonacci con ruido: dorado arriba, plata abajo, más brillo hacia el polo superior.
    private static func shellParticles(count: Int, using random: inout SeededRandom) -> [Particle] {
        let golden = Float.pi * (3 - Float(5).squareRoot())
        return (0..<count).map { index in
            let y = 1 - 2 * (Float(index) + 0.5) / Float(count)
            let ring = (1 - y * y).squareRoot()
            let angle = golden * Float(index)
            var direction = SIMD3(ring * cos(angle), y, ring * sin(angle))
            direction += SIMD3(.random(in: -0.025...0.025, using: &random), .random(in: -0.025...0.025, using: &random), .random(in: -0.025...0.025, using: &random))
            direction = simd_normalize(direction)
            var distance = radius * (1 + .random(in: -0.02...0.02, using: &random))
            if Float.random(in: 0...1, using: &random) < 0.08 { distance *= 1 + pow(.random(in: 0...1, using: &random), 2) * 0.18 }
            let light = 0.38 + 1.05 * pow(max(direction.y, 0), 0.7) + 0.4 * max(-direction.y, 0)
            let spark: Float = Float.random(in: 0...1, using: &random) < 0.04 ? 1.8 : 1
            let brightness = Float.random(in: 0.4...1, using: &random) * light * spark
            return (direction * distance, SIMD4(tone(direction.y) * brightness, 1))
        }
    }

    private static func dustParticles(count: Int, using random: inout SeededRandom) -> [Particle] {
        (0..<count).map { _ in
            let direction = simd_normalize(SIMD3(Float.random(in: -1...1, using: &random), .random(in: -1...1, using: &random), .random(in: -1...1, using: &random)))
            let distance = radius * .random(in: 1.06...1.55, using: &random)
            return (direction * distance, SIMD4(tone(direction.y) * Float.random(in: 0.08...0.35, using: &random), 1))
        }
    }

    /// Casquete alrededor de +Y, relativo al punto de la superficie; más denso y brillante en el centro.
    private static func patchParticles(count: Int, cap: Float, tint: SIMD3<Float>, using random: inout SeededRandom) -> [Particle] {
        (0..<count).map { _ in
            let spread = Float.random(in: 0...1, using: &random)
            let theta = cap * spread * spread.squareRoot()
            let phi = Float.random(in: 0...(2 * .pi), using: &random)
            let distance = radius * (1 + .random(in: 0...0.03, using: &random))
            let point = SIMD3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi)) * distance - SIMD3(0, radius, 0)
            let intensity = (1.35 - spread) * .random(in: 0.7...1, using: &random)
            return (point, SIMD4(tint * intensity, max(0.35, 1 - spread * 0.6)))
        }
    }

    private static func tone(_ y: Float) -> SIMD3<Float> {
        let silver = SIMD3<Float>(0.82, 0.84, 0.9)
        let gold = SIMD3<Float>(1, 0.6, 0.2)
        let t = simd_smoothstep(-0.2, 0.55, y)
        return silver + (gold - silver) * t
    }

    private static func cloud(_ particles: [Particle], size: CGFloat, maxPixels: CGFloat, blend: SCNBlendMode = .add) -> SCNGeometry {
        let colors = particles.map(\.color)
        let colorSource = SCNGeometrySource(
            data: colors.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .color, vectorCount: colors.count,
            usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride)
        let element = SCNGeometryElement(indices: Array(0..<Int32(particles.count)), primitiveType: .point)
        element.pointSize = size
        element.minimumPointScreenSpaceRadius = 0.6
        element.maximumPointScreenSpaceRadius = maxPixels
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: particles.map { SCNVector3($0.position) }), colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.white
        material.blendMode = blend
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        geometry.firstMaterial = material
        return geometry
    }

    private static func kindColor(_ kind: String) -> NSColor {
        switch kind {
        case "process": NSColor(srgbRed: 0.28, green: 0.5, blue: 1, alpha: 1)
        case "tcp_listener": NSColor(srgbRed: 0.2, green: 0.85, blue: 0.95, alpha: 1)
        case "launch_agent": NSColor(srgbRed: 0.65, green: 0.4, blue: 1, alpha: 1)
        default: NSColor(srgbRed: 0.6, green: 0.68, blue: 0.8, alpha: 1)
        }
    }

    private static func glow(_ color: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color.withAlphaComponent(1)
        material.transparency = color.alphaComponent
        material.blendMode = .alpha
        material.isDoubleSided = true
        return material
    }

    /// Estable entre ejecuciones, a diferencia de Hasher, para que la evidencia conserve su lugar en la esfera.
    private static func fnv(_ text: String) -> UInt64 {
        text.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}

/// SplitMix64: las partículas y los parches salen iguales en cada arranque.
private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: Overlays

private struct OrbBackdrop: View {
    let alert: Bool

    var body: some View {
        ZStack {
            Canvas { context, size in
                let spacing: CGFloat = 56
                var marks = Path()
                for x in stride(from: spacing / 2, to: size.width, by: spacing) {
                    for y in stride(from: spacing / 2, to: size.height, by: spacing) {
                        marks.move(to: CGPoint(x: x - 4, y: y)); marks.addLine(to: CGPoint(x: x + 4, y: y))
                        marks.move(to: CGPoint(x: x, y: y - 4)); marks.addLine(to: CGPoint(x: x, y: y + 4))
                    }
                }
                context.stroke(marks, with: .color(.white.opacity(0.06)), lineWidth: 0.6)
            }
            RadialGradient(colors: [Color(red: 1, green: 0.55, blue: 0.18).opacity(0.3), Color(red: 0.55, green: 0.24, blue: 0.05).opacity(0.1), .clear],
                           center: UnitPoint(x: 0.55, y: 0), startRadius: 0, endRadius: 340)
            if alert {
                RadialGradient(colors: [Color(red: 1, green: 0.18, blue: 0.15).opacity(0.12), .clear],
                               center: UnitPoint(x: 0.5, y: 0.75), startRadius: 0, endRadius: 260)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Etiquetas numeradas con línea guía hacia su parche; se alejan de la esfera hacia el lado más cercano.
private struct OrbCallouts: View {
    let anchors: [OrbAnchor]
    let onSelect: ((String) -> Void)?
    private static let cardSize = CGSize(width: 196, height: 40)

    var body: some View {
        GeometryReader { geometry in
            let layouts = anchors.filter { $0.visibility > 0.01 }.map { layout($0, in: geometry.size) }
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for item in layouts {
                        var leader = Path()
                        leader.move(to: item.anchor.point)
                        leader.addLine(to: item.elbow)
                        leader.addLine(to: item.edge)
                        context.stroke(leader, with: .color(Color.orbAlert.opacity(0.7 * item.anchor.visibility)), lineWidth: 1)
                        let ring = CGRect(x: item.anchor.point.x - 5, y: item.anchor.point.y - 5, width: 10, height: 10)
                        context.stroke(Path(ellipseIn: ring), with: .color(Color.orbAlert.opacity(item.anchor.visibility)), lineWidth: 1.2)
                    }
                }
                .allowsHitTesting(false)
                ForEach(layouts, id: \.anchor.id) { item in
                    card(item.anchor)
                        .position(item.center)
                        .opacity(item.anchor.visibility)
                        .allowsHitTesting(item.anchor.visibility > 0.5)
                }
            }
        }
    }

    private func card(_ anchor: OrbAnchor) -> some View {
        Button { onSelect?(anchor.id) } label: {
            HStack(spacing: 8) {
                Text(String(format: "%02d", anchor.index))
                    .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(Color.orbAlert, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Señal · \(humanize(anchor.kind))").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    Text(anchor.entity).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 7).padding(.trailing, 10)
            .frame(width: Self.cardSize.width, height: Self.cardSize.height)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orbAlert.opacity(0.55), lineWidth: 0.8))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(onSelect == nil ? anchor.entity : "Inspeccionar \(anchor.entity)")
        .accessibilityLabel("Señal \(anchor.index): \(humanize(anchor.kind)), \(anchor.entity)")
    }

    private struct Layout {
        let anchor: OrbAnchor
        let center: CGPoint
        let elbow: CGPoint
        let edge: CGPoint
    }

    private func layout(_ anchor: OrbAnchor, in size: CGSize) -> Layout {
        let side: CGFloat = anchor.point.x < size.width / 2 ? -1 : 1
        let rise: CGFloat = anchor.point.y < size.height / 2 ? -1 : 1
        let half = Self.cardSize.width / 2
        let x = min(max(anchor.point.x + side * (34 + half), half + 8), size.width - half - 8)
        let y = min(max(anchor.point.y + rise * 34, Self.cardSize.height / 2 + 6), size.height - Self.cardSize.height / 2 - 6)
        let edge = CGPoint(x: x - side * half, y: y)
        return Layout(anchor: anchor, center: CGPoint(x: x, y: y), elbow: CGPoint(x: anchor.point.x + side * 18, y: y), edge: edge)
    }
}

private extension Color {
    static let orbAlert = Color(red: 1, green: 0.27, blue: 0.24)
}
