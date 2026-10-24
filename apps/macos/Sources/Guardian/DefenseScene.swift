import SceneKit
import SwiftUI

// MARK: 3D scene

struct DefenseState: Equatable {
    enum Level: Equatable { case normal, fresh, threat, cited }
    /// One per pending alert, drawn as a numbered marker on the orb.
    struct Marker: Equatable {
        let alertID: String
        let index: Int          // 1-based; same number as the alert's row in the page list
        let title: String       // AlertCopy.title
        let detail: String      // AlertCopy.detail
        let time: String        // relativeTime(alert.created_at)
        let action: String?     // AlertCopy.defense?.label, e.g. "Bloquear :8080"
    }
    struct Node: Equatable {
        let key: String
        let kind: String
        let level: Level
        var marker: Marker? = nil
    }
    var nodes: [Node]
    var investigating: Bool
    var alert: Bool
    var connected: Bool = true
    var monitoring: Bool = true

    /// Marks each pending alert's node as a threat with a numbered marker, in list order;
    /// a second alert on the same entity gets its own node. Shared by every page that shows the orb.
    static func placing(_ alerts: [AgentAlert], on nodes: [Node], action: (AlertCopy.Defense) -> String? = { $0.label }) -> [Node] {
        var nodes = nodes
        for (offset, alert) in alerts.enumerated() {
            let copy = AlertCopy(alert)
            let marker = Marker(alertID: alert.id, index: offset + 1, title: copy.title, detail: copy.detail,
                                time: relativeTime(alert.created_at), action: copy.defense.flatMap(action))
            let key = alert.after.key
            if let index = nodes.firstIndex(where: { $0.key == key }), nodes[index].marker == nil {
                nodes[index] = .init(key: key, kind: nodes[index].kind, level: .threat, marker: marker)
            } else if nodes.contains(where: { $0.key == key }) {
                nodes.append(.init(key: "alert|\(alert.id)", kind: alert.after.kind, level: .threat, marker: marker))
            } else {
                nodes.append(.init(key: key, kind: alert.after.kind, level: .threat, marker: marker))
            }
        }
        return nodes
    }
}

enum OrbAlertIntent { case evidence, defend }

/// Marcador numerado ligado a su nodo; los nodos de amenaza sin alerta propia reciben uno sintético.
struct OrbMarker: Equatable {
    let key: String
    let marker: DefenseState.Marker
    let synthesized: Bool
}

/// Esfera de partículas: cada punto rojo numerado es una alerta y su tarjeta explica qué pasó.
struct DefenseSceneView: View {
    let state: DefenseState
    var onSelect: ((String) -> Void)? = nil
    var onAlert: ((String, OrbAlertIntent) -> Void)? = nil
    var focusedAlertID: Binding<String?> = .constant(nil)
    /// false: la página muestra su propia `OrbLegend` y no se dibuja la leyenda dentro del orbe.
    var showsLegend: Bool = true
    @State private var holder = DefenseSceneHolder()
    @State private var localPin: String?
    @State private var hoveredID: String?
    @State private var pointerOnMarker: String?
    @State private var cardHovered = false
    @State private var cycledID: String?
    @State private var lastCycle = Date.distantPast
    @State private var lastInteraction = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct TourID: Equatable { let ids: [String]; let reduceMotion: Bool }
    private var markers: [OrbMarker] { Self.markers(for: state) }
    private var pinnedID: String? {
        let id = focusedAlertID.wrappedValue ?? localPin
        return markers.contains { $0.marker.alertID == id } ? id : nil
    }
    private var cardID: String? { hoveredID ?? pinnedID ?? (reduceMotion ? markers.first?.marker.alertID : cycledID) }
    private var turnID: String? { pinnedID ?? (reduceMotion ? markers.first?.marker.alertID : cycledID) }
    private var turnKey: String? { turnID.flatMap { id in markers.first { $0.marker.alertID == id }?.key } }

    var body: some View {
        ZStack {
            DefenseSceneCanvas(scene: holder.scene, state: state, focusKey: turnKey, frozen: hoveredID != nil || cardHovered,
                               onSelect: onSelect, onInteract: { noteInteraction() })
                .background { OrbBackdrop(alert: state.alert) }
            OrbVerdict(state: state, count: markers.count)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if showsLegend {
                VStack(alignment: .leading, spacing: 6) {
                    OrbLegend()
                    Text("Arrastra para girar").font(.system(size: 13)).foregroundStyle(.white.opacity(0.62))
                }
                .padding(.horizontal, 18).padding(.bottom, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .allowsHitTesting(false)
            }
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: markers.isEmpty)) { _ in
                OrbMarkers(anchors: holder.scene.anchors(), cardID: cardID, pinnedID: pinnedID,
                           canDefend: onAlert != nil, canInspect: onSelect != nil || onAlert != nil,
                           toggle: togglePin, hover: markerHover, cardHover: cardHover, act: act)
            }
        }
        .onContinuousHover { phase in if case .active = phase { noteInteraction() } }
        .onChange(of: focusedAlertID.wrappedValue) { _, id in localPin = id }
        .task(id: TourID(ids: markers.map(\.marker.alertID), reduceMotion: reduceMotion)) {
            if let cycledID, !markers.contains(where: { $0.marker.alertID == cycledID }) { self.cycledID = nil }
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                tick()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(OrbVerdict.summary(state: state, count: markers.count))
    }

    static func markers(for state: DefenseState) -> [OrbMarker] {
        let real = state.nodes.compactMap { node in node.marker.map { OrbMarker(key: node.key, marker: $0, synthesized: false) } }
        if !real.isEmpty { return real.sorted { $0.marker.index < $1.marker.index } }
        return state.nodes.filter { $0.level == .threat }.enumerated().map { offset, node in
            let entity = node.key.split(separator: "|", maxSplits: 1).last.map(String.init) ?? node.key
            return OrbMarker(key: node.key, marker: .init(alertID: node.key, index: offset + 1, title: "Alerta en \(humanize(node.kind))",
                                                          detail: entity, time: "", action: nil), synthesized: true)
        }
    }

    private func noteInteraction() { lastInteraction = Date() }

    /// Recorrido de demostración: tras unos segundos sin tocar el orbe, gira hacia cada alerta y muestra su tarjeta.
    /// Cualquier interacción reciente congela el recorrido en la tarjeta actual para que se pueda usar.
    private func tick() {
        let now = Date()
        if cycledID != nil, pinnedID != nil || markers.isEmpty { cycledID = nil }
        guard !reduceMotion, !markers.isEmpty, pinnedID == nil, hoveredID == nil, !cardHovered,
              now.timeIntervalSince(lastInteraction) >= 6 else { return }
        guard cycledID == nil || now.timeIntervalSince(lastCycle) >= 4.5 else { return }
        let ids = markers.map(\.marker.alertID)
        let next = cycledID.flatMap { ids.firstIndex(of: $0) }.map { ($0 + 1) % ids.count } ?? 0
        cycledID = ids[next]
        lastCycle = now
    }

    private func togglePin(_ id: String) {
        noteInteraction()
        let next: String? = pinnedID == id ? nil : id
        localPin = next
        focusedAlertID.wrappedValue = next
    }

    private func markerHover(_ id: String, _ inside: Bool) {
        if inside {
            noteInteraction()
            pointerOnMarker = id
            hoveredID = id
        } else {
            if pointerOnMarker == id { pointerOnMarker = nil }
            releaseHover(id)
        }
    }

    private func cardHover(_ id: String, _ inside: Bool) {
        cardHovered = inside
        if inside {
            noteInteraction()
            hoveredID = id
        } else {
            releaseHover(id)
        }
    }

    /// Breve espera para que el puntero pueda pasar del marcador a su tarjeta sin cerrarla.
    private func releaseHover(_ id: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            if hoveredID == id, pointerOnMarker != id, !cardHovered { hoveredID = nil }
        }
    }

    private func act(_ item: OrbMarker, _ intent: OrbAlertIntent) {
        noteInteraction()
        if item.synthesized || onAlert == nil {
            if intent == .evidence { onSelect?(item.key) }
        } else {
            onAlert?(item.marker.alertID, intent)
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
    let focusKey: String?
    let frozen: Bool
    let onSelect: ((String) -> Void)?
    let onInteract: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> OrbSCNView {
        let view = OrbSCNView()
        view.orb = scene
        view.scene = scene.scene
        scene.view = view
        scene.selectionHandler.onSelect = onSelect
        scene.onInteraction = onInteract
        scene.reduceMotion = reduceMotion
        view.addGestureRecognizer(NSClickGestureRecognizer(target: scene.selectionHandler, action: #selector(OrbSelectionHandler.selectNode(_:))))
        view.addGestureRecognizer(NSPanGestureRecognizer(target: scene.selectionHandler, action: #selector(OrbSelectionHandler.rotate(_:))))
        view.pointOfView = scene.camera
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        // La cámara queda fija: el orbe siempre está en el centro; solo se gira con el arrastre propio.
        view.allowsCameraControl = false
        view.rendersContinuously = !reduceMotion
        view.scene?.isPaused = reduceMotion
        scene.apply(state)
        scene.focus(focusKey, animated: false)
        return view
    }

    func updateNSView(_ view: OrbSCNView, context: Context) {
        scene.selectionHandler.onSelect = onSelect
        scene.onInteraction = onInteract
        scene.reduceMotion = reduceMotion
        scene.fit(to: view.bounds.size)
        scene.apply(state)
        scene.focus(focusKey, animated: !reduceMotion)
        scene.hold(frozen)
        view.rendersContinuously = !reduceMotion
        view.scene?.isPaused = reduceMotion
    }
}

/// Vista de SceneKit sin zoom ni desplazamiento propios: el orbe no puede salir del centro.
final class OrbSCNView: SCNView {
    weak var orb: DefenseScene?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        orb?.fit(to: newSize)
    }

    // La rueda pasa a la página (si se desplaza) sin mover la cámara; pellizcar y girar con el trackpad no hacen nada.
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) {}
    override func smartMagnify(with event: NSEvent) {}
    override func rotate(with event: NSEvent) {}
}

@MainActor
final class OrbSelectionHandler: NSObject {
    var onSelect: ((String) -> Void)?
    weak var scene: DefenseScene?

    @objc func selectNode(_ recognizer: NSClickGestureRecognizer) {
        if let scene, scene.isDragging || Date().timeIntervalSince(scene.lastDragEnd) < 0.25 { return }
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

    /// Arrastre para girar el contenido del orbe; la cámara no se mueve.
    @objc func rotate(_ recognizer: NSPanGestureRecognizer) {
        guard let scene, let view = recognizer.view else { return }
        switch recognizer.state {
        case .began:
            scene.beginDrag()
            scene.drag(by: recognizer.translation(in: view))
        case .changed:
            scene.drag(by: recognizer.translation(in: view))
        case .ended:
            scene.endDrag(velocity: recognizer.velocity(in: view))
        case .cancelled, .failed:
            scene.endDrag(velocity: .zero)
        default:
            break
        }
    }
}

/// Posición en pantalla de un marcador de alerta.
struct OrbAnchor: Identifiable {
    let item: OrbMarker
    let point: CGPoint
    let visibility: Double
    var id: String { item.marker.alertID }
}

/// El Mac es una esfera de partículas; la evidencia vive en su superficie y las alertas la marcan con parches rojos.
@MainActor
final class DefenseScene {
    static let hitCategory = 2
    static let radius: Float = 1.9
    private static let spinKey = "spin"
    /// Inclinación máxima del arrastre vertical (unos 35°).
    static let maxPitch: Float = 35 * .pi / 180
    private static let dragGain: Float = 0.008
    /// Espacio reservado arriba y abajo para el veredicto, en puntos.
    private static let verdictRoom: CGFloat = 92

    let scene = SCNScene()
    let selectionHandler = OrbSelectionHandler()
    let camera = SCNNode()
    weak var view: SCNView?
    var reduceMotion = false
    var onInteraction: (() -> Void)?
    private(set) var lastDragEnd = Date.distantPast
    var isDragging: Bool { dragStart != nil }
    /// Inclinación (eje X) del arrastre; contiene a `pivot`.
    private let tilt = SCNNode()
    /// Guiñada (eje Y) compartida por el arrastre y el giro hacia la alerta enfocada.
    private let pivot = SCNNode()
    private let orbit = SCNNode()
    private let scanner: SCNNode
    private let shellMaterial: SCNMaterial?
    private let haloMaterial: SCNMaterial?
    private var nodes: [String: (node: SCNNode, level: DefenseState.Level)] = [:]
    private var markers: [OrbMarker] = []
    private var applied: DefenseState?
    private var focusedKey: String?
    private var dragStart: (yaw: Float, pitch: Float)?
    private var held = false

    init() {
        scene.background.contents = NSColor.clear

        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 40
        camera.camera?.wantsHDR = true
        camera.camera?.wantsExposureAdaptation = false
        camera.camera?.bloomIntensity = 0.35
        camera.camera?.bloomThreshold = 0.8
        camera.camera?.bloomBlurRadius = 6
        camera.position = SCNVector3(0, 1.1, 7.6)
        camera.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camera)

        scene.rootNode.addChildNode(tilt)
        tilt.addChildNode(pivot)
        pivot.addChildNode(orbit)
        orbit.eulerAngles.x = 0.08
        orbit.runAction(Self.spin, forKey: Self.spinKey)

        // Solo escribe profundidad: oculta el hemisferio trasero sin dibujar un disco opaco.
        let occluder = SCNNode(geometry: SCNSphere(radius: CGFloat(Self.radius * 0.965)))
        let mask = SCNMaterial()
        mask.colorBufferWriteMask = []
        occluder.geometry?.firstMaterial = mask
        occluder.renderingOrder = -10
        occluder.categoryBitMask = 1 | Self.hitCategory
        orbit.addChildNode(occluder)

        var random = SeededRandom(state: 0xA5C0_FFEE)
        let shell = SCNNode(geometry: Self.cloud(Self.shellParticles(count: 9_000, using: &random), size: 0.026, maxPixels: 2.2))
        shellMaterial = shell.geometry?.firstMaterial
        orbit.addChildNode(shell)
        let dust = SCNNode(geometry: Self.cloud(Self.dustParticles(count: 650, using: &random), size: 0.018, maxPixels: 1.4))
        dust.runAction(.repeatForever(.rotateBy(x: 0, y: -.pi * 2, z: 0, duration: 210)))
        scene.rootNode.addChildNode(dust)

        let halo = SCNNode(geometry: SCNTorus(ringRadius: CGFloat(Self.radius) * 1.34, pipeRadius: 0.003))
        (halo.geometry as? SCNTorus)?.ringSegmentCount = 160
        halo.geometry?.firstMaterial = Self.glow(NSColor(white: 1, alpha: 0.035))
        haloMaterial = halo.geometry?.firstMaterial
        halo.eulerAngles = SCNVector3(0.22, 0, -0.18)
        scene.rootNode.addChildNode(halo)

        let scannerShape = SCNTorus(ringRadius: CGFloat(Self.radius) * 1.03, pipeRadius: 0.006)
        scannerShape.ringSegmentCount = 160
        scanner = SCNNode(geometry: scannerShape)
        scanner.geometry?.firstMaterial = Self.glow(NSColor(srgbRed: 1, green: 0.78, blue: 0.5, alpha: 0.7))
        scanner.runAction(.repeatForever(.rotateBy(x: .pi * 2, y: 0, z: .pi, duration: 3.2)))
        orbit.addChildNode(scanner)
        selectionHandler.scene = self
    }

    /// Ajusta el campo de visión para que la esfera quepa en la dimensión menor, dejando sitio al veredicto.
    func fit(to size: CGSize) {
        guard size.width > 1, size.height > 1, let lens = camera.camera else { return }
        let shortest = min(size.width, size.height)
        var diameter = min(size.height - 2 * Self.verdictRoom, size.width - 48)
        diameter = min(max(diameter, shortest * 0.42), shortest * 0.8)
        let fraction = Double(diameter / size.height)
        let distance = Double(simd_length(camera.simdPosition))
        let r = Double(Self.radius) * 1.05
        let silhouette = r / (distance * distance - r * r).squareRoot()
        let fov = CGFloat(2 * atan(silhouette / fraction) * 180 / .pi)
        guard lens.projectionDirection != .vertical || abs(lens.fieldOfView - fov) > 0.01 else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        lens.projectionDirection = .vertical
        lens.fieldOfView = fov
        SCNTransaction.commit()
    }

    // MARK: Drag rotation

    /// El arrastre interrumpe el giro automático, el recorrido y cualquier giro hacia una alerta.
    func beginDrag() {
        onInteraction?()
        settle(pivot)
        settle(tilt)
        orbit.removeAction(forKey: Self.spinKey)
        dragStart = (pivot.simdEulerAngles.y, tilt.simdEulerAngles.x)
    }

    func drag(by translation: CGPoint) {
        guard let start = dragStart else { return }
        onInteraction?()
        setAngles(yaw: start.yaw + Float(translation.x) * Self.dragGain,
                  pitch: start.pitch - Float(translation.y) * Self.dragGain, duration: 0)
    }

    /// Inercia suave al soltar, salvo con movimiento reducido.
    func endDrag(velocity: CGPoint) {
        guard dragStart != nil else { return }
        dragStart = nil
        lastDragEnd = Date()
        onInteraction?()
        if !reduceMotion {
            let carry: Float = 0.16
            let vx = Float(min(max(velocity.x, -1_500), 1_500)), vy = Float(min(max(velocity.y, -1_500), 1_500))
            setAngles(yaw: pivot.simdEulerAngles.y + vx * Self.dragGain * carry,
                      pitch: tilt.simdEulerAngles.x - vy * Self.dragGain * carry, duration: 0.7)
        }
        resumeSpin()
    }

    private func setAngles(yaw: Float, pitch: Float, duration: CFTimeInterval) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
        pivot.simdEulerAngles.y = yaw
        tilt.simdEulerAngles.x = min(max(pitch, -Self.maxPitch), Self.maxPitch)
        SCNTransaction.commit()
    }

    /// Fija el ángulo visible como valor del modelo y descarta animaciones en curso (inercia o giro hacia una alerta).
    private func settle(_ node: SCNNode) {
        let angles = node.presentation.simdEulerAngles
        node.removeAllAnimations()
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        node.simdEulerAngles = angles
        SCNTransaction.commit()
    }

    private func resumeSpin() {
        guard focusedKey == nil, !held, dragStart == nil, orbit.action(forKey: Self.spinKey) == nil else { return }
        orbit.runAction(Self.spin, forKey: Self.spinKey)
    }

    private static var spin: SCNAction { .repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 120)) }

    func apply(_ state: DefenseState) {
        guard state != applied else { return }
        if state.alert != applied?.alert {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = applied == nil ? 0 : 1.2
            shellMaterial?.diffuse.contents = state.alert ? NSColor(srgbRed: 1, green: 0.74, blue: 0.72, alpha: 1) : NSColor.white
            haloMaterial?.diffuse.contents = state.alert ? NSColor(srgbRed: 1, green: 0.35, blue: 0.3, alpha: 1) : NSColor.white
            haloMaterial?.transparency = state.alert ? 0.1 : 0.035
            SCNTransaction.commit()
        }
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
        markers = DefenseSceneView.markers(for: state)
    }

    /// Detiene el giro y lleva el marcador al frente, rotando el contenido sobre el eje vertical; nil reanuda el giro.
    func focus(_ key: String?, animated: Bool) {
        guard key != focusedKey, dragStart == nil else { return }
        guard let key else {
            focusedKey = nil
            resumeSpin()
            return
        }
        guard let node = nodes[key]?.node, let eyeWorld = view?.pointOfView?.presentation.simdWorldPosition else { return }
        focusedKey = key
        orbit.removeAction(forKey: Self.spinKey)
        // Parte de los ángulos actuales (tras un arrastre o una inercia) y gira solo la guiñada, en el marco inclinado.
        settle(pivot)
        settle(tilt)
        let eye = tilt.presentation.simdConvertPosition(eyeWorld, from: nil)
        let position = tilt.presentation.simdConvertPosition(node.presentation.simdWorldPosition, from: nil)
        let delta = remainder(atan2(eye.x, eye.z) - atan2(position.x, position.z), 2 * .pi)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.8 : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
        pivot.simdEulerAngles.y += delta
        SCNTransaction.commit()
    }

    /// Pausa el giro mientras el puntero está sobre un marcador o su tarjeta, sin girar hacia él.
    func hold(_ frozen: Bool) {
        held = frozen
        if frozen {
            orbit.removeAction(forKey: Self.spinKey)
        } else {
            resumeSpin()
        }
    }

    /// Proyecta los marcadores a la vista; los que quedan detrás de la esfera se desvanecen.
    func anchors() -> [OrbAnchor] {
        guard let view, view.bounds.height > 0, let eye = view.pointOfView?.presentation.simdWorldPosition else { return [] }
        return markers.compactMap { item in
            guard let node = nodes[item.key]?.node else { return nil }
            let position = node.presentation.simdWorldPosition
            let facing = simd_dot(simd_normalize(position), simd_normalize(eye - position))
            let projected = view.projectPoint(SCNVector3(position))
            return OrbAnchor(item: item, point: CGPoint(x: projected.x, y: view.bounds.height - projected.y),
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

        let red = threatColor
        switch item.level {
        case .normal:
            container.addChildNode(dot(radius: 0.013, color: kindColor(item.kind).withAlphaComponent(0.28)))
        case .fresh:
            container.addChildNode(dot(radius: 0.021, color: freshColor))
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
            let patch = SCNNode(geometry: cloud(patchParticles(count: 70, cap: 0.1, tint: SIMD3(0.35, 0.88, 1), using: &random),
                                                size: 0.024, maxPixels: 2.2))
            container.addChildNode(patch)
            container.addChildNode(dot(radius: 0.036, color: citedColor))
        }
        return container
    }

    static let threatColor = NSColor(srgbRed: 1, green: 0.2, blue: 0.17, alpha: 1)
    static let citedColor = NSColor(srgbRed: 0.35, green: 0.88, blue: 1, alpha: 1)
    static let freshColor = NSColor(srgbRed: 0.5, green: 0.56, blue: 1, alpha: 0.85)

    private static func dot(radius: CGFloat, color: NSColor) -> SCNNode {
        let node = SCNNode(geometry: SCNSphere(radius: radius))
        node.geometry?.firstMaterial = glow(color)
        node.categoryBitMask = 1 | hitCategory
        return node
    }

    /// Onda tangente a la superficie que se expande desde la alerta.
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

    /// Distribución de Fibonacci con ruido: ámbar cálido arriba (el acento de la app), plata abajo.
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
            let light = 0.34 + 0.85 * pow(max(direction.y, 0), 0.7) + 0.3 * max(-direction.y, 0)
            let spark: Float = Float.random(in: 0...1, using: &random) < 0.035 ? 1.7 : 1
            let brightness = Float.random(in: 0.4...0.95, using: &random) * light * spark
            return (direction * distance, SIMD4(tone(direction.y) * brightness, 1))
        }
    }

    private static func dustParticles(count: Int, using random: inout SeededRandom) -> [Particle] {
        (0..<count).map { _ in
            let direction = simd_normalize(SIMD3(Float.random(in: -1...1, using: &random), .random(in: -1...1, using: &random), .random(in: -1...1, using: &random)))
            let distance = radius * .random(in: 1.06...1.55, using: &random)
            return (direction * distance, SIMD4(tone(direction.y) * Float.random(in: 0.05...0.22, using: &random), 1))
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
        let silver = SIMD3<Float>(0.78, 0.8, 0.86)
        let accent = SIMD3<Float>(1, 0.62, 0.26)
        let t = simd_smoothstep(-0.25, 0.6, y)
        return silver + (accent - silver) * t
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
            if alert {
                RadialGradient(colors: [Color.orbAlert.opacity(0.1), .clear],
                               center: .center, startRadius: 0, endRadius: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

/// Veredicto en lenguaje llano sobre la esfera: cuántas alertas hay o si el Mac está tranquilo.
private struct OrbVerdict: View {
    let state: DefenseState
    let count: Int
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static func lines(state: DefenseState, count: Int) -> (title: String, detail: String, tone: Color) {
        if !state.connected { return ("Sin conexión", "Inicia la vigilancia para ver tu Mac", Color.white.opacity(0.82)) }
        if count > 0 {
            return (count == 1 ? "1 alerta por revisar" : "\(count) alertas por revisar", "Cada punto rojo es una alerta", .orbAlert)
        }
        if !state.monitoring { return ("Vigilancia en pausa", "Reanúdala para detectar alertas nuevas", .warning) }
        return ("Sin alertas", state.investigating ? "Investigando…" : "Ninguna alerta pendiente · no garantiza seguridad", .commandAccent)
    }

    static func summary(state: DefenseState, count: Int) -> String {
        let verdict = lines(state: state, count: count)
        return "Orbe de este Mac. \(verdict.title). \(verdict.detail)."
    }

    var body: some View {
        let verdict = Self.lines(state: state, count: count)
        let pill = Capsule(style: .continuous)
        // Píldora de cristal en lugar de una mancha oscura: el orbe sigue visible detrás.
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(verdict.tone).frame(width: 8, height: 8).shadow(color: verdict.tone.opacity(0.9), radius: 5)
                Text(verdict.title).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background {
                if reduceTransparency { pill.fill(Color(white: 0.08)) } else { pill.fill(.ultraThinMaterial).environment(\.colorScheme, .dark) }
            }
            .overlay(pill.strokeBorder(LinearGradient(colors: [verdict.tone.opacity(0.55), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: verdict.tone.opacity(0.18), radius: 16)
            Text(verdict.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.62))
                .lineLimit(2)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Leyenda del orbe en horizontal (se apila si no cabe), con los mismos colores que dibuja la esfera.
/// `vertical: true` siempre la apila, para la franja bajo el orbe de Inicio.
struct OrbLegend: View {
    var vertical = false

    var body: some View {
        Group {
            if vertical {
                VStack(alignment: .leading, spacing: 8) { items }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { items }
                    VStack(alignment: .leading, spacing: 6) { items }
                }
            }
        }
        .font(.system(size: 13))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Leyenda del orbe: rojo, alerta; cian, evidencia que usa la IA; violeta, proceso nuevo")
    }

    @ViewBuilder private var items: some View {
        item(Color(nsColor: DefenseScene.threatColor), "Alerta")
        item(Color(nsColor: DefenseScene.citedColor), "Evidencia que usa la IA")
        item(Color(nsColor: DefenseScene.freshColor.withAlphaComponent(1)), "Proceso nuevo")
    }

    private func item(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 9) {
            Circle().fill(color).frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.8), radius: 4)
                .frame(width: 14, height: 14)
                .background(color.opacity(0.14), in: Circle())
            Text(label).foregroundStyle(.white.opacity(0.82)).fixedSize()
        }
    }
}

/// Marcadores numerados sobre cada alerta y una única tarjeta flotante para la alerta activa.
private struct OrbMarkers: View {
    let anchors: [OrbAnchor]
    let cardID: String?
    let pinnedID: String?
    let canDefend: Bool
    let canInspect: Bool
    let toggle: (String) -> Void
    let hover: (String, Bool) -> Void
    let cardHover: (String, Bool) -> Void
    let act: (OrbMarker, OrbAlertIntent) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var cardHeight: CGFloat = 250
    private static let cardWidth: CGFloat = 300

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(anchors.filter { $0.visibility > 0.01 }) { anchor in
                    marker(anchor).position(anchor.point).opacity(anchor.visibility)
                        .allowsHitTesting(anchor.visibility > 0.5)
                }
                if let anchor = anchors.first(where: { $0.id == cardID }), anchor.visibility > 0.05 {
                    card(anchor.item)
                        .offset(cardOrigin(anchor.point, in: geometry.size))
                        .opacity(min(1, anchor.visibility * 1.4))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    private func marker(_ anchor: OrbAnchor) -> some View {
        let active = anchor.id == cardID
        let item = anchor.item
        return Button { toggle(anchor.id) } label: {
            AlertBadge(index: item.marker.index, active: active)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover(anchor.id, $0) }
        .help(item.marker.title)
        .accessibilityLabel("Alerta \(item.marker.index): \(item.marker.title)")
        .accessibilityHint(pinnedID == anchor.id ? "Cierra la tarjeta de la alerta" : "Muestra la tarjeta de la alerta")
    }

    private func cardOrigin(_ point: CGPoint, in size: CGSize) -> CGSize {
        let width = Self.cardWidth, gap: CGFloat = 22
        let fitsRight = point.x + gap + width <= size.width - 8
        var x = fitsRight ? point.x + gap : point.x - gap - width
        x = min(max(x, 8), max(8, size.width - width - 8))
        let y = min(max(point.y - 36, 8), max(8, size.height - cardHeight - 8))
        return CGSize(width: x, height: y)
    }

    private func card(_ item: OrbMarker) -> some View {
        let marker = item.marker
        let pinned = pinnedID == marker.alertID
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Alerta \(marker.index)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.orbAlert)
                Spacer(minLength: 8)
                if pinned {
                    Button { toggle(marker.alertID) } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Cerrar")
                    .accessibilityLabel("Cerrar alerta \(marker.index)")
                }
            }
            .frame(height: 28)
            Text(marker.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text(marker.detail).font(.system(size: 14)).foregroundStyle(.white.opacity(0.78)).lineLimit(3)
            if !marker.time.isEmpty {
                Text(marker.time).font(.system(size: 13)).foregroundStyle(.white.opacity(0.62))
            }
            HStack(spacing: 14) {
                if canDefend, !item.synthesized, let action = marker.action {
                    Button { act(item, .defend) } label: {
                        Text(action).font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Color.commandAccent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Pide aprobación de administrador de macOS")
                }
                if canInspect {
                    Button { act(item, .evidence) } label: {
                        Text("Ver evidencia").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.commandAccent)
                            .padding(.vertical, 7).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14)
        .frame(width: Self.cardWidth, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            if reduceTransparency { shape.fill(Color(white: 0.08)) } else { shape.fill(.regularMaterial).environment(\.colorScheme, .dark) }
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
        .onHover { cardHover(marker.alertID, $0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Alerta \(marker.index): \(marker.title)")
    }
}

/// Número de alerta con el mismo aspecto en el orbe y en la lista de la página.
struct AlertBadge: View {
    let index: Int
    var active = false

    var body: some View {
        Text("\(index)")
            .font(.system(size: 13, weight: .bold)).monospacedDigit().foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Color.orbMarkerFill, in: Circle())
            .overlay(Circle().strokeBorder(active ? Color.white : Color.orbAlert, lineWidth: active ? 2 : 1.5))
    }
}

private extension Color {
    static let orbAlert = Color(red: 1, green: 0.27, blue: 0.24)
    /// Rojo más profundo para el relleno del marcador: el número blanco supera 4,5:1.
    static let orbMarkerFill = Color(red: 0.85, green: 0.16, blue: 0.14)
}
