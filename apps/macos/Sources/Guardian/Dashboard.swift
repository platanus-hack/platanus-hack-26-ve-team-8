import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case live = "En vivo", overview = "Resumen", observations = "Observaciones", investigations = "Investigaciones"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .live: "dot.radiowaves.left.and.right"
        case .overview: "square.grid.2x2"
        case .observations: "waveform.path.ecg"
        case .investigations: "text.magnifyingglass"
        }
    }
    var subtitle: String {
        switch self {
        case .live: "Mira a Claude defender este Mac en tiempo real."
        case .overview: "Primero la evidencia. Nada cambia sin tu aprobación."
        case .observations: "Evidencia local registrada, tratada como no confiable."
        case .investigations: "Hipótesis, contraevidencia y propuestas."
        }
    }
}

struct Dashboard: View {
    @Bindable var model: GuardianModel
    @State private var selection: Page? = .live
    @State private var filter = ""
    @State private var kindFilter: String?
    @Environment(\.scenePhase) private var scenePhase
    private var page: Page { selection ?? .overview }
    private let suggestions = ["Explica las escuchas de red abiertas", "Revisa mis LaunchAgents"]

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error = model.error { errorBanner(error) }
                    if model.needsSetup { onboarding }
                    if model.status == nil && (page != .overview || model.needsSetup) {
                        Text("Agente desconectado. Conectar inicia un agente en primer plano si hace falta. La evidencia cargada antes puede seguir abajo.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    switch page {
                    case .live: LiveView(model: model) { selection = .investigations }
                    case .overview: overview
                    case .observations: observationList
                    case .investigations: investigationList
                    }
                }
                .padding(28)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity)
                .animation(.snappy, value: model.error)
                .animation(.snappy, value: model.needsSetup)
            }
            .background(Color.canvas)
            .navigationTitle(page.rawValue)
            .navigationSubtitle(page.subtitle)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.busy || model.investigating { ProgressView().controlSize(.small) }
                    Button("Tomar instantánea local", systemImage: "camera.viewfinder") { Task { await model.perform("scan") } }
                        .help("Tomar una instantánea local de solo lectura").disabled(model.busy || model.status == nil)
                    Button("Actualizar", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                        .help("Actualizar los datos registrados del agente").disabled(model.busy)
                }
            }
        }
        .tint(.primary)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.restoreOnStartup()
            await model.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard !Task.isCancelled else { return }
                await model.refresh()
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(Page.allCases) { page in
                Label(page.rawValue, systemImage: page.symbol)
                    .badge(page == .observations ? model.observations.count : page == .investigations ? model.investigations.count : 0)
                    .tag(page)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                BrandMark(size: 22)
                Text("Arkangel").font(.headline)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            let state = connection
            HStack(spacing: 8) {
                StatusDot(color: state.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title).font(.callout.weight(.medium))
                    Text(model.status.map { es($0.provider) } ?? "Ningún agente accesible")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220)
    }

    private var connection: (title: String, detail: String, color: Color) {
        guard let status = model.status else {
            if model.restoringStartup { return ("Reconectando…", "Restaurando tu conexión guardada.", .secondary) }
            return ("Agente desconectado", "Conectar inicia un agente en primer plano si hace falta. La evidencia cargada antes puede seguir visible.", .secondary)
        }
        if status.onboarding_required == true {
            return ("Configuración necesaria", "Añade tu clave de API de Anthropic para activar las investigaciones.", .warning)
        }
        return status.monitoring
            ? ("Monitoreo activo", "Se están registrando instantáneas periódicas de solo lectura.", .success)
            : ("Monitoreo en pausa", "Las instantáneas están en pausa. La evidencia registrada sigue disponible para revisar.", .warning)
    }

    // MARK: Shared pieces

    private func errorBanner(_ message: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.danger)
            Text(message).font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.error = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Descartar")
        }
        .padding(12)
        .background(Color.danger.opacity(0.06), in: shape)
        .overlay(shape.strokeBorder(Color.danger.opacity(0.3)))
        .transition(.opacity)
    }

    private func section<Content: View>(_ title: String, _ detail: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
            }
            content()
        }
    }

    private func subsection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Onboarding

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 16) {
            BrandMark(size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text("Conecta tu investigador").font(.title2.weight(.semibold))
                Text("Anthropic · Claude Haiku 5.5").font(.callout).foregroundStyle(.secondary)
            }
            Text("Añade tu clave de API de Anthropic para activar las investigaciones. El agente valida el modelo antes de conectar.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Clave de API de Anthropic", text: $model.apiKey, prompt: Text("Clave de API de Anthropic (déjala vacía para usar la guardada)"))
                .textFieldStyle(.plain).font(.system(.body, design: .monospaced))
                .inputField()
                .disabled(model.busy)
            VStack(alignment: .leading, spacing: 8) {
                assurance("lock", "Tu clave se guarda en el Llavero de macOS tras validarse. Una clave guardada nunca se muestra.")
                assurance("hand.raised", "El monitoreo recolecta evidencia local. Las investigaciones con el modelo solo se ejecutan cuando las pides.")
                assurance("power", "Conectar puede iniciar el agente de Python de Arkangel en primer plano. Al salir se detiene el agente iniciado por esta app; un agente externo sigue activo.")
            }
            Toggle("Permito enviar a Anthropic metadatos minimizados de la telemetría local y entiendo que las investigaciones generan cargos de API.", isOn: $model.cloudConsent)
                .toggleStyle(.checkbox).fixedSize(horizontal: false, vertical: true)
            Hairline()
            HStack(spacing: 8) {
                if model.setupVisible && model.status?.onboarding_required == false {
                    Button("Cerrar configuración") { model.setupVisible = false; model.apiKey = "" }
                        .buttonStyle(ArkButton(prominent: false))
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Conectar") { Task { await model.connect() } }
                    .buttonStyle(ArkButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || !model.cloudConsent)
            }
        }
        .card(padding: 24)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    private func assurance(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).frame(width: 16)
        }
        .font(.callout).foregroundStyle(.secondary)
    }

    // MARK: Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.status != nil || !model.needsSetup { hero }
            AnatomyView(state: model.status.map { status in
                AnatomyState(connected: true, monitoring: status.monitoring, observations: status.observation_count,
                             investigating: model.investigating, steps: model.investigations.first?.steps.count ?? 0,
                             findings: model.investigations.count)
            }).frame(height: 380)
            if let status = model.status {
                HStack(spacing: 12) {
                    metric("Observaciones registradas", status.observation_count.formatted())
                    metric("Investigaciones", model.investigations.count.formatted())
                    metric("Proveedor del modelo", es(status.provider))
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            investigatorInput
            if let status = model.status {
                exposure(status)
                section("Cobertura de recolección", "Lo que la última instantánea pudo y no pudo ver.") {
                    VStack(spacing: 0) {
                        if status.coverage.isEmpty {
                            Text("No se informó cobertura.").foregroundStyle(.secondary).padding(14)
                        }
                        ForEach(Array(status.coverage.enumerated()), id: \.offset) { index, item in
                            if index > 0 { Hairline() }
                            HStack(spacing: 12) {
                                Image(systemName: evidenceSymbol(item.source)).foregroundStyle(.secondary).frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(humanize(item.source))
                                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 12)
                                Pill(item.status)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                        }
                    }
                    .card(padding: 0)
                }
            }
            Text("La telemetría local es evidencia no confiable. La falta de cobertura o de hallazgos no demuestra que este Mac sea seguro. Arkangel solo bloquea puertos o activa el firewall después de que lo apruebes en el aviso de administrador de macOS.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func exposure(_ status: AgentStatus) -> some View {
        section("Exposición de red", "Puertos que otros dispositivos pueden alcanzar. Un bloqueo descarta sus conexiones nuevas; este Mac puede seguir usando el puerto hasta que lo desbloquees o reinicies.") {
            VStack(spacing: 0) {
                if let firewall = status.firewall {
                    let protected = firewall.firewall_enabled && firewall.stealth_mode
                    HStack(spacing: 12) {
                        Image(systemName: protected ? "checkmark.shield" : "exclamationmark.shield").foregroundStyle(.secondary).frame(width: 16)
                        Text("Firewall \(firewall.firewall_enabled ? "activado" : "desactivado") · modo sigiloso \(firewall.stealth_mode ? "activado" : "desactivado")")
                        Spacer(minLength: 12)
                        if !protected {
                            Button("Activar firewall y modo sigiloso") { Task { await model.defend("enable_firewall") } }
                                .buttonStyle(ArkButton(prominent: false))
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                let exposed = status.exposed ?? []
                if exposed.isEmpty {
                    Hairline()
                    Text("No se vieron escuchas accesibles desde otros dispositivos.").foregroundStyle(.secondary).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(exposed) { item in
                    Hairline()
                    HStack(spacing: 12) {
                        Image(systemName: "network").foregroundStyle(.secondary).frame(width: 16)
                        Text("Puerto \(item.port)").fontWeight(.medium).monospacedDigit()
                        Text("\(item.executable) · \(item.bind_scope == "any" ? "todas las interfaces" : "una interfaz")").foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        if item.blocked { Pill("Bloqueado", .success) }
                        Button(item.blocked ? "Desbloquear" : "Bloquear desde la red") {
                            Task { await model.defend(item.blocked ? "unblock_port" : "block_port", port: item.port) }
                        }
                        .buttonStyle(ArkButton(prominent: !item.blocked))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                ForEach((status.blocked_ports ?? []).filter { port in !exposed.contains { $0.port == port } }, id: \.self) { port in
                    Hairline()
                    HStack(spacing: 12) {
                        Image(systemName: "network.slash").foregroundStyle(.secondary).frame(width: 16)
                        Text("Puerto \(port) bloqueado · sin escucha ahora").foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Button("Desbloquear") { Task { await model.defend("unblock_port", port: port) } }
                            .buttonStyle(ArkButton(prominent: false))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
            .card(padding: 0)
            .disabled(model.busy)
        }
    }

    private var hero: some View {
        let state = connection
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StatusDot(color: state.color)
                    Text(state.title).font(.title3.weight(.semibold))
                }
                Text(state.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let status = model.status {
                    Text(status.last_scan.map { "Última instantánea \(relativeTime($0))" } ?? "Aún no se ha tomado ninguna instantánea")
                        .font(.caption).foregroundStyle(.tertiary)
                        .help(status.last_scan.map(fullTime) ?? "")
                }
            }
            Spacer(minLength: 12)
            if let status = model.status {
                HStack(spacing: 8) {
                    Button(status.monitoring ? "Pausar monitoreo" : "Activar monitoreo") { Task { await model.perform("monitoring") } }
                        .buttonStyle(ArkButton(prominent: false))
                    Button("Tomar instantánea") { Task { await model.perform("scan") } }
                        .buttonStyle(ArkButton())
                }
                .disabled(model.busy)
            }
        }
        .card(padding: 20)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .card()
        .animation(.snappy, value: value)
    }

    private var investigatorInput: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pregunta al investigador").font(.headline)
                Text("Usa la evidencia local registrada y el proveedor de modelo configurado en el agente.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            TextField("¿Qué debería revisar Arkangel? (opcional)", text: $model.question, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(2...5)
                .inputField()
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) { model.question = suggestion }
                        .buttonStyle(ArkButton(prominent: false))
                }
                Spacer(minLength: 12)
                Button("Investigar") {
                    selection = .investigations
                    Task { await model.investigate() }
                }
                .buttonStyle(ArkButton())
                .disabled(model.busy || model.investigating || model.status == nil || model.status?.onboarding_required == true)
            }
        }
        .card()
    }

    // MARK: Observations

    private var observationList: some View {
        let kinds = Set(model.observations.map(\.kind)).sorted()
        let visible = model.observations.filter { item in
            (kindFilter == nil || item.kind == kindFilter)
                && (filter.isEmpty || [item.summary, item.entity, item.kind, item.source, item.id].contains { $0.localizedCaseInsensitiveContains(filter) })
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("Tipo", selection: $kindFilter) {
                    Text("Todos").tag(String?.none)
                    ForEach(kinds, id: \.self) { Text(humanize($0)).tag(String?.some($0)) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filtrar evidencia", text: $filter).textFieldStyle(.plain)
                    if !filter.isEmpty {
                        Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .frame(width: 240)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.hairline))
            }
            Text("\(visible.count) de \(model.observations.count) observaciones cargadas")
                .font(.caption).foregroundStyle(.secondary)
            if model.observations.isEmpty {
                ContentUnavailableView("No hay observaciones cargadas", systemImage: "waveform.path.ecg", description: Text("Toma una instantánea local para recolectar evidencia."))
                    .padding(.top, 30)
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: filter).padding(.top, 30)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Hairline() }
                        observationRow(item)
                    }
                }
                .card(padding: 0)
            }
        }
    }

    private func observationRow(_ item: AgentObservation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: evidenceSymbol(item.kind)).foregroundStyle(.secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.summary)
                    Text(item.entity).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Text(relativeTime(item.timestamp)).font(.caption).foregroundStyle(.tertiary)
                    .help(fullTime(item.timestamp))
            }
            DisclosureGroup("Metadatos registrados") {
                VStack(alignment: .leading, spacing: 8) {
                    if !item.attributes.isEmpty {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                            ForEach(item.attributes.keys.sorted(), id: \.self) { key in
                                GridRow {
                                    Text(key).foregroundStyle(.secondary)
                                    Text(item.attributes[key]?.display ?? "")
                                }
                            }
                        }
                    }
                    Text("\(es(item.source)) · Evidencia \(item.id)").foregroundStyle(.tertiary)
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.canvas, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.top, 4)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.leading, 26)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .textSelection(.enabled)
    }

    // MARK: Investigations

    private var investigationList: some View {
        VStack(alignment: .leading, spacing: 16) {
            investigatorInput
            if model.investigating {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Investigando la evidencia registrada. Puede tardar hasta dos minutos.")
                        .foregroundStyle(.secondary)
                }
                .card()
                .transition(.opacity)
            }
            if model.investigations.isEmpty && !model.investigating {
                ContentUnavailableView("No hay investigaciones cargadas", systemImage: "text.magnifyingglass", description: Text("Ejecuta una investigación para revisar hipótesis y referencias de evidencia."))
                    .padding(.top, 30)
            }
            ForEach(model.investigations) { investigationCard($0) }
        }
        .animation(.snappy, value: model.investigating)
    }

    private func investigationCard(_ finding: Investigation) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Pill(finding.status)
                    Text(relativeTime(finding.created_at)).font(.caption).foregroundStyle(.tertiary)
                        .help(fullTime(finding.created_at))
                }
                Text(finding.title).font(.title3.weight(.semibold))
                Text(finding.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !finding.hypotheses.isEmpty {
                subsection("Hipótesis") {
                    ForEach(Array(finding.hypotheses.enumerated()), id: \.offset) { _, hypothesis in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(hypothesis.statement).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Pill(hypothesis.status)
                            }
                            if !hypothesis.counterevidence.isEmpty {
                                Text("\(Text("Contraevidencia").foregroundStyle(.primary))  \(hypothesis.counterevidence)")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            evidenceLinks(hypothesis.evidence_ids)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.canvas, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.hairline))
                    }
                }
            }
            if !finding.steps.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(finding.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(String(format: "%02d", index + 1))
                                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(es(step.tool)).font(.system(.callout, design: .monospaced))
                                    Text(step.summary).font(.callout).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Pasos de la investigación · \(finding.steps.count)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            if !finding.proposed_actions.isEmpty {
                subsection("Acciones propuestas") {
                    ForEach(Array(finding.proposed_actions.enumerated()), id: \.offset) { _, action in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Propuesta · \(action.title)").fontWeight(.medium)
                                Text(action.description).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            ProposalStatus(action: action, model: model)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                }
            }
            if !finding.limitations.isEmpty {
                subsection("Limitaciones") {
                    ForEach(Array(finding.limitations.enumerated()), id: \.offset) { _, limitation in
                        Text("– \(limitation)").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .card(padding: 20)
        .textSelection(.enabled)
    }

    /// Las referencias de evidencia saltan a la observación correspondiente en la línea de tiempo.
    private func evidenceLinks(_ ids: [String]) -> some View {
        HStack(spacing: 6) {
            if ids.isEmpty {
                Text("Sin evidencia citada").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(ids.prefix(4), id: \.self) { id in
                Button(String(id.prefix(8))) {
                    filter = id
                    kindFilter = nil
                    selection = .observations
                }
                .buttonStyle(.plain)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.hairline))
                .help("Mostrar evidencia \(id)")
            }
            if ids.count > 4 {
                Text("+\(ids.count - 4) más").font(.caption).foregroundStyle(.tertiary)
                    .help(ids.dropFirst(4).joined(separator: "\n"))
            }
        }
    }
}

// MARK: Components

/// Botón de aprobación para una propuesta con una acción de defensa tipada; si no, "No aplicada".
struct ProposalStatus: View {
    let action: ProposedAction
    @Bindable var model: GuardianModel
    var body: some View {
        if let defense = action.action {
            if defense.type == "block_port", let port = defense.port, model.status?.blocked_ports?.contains(port) == true {
                Pill("Aplicada", .success)
            } else {
                Button(defense.type == "block_port" ? "Bloquear puerto \(defense.port ?? 0)" : "Activar firewall") {
                    Task { await model.defend(defense.type, port: defense.port) }
                }
                .buttonStyle(ArkButton())
                .disabled(model.busy)
                .help("Pide tu contraseña de administrador de macOS antes de cambiar nada.")
            }
        } else {
            Pill("No aplicada", .secondary)
        }
    }
}

struct BrandMark: View {
    let size: CGFloat
    var body: some View {
        Image(systemName: "shield.lefthalf.filled")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(Color.canvas)
            .frame(width: size, height: size)
            .background(Color.primary, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Color.hairline).frame(height: 1) }
}

struct Pill: View {
    let text: String
    let color: Color
    init(_ text: String, _ color: Color? = nil) {
        self.text = text
        self.color = color ?? toneColor(text)
    }
    var body: some View {
        HStack(spacing: 5) {
            StatusDot(color: color)
            Text(humanize(text))
        }
        .font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(Color.hairline))
    }
}

/// Botón monocromo: color sólido cuando es destacado y con contorno en los demás casos.
struct ArkButton: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return configuration.label
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .foregroundStyle(prominent ? Color.canvas : Color.primary)
            .background(prominent ? Color.primary : Color.surface, in: shape)
            .overlay(shape.strokeBorder(prominent ? Color.clear : Color.hairline))
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

// MARK: Palette

/// Neutros al estilo de Vercel; el color solo aparece en los puntos de estado.
extension Color {
    static let canvas = dynamic(light: 0xFAFAFA, dark: 0x000000)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x0A0A0A)
    static let hairline = dynamic(light: 0xEAEAEA, dark: 0x262626)
    static let success = Color(nsColor: rgb(0x30A46C))
    static let warning = Color(nsColor: rgb(0xF5A623))
    static let danger = Color(nsColor: rgb(0xE5484D))
    static let info = Color(nsColor: rgb(0x0070F3))

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }
}

private func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

extension View {
    func card(padding: CGFloat = 16) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface, in: shape)
            .overlay(shape.strokeBorder(Color.hairline))
    }

    func inputField() -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return self.padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.surface, in: shape)
            .overlay(shape.strokeBorder(Color.hairline))
    }
}

// MARK: Formatting

func humanize(_ text: String) -> String {
    let label = es(text)
    guard label == text else { return label }
    let spaced = text.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "tcp", with: "TCP")
    return spaced.prefix(1).uppercased() + spaced.dropFirst()
}

/// Sin hallazgos es azul a propósito, no verde: nunca implica seguridad.
func toneColor(_ status: String) -> Color {
    switch status {
    case "available": .success
    case "partial", "needs_review", "supported": .warning
    case "denied", "error": .danger
    case "no_finding": .info
    default: .secondary
    }
}

func evidenceSymbol(_ name: String) -> String {
    switch name {
    case "process", "processes": "cpu"
    case "tcp_listener", "tcp_listeners": "network"
    case "launch_agent", "user_launch_agents": "gearshape.2"
    case "firewall", "application_firewall": "flame"
    case "osquery": "magnifyingglass"
    case "evidence_window": "clock.arrow.circlepath"
    case "service": "server.rack"
    default: "circle.dotted"
    }
}

/// Python emite fracciones de microsegundos, que el analizador ISO8601 rechaza.
private func parseDate(_ text: String) -> Date? {
    try? Date(text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression), strategy: .iso8601)
}

func relativeTime(_ text: String) -> String {
    parseDate(text)?.formatted(.relative(presentation: .named)) ?? text
}

func fullTime(_ text: String) -> String {
    parseDate(text)?.formatted(date: .abbreviated, time: .standard) ?? text
}
