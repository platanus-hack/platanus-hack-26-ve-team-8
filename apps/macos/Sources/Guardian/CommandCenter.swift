import SwiftUI

/// A single workspace backed by recorded evidence, with details opened on demand.
struct CommandCenter: View {
    @Bindable var model: GuardianModel
    let open: (Page) -> Void
    let configure: () -> Void
    let protect: () -> Void
    let inspect: (AgentObservation) -> Void
    @FocusState private var questionFocused: Bool
    @State private var previousAlertIDs: Set<String>?
    @State private var newAlert: AgentAlert?
    @State private var orbAlert: AgentAlert?
    @State private var selectedObservation: AgentObservation?
    private var active: Bool { model.investigating || model.progress?.active == true }
    private var pending: [AgentAlert] { model.alerts.filter { !$0.acknowledged } }

    var body: some View {
        mainLayout
            .environment(\.colorScheme, .dark)
            .tint(Color.commandAccent)
            .onChange(of: loadedAlertIDs, initial: true) { _, ids in receiveAlerts(ids) }
            .onChange(of: pendingAlertIDs) { _, ids in dismissReviewedNotice(ids) }
            .sheet(item: $selectedObservation) { observation in nodeInspector(observation) }
    }

    private var pendingAlertIDs: [String] { pending.map(\.id) }

    private func receiveAlerts(_ ids: [String]?) {
        guard let ids else { return }
        let current = Set(ids)
        if let previous = previousAlertIDs,
           let fresh = model.alerts.first(where: { !previous.contains($0.id) && !$0.acknowledged }) {
            newAlert = fresh
            orbAlert = fresh
        }
        previousAlertIDs = current
    }

    private func dismissReviewedNotice(_ ids: [String]) {
        if let notice = newAlert, !ids.contains(notice.id) { newAlert = nil }
        if let notice = orbAlert, !ids.contains(notice.id) { orbAlert = nil }
    }

    private var mainLayout: some View {
        GeometryReader { geometry in
            let panelHeight = max(530, min(720, geometry.size.height - 280))
            VStack(spacing: 0) {
                header
                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                if let alert = newAlert, !alert.acknowledged { alertNotice(alert).padding(.horizontal, 20).padding(.top, 12) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let error = model.error { errorNotice(error) }
                        if geometry.size.width >= 1120 {
                            HStack(alignment: .top, spacing: 26) {
                                protection.frame(minHeight: panelHeight, alignment: .topLeading).modifier(EvidenceGlassSurface(radius: 18, accent: .commandAccent)).frame(width: 245)
                                orbPanel(height: panelHeight).frame(maxWidth: .infinity)
                                alerts.frame(minHeight: panelHeight, alignment: .topLeading).modifier(EvidenceGlassSurface(radius: 18, accent: .commandAccent)).frame(width: 285)
                            }
                        } else if geometry.size.width >= 900 {
                            HStack(alignment: .top, spacing: 20) {
                                VStack(spacing: 20) {
                                    protection.modifier(EvidenceGlassSurface(radius: 18, accent: .commandAccent))
                                    alerts.modifier(EvidenceGlassSurface(radius: 18, accent: .commandAccent))
                                }.frame(width: 270)
                                orbPanel(height: panelHeight).frame(maxWidth: .infinity)
                            }
                        } else {
                            orbPanel(height: 510)
                            protection.modifier(EvidenceGlassSurface(radius: 18, accent: .commandAccent))
                            alerts.modifier(EvidenceGlassSurface(radius: 18, accent: .commandAccent))
                        }
                        composer
                        Label("La cobertura puede ser parcial. Una señal no confirma un ataque y la ausencia de señales no garantiza seguridad.", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(Color.commandSecondary)
                    }.padding(26)
                }
            }
            .background { CommandAtmosphere() }
        }
    }

    private func nodeInspector(_ observation: AgentObservation) -> some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Evidencia del nodo").font(.headline)
                    Spacer()
                    Button("Cerrar", systemImage: "xmark") { selectedObservation = nil }.labelStyle(.iconOnly)
                }
                Text(observation.summary).font(.title3)
                Text(observation.entity).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text(fullTime(observation.timestamp)).font(.caption).foregroundStyle(Color.commandSecondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(observation.attributes.keys.sorted(), id: \.self) { key in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(key).font(.caption).foregroundStyle(Color.commandSecondary)
                                Text(observation.attributes[key]?.display ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Es evidencia registrada, no una conexión en tiempo real.").font(.caption).foregroundStyle(Color.commandSecondary)
                HStack(spacing: 12) {
                    if model.observations.contains(where: { $0.id == observation.id }) {
                        Button("Abrir registro") { selectedObservation = nil; inspect(observation) }
                    }
                    Button("Revisar señales") { selectedObservation = nil; open(.alerts) }
                    Button("Protección") { selectedObservation = nil; protect() }
                }.buttonStyle(CommandButton(prominent: false))
            }.padding(24).frame(width: 520, height: 440).background { CommandAtmosphere() }
                .environment(\.colorScheme, .dark)
    }

    private var loadedAlertIDs: [String]? {
        guard model.alertsLoaded else { return nil }
        return model.alerts.map(\.id)
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { brand; statusLine; Spacer(); headerActions }
            VStack(alignment: .leading, spacing: 12) {
                HStack { brand; Spacer(); headerActions }
                statusLine
            }
        }.padding(.horizontal, 26).padding(.vertical, 18)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.max").font(.system(size: 24, weight: .light)).foregroundStyle(Color.commandAccent)
            Text("ARKANGEL").font(.system(size: 16, weight: .semibold)).tracking(-0.5)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            StatusDot(color: model.status == nil ? .secondary : .commandAccent)
            Text(model.status == nil ? "Agente sin conexión" : model.status?.monitoring == true ? "Vigilando este Mac" : "Vigilancia en pausa")
            if let status = model.status { Text("· \(status.observation_count.formatted()) observaciones").foregroundStyle(Color.commandSecondary) }
        }.font(.caption).lineLimit(1)
    }

    private var headerActions: some View {
        HStack(spacing: 12) {
            Text(active ? "INVESTIGANDO" : "SOLO LECTURA")
                .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Color.commandAccent)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .overlay(Capsule().strokeBorder(Color.commandAccent.opacity(0.35)))
            Menu {
                Button("Observaciones") { open(.observations) }
                Button("Señales y automatización") { open(.alerts) }
                Button("Alertas principales") { open(.investigations) }
                Button("Estado y protección") { open(.overview) }
                Divider()
                Button("Configurar investigador", action: configure)
                Button("Actualizar") { Task { await model.refresh() } }
            } label: { Image(systemName: "ellipsis.circle").font(.title3) }
            .menuStyle(.borderlessButton).fixedSize().help("Evidencia, informes y configuración")
        }
    }

    private var protection: some View {
        VStack(alignment: .leading, spacing: 20) {
            eyebrow("EXPOSICIÓN OBSERVADA")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.status.map { String(($0.exposed ?? []).filter { !$0.blocked }.count) } ?? "—")
                    .font(.system(size: 76, weight: .medium)).monospacedDigit().tracking(-5)
                Text("puertos").font(.title3).foregroundStyle(Color.commandAccent)
            }
            Text(model.status == nil ? "Conecta el agente para observar la exposición local." : "Escuchas observadas accesibles desde otros dispositivos y sin bloqueo registrado.")
                .font(.callout).foregroundStyle(Color.commandSecondary).fixedSize(horizontal: false, vertical: true)
            if let status = model.status {
                protectionRow("Firewall", value: status.firewall.map { $0.firewall_enabled ? "Activado" : "Desactivado" } ?? "Sin datos")
                protectionRow("Modo sigiloso", value: status.firewall.map { $0.stealth_mode ? "Activado" : "Desactivado" } ?? "Sin datos")
                protectionRow("Cobertura", value: "\(status.coverage.filter { $0.status == "available" || $0.status == "ok" }.count) de \(status.coverage.count) fuentes")
                protectionRow("Bloqueos registrados", value: "\((status.blocked_ports ?? []).count)")
                if let scan = status.last_scan { Text("Instantánea \(relativeTime(scan))").font(.caption).foregroundStyle(Color.commandSecondary).help(fullTime(scan)) }
                HStack(spacing: 10) {
                    Button(status.monitoring ? "Pausar" : "Reanudar") { Task { await model.perform("monitoring") } }
                    Button("Instantánea") { Task { await model.perform("scan") } }
                }.buttonStyle(CommandButton(prominent: false)).disabled(model.busy)
            } else {
                Button("Iniciar vigilancia local") { Task { await model.startLocalMonitoring() } }
                    .buttonStyle(CommandButton()).disabled(model.busy)
            }
            Button(action: protect) {
                HStack { VStack(alignment: .leading, spacing: 4) {
                    Text("Revisar protección").fontWeight(.semibold)
                    Text("Puertos, firewall y cobertura").font(.caption)
                }; Spacer(); Image(systemName: "arrow.right") }
            }.buttonStyle(CommandButton())
            Text("Cada acción de defensa requiere su propia aprobación de administrador de macOS.")
                .font(.caption).foregroundStyle(Color.commandSecondary)
        }
        .padding(18)
    }

    private func protectionRow(_ title: String, value: String) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption)
                Spacer()
                Text(value).font(.system(.caption, design: .monospaced)).foregroundStyle(Color.commandSecondary)
            }
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
        }
    }

    private func orbPanel(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { eyebrow("ESTE MAC · EVIDENCIA LOCAL"); Spacer(); Text("\(orbState.nodes.count) nodos").font(.caption).foregroundStyle(Color.commandSecondary) }
            DefenseSceneView(state: orbState, onSelect: { key in
                selectedObservation = model.observations.first { $0.key == key }
            }).frame(height: max(230, height - 300))
                .overlay(alignment: .bottomTrailing) {
                    if let alert = orbAlert {
                        orbSignalPopup(alert).frame(maxWidth: 300).padding(12)
                    }
                }
                .accessibilityLabel("Orbe de evidencia registrada. Usa Registro de observaciones para inspeccionar los nodos con teclado.")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { orbLinks }
                VStack(alignment: .leading, spacing: 10) { orbLinks }
            }.buttonStyle(CommandButton(prominent: false))
            Text("Arrastra para girar · Haz clic en un punto para inspeccionar evidencia")
                .font(.caption2).foregroundStyle(Color.commandSecondary)
            HStack(spacing: 14) {
                Button("Registro de observaciones") { open(.observations) }
            Button("Renovar referencia") { model.setBaseline() }.disabled(model.observations.isEmpty)
                Button("Alertas principales") { open(.investigations) }
            }.buttonStyle(.plain).font(.caption).foregroundStyle(Color.commandAccent)
            if let report = model.investigations.first, !active {
                Button { open(.investigations) } label: {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 15)).foregroundStyle(Color.commandAccent)
                            .frame(width: 34, height: 34).background(Color.commandAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("ÚLTIMO INFORME · \(es(report.status))").font(.caption2).foregroundStyle(Color.commandAccent)
                            Text(report.title).font(.callout.weight(.medium)).multilineTextAlignment(.leading).lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 4) {
                            Text("Ver alertas")
                            Image(systemName: "arrow.up.right")
                        }.font(.caption.weight(.medium)).foregroundStyle(Color.commandAccent).fixedSize()
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        .modifier(EvidenceGlassSurface(radius: 14, accent: .commandAccent))
                }.buttonStyle(ReportLinkStyle())
                    .help("Abrir las alertas principales y su informe")
            }
        }
        .padding(18)
        .frame(minHeight: height, alignment: .topLeading)
        .modifier(EvidenceGlassSurface(radius: 18, accent: .commandAccent))
    }

    private func orbSignalPopup(_ alert: AgentAlert) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Señal por revisar", systemImage: "exclamationmark.shield").font(.caption.weight(.semibold)).foregroundStyle(Color.warning)
                Spacer()
                Button("Cerrar aviso", systemImage: "xmark") { orbAlert = nil }.labelStyle(.iconOnly).buttonStyle(.plain)
            }
            Text(alert.reason).font(.callout.weight(.medium)).lineLimit(2)
            Text(relativeTime(alert.created_at)).font(.caption2).foregroundStyle(Color.commandSecondary)
            HStack(spacing: 12) {
                Button("Ver evidencia") { selectedObservation = alert.signal }.buttonStyle(CommandButton())
                Button("Revisar señales") { open(.alerts) }.buttonStyle(.plain).font(.caption).foregroundStyle(Color.commandAccent)
            }
        }
        .padding(16)
        .modifier(EvidenceGlassSurface(radius: 16, accent: .warning))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.warning.opacity(0.35)))
    }

    @ViewBuilder private var orbLinks: some View {
        Button("Procesos · \(uniqueCount("process"))") { open(.observations) }
        Button("LaunchAgents · \(uniqueCount("launch_agent"))") { open(.observations) }
        Button("Red · \(model.status?.exposed?.count ?? 0)", action: protect)
    }

    private func uniqueCount(_ kind: String) -> Int { Set(model.observations.filter { $0.kind == kind }.map(\.key)).count }

    private var alerts: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { eyebrow("CAMBIOS PARA REVISAR"); Spacer(); Text("\(pending.count)").font(.caption).foregroundStyle(Color.commandSecondary) }
            if pending.isEmpty {
                Text("Sin señales pendientes").font(.title3.weight(.medium))
                Text("Los cambios registrados aparecerán aquí. No es una garantía de seguridad.").font(.callout).foregroundStyle(Color.commandSecondary)
            }
            ForEach(pending.prefix(3)) { alert in
                VStack(alignment: .leading, spacing: 10) {
                        HStack { StatusDot(color: .warning); Text("REQUIERE REVISIÓN").font(.system(size: 10, weight: .semibold)); Spacer() }
                            .foregroundStyle(Color.warning)
                        Text(alert.reason).font(.callout.weight(.medium)).multilineTextAlignment(.leading)
                        Text(relativeTime(alert.created_at)).font(.caption).foregroundStyle(Color.commandSecondary)
                        Button("Ver evidencia", systemImage: "arrow.up.right") { selectedObservation = alert.signal }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(Color.commandAccent)
                        Button("Ver en el orbe", systemImage: "scope") { orbAlert = alert }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(Color.commandAccent)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.warning.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.warning.opacity(0.3)))
            }
            Button("Ver todas las señales", systemImage: "arrow.right") { open(.alerts) }.buttonStyle(.plain).font(.caption).foregroundStyle(Color.commandAccent)
            Divider().padding(.vertical, 4)
            eyebrow("ACTIVIDAD DEL INVESTIGADOR")
            if let progress = model.progress, !progress.steps.isEmpty {
                ForEach(Array(progress.steps.suffix(3).enumerated()), id: \.offset) { _, step in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(es(step.tool)).font(.system(.caption, design: .monospaced)).foregroundStyle(Color.commandAccent)
                        Text(step.summary).font(.caption).foregroundStyle(Color.commandSecondary).lineLimit(3)
                    }
                }
            } else {
                Text("Pide una investigación para seguir las consultas de evidencia aquí.").font(.caption).foregroundStyle(Color.commandSecondary)
            }
            Button("Abrir seguimiento completo") { open(.live) }.buttonStyle(.plain).font(.caption).foregroundStyle(Color.commandAccent)
        }
        .padding(18)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(Color.commandAccent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Investiga lo que ocurre en tu Mac").font(.callout.weight(.semibold))
                    Text(active ? "Consultando evidencia registrada…" : "Haz una pregunta. El agente consultará evidencia de solo lectura.")
                        .font(.caption).foregroundStyle(Color.commandSecondary)
                }
                Spacer(minLength: 0)
                Text("⌘ K").font(.system(.caption, design: .monospaced)).foregroundStyle(Color.commandSecondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) { questionField; sendQuestion }
                VStack(alignment: .leading, spacing: 12) { questionField; sendQuestion }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { suggestedQuestions }
                VStack(alignment: .leading, spacing: 10) { suggestedQuestions }
            }
        }.padding(20).modifier(EvidenceGlassSurface(radius: 18, accent: .commandAccent))
    }

    @ViewBuilder private var suggestedQuestions: some View {
        ForEach(["Explica las escuchas de red abiertas", "Revisa mis LaunchAgents"], id: \.self) { suggestion in
            Button(suggestion, systemImage: "arrow.turn.down.right") {
                model.question = suggestion
                questionFocused = true
            }
            .buttonStyle(CommandButton(prominent: false))
            .help("Usar esta pregunta; pulsa Investigar cuando quieras enviarla")
        }
    }

    private var questionField: some View {
        TextField("Por ejemplo: ¿qué puertos están accesibles desde la red?", text: $model.question, axis: .vertical)
            .textFieldStyle(.plain).font(.body).lineLimit(1...3).focused($questionFocused)
            .padding(14).frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(questionFocused ? Color.commandAccent.opacity(0.6) : Color.white.opacity(0.12)))
            .background { Button("") { questionFocused = true }.keyboardShortcut("k", modifiers: .command).hidden() }
    }

    @ViewBuilder private var sendQuestion: some View {
        if model.status?.onboarding_required == true {
            Button("Conectar investigador", action: configure).buttonStyle(CommandButton())
        } else {
            Button(active ? "Investigando…" : "Investigar", systemImage: "arrow.up.right") { Task { await model.investigate() } }
                .buttonStyle(CommandButton()).disabled(model.busy || active || model.status == nil)
        }
    }

    private func eyebrow(_ text: String) -> some View { Text(text).font(.system(size: 10, weight: .semibold)).tracking(1.8).foregroundStyle(Color.commandSecondary) }

    private func errorNotice(_ error: String) -> some View {
        HStack { Image(systemName: "exclamationmark.triangle"); Text(error).font(.callout); Spacer(); Button("Cerrar") { model.error = nil } }
            .padding(12).background(Color.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(Color.danger)
    }

    private func alertNotice(_ alert: AgentAlert) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bell.badge").foregroundStyle(Color.warning)
            VStack(alignment: .leading, spacing: 4) { Text("Nueva señal detectada").font(.callout.weight(.semibold)); Text(alert.reason).font(.caption) }
            Spacer()
            Button("Revisar") { newAlert = nil; open(.alerts) }.buttonStyle(CommandButton())
            Button("Descartar aviso", systemImage: "xmark") { newAlert = nil }.labelStyle(.iconOnly).buttonStyle(.plain)
        }.padding(14).background(Color.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Nueva señal detectada: \(alert.reason)")
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
        return DefenseState(nodes: nodes, investigating: active, alert: !pending.isEmpty)
    }
}

extension Color {
    static let commandSecondary = Color.white.opacity(0.72)
    static let commandAccent = Color(red: 0.88, green: 0.96, blue: 0.02)
}

/// Tarjeta navegable: resalta el borde al pasar el cursor y muestra la mano de enlace.
struct ReportLinkStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.commandAccent.opacity(hovering ? 0.55 : 0), lineWidth: 1))
            .background(Color.commandAccent.opacity(hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.snappy(duration: 0.15), value: hovering)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

struct CommandButton: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent && enabled ? Color.black : Color.white.opacity(enabled ? 0.9 : 0.35))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(prominent && enabled ? Color.commandAccent : Color.white.opacity(configuration.isPressed ? 0.1 : 0.025), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(prominent && enabled ? Color.clear : Color.white.opacity(0.15)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
