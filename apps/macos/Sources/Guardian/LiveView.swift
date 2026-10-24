import SceneKit
import SwiftUI

/// Demo-first view: detections since baseline, Claude's steps as they happen, and the verdict.
struct LiveView: View {
    @Bindable var model: GuardianModel
    let openReport: () -> Void

    private var investigating: Bool { model.investigating || model.progress?.active == true }
    private var threats: [AgentObservation] { model.detections.filter { $0.kind != "process" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                DefenseSceneView(state: sceneState)
                hud
            }
            .frame(height: 420)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.hairline))
            HStack(alignment: .top, spacing: 16) {
                detectionsCard
                claudeCard
            }
            .fixedSize(horizontal: false, vertical: true)
            if !investigating, let latest = model.investigations.first { verdictCard(latest) }
        }
        .task {
            var tick = 0
            while !Task.isCancelled {
                if model.baseline == nil && !model.observations.isEmpty { model.setBaseline() }
                await model.pollProgress()
                // Faster than the dashboard's 15 s refresh so detections land within a few seconds.
                if tick % 3 == 0 { await model.refresh() }
                tick += 1
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    // MARK: HUD

    private var hud: some View {
        VStack(alignment: .leading) {
            HStack(spacing: 8) {
                StatusDot(color: headline.color)
                Text(headline.title).font(.headline)
            }
            Text(headline.detail).font(.callout).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 8) {
                Text("Drag to rotate").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if model.status?.monitoring == false {
                    Button("Enable monitoring") { Task { await model.perform("monitoring") } }
                        .buttonStyle(ArkButton(prominent: false)).disabled(model.busy)
                }
                Button("Reset baseline") { model.setBaseline() }
                    .buttonStyle(ArkButton(prominent: false))
                    .disabled(model.observations.isEmpty)
                Button("Investigate") { Task { await model.investigate() } }
                    .buttonStyle(ArkButton())
                    .disabled(investigating || model.status == nil || model.status?.onboarding_required == true)
            }
        }
        .padding(18)
        .environment(\.colorScheme, .dark)
    }

    private var headline: (title: String, detail: String, color: Color) {
        if investigating {
            return ("Claude is investigating", "Reading recorded evidence with read-only tools.", .white)
        }
        guard let status = model.status else {
            return ("Agent disconnected", "Connect from Overview to start defending this Mac.", .secondary)
        }
        if !threats.isEmpty {
            return ("\(threats.count) new \(threats.count == 1 ? "threat" : "threats") detected",
                    "New persistence or listeners since baseline.", .danger)
        }
        return (status.monitoring ? "Watching this Mac" : "Monitoring paused",
                "No new persistence or listeners since baseline.", status.monitoring ? .success : .warning)
    }

    // MARK: Cards

    private var detectionsCard: some View {
        let detections = model.detections
        let newProcesses = detections.count - threats.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Detections").font(.headline)
                Spacer()
                if let date = model.baselineDate {
                    Text("since \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.tertiary)
                }
            }
            if threats.isEmpty {
                Text("No new persistence or listeners since baseline.").font(.callout).foregroundStyle(.secondary)
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
                Text("+\(threats.count - 6) more").font(.caption).foregroundStyle(.tertiary)
            }
            if newProcesses > 0 {
                Text("\(newProcesses) new \(newProcesses == 1 ? "process" : "processes") (normal activity is included)")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .animation(.snappy, value: threats.count)
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }

    private var claudeCard: some View {
        let steps = model.progress?.steps ?? []
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Claude").font(.headline)
                Spacer()
                if investigating { ProgressView().controlSize(.small) }
            }
            if steps.isEmpty {
                Text(investigating ? "Starting investigation…" : "Press Investigate to let Claude examine the evidence.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(steps.suffix(7).enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(step.tool).font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.canvas, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.hairline))
                    Text(step.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !steps.isEmpty && !investigating {
                Text("\(steps.count) read-only \(steps.count == 1 ? "step" : "steps") · no commands executed")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .animation(.snappy, value: steps.count)
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }

    private func verdictCard(_ finding: Investigation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Pill(finding.status)
                Text(relativeTime(finding.created_at)).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Full report", action: openReport).buttonStyle(ArkButton(prominent: false))
            }
            Text(finding.title).font(.title3.weight(.semibold))
            Text(finding.summary).foregroundStyle(.secondary).lineLimit(3)
            if let action = finding.proposed_actions.first {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Proposal · \(action.title)").fontWeight(.medium)
                        Text(action.description).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Pill("Not applied", .secondary)
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
                // ponytail: newest 120 processes keep the scene legible; raise if the orbit looks sparse.
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

    func makeCoordinator() -> DefenseScene { DefenseScene() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.camera
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.rendersContinuously = true
        context.coordinator.apply(state)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.apply(state)
    }
}

/// The Mac is the core, wrapped in a wireframe shield; evidence orbits on one ring per kind.
@MainActor
final class DefenseScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private let orbit = SCNNode()
    private let shield: SCNNode
    private let core: SCNNode
    private let scanner: SCNNode
    private var nodes: [String: (node: SCNNode, level: DefenseState.Level)] = [:]
    private var applied: DefenseState?

    private static let radii: [String: CGFloat] = ["process": 2.2, "tcp_listener": 3.0, "launch_agent": 3.7]

    init() {
        scene.background.contents = NSColor.black

        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 42
        camera.camera?.wantsHDR = true
        camera.camera?.bloomIntensity = 1.6
        camera.camera?.bloomThreshold = 0.25
        camera.camera?.bloomBlurRadius = 14
        camera.position = SCNVector3(0, 2.5, 7.4)
        camera.look(at: SCNVector3(0, -0.15, 0))
        scene.rootNode.addChildNode(camera)

        core = SCNNode(geometry: SCNSphere(radius: 0.3))
        let shieldShape = SCNSphere(radius: 1.05)
        shieldShape.isGeodesic = true
        shieldShape.segmentCount = 18
        shield = SCNNode(geometry: shieldShape)
        shield.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 40)))
        scanner = SCNNode(geometry: SCNTorus(ringRadius: 1.35, pipeRadius: 0.012))
        scanner.geometry?.firstMaterial = Self.glow(.white)
        scanner.runAction(.repeatForever(.rotateBy(x: .pi * 2, y: 0, z: .pi, duration: 2.4)))

        scene.rootNode.addChildNode(orbit)
        orbit.eulerAngles.x = 0.12
        orbit.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 90)))
        for node in [core, shield, scanner] { orbit.addChildNode(node) }
        for radius in Self.radii.values {
            let ring = SCNNode(geometry: SCNTorus(ringRadius: radius, pipeRadius: 0.004))
            ring.geometry?.firstMaterial = Self.glow(NSColor(white: 1, alpha: 0.12))
            orbit.addChildNode(ring)
        }
    }

    func apply(_ state: DefenseState) {
        guard state != applied else { return }
        applied = state

        let alertColor = NSColor(srgbRed: 0.9, green: 0.28, blue: 0.3, alpha: 1)
        core.geometry?.firstMaterial = Self.glow(state.alert && !state.investigating ? alertColor : .white)
        let shieldMaterial = Self.glow(state.investigating ? NSColor(white: 1, alpha: 0.5)
            : state.alert ? alertColor.withAlphaComponent(0.45) : NSColor(white: 1, alpha: 0.22))
        shieldMaterial.fillMode = .lines
        shield.geometry?.firstMaterial = shieldMaterial
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
        let radius = radii[item.kind] ?? 4.3
        let position = SCNVector3(cos(angle) * radius, lift, sin(angle) * radius)

        let (size, color): (CGFloat, NSColor) = switch item.level {
        case .normal: (0.035, NSColor(white: 1, alpha: 0.35))
        case .fresh: (0.05, NSColor(white: 1, alpha: 0.85))
        case .threat: (0.11, alertColor)
        case .cited: (0.09, .white)
        }
        let container = SCNNode()
        let dot = SCNNode(geometry: SCNSphere(radius: size))
        dot.geometry?.firstMaterial = glow(color)
        dot.position = position
        container.addChildNode(dot)
        if item.level == .threat || item.level == .cited {
            // A beam back to the core shows what is touching this Mac, or what Claude just read.
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

    private static func glow(_ color: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.isDoubleSided = true
        return material
    }

    /// Stable across launches, unlike Hasher, so evidence keeps its place in orbit.
    private static func fnv(_ text: String) -> UInt64 {
        text.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}
