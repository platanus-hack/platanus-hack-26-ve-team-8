import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case alerts = "Señales", live = "En vivo", overview = "Estado del Mac", observations = "Observaciones", investigations = "Alertas principales"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .alerts: "exclamationmark.shield"
        case .live: "dot.radiowaves.left.and.right"
        case .overview: "square.grid.2x2"
        case .observations: "waveform.path.ecg"
        case .investigations: "text.magnifyingglass"
        }
    }
    var section: Page {
        switch self {
        case .overview: .overview
        case .alerts, .observations: .alerts
        case .live, .investigations: .live
        }
    }
    var sectionTitle: String {
        switch section {
        case .overview: "Estado del Mac"
        case .alerts: "Actividad"
        default: "Investigador"
        }
    }
    var subtitle: String {
        switch self {
        case .alerts: "Entiende qué cambió en tu Mac y decide qué revisar."
        case .live: "Sigue los pasos del investigador y los cambios de este Mac."
        case .overview: "Lo que está pasando en tu Mac, en un solo lugar."
        case .observations: "Evidencia local registrada, tratada como no confiable."
        case .investigations: "Lo más importante de tu Mac y qué hacer."
        }
    }
}

private enum OverviewDetail: String, Identifiable {
    case network, coverage
    var id: String { rawValue }
}

struct Dashboard: View {
    @Bindable var model: GuardianModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var selection: Page?
    @State private var filter = ""
    @State private var kindFilter: String?
    @State private var localStartError: String?
    @State private var onlyUnreviewedAlerts = false
    @State private var overviewDetail: OverviewDetail?
    @State private var showProtection = false
    private var page: Page { selection ?? .live }
    private let suggestions = ["Explica las escuchas de red abiertas", "Revisa mis LaunchAgents"]

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                commandCenter
                .disabled(selection != nil)
                .accessibilityHidden(selection != nil)
                if selection != nil {
                    Color.black.opacity(0.65).ignoresSafeArea().onTapGesture { selection = nil }
                    detailPanel
                        .frame(width: min(page == .investigations ? 500 : 780, geometry.size.width - 24))
                        .frame(maxHeight: .infinity)
                        .background(Color.canvas)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1) }
                        .shadow(color: .black.opacity(0.5), radius: 30, x: -10)
                        .accessibilityAddTraits(.isModal)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .tint(Color.commandAccent)
        .sheet(isPresented: $model.setupVisible, onDismiss: { model.apiKey = "" }) {
            VStack(spacing: 0) {
                ScrollView {
                    onboarding.padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 24)
                }
                Hairline()
                providerActions.padding(.horizontal, 28).padding(.vertical, 18)
            }
            .frame(width: 580, height: 600)
            .background(Color.surface)
            .interactiveDismissDisabled(model.busy)
        }
        .sheet(item: $overviewDetail) { detail in
            VStack(spacing: 0) {
                HStack {
                    Text(detail == .network ? "Exposición de red" : "Cobertura de recolección").font(.title3.weight(.semibold))
                    Spacer()
                    Button("Cerrar", systemImage: "xmark") { overviewDetail = nil }
                        .labelStyle(.iconOnly).buttonStyle(ArkButton(prominent: false))
                        .keyboardShortcut(.cancelAction)
                }.padding(22)
                Hairline()
                ScrollView {
                    if let status = model.status {
                        if detail == .network { exposure(status).padding(22) }
                        else { coverageDetails(status).padding(22) }
                    } else {
                        ContentUnavailableView("Agente sin conexión", systemImage: "bolt.slash", description: Text("Reconecta el agente para consultar su estado actual."))
                    }
                }
            }
            .frame(width: 640, height: 500).background(Color.canvas)
        }
        .onChange(of: model.showAlerts, initial: true) { _, requested in
            if requested { selection = .alerts; model.showAlerts = false }
        }
    }

    private var commandCenter: some View {
        CommandCenter(model: model, open: { showProtection = false; selection = $0 }, configure: { model.setupVisible = true }, protect: { showProtection = true; selection = .overview }, inspect: { observation in
                    filter = observation.id
                    kindFilter = nil
                    selection = .observations
                })
    }

    private var panelTitle: String {
        if showProtection && page == .overview { return "Acciones de protección" }
        if page == .investigations { return "Tu seguridad" }
        return page == .live ? "Sucesos de la investigación" : page.rawValue
    }

    private var protectionPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Revisa cada acción antes de aplicarla. Cada botón solicita su propia aprobación de administrador de macOS.")
                .font(.callout).foregroundStyle(.secondary)
            if let status = model.status {
                exposure(status)
                DisclosureGroup("Cobertura y limitaciones") { coverageDetails(status).padding(.top, 12) }
            }
        }
    }

    private var detailPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(panelTitle).font(.headline)
                Spacer()
                Menu("Abrir") {
                    Button("Señales y automatización") { selection = .alerts }
                    Button("Registro de observaciones") { selection = .observations }
                    Button("Alertas principales") { selection = .investigations }
                    Button("Seguimiento en vivo") { selection = .live }
                    Button("Estado y protección") { showProtection = false; selection = .overview }
                    Button("Configurar investigador") { model.setupVisible = true }
                }.menuStyle(.borderlessButton).fixedSize()
                Button("Cerrar", systemImage: "xmark") { selection = nil }
                    .labelStyle(.iconOnly).buttonStyle(CommandButton(prominent: false))
                    .keyboardShortcut(.cancelAction)
            }.padding(20)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error = model.error { errorBanner(error) }
                    if model.status == nil { welcome }
                    switch page {
                    case .alerts: alertList
                    case .observations: observationList
                    case .investigations: investigationList
                    case .overview:
                        if showProtection { protectionPanel } else { overview }
                    case .live:
                        LiveView(model: model, openActivity: { selection = .alerts }, openStatus: { selection = .overview }) { selection = .investigations }
                    }
                }.padding(22)
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 40) {
                    welcomeIntro.frame(maxWidth: 420, alignment: .leading)
                    welcomeSteps.frame(minWidth: 280)
                }
                VStack(alignment: .leading, spacing: 28) { welcomeIntro; welcomeSteps }
            }
            Hairline()
            if let localStartError { errorBanner(localStartError, dismiss: { self.localStartError = nil }) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { welcomeActions }
                VStack(alignment: .leading, spacing: 12) { welcomeActions }
            }
            Label("La vigilancia local funciona sin clave ni llamadas a modelos.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
            if model.restoringStartup || model.busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Preparando la conexión local…").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .card(padding: 28)
    }

    private var welcomeIntro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tu Mac, bajo una mirada atenta.").font(.largeTitle.weight(.semibold))
            Text("Empieza con vigilancia local. Conecta Claude cuando quieras investigar los cambios con ayuda de IA.")
                .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcomeSteps: some View {
        VStack(alignment: .leading, spacing: 20) {
            welcomeStep("01", "Observa", "Procesos, escuchas de red y cambios en archivos seleccionados.")
            welcomeStep("02", "Investiga", "Revisa señales y contrasta hipótesis con evidencia registrada.")
            welcomeStep("03", "Decide", "Cada acción de defensa requiere tu aprobación de macOS.")
        }
    }

    @ViewBuilder private var welcomeActions: some View {
        Button("Iniciar vigilancia local", systemImage: "play.fill") {
            Task {
                localStartError = nil
                await model.startLocalMonitoring()
                localStartError = model.error
            }
        }
            .buttonStyle(ArkButton()).disabled(model.busy || model.restoringStartup)
        Button("Conectar Claude", systemImage: "sparkles") { model.setupVisible = true }
            .buttonStyle(ArkButton(prominent: false)).disabled(model.busy)
    }

    private func welcomeStep(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.info)
                .frame(width: 30, height: 30).background(Color.info.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var disconnectedNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.slash").foregroundStyle(Color.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text("Agente sin conexión").font(.callout.weight(.semibold))
                Text("Los datos cargados son anteriores. Inicia la vigilancia desde el investigador para actualizar la evidencia.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Abrir investigador") { selection = .live }.buttonStyle(ArkButton(prominent: false))
        }.card()
    }

    private var providerNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").foregroundStyle(Color.info)
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude aún no está conectado").font(.callout.weight(.semibold))
                Text("Puedes vigilar este Mac sin IA. Conecta Claude cuando quieras investigar las señales.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Conectar Claude") { model.setupVisible = true }.buttonStyle(ArkButton(prominent: false))
        }.card()
    }

    private var connection: (title: String, detail: String, color: Color) {
        guard let status = model.status else {
            if model.restoringStartup { return ("Reconectando…", "Restaurando tu conexión guardada.", .secondary) }
            return ("Agente desconectado", "Conectar inicia un agente en primer plano si hace falta. La evidencia cargada antes puede seguir visible.", .secondary)
        }
        if status.onboarding_required == true {
            return status.monitoring
                ? ("Vigilancia local activa", "Registrando evidencia en este Mac. Conecta Claude para activar las investigaciones.", .success)
                : ("Vigilancia local en pausa", "Puedes reanudar la recolección sin conectar un proveedor de IA.", .warning)
        }
        return status.monitoring
            ? ("Monitoreo activo", "Se están registrando instantáneas periódicas de solo lectura.", .success)
            : ("Monitoreo en pausa", "Las instantáneas están en pausa. La evidencia registrada sigue disponible para revisar.", .warning)
    }

    // MARK: Shared pieces

    private func errorBanner(_ message: String, dismiss: (() -> Void)? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.danger)
            Text(message).font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.error = nil; dismiss?() } label: { Image(systemName: "xmark") }
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
        VStack(alignment: .leading, spacing: 10) {
            ReportSectionTitle(title)
            content()
        }
    }

    // MARK: Onboarding

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                BrandMark(size: 40)
                Spacer()
                Button("Cerrar", systemImage: "xmark") { model.setupVisible = false; model.apiKey = "" }
                    .labelStyle(.iconOnly).buttonStyle(.plain).help("Cerrar configuración").disabled(model.busy)
            }
            if let error = model.error { errorBanner(error) }
            VStack(alignment: .leading, spacing: 4) {
                Text("Conecta tu investigador").font(.title2.weight(.semibold))
                Text("Anthropic · Claude Haiku 5.5").font(.callout).foregroundStyle(.secondary)
            }
            Text("Arkangel incluye una clave de API de Anthropic de demostración: pulsa Conectar para activar las investigaciones. Opcionalmente, usa tu propia clave.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            SecureField("Clave de API de Anthropic", text: $model.apiKey, prompt: Text("Clave de API de Anthropic (opcional; vacía usa la guardada o la de demostración)"))
                .textFieldStyle(.plain).font(.system(.body, design: .monospaced))
                .inputField()
                .disabled(model.busy)
            Text("Deja el campo vacío para reutilizar una clave guardada.").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                assurance("lock", "Tu clave se guarda en el Llavero de macOS tras validarse. Una clave guardada nunca se muestra.")
                assurance("hand.raised", "La vigilancia local funciona sin clave. Claude investiga cuando lo pides o cuando autorizas por separado las investigaciones automáticas.")
                assurance("power", "Conectar puede iniciar el agente de Python de Arkangel en primer plano. Al salir se detiene el agente iniciado por esta app; un agente externo sigue activo.")
            }
            Toggle("Permito enviar a Anthropic metadatos minimizados de la telemetría local y entiendo que las investigaciones generan cargos de API.", isOn: $model.cloudConsent)
                .toggleStyle(.checkbox).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var providerActions: some View {
        HStack(spacing: 12) {
            Button("Cancelar") { model.setupVisible = false; model.apiKey = "" }
                .buttonStyle(ArkButton(prominent: false))
                .keyboardShortcut(.cancelAction)
                .disabled(model.busy)
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            Button(model.busy ? "Conectando…" : "Conectar") { Task { await model.connect() } }
                .buttonStyle(ArkButton())
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy || !model.cloudConsent)
        }
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
        VStack(alignment: .leading, spacing: 14) {
            if let status = model.status {
                compactMonitoring(status)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    overviewMetric("Observaciones", status.observation_count.formatted(), symbol: "waveform.path.ecg", destination: .observations)
                    overviewMetric("Señales sin revisar", (status.alerts?.unacknowledged ?? 0).formatted(), symbol: "exclamationmark.shield", destination: .alerts)
                    overviewMetric("Investigaciones", model.investigations.count.formatted(), symbol: "text.magnifyingglass", destination: .investigations)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    overviewActivity.frame(minWidth: 370, maxWidth: .infinity)
                    overviewControls.frame(minWidth: 300, idealWidth: 320, maxWidth: 360)
                }
                VStack(spacing: 14) { overviewActivity; overviewControls }
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                Text("La evidencia puede ser incompleta. Sin señales no significa que el Mac sea seguro.")
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private func compactMonitoring(_ status: AgentStatus) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { compactMonitoringLabel(status); Spacer(); compactMonitoringActions(status) }
            VStack(alignment: .leading, spacing: 12) { compactMonitoringLabel(status); compactMonitoringActions(status) }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16).fill(LinearGradient(colors: [Color.info.opacity(0.16), Color.info.opacity(0.045)], startPoint: .leading, endPoint: .trailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.info.opacity(0.16)))
    }

    private func compactMonitoringLabel(_ status: AgentStatus) -> some View {
        HStack(spacing: 10) {
            StatusDot(color: status.monitoring ? .success : .warning)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.monitoring ? "Vigilancia activa" : "Vigilancia en pausa").font(.callout.weight(.semibold))
                Text(status.last_scan.map { "Última instantánea \(relativeTime($0))" } ?? "Esperando la primera instantánea")
                    .font(.caption).foregroundStyle(.secondary).help(status.last_scan.map(fullTime) ?? "")
            }
        }
    }

    private func compactMonitoringActions(_ status: AgentStatus) -> some View {
        HStack(spacing: 8) {
            Button(status.monitoring ? "Pausar" : "Reanudar", systemImage: status.monitoring ? "pause" : "play.fill") {
                Task { await model.perform("monitoring") }
            }.buttonStyle(ArkButton(prominent: false))
            Button("Tomar instantánea", systemImage: "camera.viewfinder") { Task { await model.perform("scan") } }
                .buttonStyle(ArkButton(prominent: false))
        }.disabled(model.busy)
    }

    private func overviewMetric(_ title: String, _ value: String, symbol: String, destination: Page) -> some View {
        Button { selection = destination } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(value).font(.title2.weight(.semibold)).monospacedDigit().contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                Image(systemName: symbol).font(.system(size: 18, weight: .light)).foregroundStyle(Color.info)
            }.card(padding: 14).contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }.buttonStyle(.plain).help("Abrir \(destination.rawValue)")
    }

    private var overviewActivity: some View {
        VStack(alignment: .leading, spacing: 0) {
            overviewSectionHeader("Cambios por revisar", action: "Abrir actividad") { selection = .alerts }.padding(18)
            let pending = model.alerts.filter { !$0.acknowledged }
            if pending.isEmpty {
                Label("No hay señales sin revisar en los datos cargados.", systemImage: "tray")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 18)
            }
            ForEach(pending.prefix(2)) { alert in
                Button { selection = .alerts } label: {
                    WorkspaceActivityRow(symbol: "exclamationmark.shield", title: alert.reason, detail: "Sin revisar", timestamp: relativeTime(alert.created_at), color: .warning)
                }.buttonStyle(.plain)
            }
            Hairline()
            overviewSectionHeader("Actividad reciente", action: "Ver registro") { selection = .observations }.padding(18)
            if model.observations.isEmpty {
                workspaceEmpty("Aún no hay observaciones", detail: "Toma una instantánea para empezar a registrar la actividad de este Mac.", symbol: "tray")
            }
            ForEach(model.observations.prefix(5)) { item in
                Button {
                    filter = item.id
                    kindFilter = nil
                    selection = .observations
                } label: {
                    WorkspaceActivityRow(symbol: evidenceSymbol(item.kind), title: item.summary, detail: humanize(item.kind), timestamp: relativeTime(item.timestamp), color: .info)
                }.buttonStyle(.plain).help("Inspeccionar esta observación")
                Hairline().padding(.leading, 60)
            }
            if model.investigating || model.progress?.active == true {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Investigación en curso").font(.callout)
                    Spacer()
                    Button("Ver pasos") { selection = .live }.buttonStyle(.plain).font(.caption).foregroundStyle(Color.info)
                }.padding(18)
            } else if let report = model.investigations.first {
                overviewSectionHeader("Último informe", action: "Ver informes") { selection = .investigations }.padding(18)
                Button { selection = .investigations } label: {
                    WorkspaceActivityRow(symbol: "doc.text", title: report.title, detail: es(report.status), timestamp: relativeTime(report.created_at), color: toneColor(report.status))
                }.buttonStyle(.plain)
            }
            Text("Las observaciones incluyen actividad normal; no son alertas por sí mismas.")
                .font(.caption).foregroundStyle(.secondary).padding(18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(EvidenceGlassSurface())
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func workspaceEmpty(_ title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 24, weight: .light)).foregroundStyle(Color.info)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
    }

    private func overviewSectionHeader(_ title: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.callout.weight(.semibold))
            Spacer(minLength: 0)
            Button(action, action: perform).buttonStyle(.plain).font(.caption).foregroundStyle(Color.info)
        }
    }

    private var overviewControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "text.magnifyingglass").foregroundStyle(Color.info)
                        .frame(width: 32, height: 32).background(Color.info.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Investigar este Mac").font(.callout.weight(.semibold))
                        Text(model.status?.onboarding_required == true ? "Proveedor sin conectar" : model.investigating ? "Investigación en curso" : "Consultas de solo lectura")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.status?.onboarding_required == true {
                    Text("La vigilancia local ya está disponible. Conecta Claude para investigar los cambios.").font(.callout).foregroundStyle(.secondary)
                    Button("Conectar investigador") { model.setupVisible = true }.buttonStyle(ArkButton())
                } else {
                    TextField("¿Qué quieres entender de tu Mac?", text: $model.question, axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(2...3).inputField()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Empieza por una pregunta").font(.caption).foregroundStyle(.secondary)
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button { model.question = suggestion } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "arrow.turn.down.right").font(.caption)
                                    Text(suggestion).font(.caption).multilineTextAlignment(.leading)
                                }.foregroundStyle(Color.info)
                            }.buttonStyle(.plain)
                        }
                    }
                    HStack {
                        Button("Proveedor") { model.setupVisible = true }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(model.investigating ? "Investigando…" : "Investigar", systemImage: "arrow.up") {
                            Task { await model.investigate() }
                        }.buttonStyle(ArkButton()).disabled(model.busy || model.investigating || model.status == nil)
                    }
                }
            }.card(padding: 18)
            if let status = model.status {
                VStack(alignment: .leading, spacing: 14) {
                    overviewSectionHeader("Red y protección", action: "Ampliar") { overviewDetail = .network }
                    if let firewall = status.firewall {
                        Label(firewall.firewall_enabled ? "Firewall activado" : "Firewall desactivado", systemImage: "shield.lefthalf.filled")
                            .font(.callout).foregroundStyle(firewall.firewall_enabled ? Color.secondary : Color.warning)
                        if !firewall.firewall_enabled || !firewall.stealth_mode {
                            Button("Activar firewall y modo sigiloso") { Task { await model.defend("enable_firewall") } }
                                .buttonStyle(ArkButton(prominent: false)).disabled(model.busy)
                        }
                    } else { Text("Estado del firewall no disponible").font(.caption).foregroundStyle(.secondary) }
                    let ports = status.exposed ?? []
                    Text("\(ports.count) escuchas accesibles · \((status.blocked_ports ?? []).count) puertos bloqueados")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(ports.prefix(2)) { port in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Puerto \(port.port)").font(.caption.weight(.medium))
                                Text(port.executable).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            Button(port.blocked ? "Desbloquear" : "Bloquear") {
                                Task { await model.defend(port.blocked ? "unblock_port" : "block_port", port: port.port) }
                            }.buttonStyle(ArkButton(prominent: false)).disabled(model.busy)
                        }
                    }
                    Text("Cada cambio requiere tu aprobación de administrador de macOS.").font(.caption2).foregroundStyle(.secondary)
                    Hairline()
                    DisclosureGroup("Cobertura de recolección") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(status.coverage) { item in
                                HStack(alignment: .top) {
                                    Text(humanize(item.source)).font(.caption)
                                    Spacer()
                                    Text(es(item.status)).font(.caption).foregroundStyle(toneColor(item.status))
                                }.help(item.detail)
                            }
                            Button("Ver alcance y limitaciones") { overviewDetail = .coverage }.buttonStyle(.plain).font(.caption).foregroundStyle(Color.info)
                        }.padding(.top, 10)
                    }.font(.caption)
                }.card(padding: 18)
            }
        }
    }

    private func coverageDetails(_ status: AgentStatus) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Alcance de la última instantánea. La cobertura parcial limita las conclusiones.").font(.callout).foregroundStyle(.secondary)
            if status.coverage.isEmpty { Text("No se informó cobertura.").foregroundStyle(.secondary) }
            ForEach(status.coverage) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(humanize(item.source)).font(.headline); Spacer(); Pill(item.status) }
                    Text(item.detail).font(.callout).foregroundStyle(.secondary)
                }.card()
            }
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

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.title.weight(.semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .card()
        .animation(.snappy, value: value)
    }

    private var alertList: some View {
        let visible = model.alerts.filter { !onlyUnreviewedAlerts || !$0.acknowledged }
        return VStack(alignment: .leading, spacing: 24) {
            if let status = model.status {
                signalMonitoring(status)
                HStack(spacing: 12) {
                    metric("Sin revisar", (status.alerts?.unacknowledged ?? 0).formatted())
                    metric("Por investigar", (status.alerts?.pending ?? 0).formatted())
                }
                if let automation = status.automation { signalAutomation(automation) }
                signalCoverage(status)
            }
            VStack(alignment: .leading, spacing: 16) {
                ViewThatFits(in: .horizontal) {
                    HStack { signalInboxTitle; Spacer(); signalFilter }
                    VStack(alignment: .leading, spacing: 12) { signalInboxTitle; signalFilter }
                }
                if visible.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: model.alerts.isEmpty ? "tray" : "checkmark.circle")
                            .font(.system(size: 28, weight: .light)).foregroundStyle(Color.info)
                            .frame(width: 56, height: 56).background(Color.info.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Text(model.alerts.isEmpty ? "Aún no hay señales" : "No quedan señales sin revisar")
                            .font(.title3.weight(.semibold))
                        Text(model.alerts.isEmpty
                             ? (model.status?.monitoring == true ? "Los cambios detectados aparecerán aquí con su evidencia." : "Activa la vigilancia para registrar nuevos cambios. La evidencia anterior se conserva.")
                             : "Puedes desactivar el filtro para consultar las señales ya revisadas.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                        Text("La ausencia de señales no garantiza que el Mac sea seguro.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 30).card(padding: 24)
                }
                LazyVStack(spacing: 14) {
                    ForEach(visible) { signalCard($0) }
                }
                Text("Hasta 500 señales · Historial de los últimos 7 días")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var signalInboxTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bandeja de señales").font(.title3.weight(.semibold))
            Text("Un cambio es un motivo para revisar, no una confirmación de compromiso.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var signalFilter: some View {
        Toggle("Solo sin revisar", isOn: $onlyUnreviewedAlerts)
            .toggleStyle(.switch).controlSize(.small).fixedSize()
    }

    private func signalMonitoring(_ status: AgentStatus) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { signalMonitoringLabel(status); Spacer(); signalMonitoringButton(status) }
                VStack(alignment: .leading, spacing: 16) { signalMonitoringLabel(status); signalMonitoringButton(status) }
            }
            HStack(spacing: 7) {
                Image(systemName: "clock")
                Text(status.last_file_scan.map { "Archivos revisados \(relativeTime($0))" } ?? "Esperando la primera revisión de archivos")
                    .help(status.last_file_scan.map(fullTime) ?? "")
            }.font(.caption).foregroundStyle(.secondary)
        }.card(padding: 22)
    }

    private func signalMonitoringLabel(_ status: AgentStatus) -> some View {
        HStack(spacing: 12) {
            Image(systemName: status.monitoring ? "waveform.path.ecg" : "pause")
                .font(.system(size: 18)).foregroundStyle(status.monitoring ? Color.success : Color.warning)
                .frame(width: 42, height: 42)
                .background((status.monitoring ? Color.success : Color.warning).opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(status.monitoring ? "Vigilancia activa" : "Vigilancia en pausa").font(.headline)
                Text(status.monitoring ? "Registrando cambios locales de solo lectura." : "No se están tomando nuevas instantáneas.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func signalMonitoringButton(_ status: AgentStatus) -> some View {
        Button(status.monitoring ? "Pausar" : "Reanudar vigilancia", systemImage: status.monitoring ? "pause" : "play.fill") {
            Task { await model.perform("monitoring") }
        }
        .buttonStyle(ArkButton(prominent: !status.monitoring)).disabled(model.busy)
    }

    private func signalAutomation(_ automation: AutomationState) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(Color.info).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Investigación automática").font(.headline)
                    Text("Permite que el investigador revise las señales pendientes cuando el proveedor esté disponible.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Toggle("Autorizo enviar metadatos minimizados a mi proveedor de IA y acepto los cargos de API que correspondan.", isOn: Binding(
                get: { model.status?.automation?.enabled ?? false },
                set: { enabled in Task { await model.setAutomation(enabled) } }
            ))
            .toggleStyle(.checkbox).fixedSize(horizontal: false, vertical: true).disabled(model.busy)
            Hairline()
            ViewThatFits(in: .horizontal) {
                HStack { automationStatus(automation); Spacer(); automationQuota(automation) }
                VStack(alignment: .leading, spacing: 8) { automationStatus(automation); automationQuota(automation) }
            }
            DisclosureGroup("Límites y funcionamiento") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Solo investiga cuando hay señales pendientes: como máximo un intento cada 5 minutos y 12 en 24 horas. Los intentos fallidos también cuentan.")
                    Text("La cuota limita intentos, no el gasto. Las investigaciones manuales quedan fuera de estos límites.")
                    Text("Pausar la vigilancia impide nuevas investigaciones automáticas. Una que ya esté en curso puede terminar.")
                    if automation.cooldown_seconds > 0 {
                        Text("Próximo intento automático en al menos \(automation.cooldown_seconds) segundos, si se cumplen las demás condiciones.")
                    }
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 10)
            }.font(.caption).foregroundStyle(.secondary)
        }.card(padding: 22)
    }

    private func automationStatus(_ automation: AutomationState) -> some View {
        Label(es(automation.reason), systemImage: automation.enabled ? "bolt" : "bolt.slash")
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
    }

    private func automationQuota(_ automation: AutomationState) -> some View {
        Text("\(automation.remaining) intentos disponibles / 24 h")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }

    private func signalCoverage(_ status: AgentStatus) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 14) {
                Label("Cerrar la ventana mantiene la vigilancia. Salir de Arkangel detiene el agente iniciado por la app; un agente externo sigue activo.", systemImage: "info.circle")
                if let detail = model.notificationDetail { Label(detail, systemImage: "bell.badge") }
                let partial = status.coverage.filter { $0.status != "available" && $0.status != "ok" }
                if !partial.isEmpty {
                    Hairline()
                    Text("Cobertura con limitaciones").fontWeight(.medium)
                    ForEach(partial) { coverage in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(es(coverage.source)).fontWeight(.medium).foregroundStyle(.primary)
                            Text(coverage.detail)
                        }
                    }
                }
            }
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
        } label: {
            Label("Cobertura, notificaciones y funcionamiento", systemImage: "info.circle")
                .font(.callout.weight(.medium))
        }.card(padding: 18)
    }

    private func signalCard(_ alert: AgentAlert) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.shield").foregroundStyle(alert.acknowledged ? Color.secondary : Color.warning)
                VStack(alignment: .leading, spacing: 5) {
                    Text(alert.reason).font(.headline)
                    Text(relativeTime(alert.created_at)).font(.caption).foregroundStyle(.secondary).help(fullTime(alert.created_at))
                }
                Spacer()
                Pill(alert.acknowledged ? "Revisada" : "Sin revisar", alert.acknowledged ? .secondary : .warning)
            }
            Text(alert.signal.entity).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            Label(alert.investigated ? "Investigación completada" : "Pendiente de investigación", systemImage: alert.investigated ? "text.magnifyingglass" : "clock")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Comparar evidencia del cambio") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Antes").font(.caption.weight(.semibold))
                    if let before = alert.before { observationRow(before) }
                    else { Text("No hay evidencia anterior disponible.").font(.caption).foregroundStyle(.secondary) }
                    Text("Después").font(.caption.weight(.semibold))
                    observationRow(alert.after)
                    Text("Señal registrada").font(.caption.weight(.semibold))
                    observationRow(alert.signal)
                }.padding(.top, 12)
            }.font(.callout)
            if !alert.acknowledged {
                Button("Marcar como revisada", systemImage: "checkmark") { Task { await model.acknowledge(alert.id) } }
                    .buttonStyle(ArkButton(prominent: false)).disabled(model.busy)
            } else {
                Text("Revisada. La evidencia se conserva y la investigación pendiente no se cancela.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.card(padding: 22)
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
                .pickerStyle(.menu).labelsHidden().frame(maxWidth: 210)
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
                .frame(minWidth: 160, maxWidth: 240)
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
        TopAlertsPanel(model: model, openSignals: { selection = .alerts }, showOrb: { selection = nil }) { report in
            investigationDetails(report)
        }
    }

    /// Hipótesis, pasos y limitaciones: el detalle técnico que la barra de alertas mantiene plegado.
    private func investigationDetails(_ finding: Investigation) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if !finding.hypotheses.isEmpty {
                subsection("Hipótesis") {
                    ForEach(Array(finding.hypotheses.enumerated()), id: \.offset) { _, hypothesis in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                Text(hypothesis.statement).reportItemTitle()
                                Spacer(minLength: 8)
                                Pill(hypothesis.status)
                            }
                            if !hypothesis.counterevidence.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Contraevidencia").font(.caption.weight(.medium)).foregroundStyle(.tertiary)
                                    Text(hypothesis.counterevidence).reportBody()
                                }
                            }
                            evidenceLinks(hypothesis.evidence_ids)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.hairline))
                    }
                }
            }
            if !finding.steps.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(finding.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(String(format: "%02d", index + 1))
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(es(step.tool)).font(.system(size: 12, weight: .medium, design: .monospaced))
                                    Text(step.summary).reportBody()
                                }
                            }
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    ReportSectionTitle("Pasos de la investigación · \(finding.steps.count)")
                }
            }
            if !finding.limitations.isEmpty {
                subsection("Limitaciones") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(finding.limitations.enumerated()), id: \.offset) { _, limitation in
                            Text("– \(limitation)").reportBody()
                        }
                    }
                }
            }
        }
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
            .foregroundStyle(Color.black)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color.info, Color.info.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Color.hairline).frame(height: 1) }
}

struct ReportSectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
    }
}

extension Text {
    func reportItemTitle() -> some View {
        font(.system(size: 13, weight: .medium)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
    }

    func reportBody() -> some View {
        font(.system(size: 12)).lineSpacing(3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
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
        .font(.caption.weight(.medium)).foregroundStyle(color).lineLimit(1)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(color.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.hairline))
    }
}

/// Shared action hierarchy for local monitoring, investigation, and explicit approvals.
struct ArkButton: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let active = isEnabled && hovered
        return configuration.label
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .foregroundStyle(isEnabled ? (prominent ? Color.black : Color.primary) : Color.secondary)
            .background {
                if prominent && isEnabled {
                    shape.fill(Color.info.opacity(configuration.isPressed ? 0.8 : active ? 0.9 : 1))
                        .shadow(color: Color.info.opacity(0.12), radius: 3, y: 1)
                } else {
                    shape.fill(Color.primary.opacity(isEnabled ? (configuration.isPressed ? 0.1 : active ? 0.075 : 0.035) : 0.025))
                        .overlay(shape.strokeBorder(Color.hairline.opacity(isEnabled ? 0.8 : 0.4)))
                }
            }
            .contentShape(shape)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: active)
    }
}

// MARK: Palette

/// Adaptive slate surfaces keep evidence legible in both macOS appearances.
extension Color {
    static let canvas = dynamic(light: 0xF5F5F2, dark: 0x080909)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x101111)
    static let hairline = dynamic(light: 0xE1E3DC, dark: 0x282B26)
    static let success = Color(nsColor: rgb(0x30A46C))
    static let warning = Color(nsColor: rgb(0xF5A623))
    static let danger = Color(nsColor: rgb(0xE5484D))
    static let info = Color.commandAccent

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
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(EvidenceGlassSurface())
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
func parseDate(_ text: String) -> Date? {
    try? Date(text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression), strategy: .iso8601)
}

func relativeTime(_ text: String) -> String {
    parseDate(text)?.formatted(.relative(presentation: .named)) ?? text
}

func fullTime(_ text: String) -> String {
    parseDate(text)?.formatted(date: .abbreviated, time: .standard) ?? text
}
