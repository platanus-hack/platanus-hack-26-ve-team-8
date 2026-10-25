import SwiftUI

/// Destinations other views can request; the shell maps each one to a page (and tab) of the app.
enum Page: String, CaseIterable, Identifiable {
    case alerts = "Alertas", live = "En vivo", overview = "Protección", observations = "Observaciones", investigations = "Informes"
    var id: String { rawValue }
}

/// The three pages of the app, listed in the left sidebar.
enum AppSection: String, CaseIterable, Identifiable {
    case home, protection, activity
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Inicio"
        case .protection: "Protección"
        case .activity: "Actividad"
        }
    }
    var symbol: String {
        switch self {
        case .home: "circle.hexagongrid"
        case .protection: "shield.lefthalf.filled"
        case .activity: "waveform.path.ecg"
        }
    }
    var key: KeyEquivalent {
        switch self {
        case .home: "1"
        case .protection: "2"
        case .activity: "3"
        }
    }
}

enum ActivityTab: String, CaseIterable, Identifiable {
    case alerts, observations, live
    var id: String { rawValue }
    var title: String {
        switch self {
        case .alerts: "Alertas"
        case .observations: "Observaciones"
        case .live: "En vivo"
        }
    }
    var subtitle: String {
        switch self {
        case .alerts: "Qué cambió en tu Mac, la investigación automática y la respuesta de IA."
        case .observations: "Evidencia local registrada, tratada como no confiable."
        case .live: "Sigue los pasos del investigador y los cambios de este Mac."
        }
    }
}

fileprivate extension Font {
    static let pageTitle = Font.system(size: 22, weight: .semibold)
    static let heading = Font.system(size: 17, weight: .semibold)
    static let alertTitle = Font.system(size: 16, weight: .semibold)
    static let bodyText = Font.system(size: 14)
    static let label = Font.system(size: 13)
    static let small = Font.system(size: 12)
    static let mono = Font.system(size: 12, design: .monospaced)
}

struct Dashboard: View {
    @Bindable var model: GuardianModel
    @State private var section: AppSection = .home
    @State private var activityTab: ActivityTab = .alerts
    @State private var filter = ""
    @State private var kindFilter: String?
    @State private var localStartError: String?
    @State private var onlyUnreviewedAlerts = false
    /// Only used when the window is too narrow to keep the Informes sidebar beside the orb.
    @State private var reportsOpen = false
    @State private var reportsScrollRequest = 0

    private static let sidebarWidth: CGFloat = 180
    private static let reportsWidth: CGFloat = 300
    private static let centerMinWidth: CGFloat = 620

    var body: some View {
        GeometryReader { geometry in
            let reportsFit = geometry.size.width - Self.sidebarWidth - Self.reportsWidth - 2 >= Self.centerMinWidth
            HStack(spacing: 0) {
                sidebar(reportsFit: reportsFit).frame(width: Self.sidebarWidth)
                VerticalHairline()
                Group {
                    switch section {
                    case .home: home(reportsFit: reportsFit)
                    case .protection: protectionPage
                    case .activity: activityPage
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
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
        .onChange(of: model.showAlerts, initial: true) { _, requested in
            if requested { show(.alerts); model.showAlerts = false }
        }
    }

    // MARK: Navigation

    private func open(_ page: Page) {
        switch page {
        case .alerts: show(.alerts)
        case .observations: show(.observations)
        case .live: show(.live)
        case .overview: section = .protection
        case .investigations:
            section = .home
            reportsOpen = true
            reportsScrollRequest += 1
        }
    }

    private func show(_ tab: ActivityTab) {
        activityTab = tab
        section = .activity
    }

    private func inspect(_ evidenceID: String) {
        filter = evidenceID
        kindFilter = nil
        show(.observations)
    }

    private func sidebar(reportsFit: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                BrandMark(size: 26)
                Text("Arkangel").font(.heading).foregroundStyle(Color.commandAccent)
            }
            .padding(.horizontal, 10).padding(.bottom, 22)
            .accessibilityElement(children: .combine)
            ForEach(AppSection.allCases) { item in
                navRow(item.title, symbol: item.symbol, selected: section == item) { section = item }
                    .keyboardShortcut(item.key, modifiers: .command)
                    .help("\(item.title) (⌘\(String(item.key.character)))")
            }
            if !reportsFit {
                navRow("Informes", symbol: "doc.text.magnifyingglass", selected: section == .home && reportsOpen) {
                    if section == .home { reportsOpen.toggle() } else { section = .home; reportsOpen = true }
                }
                .help("Mostrar u ocultar los informes del investigador")
            }
            Spacer(minLength: 16)
            connectionLine.padding(.horizontal, 10).padding(.bottom, 8)
            navRow("Configuración", symbol: "gearshape", selected: false) { model.setupVisible = true }
                .help("Configurar investigador")
        }
        .padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black)
    }

    private func navRow(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14))
                    .foregroundStyle(selected ? Color.commandAccent : Color.secondary)
                    .frame(width: 18)
                Text(title).font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background {
                let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                if selected {
                    shape.fill(LinearGradient(colors: [Color.commandAccent.opacity(0.16), Color.white.opacity(0.04)], startPoint: .leading, endPoint: .trailing))
                        .overlay(shape.strokeBorder(Color.white.opacity(0.08)))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Color.commandAccent).frame(width: 3, height: 16)
                                .shadow(color: Color.commandAccent.opacity(0.8), radius: 4).offset(x: -1)
                        }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(NavRowHoverStyle(selected: selected))
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var connectionLine: some View {
        let state = connection
        return HStack(spacing: 8) {
            StatusDot(color: state.color)
            Text(state.title).font(.label).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(state.detail)
        .accessibilityElement(children: .combine)
    }

    private var connection: (title: String, detail: String, color: Color) {
        guard let status = model.status else {
            if model.restoringStartup { return ("Reconectando…", "Restaurando tu conexión guardada.", .secondary) }
            return ("Agente sin conexión", "Inicia la vigilancia local desde Protección. La evidencia cargada antes puede seguir visible.", .secondary)
        }
        return status.monitoring
            ? ("Vigilando este Mac", "Se están registrando instantáneas periódicas de solo lectura.", .success)
            : ("Vigilancia en pausa", "Las instantáneas están en pausa. La evidencia registrada sigue disponible.", .warning)
    }

    // MARK: Inicio

    private func home(reportsFit: Bool) -> some View {
        HStack(spacing: 0) {
            CommandCenter(model: model, open: { open($0) }, protect: { section = .protection }, inspect: { inspect($0.id) })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .trailing) {
                    if !reportsFit && reportsOpen {
                        HStack(spacing: 0) {
                            VerticalHairline()
                            reportsSidebar(collapsible: true)
                        }
                        .frame(width: Self.reportsWidth)
                        .shadow(color: .black.opacity(0.6), radius: 24, x: -8)
                        .transition(.move(edge: .trailing))
                    }
                }
            if reportsFit {
                VerticalHairline()
                reportsSidebar(collapsible: false).frame(width: Self.reportsWidth)
            }
        }
    }

    private func reportsSidebar(collapsible: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Informes").font(.heading)
                if !model.investigations.isEmpty {
                    Text(model.investigations.count.formatted()).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Color.commandAccent)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.commandAccent.opacity(0.12), in: Capsule())
                        .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] + 1 }
                }
                Spacer()
                if collapsible {
                    // No Esc shortcut: the pinned orb card on Inicio already owns cancelAction.
                    Button("Ocultar informes", systemImage: "xmark") { reportsOpen = false }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id("reportsTop")
                        TopAlertsPanel(model: model, openSignals: { show(.alerts) }, showOrb: { section = .home }, sections: .reportsOnly) { report in
                            investigationDetails(report)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: reportsScrollRequest) { _, _ in proxy.scrollTo("reportsTop", anchor: .top) }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Informes")
    }

    // MARK: Pages

    private func pageHeading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.pageTitle).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.bodyText).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var protectionPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                pageHeading("Protección", "Estado de este Mac, su exposición en la red y los controles de vigilancia.")
                if let error = model.error { errorBanner(error) }
                if let status = model.status {
                    monitoringControls(status)
                    exposure(status)
                    coverageDetails(status)
                    Label("La evidencia puede ser incompleta. Sin alertas no significa que el Mac sea seguro.", systemImage: "info.circle")
                        .font(.label).foregroundStyle(.secondary)
                } else {
                    welcome
                    Button("Actualizar", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                        .buttonStyle(ArkButton(prominent: false)).disabled(model.busy)
                        .help("Vuelve a consultar el estado del agente")
                }
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var activityPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 20) { activityHeading; Spacer(minLength: 0); activityPicker }
                VStack(alignment: .leading, spacing: 14) { activityHeading; activityPicker }
            }
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 18)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error = model.error { errorBanner(error) }
                    switch activityTab {
                    case .alerts: alertList
                    case .observations: observationList
                    case .live:
                        LiveView(model: model, openActivity: { show(.alerts) }, openStatus: { section = .protection }) { open(.investigations) }
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var activityHeading: some View { pageHeading("Actividad", activityTab.subtitle) }

    private var activityPicker: some View {
        Picker("Vista de actividad", selection: $activityTab) {
            ForEach(ActivityTab.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .accessibilityLabel("Vista de actividad")
    }

    // MARK: Welcome

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
                .font(.label).foregroundStyle(.secondary)
            if model.restoringStartup || model.busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Preparando la conexión local…").font(.label).foregroundStyle(.secondary) }
            }
        }
        .card(padding: 28)
    }

    private var welcomeIntro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tu Mac, bajo una mirada atenta.").font(.largeTitle.weight(.semibold))
            Text("Empieza con vigilancia local. Conecta Claude cuando quieras investigar los cambios con ayuda de IA.")
                .font(.bodyText).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcomeSteps: some View {
        VStack(alignment: .leading, spacing: 20) {
            welcomeStep("01", "Observa", "Procesos, escuchas de red y cambios en archivos seleccionados.")
            welcomeStep("02", "Investiga", "Revisa alertas y contrasta hipótesis con evidencia registrada.")
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
            Text(number).font(.mono).foregroundStyle(Color.info)
                .frame(width: 30, height: 30).background(Color.info.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.label).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Shared pieces

    private func errorBanner(_ message: String, dismiss: (() -> Void)? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.danger)
            Text(message).font(.label).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.error = nil; dismiss?() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Descartar")
                .accessibilityLabel("Descartar aviso")
        }
        .padding(12)
        .background(Color.danger.opacity(0.06), in: shape)
        .overlay(shape.strokeBorder(Color.danger.opacity(0.3)))
        .transition(.opacity)
    }

    private func section<Content: View>(_ title: String, _ detail: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.heading).accessibilityAddTraits(.isHeader)
                if let detail { Text(detail).font(.bodyText).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
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
                Text("Anthropic · Claude Haiku 5.5").font(.label).foregroundStyle(.secondary)
            }
            Text("Arkangel incluye una clave de API de Anthropic de demostración: pulsa Conectar para activar las investigaciones. Opcionalmente, usa tu propia clave.")
                .font(.bodyText).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            SecureField("Clave de API de Anthropic", text: $model.apiKey, prompt: Text("Clave de API de Anthropic (opcional; vacía usa la guardada o la de demostración)"))
                .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                .inputField()
                .disabled(model.busy)
            Text("Deja el campo vacío para reutilizar una clave guardada.").font(.small).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                assurance("lock", "Tu clave se guarda en el Llavero de macOS tras validarse. Una clave guardada nunca se muestra.")
                assurance("hand.raised", "La vigilancia local funciona sin clave. Claude investiga cuando lo pides o cuando autorizas por separado las investigaciones automáticas.")
                assurance("power", "Conectar puede iniciar el agente de Python de Arkangel en primer plano. Al salir se detiene el agente iniciado por esta app; un agente externo sigue activo.")
            }
            Toggle("Permito enviar a Anthropic metadatos minimizados de la telemetría local y entiendo que las investigaciones generan cargos de API.", isOn: $model.cloudConsent)
                .toggleStyle(.checkbox).font(.label).fixedSize(horizontal: false, vertical: true)
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
        .font(.label).foregroundStyle(.secondary)
    }

    // MARK: Protección

    /// The controls that used to live in the overflow menu: monitoring, snapshot, baseline and refresh.
    private func monitoringControls(_ status: AgentStatus) -> some View {
        section("Vigilancia") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    StatusDot(color: status.monitoring ? .success : .warning)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(status.monitoring ? "Vigilancia activa" : "Vigilancia en pausa").font(.system(size: 14, weight: .semibold))
                        Text(status.last_scan.map { "Última instantánea \(relativeTime($0))" } ?? "Esperando la primera instantánea")
                            .font(.label).foregroundStyle(.secondary).help(status.last_scan.map(fullTime) ?? "")
                    }
                }
                Text("\(status.observation_count.formatted()) observaciones · \((status.alerts?.unacknowledged ?? 0).formatted()) alertas sin revisar · \(model.investigations.count.formatted()) informes")
                    .font(.label).monospacedDigit().foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { monitoringButtons(status) }
                    VStack(alignment: .leading, spacing: 8) { monitoringButtons(status) }
                }
                Text(model.baselineDate.map { "Referencia de procesos tomada \($0.formatted(.relative(presentation: .named))). Los procesos nuevos se comparan con ella." }
                     ?? "Renovar referencia marca los procesos actuales como conocidos; los que aparezcan después se resaltan como nuevos.")
                    .font(.label).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .card(padding: 20)
        }
    }

    @ViewBuilder private func monitoringButtons(_ status: AgentStatus) -> some View {
        Button(status.monitoring ? "Pausar vigilancia" : "Reanudar vigilancia", systemImage: status.monitoring ? "pause" : "play.fill") {
            Task { await model.perform("monitoring") }
        }
        .buttonStyle(ArkButton(prominent: !status.monitoring)).disabled(model.busy)
        Button("Tomar instantánea", systemImage: "camera.viewfinder") { Task { await model.perform("scan") } }
            .buttonStyle(ArkButton(prominent: false)).disabled(model.busy)
        Button("Renovar referencia", systemImage: "arrow.triangle.2.circlepath") { model.setBaseline() }
            .buttonStyle(ArkButton(prominent: false)).disabled(model.observations.isEmpty)
            .help("Marca los procesos observados ahora como conocidos")
        Button("Actualizar", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
            .buttonStyle(ArkButton(prominent: false)).disabled(model.busy)
            .help("Vuelve a consultar el estado del agente")
    }

    private func coverageDetails(_ status: AgentStatus) -> some View {
        section("Cobertura de recolección", "Alcance de la última instantánea. La cobertura parcial limita las conclusiones.") {
            VStack(spacing: 0) {
                if status.coverage.isEmpty {
                    Text("No se informó cobertura.").font(.bodyText).foregroundStyle(.secondary).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(status.coverage.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Hairline() }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(humanize(item.source)).font(.system(size: 14, weight: .medium)); Spacer(); Pill(item.status) }
                        Text(item.detail).font(.label).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                }
            }
            .card(padding: 0)
        }
    }

    private func exposure(_ status: AgentStatus) -> some View {
        section("Exposición de red", "Puertos que otros dispositivos pueden alcanzar. Un bloqueo descarta sus conexiones nuevas; este Mac puede seguir usando el puerto hasta que lo desbloquees o reinicies. Cada cambio requiere tu aprobación de administrador de macOS.") {
            VStack(spacing: 0) {
                if let firewall = status.firewall {
                    let protected = firewall.firewall_enabled && firewall.stealth_mode
                    HStack(spacing: 12) {
                        Image(systemName: protected ? "checkmark.shield" : "exclamationmark.shield")
                            .foregroundStyle(protected ? Color.secondary : Color.warning).frame(width: 16)
                        Text("Firewall \(firewall.firewall_enabled ? "activado" : "desactivado") · modo sigiloso \(firewall.stealth_mode ? "activado" : "desactivado")")
                            .font(.bodyText)
                        Spacer(minLength: 12)
                        if !protected {
                            Button("Activar firewall y modo sigiloso") { Task { await model.defend("enable_firewall") } }
                                .buttonStyle(ArkButton(prominent: false))
                                .help("macOS te pedirá tu contraseña de administrador antes de cambiar nada.")
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                } else {
                    Text("Estado del firewall no disponible").font(.bodyText).foregroundStyle(.secondary).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                let exposed = status.exposed ?? []
                if exposed.isEmpty {
                    Hairline()
                    Text("No se vieron escuchas accesibles desde otros dispositivos.").font(.bodyText).foregroundStyle(.secondary).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(exposed) { item in
                    Hairline()
                    HStack(spacing: 12) {
                        Image(systemName: "network").foregroundStyle(.secondary).frame(width: 16)
                        Text("Puerto \(item.port)").font(.system(size: 14, weight: .medium)).monospacedDigit()
                        Text("\(item.executable) · \(item.bind_scope == "any" ? "todas las interfaces" : "una interfaz")")
                            .font(.label).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 12)
                        if item.blocked { Pill("Bloqueado", .success) }
                        Button(item.blocked ? "Desbloquear" : "Bloquear desde la red") {
                            Task { await model.defend(item.blocked ? "unblock_port" : "block_port", port: item.port) }
                        }
                        .buttonStyle(ArkButton(prominent: !item.blocked))
                        .accessibilityLabel(item.blocked ? "Desbloquear puerto \(item.port)" : "Bloquear puerto \(item.port) desde la red")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                ForEach((status.blocked_ports ?? []).filter { port in !exposed.contains { $0.port == port } }, id: \.self) { port in
                    Hairline()
                    HStack(spacing: 12) {
                        Image(systemName: "network.slash").foregroundStyle(.secondary).frame(width: 16)
                        Text("Puerto \(port) bloqueado · sin escucha ahora").font(.bodyText).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Button("Desbloquear") { Task { await model.defend("unblock_port", port: port) } }
                            .buttonStyle(ArkButton(prominent: false))
                            .accessibilityLabel("Desbloquear puerto \(port)")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                ForEach(status.blocked_peers ?? [], id: \.self) { address in
                    Hairline()
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.xmark").foregroundStyle(.secondary).frame(width: 16)
                        Text("Equipo \(address) bloqueado").foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Button("Desbloquear") { Task { await model.defend("unblock_peer", address: address) } }
                            .buttonStyle(ArkButton(prominent: false))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
            .card(padding: 0)
            .disabled(model.busy)
        }
    }

    // MARK: Actividad · Alertas

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.label).foregroundStyle(.secondary)
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
                if let demo = status.demo { DemoLabView(model: model, demo: demo) }
                HStack(spacing: 12) {
                    metric("Sin revisar", (status.alerts?.unacknowledged ?? 0).formatted())
                    metric("Por investigar", (status.alerts?.pending ?? 0).formatted())
                }
                if let automation = status.automation { signalAutomation(automation) }
                if let protection = status.protection { ProtectionView(model: model, protection: protection) }
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
                            .font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                        Text(model.alerts.isEmpty ? "Aún no hay alertas" : "No quedan alertas sin revisar")
                            .font(.heading)
                        Text(model.alerts.isEmpty
                             ? (model.status?.monitoring == true ? "Los cambios detectados aparecerán aquí con su evidencia." : "Activa la vigilancia para registrar nuevos cambios. La evidencia anterior se conserva.")
                             : "Puedes desactivar el filtro para consultar las alertas ya revisadas.")
                            .font(.bodyText).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                        Text("La ausencia de alertas no garantiza que el Mac sea seguro.")
                            .font(.label).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 30).card(padding: 24)
                }
                LazyVStack(spacing: 14) {
                    ForEach(visible) { signalCard($0) }
                }
                Text("Hasta 500 alertas · Historial de los últimos 7 días")
                    .font(.label).foregroundStyle(.secondary)
            }
        }
    }

    private var signalInboxTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bandeja de alertas").font(.heading).accessibilityAddTraits(.isHeader)
            Text("Un cambio es un motivo para revisar, no una confirmación de compromiso.")
                .font(.label).foregroundStyle(.secondary)
        }
    }

    private var signalFilter: some View {
        Toggle("Solo sin revisar", isOn: $onlyUnreviewedAlerts)
            .toggleStyle(.switch).controlSize(.small).font(.label).fixedSize()
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
            }.font(.label).foregroundStyle(.secondary)
        }.card(padding: 22)
    }

    private func signalMonitoringLabel(_ status: AgentStatus) -> some View {
        HStack(spacing: 12) {
            Image(systemName: status.monitoring ? "waveform.path.ecg" : "pause")
                .font(.system(size: 18)).foregroundStyle(status.monitoring ? Color.success : Color.warning)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.monitoring ? "Vigilancia activa" : "Vigilancia en pausa").font(.system(size: 14, weight: .semibold))
                Text(status.monitoring ? "Registrando cambios locales de solo lectura." : "No se están tomando nuevas instantáneas.")
                    .font(.label).foregroundStyle(.secondary)
            }
        }
    }

    private func signalMonitoringButton(_ status: AgentStatus) -> some View {
        Button(status.monitoring ? "Pausar" : "Reanudar vigilancia", systemImage: status.monitoring ? "pause" : "play.fill") {
            Task { await model.perform("monitoring") }
        }
        .buttonStyle(ArkButton(prominent: !status.monitoring)).disabled(model.busy)
        .accessibilityLabel(status.monitoring ? "Pausar vigilancia" : "Reanudar vigilancia")
    }

    private func signalAutomation(_ automation: AutomationState) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(Color.info).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Investigación automática").font(.system(size: 14, weight: .semibold))
                    Text("Permite que el investigador revise las alertas pendientes cuando el proveedor esté disponible.")
                        .font(.label).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Toggle("Autorizo enviar metadatos minimizados a mi proveedor de IA y acepto los cargos de API que correspondan.", isOn: Binding(
                get: { model.status?.automation?.enabled ?? false },
                set: { enabled in Task { await model.setAutomation(enabled) } }
            ))
            .toggleStyle(.checkbox).font(.label).fixedSize(horizontal: false, vertical: true).disabled(model.busy)
            Hairline()
            ViewThatFits(in: .horizontal) {
                HStack { automationStatus(automation); Spacer(); automationQuota(automation) }
                VStack(alignment: .leading, spacing: 8) { automationStatus(automation); automationQuota(automation) }
            }
            DisclosureGroup("Límites y funcionamiento") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Solo investiga cuando hay alertas pendientes: como máximo un intento cada 5 minutos y 12 en 24 horas. Los intentos fallidos también cuentan.")
                    Text("La cuota limita intentos, no el gasto. Las investigaciones manuales quedan fuera de estos límites.")
                    Text("Pausar la vigilancia impide nuevas investigaciones automáticas. Una que ya esté en curso puede terminar.")
                    if automation.cooldown_seconds > 0 {
                        Text("Próximo intento automático en al menos \(automation.cooldown_seconds) segundos, si se cumplen las demás condiciones.")
                    }
                }.font(.label).foregroundStyle(.secondary).padding(.top, 10)
            }.font(.label).foregroundStyle(.secondary)
        }.card(padding: 22)
    }

    private func automationStatus(_ automation: AutomationState) -> some View {
        Label(es(automation.reason), systemImage: automation.enabled ? "bolt" : "bolt.slash")
            .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
    }

    private func automationQuota(_ automation: AutomationState) -> some View {
        Text("\(automation.remaining) intentos disponibles / 24 h")
            .font(.label.monospacedDigit()).foregroundStyle(.secondary)
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
            .font(.label).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
        } label: {
            Label("Cobertura, notificaciones y funcionamiento", systemImage: "info.circle")
                .font(.system(size: 14, weight: .medium))
        }.card(padding: 18)
    }

    private func signalCard(_ alert: AgentAlert) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.shield").foregroundStyle(alert.acknowledged ? Color.secondary : Color.danger)
                VStack(alignment: .leading, spacing: 5) {
                    Text(alert.reason).font(.alertTitle).fixedSize(horizontal: false, vertical: true)
                    Text(relativeTime(alert.created_at)).font(.label).foregroundStyle(.secondary).help(fullTime(alert.created_at))
                }
                Spacer()
                Pill(alert.acknowledged ? "Revisada" : "Sin revisar", alert.acknowledged ? .secondary : .danger)
            }
            Text(alert.signal.entity).font(.mono).foregroundStyle(.secondary)
                .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            Label(alert.signal.source == "demo_lab" ? "Demo local · excluida de investigaciones de IA" :
                alert.investigated ? "Investigación completada" : "Pendiente de investigación",
                systemImage: alert.signal.source == "demo_lab" ? "testtube.2" : alert.investigated ? "text.magnifyingglass" : "clock")
                .font(.label).foregroundStyle(.secondary)
            if alert.signal.source == "demo_lab" {
                Text("Revisa la evidencia y los controles de reparación en Laboratorio local con Frame, arriba.")
                    .font(.label).foregroundStyle(.secondary)
            }
            DisclosureGroup("Comparar evidencia del cambio") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Antes").font(.system(size: 13, weight: .semibold))
                    if let before = alert.before { observationRow(before) }
                    else { Text("No hay evidencia anterior disponible.").font(.label).foregroundStyle(.secondary) }
                    Text("Después").font(.system(size: 13, weight: .semibold))
                    observationRow(alert.after)
                    Text("Evidencia de la alerta").font(.system(size: 13, weight: .semibold))
                    observationRow(alert.signal)
                }.padding(.top, 12)
            }.font(.label)
            if !alert.acknowledged {
                Button("Marcar como revisada", systemImage: "checkmark") { Task { await model.acknowledge(alert.id) } }
                    .buttonStyle(ArkButton(prominent: false)).disabled(model.busy)
            } else {
                Text("Revisada. La evidencia se conserva y la investigación pendiente no se cancela.")
                    .font(.label).foregroundStyle(.secondary)
            }
        }.card(padding: 22)
    }

    // MARK: Actividad · Observaciones

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
                .accessibilityLabel("Tipo de observación")
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filtrar evidencia", text: $filter).textFieldStyle(.plain).font(.label)
                    if !filter.isEmpty {
                        Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("Borrar filtro")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .frame(minWidth: 160, maxWidth: 240)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.hairline))
            }
            Text("\(visible.count) de \(model.observations.count) observaciones cargadas")
                .font(.label).foregroundStyle(.secondary)
            if model.observations.isEmpty {
                ContentUnavailableView("No hay observaciones cargadas", systemImage: "waveform.path.ecg", description: Text("Toma una instantánea local desde Protección para recolectar evidencia."))
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
                    Text(item.summary).font(.bodyText)
                    Text(item.entity).font(.mono).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Text(relativeTime(item.timestamp)).font(.small).foregroundStyle(.tertiary)
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
                .font(.mono)
                .foregroundStyle(.primary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.canvas, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.top, 4)
            }
            .font(.small).foregroundStyle(.secondary)
            .padding(.leading, 26)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .textSelection(.enabled)
    }

    // MARK: Informes

    /// Hipótesis, pasos y limitaciones: el detalle técnico que la barra de informes mantiene plegado.
    private func investigationDetails(_ finding: Investigation) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if !finding.hypotheses.isEmpty {
                subsection("Hipótesis") {
                    ForEach(Array(finding.hypotheses.enumerated()), id: \.offset) { index, hypothesis in
                        if index > 0 { Hairline() }
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                Text(hypothesis.statement).reportItemTitle()
                                Spacer(minLength: 8)
                                Pill(hypothesis.status)
                            }
                            if !hypothesis.counterevidence.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Contraevidencia").font(.system(size: 13, weight: .medium)).foregroundStyle(.tertiary)
                                    Text(hypothesis.counterevidence).reportBody()
                                }
                            }
                            evidenceLinks(hypothesis.evidence_ids)
                        }
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if !finding.steps.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(finding.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(String(format: "%02d", index + 1))
                                    .font(.mono).foregroundStyle(.tertiary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(es(step.tool)).font(.system(size: 13, weight: .medium, design: .monospaced))
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

    /// Las referencias de evidencia saltan a la observación correspondiente en Actividad.
    private func evidenceLinks(_ ids: [String]) -> some View {
        HStack(spacing: 6) {
            if ids.isEmpty {
                Text("Sin evidencia citada").font(.small).foregroundStyle(.tertiary)
            }
            ForEach(ids.prefix(4), id: \.self) { id in
                Button(String(id.prefix(8))) { inspect(id) }
                    .buttonStyle(.plain)
                    .font(.mono)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.hairline))
                    .help("Mostrar evidencia \(id)")
                    .accessibilityLabel("Mostrar evidencia \(id)")
            }
            if ids.count > 4 {
                Text("+\(ids.count - 4) más").font(.small).foregroundStyle(.tertiary)
                    .help(ids.dropFirst(4).joined(separator: "\n"))
            }
        }
    }
}

/// Fondo tenue al pasar el cursor por una fila de navegación no seleccionada.
private struct NavRowHoverStyle: ButtonStyle {
    let selected: Bool
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(!selected && hovered ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

struct VerticalHairline: View {
    var body: some View { Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1) }
}


// MARK: Components

/// Botón de aprobación para una propuesta con una acción de defensa tipada; si no, "No aplicada".
struct ProposalStatus: View {
    let action: ProposedAction
    @Bindable var model: GuardianModel
    var body: some View {
        if let defense = action.action {
            if defense.type == "terminate_process" || defense.type == "quarantine_file" {
                Text("Respuesta de IA: consulta el resultado en Actividad → Alertas → Historial de respuesta y cuarentena.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            } else if defense.type == "block_peer", model.peerBlocked(defense.observation_id) {
                Pill("Aplicada", .success)
            } else if defense.type == "block_peer", let observation = defense.observation_id {
                Button("Bloquear equipo") { Task { await model.defend("block_peer", observation: observation) } }
                    .buttonStyle(ArkButton())
                    .disabled(model.busy)
                    .help("Corta la conexión de ese equipo y bloquea sus conexiones nuevas. Pide tu contraseña de administrador de macOS.")
            } else if defense.type == "block_port", let port = defense.port, model.status?.blocked_ports?.contains(port) == true {
                Pill("Aplicada", .success)
            } else if defense.type == "block_port" || defense.type == "enable_firewall" {
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
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
    }
}

extension Text {
    func reportItemTitle() -> some View {
        font(.system(size: 14, weight: .medium)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
    }

    func reportBody() -> some View {
        font(.system(size: 13)).lineSpacing(3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        .font(.system(size: 12, weight: .medium)).foregroundStyle(color).lineLimit(1)
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
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
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
    case "tcp_listener", "tcp_listeners", "tcp_connection", "tcp_connections", "ssh_logins": "network"
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
