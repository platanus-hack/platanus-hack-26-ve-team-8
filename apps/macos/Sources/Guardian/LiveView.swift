import SceneKit
import SwiftUI

/// Señales persistentes y pasos de investigación; una señal no confirma un compromiso.
struct LiveView: View {
    @Bindable var model: GuardianModel
    let openReport: () -> Void

    private var investigating: Bool { model.investigating || model.progress?.active == true }
    private var threats: [AgentObservation] { model.detections.filter { $0.kind != "process" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    orbPanel.frame(minWidth: 430, maxWidth: .infinity)
                    activityPanel.frame(width: 300)
                }
                VStack(spacing: 18) { orbPanel; activityPanel }
            }
            Label("El núcleo representa este Mac. Los puntos representan evidencia registrada, no conexiones en tiempo real. La ausencia de señales no garantiza seguridad.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !investigating, let latest = model.investigations.first { verdictCard(latest) }
        }
    }

    private var orbPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("MAPA DE EVIDENCIA").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        StatusDot(color: headline.color)
                        Text(headline.title).font(.system(size: 19, weight: .medium, design: .serif))
                    }
                    Text(headline.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("\(sceneState.nodes.count) nodos").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(20)
            DefenseSceneView(state: sceneState)
                .frame(height: 310)
                .accessibilityLabel("Mapa tridimensional de la evidencia registrada")
                .accessibilityValue("\(sceneState.nodes.count) nodos; \(threats.count) señales pendientes")
                .overlay(alignment: .bottomLeading) {
                    Label("Arrastra para girar · Desplaza para acercar", systemImage: "cursorarrow.motionlines")
                        .font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                        .padding(.horizontal, 20).padding(.bottom, 12).allowsHitTesting(false)
                }
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { sceneLegend }
                    VStack(alignment: .leading, spacing: 7) { sceneLegend }
                }
                Text("Dorado: evidencia citada · Coral: señales por revisar")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Hairline()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { liveActions }
                    VStack(alignment: .leading, spacing: 8) { liveActions }
                }
            }.padding(16)
                .background(Color.white.opacity(0.025))
        }
        .background(Color(red: 0.025, green: 0.04, blue: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing)))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var sceneLegend: some View {
        legendItem("Procesos", .info)
        legendItem("Red", .cyan)
        legendItem("LaunchAgents", .purple)
        legendItem("Otras evidencias", .gray)
    }

    private func legendItem(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) { StatusDot(color: color); Text(title) }
            .font(.system(size: 9)).foregroundStyle(.secondary)
    }

    private var activityPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            claudeCard
            detectionsCard
        }
    }

    @ViewBuilder private var liveActions: some View {
        if model.status?.monitoring == false {
            Button("Activar monitoreo") { Task { await model.perform("monitoring") } }
                .buttonStyle(ArkButton(prominent: false)).disabled(model.busy)
        }
        Button("Renovar referencia", systemImage: "arrow.triangle.2.circlepath") { model.setBaseline() }
            .buttonStyle(ArkButton(prominent: false))
            .disabled(model.observations.isEmpty)
            .help("Usar los procesos cargados como nueva referencia visual. No borra ni revisa las señales.")
        Button("Investigar") { Task { await model.investigate() } }
            .buttonStyle(ArkButton())
            .disabled(model.busy || investigating || model.status == nil || model.status?.onboarding_required == true)
    }

    private var headline: (title: String, detail: String, color: Color) {
        if investigating {
            return ("Investigación en curso", "Leyendo la evidencia registrada con herramientas de solo lectura.", .white)
        }
        guard let status = model.status else {
            return ("Agente desconectado", "Inicia la vigilancia local desde Resumen para registrar evidencia.", .secondary)
        }
        if !threats.isEmpty {
            return (threats.count == 1 ? "1 señal pendiente de revisión" : "\(threats.count) señales pendientes de revisión",
                    "Cambios de archivos, firewall o escuchas para revisar.", .danger)
        }
        return (status.monitoring ? "Vigilando este Mac" : "Monitoreo en pausa",
                status.monitoring ? "Registrando observaciones locales de solo lectura." : "La evidencia anterior sigue disponible.", status.monitoring ? .success : .warning)
    }

    // MARK: Cards

    private var detectionsCard: some View {
        let detections = model.detections
        let newProcesses = detections.count - threats.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Cambios para revisar").font(.headline)
                Spacer()
                if let date = model.baselineDate {
                    Text("desde las \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.tertiary)
                }
            }
            if threats.isEmpty {
                Text("No hay señales pendientes en los datos cargados.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(threats.prefix(6)) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StatusDot(color: .danger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(humanize(item.kind)).fontWeight(.medium)
                        Text(item.entity).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Text(relativeTime(item.timestamp)).font(.caption).foregroundStyle(.tertiary)
                }
                .transition(.opacity)
            }
            if threats.count > 6 {
                Text("+\(threats.count - 6) más").font(.caption).foregroundStyle(.tertiary)
            }
            if newProcesses > 0 {
                Text("\(newProcesses) \(newProcesses == 1 ? "proceso nuevo" : "procesos nuevos") (incluye actividad normal)")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .animation(.snappy, value: threats.count)
        .card(padding: 18)
    }

    private var claudeCard: some View {
        let steps = model.progress?.steps ?? []
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Actividad del investigador").font(.headline)
                Spacer()
                if investigating { ProgressView().controlSize(.small) }
            }
            if steps.isEmpty {
                Text(investigating ? "Iniciando investigación…" : "Inicia una investigación para ver qué evidencia consulta el agente y cómo avanza.")
                    .font(.callout).foregroundStyle(.secondary)
                if !investigating {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Consulta la evidencia", systemImage: "doc.text.magnifyingglass")
                        Label("Contrasta hipótesis", systemImage: "point.3.connected.trianglepath.dotted")
                        Label("Presenta un informe con referencias", systemImage: "text.bubble")
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 10)
                    Label("Solo lectura · Sin acciones automáticas de defensa", systemImage: "lock.shield")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(steps.suffix(5).enumerated()), id: \.offset) { _, step in
                VStack(alignment: .leading, spacing: 6) {
                    Text(es(step.tool)).font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.canvas, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.hairline))
                    Text(step.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !steps.isEmpty && !investigating {
                Text("\(steps.count) \(steps.count == 1 ? "paso" : "pasos") de solo lectura · ningún comando ejecutado")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .animation(.snappy, value: steps.count)
        .card(padding: 18)
    }

    private func verdictCard(_ finding: Investigation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Pill(finding.status)
                Text(relativeTime(finding.created_at)).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Informe completo", action: openReport).buttonStyle(ArkButton(prominent: false))
            }
            Text(finding.title).font(.title3.weight(.semibold))
            Text(finding.summary).foregroundStyle(.secondary).lineLimit(3)
            if let action = finding.proposed_actions.first {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Propuesta · \(action.title)").fontWeight(.medium)
                        Text(action.description).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    ProposalStatus(action: action, model: model)
                }
                .padding(12)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
        .card(padding: 20)
        .transition(.opacity)
    }

    // MARK: Scene state

    private var sceneState: DefenseState {
        let cited = Set(model.progress?.steps.flatMap(\.evidence_ids)
            ?? model.investigations.first?.hypotheses.flatMap(\.evidence_ids) ?? [])
        let fresh = Set(model.detections.map(\.key))
        var seen = Set<String>()
        var processes = 0
        var nodes: [DefenseState.Node] = []
        for item in model.observations where seen.insert(item.key).inserted {
            if item.kind == "process" {
                // Keep a bounded view of recent processes; cited evidence remains visible.
                processes += 1
                if processes > 120 && !cited.contains(item.id) { continue }
            }
            let level: DefenseState.Level = cited.contains(item.id) ? .cited
                : fresh.contains(item.key) ? (item.kind == "process" ? .fresh : .threat) : .normal
            nodes.append(.init(key: item.key, kind: item.kind, level: level))
        }
        return DefenseState(nodes: nodes, investigating: investigating, alert: !threats.isEmpty)
    }
}

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

struct DefenseSceneView: NSViewRepresentable {
    let state: DefenseState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> DefenseScene { DefenseScene() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.camera
        view.backgroundColor = NSColor(srgbRed: 0.025, green: 0.04, blue: 0.07, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.defaultCameraController.minimumVerticalAngle = -65
        view.defaultCameraController.maximumVerticalAngle = 65
        view.allowsCameraControl = true
        view.rendersContinuously = !reduceMotion
        view.scene?.isPaused = reduceMotion
        context.coordinator.apply(state)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.apply(state)
        view.rendersContinuously = !reduceMotion
        view.scene?.isPaused = reduceMotion
    }
}

/// El Mac es el núcleo, envuelto en un escudo de alambre; la evidencia orbita en un anillo por tipo.
@MainActor
final class DefenseScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private let orbit = SCNNode()
    private let shield: SCNNode
    private let core: SCNNode
    private let scanner: SCNNode
    private let innerShell: SCNNode
    private var nodes: [String: (node: SCNNode, level: DefenseState.Level)] = [:]
    private var applied: DefenseState?

    private static let radii: [String: CGFloat] = ["process": 2.0, "tcp_listener": 2.65, "launch_agent": 3.3]

    init() {
        scene.background.contents = NSColor(srgbRed: 0.025, green: 0.04, blue: 0.07, alpha: 1)

        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 42
        camera.camera?.wantsHDR = true
        camera.camera?.wantsExposureAdaptation = false
        camera.camera?.exposureOffset = -0.3
        camera.camera?.bloomIntensity = 0.22
        camera.camera?.bloomThreshold = 0.9
        camera.camera?.bloomBlurRadius = 5
        camera.position = SCNVector3(0, 3.4, 9.6)
        camera.look(at: SCNVector3(0, -0.15, 0))
        scene.rootNode.addChildNode(camera)

        core = SCNNode(geometry: SCNSphere(radius: 0.9))
        let coreMaterial = SCNMaterial()
        coreMaterial.lightingModel = .physicallyBased
        coreMaterial.diffuse.contents = NSColor(srgbRed: 0.035, green: 0.09, blue: 0.18, alpha: 1)
        coreMaterial.metalness.contents = 0.65
        coreMaterial.roughness.contents = 0.3
        core.geometry?.firstMaterial = coreMaterial
        let innerShape = SCNSphere(radius: 1.13)
        innerShape.segmentCount = 24
        innerShell = SCNNode(geometry: innerShape)
        innerShell.eulerAngles.z = 0.4
        innerShell.runAction(.repeatForever(.rotateBy(x: 0, y: -.pi * 2, z: 0, duration: 65)))
        for (position, color, intensity) in [
            (SCNVector3(-3, 4, 3), NSColor(srgbRed: 0.2, green: 0.65, blue: 1, alpha: 1), 650.0),
            (SCNVector3(3, -1, -2), NSColor(srgbRed: 0.4, green: 0.25, blue: 1, alpha: 1), 500.0)
        ] {
            let light = SCNNode()
            light.light = SCNLight()
            light.light?.type = .omni
            light.light?.color = color
            light.light?.intensity = intensity
            light.position = position
            scene.rootNode.addChildNode(light)
        }
        let shieldShape = SCNSphere(radius: 1.35)
        shieldShape.isGeodesic = true
        shieldShape.segmentCount = 12
        shield = SCNNode(geometry: shieldShape)
        shield.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 40)))
        scanner = SCNNode(geometry: SCNTorus(ringRadius: 1.55, pipeRadius: 0.008))
        scanner.geometry?.firstMaterial = Self.glow(NSColor(srgbRed: 0.3, green: 0.8, blue: 1, alpha: 0.7))
        scanner.runAction(.repeatForever(.rotateBy(x: .pi * 2, y: 0, z: .pi, duration: 2.4)))

        scene.rootNode.addChildNode(orbit)
        orbit.eulerAngles.x = 0.12
        orbit.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 90)))
        for node in [core, innerShell, shield, scanner] { orbit.addChildNode(node) }
        for (kind, radius) in Self.radii.sorted(by: { $0.value < $1.value }) {
            let ring = SCNNode(geometry: SCNTorus(ringRadius: radius, pipeRadius: 0.004))
            ring.geometry?.firstMaterial = Self.glow(Self.kindColor(kind).withAlphaComponent(0.22))
            orbit.addChildNode(ring)
        }
    }

    func apply(_ state: DefenseState) {
        guard state != applied else { return }
        applied = state

        let alertColor = NSColor(srgbRed: 0.9, green: 0.28, blue: 0.3, alpha: 1)
        core.geometry?.firstMaterial?.emission.contents = state.alert && !state.investigating
            ? alertColor.withAlphaComponent(0.15) : NSColor(srgbRed: 0.01, green: 0.035, blue: 0.075, alpha: 1)
        let cyan = NSColor(srgbRed: 0.25, green: 0.65, blue: 1, alpha: 1)
        let shieldMaterial = Self.glow(state.alert && !state.investigating
            ? alertColor.withAlphaComponent(0.3) : cyan.withAlphaComponent(state.investigating ? 0.6 : 0.3))
        shieldMaterial.fillMode = .lines
        shield.geometry?.firstMaterial = shieldMaterial
        let innerMaterial = Self.glow(NSColor(srgbRed: 0.5, green: 0.35, blue: 1, alpha: 0.14))
        innerMaterial.fillMode = .lines
        innerShell.geometry?.firstMaterial = innerMaterial
        scanner.isHidden = !state.investigating

        let wanted = Dictionary(state.nodes.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, entry) in nodes where wanted[key] == nil {
            entry.node.removeFromParentNode()
            nodes[key] = nil
        }
        for item in state.nodes {
            if let existing = nodes[item.key], existing.level == item.level { continue }
            nodes[item.key]?.node.removeFromParentNode()
            let node = Self.evidenceNode(item, alertColor: alertColor)
            orbit.addChildNode(node)
            nodes[item.key] = (node, item.level)
        }
    }

    private static func evidenceNode(_ item: DefenseState.Node, alertColor: NSColor) -> SCNNode {
        let hash = fnv(item.key)
        let angle = CGFloat(hash % 3600) / 3600 * .pi * 2
        let lift = (CGFloat((hash >> 12) % 100) / 100 - 0.5) * 0.35
        let radius = radii[item.kind] ?? 3.8
        let position = SCNVector3(cos(angle) * radius, lift, sin(angle) * radius)

        let (size, color): (CGFloat, NSColor) = switch item.level {
        case .normal: (0.025, kindColor(item.kind).withAlphaComponent(0.55))
        case .fresh: (0.04, kindColor(item.kind))
        case .threat: (0.075, alertColor)
        case .cited: (0.065, NSColor(srgbRed: 1, green: 0.78, blue: 0.35, alpha: 1))
        }
        let container = SCNNode()
        let dot = SCNNode(geometry: SCNSphere(radius: size))
        dot.geometry?.firstMaterial = glow(color)
        dot.position = position
        container.addChildNode(dot)
        if item.level == .threat || item.level == .cited {
            // Un rayo hacia el núcleo muestra qué está tocando este Mac o qué acaba de leer Claude.
            container.addChildNode(beam(to: position, color: color.withAlphaComponent(0.6)))
        }
        if item.level == .threat {
            let pulse = SCNAction.sequence([.scale(to: 1.7, duration: 0.7), .scale(to: 1, duration: 0.7)])
            pulse.timingMode = .easeInEaseOut
            dot.runAction(.repeatForever(pulse))
        }
        return container
    }

    private static func beam(to point: SCNVector3, color: NSColor) -> SCNNode {
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: [SCNVector3Zero, point])],
                                   elements: [SCNGeometryElement(indices: [Int32(0), 1], primitiveType: .line)])
        geometry.firstMaterial = glow(color)
        return SCNNode(geometry: geometry)
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

    /// Estable entre ejecuciones, a diferencia de Hasher, para que la evidencia conserve su lugar en la órbita.
    private static func fnv(_ text: String) -> UInt64 {
        text.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}
