import SwiftUI

/// Inicio: the orb stays centered and fixed in the column; the band under it pairs its legend with the numbered alerts.
struct CommandCenter: View {
    @Bindable var model: GuardianModel
    let open: (Page) -> Void
    let protect: () -> Void
    let inspect: (AgentObservation) -> Void
    @FocusState private var questionFocused: Bool
    @State private var previousAlertIDs: Set<String>?
    @State private var focusedAlertID: String?
    /// Row under the pointer whose hover (not a click) set the focus; cleared when the pointer leaves.
    @State private var hoveredRowID: String?
    @State private var selectedObservation: AgentObservation?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var active: Bool { model.investigating || model.progress?.active == true }
    private var pending: [AgentAlert] { model.pendingAlerts }
    private static let alertRed = Color(red: 1, green: 0.27, blue: 0.24)
    private static let visibleAlerts = 4
    private static let bandHeight: CGFloat = 220

    var body: some View {
        mainLayout
            .environment(\.colorScheme, .dark)
            .tint(Color.commandAccent)
            .onChange(of: loadedAlertIDs, initial: true) { _, ids in receiveAlerts(ids) }
            .onChange(of: pendingAlertIDs) { _, ids in dropReviewedFocus(ids) }
            .sheet(item: $selectedObservation) { observation in nodeInspector(observation) }
    }

    private var pendingAlertIDs: [String] { pending.map(\.id) }

    private var loadedAlertIDs: [String]? {
        guard model.alertsLoaded else { return nil }
        return model.alerts.map(\.id)
    }

    private func receiveAlerts(_ ids: [String]?) {
        guard let ids else { return }
        if let previous = previousAlertIDs,
           let fresh = pending.first(where: { !previous.contains($0.id) }) {
            focusedAlertID = fresh.id
        }
        previousAlertIDs = Set(ids)
    }

    private func dropReviewedFocus(_ ids: [String]) {
        if let focused = focusedAlertID, !ids.contains(focused) { focusedAlertID = nil }
    }

    // MARK: Layout

    /// Fits the window instead of scrolling, so the orb never moves away from the center of the column.
    private var mainLayout: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            if let error = model.error { errorNotice(error).padding(.horizontal, 26).padding(.top, 12) }
            statusStrip
                .padding(.horizontal, 12).padding(.vertical, 10)
                .modifier(EvidenceGlassSurface(radius: 16, accent: .commandAccent))
                .padding(.horizontal, 26).padding(.top, geometry.size.height < 720 ? 8 : 18).padding(.bottom, 8)
            orbPresentation.frame(maxWidth: .infinity, minHeight: geometry.size.height < 720 ? 180 : 220, maxHeight: .infinity).layoutPriority(1)
            // Offered space before the orb so it keeps its full height, and shrinks only when the window is too short.
            alertBand.frame(minHeight: 130, maxHeight: Self.bandHeight).layoutPriority(2)
                .modifier(EvidenceGlassSurface(radius: 20, accent: .commandAccent))
                .padding(.horizontal, 26).padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 8) {
                composer.padding(geometry.size.height < 720 ? 10 : 14).modifier(EvidenceGlassSurface(radius: 16, accent: .commandAccent))
                footer
            }.padding(.horizontal, 26).padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { CommandAtmosphere() }
        }
    }

    private var divider: some View { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1) }

    // MARK: Status strip

    @ViewBuilder private var statusStrip: some View {
        if let status = model.status {
            let open = (status.exposed ?? []).filter { !$0.blocked }.count
            HStack(spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { firewallFacts(status); portsFact(open) }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) { firewallFacts(status) }
                        portsFact(open)
                    }
                }
                Spacer(minLength: 12)
                investigatingPill
                protectionLink
            }
            .font(.system(size: 14))
            .help(status.last_scan.map { "Última instantánea: \(fullTime($0))" } ?? "Aún no hay instantáneas")
        } else {
            HStack(spacing: 12) {
                StatusDot(color: Self.alertRed)
                Text("Agente sin conexión").font(.system(size: 14, weight: .medium))
                Spacer(minLength: 12)
                investigatingPill
                Button("Iniciar vigilancia local") { Task { await model.startLocalMonitoring() } }
                    .buttonStyle(CommandButton()).disabled(model.busy)
            }
        }
    }

    @ViewBuilder private var investigatingPill: some View {
        if active {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Investigando…")
            }
            .font(.system(size: 14, weight: .medium)).foregroundStyle(Color.commandAccent)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .overlay(Capsule().strokeBorder(Color.commandAccent.opacity(0.4)))
            .fixedSize()
            .accessibilityElement(children: .combine)
        }
    }

    /// Firewall and stealth share a line; when the strip stacks, ports take the second line, so it never exceeds 2 lines.
    @ViewBuilder private func firewallFacts(_ status: AgentStatus) -> some View {
        let firewall = status.firewall
        statusFact(firewall.map { $0.firewall_enabled ? "Firewall activado" : "Firewall desactivado" } ?? "Firewall sin datos",
                   weak: firewall.map { $0.firewall_enabled ? nil : Self.alertRed } ?? nil)
        statusFact(firewall.map { $0.stealth_mode ? "Modo sigiloso activado" : "Modo sigiloso desactivado" } ?? "Modo sigiloso sin datos",
                   weak: firewall.map { $0.stealth_mode ? nil : Color.warning } ?? nil)
    }

    private func portsFact(_ open: Int) -> some View {
        statusFact(open == 0 ? "Ningún puerto abierto a la red" : open == 1 ? "1 puerto abierto a la red" : "\(open) puertos abiertos a la red",
                   weak: open > 0 ? Color.warning : nil)
    }

    /// Chip tintado: rojo o ámbar cuando algo está débil, neutro con check cuando está bien.
    private func statusFact(_ text: String, weak: Color?) -> some View {
        let tint = weak ?? Color.white
        return HStack(spacing: 7) {
            if let weak {
                Circle().fill(weak).frame(width: 6, height: 6).shadow(color: weak.opacity(0.9), radius: 3)
            } else {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.success)
            }
            Text(text).font(.system(size: 13, weight: weak == nil ? .regular : .medium))
                .foregroundStyle(weak == nil ? Color.commandSecondary : Color.white)
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(tint.opacity(weak == nil ? 0.04 : 0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(weak == nil ? 0.1 : 0.3), lineWidth: 1))
        .lineLimit(1).fixedSize()
    }

    private var protectionLink: some View {
        Button(action: protect) {
            HStack(spacing: 4) { Text("Revisar protección"); Image(systemName: "arrow.right") }
        }
        .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.commandAccent).fixedSize()
        .help("Puertos, firewall, cobertura y bloqueos registrados")
    }

    private var orbPresentation: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                orb
                if geometry.size.width >= 1080 && geometry.size.height >= 300 {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("[ EVIDENCIA LOCAL ]")
                            .font(.system(size: 12, weight: .medium, design: .monospaced)).tracking(1.2)
                            .foregroundStyle(Color.commandSecondary)
                        Text("ENTIENDE\nTU MAC.")
                            .font(.system(size: 34, weight: .medium).width(.expanded)).tracking(-1.3)
                            .foregroundStyle(LinearGradient(colors: [.white, Color.white.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                        Text("Observa cambios.\nConsulta su evidencia.")
                            .font(.system(size: 15)).lineSpacing(3).foregroundStyle(Color.commandSecondary)
                    }
                    .frame(width: 245, alignment: .leading).padding(.leading, 40).padding(.top, 24)
                    .allowsHitTesting(false)
                    VStack(spacing: 12) {
                        orbitMetric("Registro local", value: model.status.map { $0.observation_count.formatted() } ?? "—", detail: "Observaciones", symbol: "waveform.path.ecg") { open(.observations) }
                        orbitMetric("Para revisar", value: connected ? pending.count.formatted() : "—", detail: "Alertas pendientes", symbol: "tray") { open(.alerts) }
                    }
                    .frame(width: 170).frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 40).padding(.top, 24)
                }
            }
        }
    }

    private func orbitMetric(_ title: String, value: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text(title).font(.system(size: 13, weight: .medium)); Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 11)) }
                    .foregroundStyle(Color.commandSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(value).font(.system(size: 27, weight: .regular).width(.expanded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    Image(systemName: symbol).font(.system(size: 15, weight: .light)).foregroundStyle(Color.commandAccent)
                }
                Text(detail).font(.system(size: 13)).foregroundStyle(Color.commandSecondary)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(EvidenceGlassSurface(radius: 18, accent: .commandAccent))
        }.buttonStyle(HoverCardStyle(radius: 18))
    }

    // MARK: Orb

    private var orb: some View {
        DefenseSceneView(state: orbState, onSelect: { key in
            selectedObservation = model.observations.first { $0.key == key }
                ?? pending.first { $0.after.key == key || "alert|\($0.id)" == key }?.after
        }, onAlert: { id, intent in handleOrb(id, intent) }, focusedAlertID: $focusedAlertID, showsLegend: false)
    }

    private func handleOrb(_ id: String, _ intent: OrbAlertIntent) {
        guard let alert = model.alerts.first(where: { $0.id == id }) else { return }
        focusedAlertID = id
        switch intent {
        case .evidence:
            selectedObservation = model.observations.first { $0.key == alert.after.key } ?? alert.after
        case .defend:
            guard let defense = AlertCopy(alert).defense, !model.busy, !applied(defense) else { return }
            Task { await model.defend(defense.type, port: defense.port) }
        }
    }

    private func applied(_ defense: AlertCopy.Defense) -> Bool {
        if defense.type == "block_port", let port = defense.port { return model.status?.blocked_ports?.contains(port) == true }
        return model.status?.firewall?.firewall_enabled == true
    }

    private var orbState: DefenseState {
        let fresh = Set(model.detections.map(\.key))
        let cited = Set(model.progress?.steps.flatMap(\.evidence_ids) ?? [])
        var seen = Set<String>()
        var processes = 0
        let nodes = model.observations.compactMap { observation -> DefenseState.Node? in
            guard seen.insert(observation.key).inserted else { return nil }
            if observation.kind == "process" { processes += 1; if processes > 120 && !cited.contains(observation.id) { return nil } }
            let level: DefenseState.Level = cited.contains(observation.id) ? .cited : fresh.contains(observation.key) ? (observation.kind == "process" ? .fresh : .threat) : .normal
            return .init(key: observation.key, kind: observation.kind, level: level)
        }
        // A defense already applied, or one waiting on the admin prompt, is not offered again.
        let placed = DefenseState.placing(pending, on: nodes) { applied($0) || model.busy ? nil : $0.label }
        return DefenseState(nodes: placed, investigating: active, alert: !pending.isEmpty, connected: connected,
                            monitoring: model.status?.monitoring ?? true)
    }

    // MARK: Legend and alerts band

    /// One section under the orb: how to read it on one side, the alerts it marks on the other.
    /// The vertical legend (about 252pt with padding) plus the 360pt list fits the 620pt minimum center column.
    private var alertBand: some View {
        HStack(alignment: .top, spacing: 0) {
            legend.frame(width: 200, alignment: .leading).padding(.horizontal, 26).padding(.vertical, 16)
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            alertList.frame(minWidth: 360, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("[ LEYENDA ]").font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(1.2)
                .foregroundStyle(Color.commandSecondary.opacity(0.8)).accessibilityHidden(true)
            OrbLegend(vertical: true)
            Label("Arrastra para girar", systemImage: "hand.draw")
                .font(.system(size: 12)).foregroundStyle(Color.commandSecondary.opacity(0.8))
        }.fixedSize(horizontal: false, vertical: true)
    }

    private var alertList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Cambios por revisar").font(.system(size: 18, weight: .medium).width(.expanded))
                if connected && !pending.isEmpty {
                    Text("\(pending.count)").font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Self.alertRed, in: Capsule())
                        .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] + 1 }
                }
                Spacer(minLength: 8)
                if connected && pending.count > Self.visibleAlerts {
                    Button { open(.alerts) } label: {
                        HStack(spacing: 4) { Text("Ver todas las alertas (\(pending.count))"); Image(systemName: "arrow.right") }
                    }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.commandAccent)
                    .accessibilityLabel("Ver todas las alertas, \(pending.count) en total")
                }
            }
            .padding(.horizontal, 10)
            if !connected {
                Text(model.status == nil ? "Las alertas aparecerán al conectar el agente." : "Cargando alertas…")
                    .font(.system(size: 14)).foregroundStyle(Color.commandSecondary).padding(.horizontal, 10)
            } else if pending.isEmpty {
                emptyState("Nada pendiente por ahora", "Te avisaremos si algo cambia. No ver alertas no garantiza que el Mac esté seguro.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(pending.prefix(Self.visibleAlerts).enumerated()), id: \.element.id) { offset, alert in
                            alertRow(alert, index: offset + 1)
                        }
                    }
                }.scrollIndicators(.automatic)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var connected: Bool { model.status != nil && model.alertsLoaded }

    private func alertRow(_ alert: AgentAlert, index: Int) -> some View {
        let copy = AlertCopy(alert)
        let focused = focusedAlertID == alert.id
        return Button {
            hoveredRowID = nil
            focusedAlertID = alert.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                AlertBadge(index: index, active: focused)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(copy.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.white).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(relativeTime(alert.created_at)).font(.system(size: 13)).foregroundStyle(Color.commandSecondary)
                            .lineLimit(1).fixedSize().help(fullTime(alert.created_at))
                    }
                    Text(copy.detail).font(.system(size: 14)).foregroundStyle(Color.commandSecondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(focused ? Color.commandAccent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copy.title)
        .onHover { inside in rowHover(alert.id, inside) }
        .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: focused)
        .accessibilityLabel("Alerta \(index): \(copy.title)")
        .accessibilityHint("Señala esta alerta en el orbe")
        .accessibilityAddTraits(focused ? .isSelected : [])
    }

    /// Hover previews a row on the orb without replacing a pin made by a click.
    private func rowHover(_ id: String, _ inside: Bool) {
        if inside {
            guard focusedAlertID == nil || focusedAlertID == hoveredRowID else { return }
            hoveredRowID = id
            focusedAlertID = id
        } else if hoveredRowID == id {
            hoveredRowID = nil
            if focusedAlertID == id { focusedAlertID = nil }
        }
    }

    private func emptyState(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 17, weight: .medium)).foregroundStyle(Color.commandAccent)
                .frame(width: 40, height: 40)
                .background(Color.commandAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.commandAccent.opacity(0.22)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(Color.commandSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10).padding(.top, 6)
        .accessibilityElement(children: .combine)
    }

    // MARK: Composer

    /// One slim row; the suggestions (or the progress note) only appear when the column has room for them.
    private var composer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { questionField; composerExtras; sendQuestion }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) { questionField; sendQuestion }
                composerExtras
            }
            HStack(spacing: 12) { questionField; sendQuestion }
        }
    }

    @ViewBuilder private var composerExtras: some View {
        if active {
            HStack(spacing: 10) {
                Text("Consultando evidencia…").font(.system(size: 13)).foregroundStyle(Color.commandSecondary)
                Button("Ver seguimiento") { open(.live) }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.commandAccent)
            }.fixedSize()
        } else {
            HStack(spacing: 8) { suggestedQuestions }.fixedSize()
        }
    }

    @ViewBuilder private var suggestedQuestions: some View {
        ForEach(["Explica las escuchas de red abiertas", "Revisa mis LaunchAgents"], id: \.self) { suggestion in
            Button {
                model.question = suggestion
                questionFocused = true
            } label: {
                Text(suggestion).font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.white.opacity(0.04), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Usar esta pregunta; pulsa Investigar cuando quieras enviarla")
        }
    }

    private var questionField: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 14)).foregroundStyle(Color.commandAccent)
            TextField("¿Qué quieres revisar?", text: $model.question)
                .textFieldStyle(.plain).font(.system(size: 15)).lineLimit(1).focused($questionFocused)
            Text("⌘K").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Color.commandSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.1)))
                .opacity(questionFocused ? 0 : 1)
                .accessibilityHidden(true)
        }
            .padding(.horizontal, 14).padding(.vertical, 10).frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(questionFocused ? 0.06 : 0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(questionFocused ? Color.commandAccent.opacity(0.6) : Color.white.opacity(0.12)))
            .shadow(color: Color.commandAccent.opacity(questionFocused ? 0.18 : 0), radius: 12)
            .animation(.easeOut(duration: 0.15), value: questionFocused)
            .background { Button("") { questionFocused = true }.keyboardShortcut("k", modifiers: .command).hidden() }
            .accessibilityLabel("Pregunta para el investigador")
            .help("Por ejemplo: ¿qué puertos están accesibles desde la red?")
    }

    @ViewBuilder private var sendQuestion: some View {
        if model.status?.onboarding_required == true {
            Button("Conectar investigador") { model.setupVisible = true }.buttonStyle(CommandButton()).fixedSize()
        } else {
            Button(active ? "Investigando…" : "Investigar", systemImage: "arrow.up.right") { Task { await model.investigate() } }
                .buttonStyle(CommandButton()).disabled(model.busy || active || model.status == nil).fixedSize()
        }
    }

    private var footer: some View {
        Text("Una alerta no confirma un ataque y no ver alertas no garantiza seguridad. Cada defensa pide aprobación de macOS.")
            .font(.system(size: 12)).foregroundStyle(Color.commandSecondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            .help("La cobertura puede ser parcial: una alerta no confirma un ataque y no ver alertas no garantiza seguridad. Cada defensa pide tu aprobación de administrador de macOS.")
    }

    private func errorNotice(_ error: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
            Text(error).font(.system(size: 14))
            Spacer(minLength: 8)
            Button("Reintentar") { Task { await model.refresh() } }.buttonStyle(CommandButton(prominent: false)).disabled(model.busy)
            Button("Cerrar") { model.error = nil }.buttonStyle(CommandButton(prominent: false))
        }
        .padding(12).foregroundStyle(Color.danger)
        .background(Color.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Evidence sheet

    private func nodeInspector(_ observation: AgentObservation) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(observation.summary).font(.system(size: 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cerrar", systemImage: "xmark") { selectedObservation = nil }.labelStyle(.iconOnly).keyboardShortcut(.cancelAction)
            }
            Text(observation.entity).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
            Text(fullTime(observation.timestamp)).font(.system(size: 13)).foregroundStyle(Color.commandSecondary)
            Text("Es evidencia registrada, no una conexión en tiempo real.").font(.system(size: 13)).foregroundStyle(Color.commandSecondary)
            DisclosureGroup {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(observation.attributes.keys.sorted(), id: \.self) { key in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(key).font(.system(size: 13)).foregroundStyle(Color.commandSecondary)
                                Text(observation.attributes[key]?.display ?? "").font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }.frame(maxHeight: 200)
            } label: { Text("Detalles técnicos").font(.system(size: 13, weight: .medium)) }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                if model.observations.contains(where: { $0.id == observation.id }) {
                    Button("Abrir registro") { selectedObservation = nil; inspect(observation) }
                }
                Button("Ver alertas") { selectedObservation = nil; open(.alerts) }
                Button("Revisar protección") { selectedObservation = nil; protect() }
            }.buttonStyle(CommandButton(prominent: false))
        }.padding(24).frame(width: 520, height: 440).background { CommandAtmosphere() }
            .environment(\.colorScheme, .dark)
    }
}

extension Color {
    static let commandSecondary = Color.white.opacity(0.78)
    static let commandAccent = Color(red: 1.0, green: 0.7, blue: 0.4)
}

/// Primario: ámbar con brillo superior y halo suave. Secundario: cristal tenue que se aclara al pasar el cursor.
struct CommandButton: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let filled = prominent && enabled
        let lit = enabled && hovered
        return configuration.label.font(.system(size: 14, weight: .medium))
            .foregroundStyle(filled ? Color.black : Color.white.opacity(enabled ? 0.92 : 0.35))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background {
                if filled {
                    shape.fill(LinearGradient(colors: [Color.commandAccent.mix(with: .white, by: lit ? 0.22 : 0.12), Color.commandAccent],
                                              startPoint: .top, endPoint: .bottom))
                        .shadow(color: Color.commandAccent.opacity(lit ? 0.45 : 0.25), radius: lit ? 14 : 8, y: 2)
                } else {
                    shape.fill(Color.white.opacity(configuration.isPressed ? 0.12 : lit ? 0.08 : 0.035))
                }
            }
            .overlay {
                shape.strokeBorder(filled ? Color.white.opacity(0.35) : Color.white.opacity(lit ? 0.26 : 0.14), lineWidth: filled ? 0.5 : 1)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(shape)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: lit)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Tarjeta navegable: se eleva un poco y su borde toma el acento al pasar el cursor.
struct HoverCardStyle: ButtonStyle {
    var radius: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return configuration.label
            .overlay(shape.strokeBorder(Color.commandAccent.opacity(hovered ? 0.5 : 0), lineWidth: 1))
            .shadow(color: Color.commandAccent.opacity(hovered ? 0.16 : 0), radius: 18, y: 6)
            .offset(y: hovered && !reduceMotion ? -2 : 0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(shape)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: hovered)
    }
}
