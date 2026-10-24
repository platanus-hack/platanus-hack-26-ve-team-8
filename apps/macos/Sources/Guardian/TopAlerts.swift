import SwiftUI

/// Barra lateral pensada para personas no técnicas: primero qué pasa y qué hacer, los detalles técnicos quedan plegados.
struct TopAlertsPanel<Details: View>: View {
    @Bindable var model: GuardianModel
    let openSignals: () -> Void
    let showOrb: () -> Void
    @ViewBuilder let technicalDetails: (Investigation) -> Details
    @State private var expanded: String?

    private static var visibleCount: Int { 3 }

    private var pending: [AgentAlert] {
        model.alerts.filter { !$0.acknowledged }.sorted {
            let left = AlertCopy($0).priority, right = AlertCopy($1).priority
            return left != right ? left < right : $0.created_at > $1.created_at
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            alertsSection
            reportSection
            askSection
        }
        .animation(.snappy, value: pending.map(\.id))
    }

    // MARK: Alerts

    private var alertsSection: some View {
        let alerts = pending
        let shown = Array(alerts.prefix(Self.visibleCount))
        return VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Alertas principales") {
                if !alerts.isEmpty {
                    Text("\(shown.count) de \(alerts.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            if let featured = shown.first {
                featuredCard(featured)
                VStack(spacing: 0) {
                    ForEach(shown.dropFirst()) { alertRow($0) }
                }
            } else {
                calmState
            }
            if !model.alerts.isEmpty {
                Button(action: openSignals) {
                    HStack {
                        Text(model.alerts.count == 1 ? "Ver la señal" : "Ver las \(model.alerts.count) señales")
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 14)).foregroundStyle(.primary)
                    .padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private func featuredCard(_ alert: AgentAlert) -> some View {
        let copy = AlertCopy(alert)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(Color.danger).frame(width: 8, height: 8).shadow(color: .danger, radius: 4)
                Text("REQUIERE TU ATENCIÓN").font(.system(size: 11, weight: .semibold)).tracking(1).foregroundStyle(Color.danger)
                Spacer()
                Text(relativeTime(alert.created_at)).font(.system(size: 12)).foregroundStyle(.secondary).help(fullTime(alert.created_at))
            }
            Text(copy.title).font(.system(size: 18, weight: .semibold)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            Text(copy.detail).font(.system(size: 13)).lineSpacing(3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { featuredActions(alert, copy) }
                VStack(alignment: .leading, spacing: 8) { featuredActions(alert, copy) }
            }
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            HStack {
                Label(stateText(alert), systemImage: alert.investigated ? "checkmark.circle" : "clock")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if copy.defense != nil {
                    Button("Marcar como revisada") { Task { await model.acknowledge(alert.id) } }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .disabled(model.busy)
                }
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.danger.opacity(0.55), lineWidth: 1))
    }

    @ViewBuilder private func featuredActions(_ alert: AgentAlert, _ copy: AlertCopy) -> some View {
        if let defense = copy.defense {
            defenseButton(defense)
        } else {
            Button("Marcar como revisada") { Task { await model.acknowledge(alert.id) } }
                .buttonStyle(CommandButton()).disabled(model.busy)
        }
        Button("Ver en el orbe", action: showOrb).buttonStyle(CommandButton(prominent: false))
    }

    @ViewBuilder private func defenseButton(_ defense: AlertCopy.Defense) -> some View {
        if applied(defense) {
            Label(defense.type == "block_peer" ? "Equipo bloqueado" : defense.type == "block_port" ? "Puerto bloqueado" : "Firewall activado", systemImage: "checkmark.shield")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.success)
                .padding(.horizontal, 12).padding(.vertical, 10)
        } else {
            Button(defense.label) { Task { await model.defend(defense.type, port: defense.port, observation: defense.observation) } }
                .buttonStyle(CommandButton()).disabled(model.busy)
                .help("macOS te pedirá tu contraseña de administrador antes de cambiar nada.")
        }
    }

    private func applied(_ defense: AlertCopy.Defense) -> Bool {
        if defense.type == "block_peer" { return model.peerBlocked(defense.observation) }
        if defense.type == "block_port", let port = defense.port { return model.status?.blocked_ports?.contains(port) == true }
        return model.status?.firewall?.firewall_enabled == true
    }

    private func alertRow(_ alert: AgentAlert) -> some View {
        let copy = AlertCopy(alert)
        let open = expanded == alert.id
        return VStack(alignment: .leading, spacing: 12) {
            Button { expanded = open ? nil : alert.id } label: {
                HStack(alignment: .top, spacing: 14) {
                    statusIcon(alert).frame(width: 16, height: 20)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(copy.title).font(.system(size: 14, weight: .medium)).foregroundStyle(.primary)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        Text("\(copy.short) · \(stateText(alert))").font(.system(size: 12)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(clock(alert.created_at)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        .help(fullTime(alert.created_at))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Ocultar explicación" : "Mostrar explicación")
            if open {
                VStack(alignment: .leading, spacing: 12) {
                    Text(copy.detail).font(.system(size: 13)).lineSpacing(3).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        if let defense = copy.defense { defenseButton(defense) }
                        Button("Marcar como revisada") { Task { await model.acknowledge(alert.id) } }
                            .buttonStyle(CommandButton(prominent: copy.defense == nil)).disabled(model.busy)
                    }
                }
                .padding(.leading, 30)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
        .animation(.snappy, value: open)
    }

    @ViewBuilder private func statusIcon(_ alert: AgentAlert) -> some View {
        if alert.investigated {
            Circle().strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2.5])).frame(width: 12, height: 12)
        } else {
            Circle().strokeBorder(Color.commandAccent, lineWidth: 2).frame(width: 12, height: 12)
        }
    }

    private var calmState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No hay alertas pendientes", systemImage: "checkmark.shield").font(.system(size: 15, weight: .semibold))
            Text(model.status?.monitoring == true ? "Te avisaremos si se detectan nuevos cambios." : "La vigilancia está en pausa o sin conexión.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Text("La ausencia de alertas no garantiza tu seguridad.")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func stateText(_ alert: AgentAlert) -> String {
        if alert.investigated { return "el investigador ya lo revisó" }
        return model.investigating || model.progress?.active == true ? "el investigador lo está revisando" : "pendiente de revisar"
    }

    // MARK: Report

    private var reportSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Informe del investigador") {
                if let report = model.investigations.first {
                    Text(relativeTime(report.created_at)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if model.investigating {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Revisando la evidencia de tu Mac. Puede tardar hasta dos minutos.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            if let report = model.investigations.first {
                reportCard(report)
            } else if !model.investigating {
                Text("Todavía no hay informes. Pide una revisión más abajo y aquí verás qué encontró el investigador.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.investigations.count > 1 {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(model.investigations.dropFirst()) { report in
                            reportCard(report)
                        }
                    }.padding(.top, 12)
                } label: {
                    Text("Informes anteriores · \(model.investigations.count - 1)").font(.system(size: 13, weight: .medium))
                }
            }
        }
    }

    private func reportCard(_ report: Investigation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            verdict(report.status)
            Text(briefReport(report.status))
                .font(.system(size: 13)).lineSpacing(3).foregroundStyle(.secondary)
                .lineLimit(3)
            DisclosureGroup {
                fullReport(report).padding(.top, 12)
            } label: { technicalLabel }
        }
        .padding(18)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .textSelection(.enabled)
    }

    /// Only translates the recorded outcome; the complete model response stays available below.
    private func briefReport(_ status: String) -> String {
        switch status {
        case "inconclusive":
            "La evidencia no permite llegar a una conclusión. Revisa los detalles y la cobertura antes de decidir."
        case "needs_review":
            "Hay cambios que conviene revisar. Consulta la evidencia y las recomendaciones antes de actuar."
        case "no_finding":
            "Esta revisión no encontró hallazgos en la evidencia consultada. Esto no garantiza tu seguridad."
        default:
            "Revisa la evidencia y las limitaciones del informe antes de tomar decisiones."
        }
    }

    private func fullReport(_ report: Investigation) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(report.title).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(report.summary).font(.system(size: 13)).lineSpacing(3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !report.proposed_actions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recomendaciones").font(.system(size: 13, weight: .semibold))
                    ForEach(Array(report.proposed_actions.enumerated()), id: \.offset) { _, action in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(action.title).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                            Text(action.description).font(.system(size: 13)).lineSpacing(3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            ProposalStatus(action: action, model: model)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            technicalDetails(report)
        }
    }

    private var technicalLabel: some View {
        Text("Ver detalles técnicos").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.commandAccent)
    }

    /// Veredicto en palabras simples; "sin hallazgos" nunca se presenta como "seguro".
    private func verdict(_ status: String) -> some View {
        let (text, symbol, color): (String, String, Color) = switch status {
        case "needs_review": ("Conviene que revises algo", "exclamationmark.circle", .warning)
        case "no_finding": ("No encontró nada preocupante", "checkmark.circle", .info)
        case "inconclusive": ("Sin conclusión todavía", "questionmark.circle", .secondary)
        default: (humanize(status), "circle", .secondary)
        }
        return Label(text, systemImage: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(color)
    }

    // MARK: Ask

    private var askSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Pregunta al investigador") { EmptyView() }
            Text("Cuéntale qué te preocupa. La investigación solo consulta evidencia.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.status?.onboarding_required == true {
                Button("Conectar investigador") { model.setupVisible = true }.buttonStyle(CommandButton())
            } else {
                TextField("Por ejemplo: ¿hay algo raro en mi red?", text: $model.question, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(2...4).font(.system(size: 13)).inputField()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(["Explica las escuchas de red abiertas", "Revisa mis LaunchAgents"], id: \.self) { suggestion in
                        Button(suggestion) { model.question = suggestion }.buttonStyle(CommandButton(prominent: false))
                    }
                }
                Button("Investigar", systemImage: "sparkles") { Task { await model.investigate() } }
                    .buttonStyle(CommandButton())
                    .disabled(model.busy || model.investigating || model.status == nil)
            }
        }
    }

    // MARK: Helpers

    private func sectionHeader<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased()).font(.system(size: 12, weight: .medium)).tracking(1.6).foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
    }

    private func clock(_ text: String) -> String {
        guard let date = parseDate(text) else { return text }
        return Calendar.current.isDateInToday(date) ? date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            : date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// Traduce una señal del agente a un título y una explicación que no requieren conocimientos técnicos.
struct AlertCopy {
    struct Defense { let label: String; let type: String; let port: Int?; var observation: String? = nil }
    let title: String
    let detail: String
    let short: String
    let priority: Int
    let defense: Defense?

    init(_ alert: AgentAlert) {
        let rule = alert.signal.attributes["rule"]?.text
        let change = alert.signal.attributes["change"]?.text
        switch rule {
        case "firewall_weakened":
            title = "El firewall de tu Mac se desactivó"
            detail = "El firewall o el modo sigiloso se apagó. Sin esa protección, otros equipos de la red pueden intentar conectarse a tu Mac con más facilidad. Si no lo apagaste tú, conviene volver a activarlo."
            short = "Firewall"
            priority = 0
            defense = Defense(label: "Activar firewall", type: "enable_firewall", port: nil)
        case "listener_exposed":
            let program = alert.after.attributes["executable"]?.text ?? "Un programa"
            let port = alert.after.attributes["port"]?.int
            let scope = alert.after.attributes["bind_scope"]?.text
            title = port.map { "\(program) abrió el puerto :\($0) a la red" } ?? "\(program) acepta conexiones de la red"
            detail = "\(program) empezó a aceptar conexiones" + (port.map { " en el puerto \($0)" } ?? "")
                + (scope == "any" ? " desde cualquier dispositivo de tu red." : " desde otros dispositivos.")
                + " Es normal en apps de desarrollo o para compartir archivos, pero si no lo reconoces puedes bloquearlo."
            short = program + (port.map { " · puerto \($0)" } ?? "")
            priority = 1
            defense = port.map { Defense(label: "Bloquear :\($0)", type: "block_port", port: $0) }
        case "inbound_connection":
            let program = alert.after.attributes["executable"]?.text ?? "un servicio"
            let port = alert.after.attributes["local_port"]?.int
            let remote = alert.after.attributes["remote_address"]?.text ?? "Un equipo"
            let internet = alert.after.attributes["remote_scope"]?.text == "public"
            if let failures = alert.after.attributes["auth_failures"]?.int {
                title = "\(remote) intenta entrar por SSH (\(failures) fallos)"
                detail = (internet ? "Un equipo de internet" : "Un equipo de tu red local") + " (\(remote)) falló \(failures) veces al iniciar sesión por SSH en este Mac."
                    + " Varios intentos seguidos indican que prueba contraseñas. Bloquéalo y, si no usas SSH, desactiva Inicio de sesión remoto en Ajustes del Sistema."
            } else {
                title = "\(remote) se conectó a \(program)" + (port.map { " (:\($0))" } ?? "")
                detail = (internet ? "Un equipo de internet" : "Un equipo de tu red local") + " (\(remote)) abrió una conexión con \(program)"
                    + (port.map { " en el puerto \($0)" } ?? "") + ". Si no lo reconoces, bloquéalo: se corta su sesión actual y no podrá volver a conectarse."
            }
            short = remote + (port.map { " → :\($0)" } ?? "")
            priority = 0
            defense = Defense(label: "Bloquear equipo", type: "block_peer", port: nil, observation: alert.after.id)
        case "file_changed":
            let name = alert.signal.entity.split(separator: "/").last.map(String.init) ?? alert.signal.entity
            title = switch change {
            case "created": "Se agregó un programa que se abre solo"
            case "deleted": "Se eliminó un archivo de inicio"
            default: "Cambió un archivo que se abre al iniciar"
            }
            let place = alert.signal.attributes["category"]?.text.map { " Está en: \(es($0))." } ?? ""
            detail = "\(name) pertenece a los archivos que hacen que algo se ejecute automáticamente al encender tu Mac o abrir la terminal.\(place) Si instalaste algo hace poco puede ser normal; si no, vale la pena revisarlo."
            short = name
            priority = 2
            defense = nil
        default:
            title = alert.reason
            detail = alert.signal.summary
            short = alert.signal.entity
            priority = 3
            defense = nil
        }
    }
}

private extension JSONValue {
    var text: String? { if case .string(let value) = self { value } else { nil } }
    var int: Int? { if case .number(let value) = self { Int(value) } else { nil } }
}
