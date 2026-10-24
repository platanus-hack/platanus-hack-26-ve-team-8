import SwiftUI

/// Alertas persistentes y pasos de investigación; una alerta no confirma un compromiso.
struct LiveView: View {
    @Bindable var model: GuardianModel
    let openActivity: () -> Void
    let openStatus: () -> Void
    let openReport: () -> Void

    private var investigating: Bool { model.investigating || model.progress?.active == true }
    private var threats: [AgentAlert] { model.pendingAlerts }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            investigationComposer
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    orbPanel.frame(minWidth: 430, maxWidth: .infinity)
                    activityPanel.frame(width: 300)
                }
                VStack(spacing: 18) { orbPanel; activityPanel }
            }
            Label("El núcleo representa este Mac. Los puntos representan evidencia registrada, no conexiones en tiempo real. La ausencia de alertas no garantiza seguridad.", systemImage: "info.circle")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !investigating, let latest = model.investigations.first { verdictCard(latest) }
        }
    }

    private var investigationComposer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Tu espacio de investigación", systemImage: "viewfinder").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.investigatorAccent)
                    Text("¿Qué quieres entender de tu Mac?").font(.title3.weight(.semibold))
                }
                Spacer()
                Button("Alertas principales", systemImage: "exclamationmark.shield", action: openReport)
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.info)
            }
            if model.status?.onboarding_required == true {
                Text("Puedes vigilar localmente sin IA. Conecta Claude cuando quieras investigar la evidencia.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Conectar investigador") { model.setupVisible = true }.buttonStyle(ArkButton())
            } else {
                TextField("Por ejemplo: ¿qué servicios están escuchando en la red?", text: $model.question, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...3).inputField()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { investigationSuggestions }
                    VStack(alignment: .leading, spacing: 8) { investigationSuggestions }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                Text("Preguntas → evidencia de solo lectura → conclusiones para revisar")
            }.font(.system(size: 12)).foregroundStyle(.secondary)
            Hairline()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { monitoringActions; Spacer(minLength: 0); investigationAction }
                VStack(alignment: .leading, spacing: 12) { monitoringActions; investigationAction }
            }
        }.card(padding: 18)
    }

    @ViewBuilder private var investigationSuggestions: some View {
        ForEach(["Revisa las escuchas de red", "Explica los cambios recientes"], id: \.self) { question in
            Button(question) { model.question = question }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.info)
        }
    }

    @ViewBuilder private var monitoringActions: some View {
        if let status = model.status {
            Button(status.monitoring ? "Pausar vigilancia" : "Reanudar vigilancia", systemImage: status.monitoring ? "pause" : "play.fill") {
                Task { await model.perform("monitoring") }
            }.buttonStyle(ArkButton(prominent: false)).disabled(model.busy)
            Button("Tomar instantánea", systemImage: "camera.viewfinder") { Task { await model.perform("scan") } }
                .buttonStyle(ArkButton(prominent: false)).disabled(model.busy)
        }
    }

    private var investigationAction: some View {
        Button(investigating ? "Investigando…" : "Investigar", systemImage: "arrow.up") { Task { await model.investigate() } }
            .buttonStyle(ArkButton())
            .disabled(model.busy || investigating || model.status == nil || model.status?.onboarding_required == true)
    }

    private var orbPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Evidencia de este Mac", systemImage: "point.3.connected.trianglepath.dotted").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.investigatorAccent)
                    HStack(spacing: 8) {
                        StatusDot(color: headline.color)
                        Text(headline.title).font(.title3.weight(.semibold))
                    }
                    Text(headline.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("\(sceneState.nodes.count) nodos").font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.investigatorAccent)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color.investigatorAccent.opacity(0.08), in: Capsule())
            }.padding(20)
            DefenseSceneView(state: sceneState)
                .frame(height: 360)
                .accessibilityLabel("Mapa tridimensional de la evidencia registrada")
                .accessibilityValue("\(sceneState.nodes.count) nodos; \(threats.count) alertas pendientes")
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { liveActions }
                    VStack(alignment: .leading, spacing: 8) { liveActions }
                }
            }.padding(16)
                .background(Color.investigatorAccent.opacity(0.025))
        }
        .modifier(EvidenceGlassSurface(radius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private var activityPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            claudeCard
            detectionsCard
            HStack {
                Button("Ver alertas", action: openActivity)
                Spacer()
            }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.info)
        }
    }

    @ViewBuilder private var liveActions: some View {
        Button("Renovar referencia", systemImage: "arrow.triangle.2.circlepath") { model.setBaseline() }
            .buttonStyle(ArkButton(prominent: false))
            .disabled(model.observations.isEmpty)
            .help("Usar los procesos cargados como nueva referencia visual. No borra ni revisa las alertas.")
        Button("Red, protección y cobertura", systemImage: "shield.lefthalf.filled", action: openStatus)
            .buttonStyle(ArkButton(prominent: false))
    }

    private var headline: (title: String, detail: String, color: Color) {
        if investigating {
            return ("Investigación en curso", "Leyendo la evidencia registrada con herramientas de solo lectura.", .white)
        }
        guard let status = model.status else {
            return ("Agente desconectado", "Inicia la vigilancia local para registrar evidencia.", .secondary)
        }
        if !threats.isEmpty {
            return (threats.count == 1 ? "1 alerta pendiente de revisión" : "\(threats.count) alertas pendientes de revisión",
                    "Cambios de archivos, firewall o escuchas para revisar.", .danger)
        }
        return (status.monitoring ? "Vigilando este Mac" : "Vigilancia en pausa",
                status.monitoring ? "Registrando observaciones locales de solo lectura." : "La evidencia anterior sigue disponible.", status.monitoring ? .success : .warning)
    }

    // MARK: Cards

    private var detectionsCard: some View {
        let newProcesses = model.detections.filter { $0.kind == "process" }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Alertas para revisar").font(.headline)
                Spacer()
                if let date = model.baselineDate {
                    Text("desde las \(date.formatted(date: .omitted, time: .shortened))").font(.system(size: 13)).foregroundStyle(.tertiary)
                }
            }
            if threats.isEmpty {
                Text("No hay alertas pendientes en los datos cargados.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(threats.prefix(6).enumerated()), id: \.element.id) { index, alert in
                let copy = AlertCopy(alert)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)").font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Color.danger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(copy.title).fontWeight(.medium)
                        Text(alert.after.entity).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Text(relativeTime(alert.created_at)).font(.system(size: 13)).foregroundStyle(.tertiary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Alerta \(index + 1): \(copy.title), \(relativeTime(alert.created_at))")
                .transition(.opacity)
            }
            if threats.count > 6 {
                Text("+\(threats.count - 6) más").font(.system(size: 13)).foregroundStyle(.tertiary)
            }
            if newProcesses > 0 {
                Text("\(newProcesses) \(newProcesses == 1 ? "proceso nuevo" : "procesos nuevos") (incluye actividad normal)")
                    .font(.system(size: 13)).foregroundStyle(.tertiary)
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
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 10)
                    Label("Solo lectura · Sin acciones automáticas de defensa", systemImage: "lock.shield")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(steps.suffix(5).enumerated()), id: \.offset) { _, step in
                VStack(alignment: .leading, spacing: 6) {
                    Text(es(step.tool)).font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.canvas, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.hairline))
                    Text(step.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !steps.isEmpty && !investigating {
                Text("\(steps.count) \(steps.count == 1 ? "paso" : "pasos") de solo lectura · ningún comando ejecutado")
                    .font(.system(size: 13)).foregroundStyle(.tertiary)
            }
        }
        .animation(.snappy, value: steps.count)
        .card(padding: 18)
    }

    private func verdictCard(_ finding: Investigation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Pill(finding.status)
                Text(relativeTime(finding.created_at)).font(.system(size: 13)).foregroundStyle(.tertiary)
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
        let alertKeys = Set(threats.map(\.after.key))
        var seen = Set<String>()
        var processes = 0
        var nodes: [DefenseState.Node] = []
        for item in model.observations where seen.insert(item.key).inserted {
            if item.kind == "process" {
                // Keep a bounded view of recent processes; cited evidence remains visible.
                processes += 1
                if processes > 120 && !cited.contains(item.id) { continue }
            }
            let level: DefenseState.Level = alertKeys.contains(item.key) ? .threat : cited.contains(item.id) ? .cited
                : fresh.contains(item.key) ? .fresh : .normal
            nodes.append(.init(key: item.key, kind: item.kind, level: level))
        }
        // Same numbering as the list; alerts whose observation fell outside the loaded window still get a node.
        // This page has no defense handler, so markers offer no action button.
        return DefenseState(nodes: DefenseState.placing(threats, on: nodes) { _ in nil }, investigating: investigating,
                            alert: !threats.isEmpty, connected: model.status != nil && model.alertsLoaded,
                            monitoring: model.status?.monitoring ?? true)
    }
}
