import SwiftUI
import UserNotifications

// Los valores del protocolo siguen en inglés; solo se traducen al mostrarlos.
private let spanishLabels = [
    "file": "Archivo", "detection": "Señal", "user_launch_files": "Archivos LaunchAgents del usuario",
    "system_launch_agents": "LaunchAgents del sistema", "system_launch_daemons": "LaunchDaemons del sistema",
    "shell_files": "Archivos de inicio del shell", "disabled": "Automatización desactivada",
    "paused": "Vigilancia en pausa", "provider_unavailable": "Proveedor no disponible",
    "cloud_disabled": "Procesamiento en la nube desactivado", "investigating": "Investigando",
    "no_signals": "Sin señales pendientes", "quota_exhausted": "Límite de 24 horas alcanzado",
    "cooldown": "Esperando entre investigaciones", "ready": "Listo para investigar",
    "created": "Creado", "modified": "Modificado", "deleted": "Eliminado",
    "file_changed": "Cambio de archivo", "firewall_weakened": "Protección del firewall reducida",
    "listener_exposed": "Nueva escucha expuesta", "launch_daemon": "LaunchDaemon",
    "inbound_connection": "Conexión entrante de la red", "tcp_connection": "Conexión entrante",
    "tcp_connections": "Conexiones entrantes", "block_peer": "Bloquear equipo", "lan": "Red local",
    "public": "Internet", "inbound": "Entrante",
    "shell_startup": "Inicio del shell", "regular": "Archivo regular", "symlink": "Enlace simbólico", "other": "Otro",

    "inconclusive": "No concluyente", "needs_review": "Requiere revisión", "no_finding": "Sin hallazgos",
    "partial": "Parcial", "available": "Disponible", "unavailable": "No disponible", "denied": "Denegado",
    "unknown": "Desconocido", "unsupported": "No compatible", "error": "Error", "ok": "Correcto",
    "processes": "Procesos", "tcp_listeners": "Escuchas TCP", "user_launch_agents": "LaunchAgents del usuario",
    "service": "Servicio", "evidence_window": "Ventana de evidencia",
    "process": "Proceso", "tcp_listener": "Escucha TCP", "launch_agent": "LaunchAgent",
    "terminate_process": "Forzar terminación", "quarantine_file": "Poner en cuarentena",
    "pending": "Iniciada; verificar resultado", "termination_requested": "Terminación solicitada",
    "quarantined": "En cuarentena", "restored": "Restaurado", "restoring": "Restauración iniciada",
    "recovery_required": "Requiere recuperación manual", "failed": "Falló",
    "application_firewall": "Firewall de aplicaciones", "firewall": "Firewall",
    "search_observations": "Buscar observaciones", "inspect_entity": "Inspeccionar entidad",
    "get_evidence": "Obtener evidencia", "get_coverage": "Leer cobertura", "not_configured": "No configurado",
]
func es(_ value: String) -> String { spanishLabels[value] ?? value }

@MainActor
@Observable
final class GuardianModel {
    var alerts: [AgentAlert] = []
    var alertsLoaded = false
    var showAlerts = false
    var notificationDetail: String?
    private var notificationRequested = false
    private var polling: Task<Void, Never>?
    private var notified = Set(UserDefaults.standard.stringArray(forKey: "guardian.notifiedAlerts") ?? [])
    var status: AgentStatus?
    var observations: [AgentObservation] = []
    var investigations: [Investigation] = []
    var error: String?
    var busy = false
    var investigating = false
    /// Última investigación del agente, incluidas las iniciadas por `serve --watch`.
    var progress: InvestigationProgress?
    /// Referencia visual de procesos; las señales persistentes se mantienen por separado.
    var baseline: Set<String>?
    var baselineDate: Date?
    // Se incrementa al llegar un resultado local para que una actualización anterior en curso no lo descarte.
    private var investigationsVersion = 0
    var question = ""
    var apiKey = ""
    var cloudConsent = UserDefaults.standard.bool(forKey: "guardian.cloudConsent")
    var setupVisible = false
    private var restoreAttempted = false
    private var startupAttempted = false
    var restoringStartup = false
    var needsSetup: Bool {
        !restoringStartup && (setupVisible || status == nil || status?.onboarding_required == true)
    }

    func restoreOnStartup() async {
        guard !startupAttempted else { return }
        startupAttempted = true
        guard cloudConsent, !setupVisible, apiKey.isEmpty else { return }
        restoringStartup = true
        defer { restoringStartup = false }
        do {
            restoreAttempted = true
            guard let saved = try ProviderKeychain.read() else { return }
            await connect(savedKey: saved, restoring: true)
            if error != nil { setupVisible = true }
        } catch {
            self.error = error.localizedDescription
            setupVisible = true
        }
    }

    func connect(savedKey: String? = nil, restoring: Bool = false) async {
        guard !busy else { return }
        if restoring && (setupVisible || !apiKey.isEmpty) { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            guard cloudConsent else { throw ClientError(message: "Confirma el consentimiento para metadatos en la nube e inferencia de pago para conectar.") }
            let enteredKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let key: String
            if let savedKey { key = savedKey }
            else if !enteredKey.isEmpty { key = enteredKey }
            else if let saved = try ProviderKeychain.read() { key = saved }
            else { throw ClientError(message: "Introduce tu clave de API de Anthropic.") }
            var current = try? await client.status()
            if current == nil {
                try LocalRuntime.shared.start()
                let readinessDeadline = Date().addingTimeInterval(10)
                while Date() < readinessDeadline {
                    try await Task.sleep(for: .milliseconds(250))
                    current = try? await client.status()
                    if current != nil { break }
                }
            }
            guard let current else { throw ClientError(message: "El agente no estuvo listo. Reinicia Arkangel y vuelve a pulsar Conectar.") }
            status = current
            guard current.sdk_available != false else {
                throw ClientError(message: "La instalación del agente está incompleta. Reinstala Arkangel; si usas el entorno de desarrollo, vuelve a prepararlo.")
            }
            // An already-running agent may hold a different key than this Mac's Keychain.
            diagnosticLogger.info("Enviando la clave al agente; restauración=\(restoring, privacy: .public)")
            let configuredStatus = try await client.configure(key)
            diagnosticLogger.info("Proveedor configurado en el agente.")
            if !restoring {
                setupVisible = true
                if key != ProviderKeychain.demoKey { try ProviderKeychain.save(key) }
            }
            status = configuredStatus
            UserDefaults.standard.set(true, forKey: "guardian.localMonitoring")
            if configuredStatus.monitoring { await requestNotifications() }
            if !restoring { apiKey = "" }
            UserDefaults.standard.set(true, forKey: "guardian.cloudConsent")
            setupVisible = false
            restoreAttempted = false
        } catch { self.error = error.localizedDescription }
    }
    let client = AgentClient()

    // El sondeo de fondo no toca `busy`: alternarlo cada 5 s deshabilitaba todos los botones y hacía parpadear la interfaz.
    private var refreshing = false
    func refresh() async {
        guard !busy, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let version = investigationsVersion
        do {
            let newStatus = try await client.status()
            let newObservations = try await client.observations()
            let newInvestigations = try await client.investigations()
            var newAlerts: [AgentAlert] = []
            if newStatus.alerts != nil { newAlerts = try await client.alerts() }
            status = newStatus
            if newStatus.onboarding_required == false { restoreAttempted = false }
            if newStatus.onboarding_required == true && cloudConsent && !restoreAttempted && !setupVisible && apiKey.isEmpty {
                restoreAttempted = true
                if let saved = try ProviderKeychain.read() {
                    status = try await client.configure(saved)
                }
            }
            observations = newObservations
            if baseline == nil && !observations.isEmpty { setBaseline() }
            alerts = newAlerts
            alertsLoaded = true
            if newStatus.monitoring {
                await requestNotifications()
                await notifyNewAlerts()
            }
            if version == investigationsVersion { investigations = newInvestigations }
            error = nil
        } catch {
            status = nil
            self.error = error.localizedDescription
        }
    }

    func defend(_ action: String, port: Int? = nil, observation: String? = nil, address: String? = nil) async {
        guard !busy else { return }
        busy = true
        do {
            status = try await client.applyDefense(action, port: port, observation: observation, address: address)
            error = nil
        } catch { self.error = error.localizedDescription }
        busy = false
    }

    /// La IP solo se lee de la evidencia local de una conexión entrante; el servicio vuelve a validarla.
    func peerBlocked(_ observation: String?) -> Bool {
        guard let observation else { return false }
        let item = alerts.first { $0.after.id == observation }?.after ?? observations.first { $0.id == observation }
        guard case .string(let address)? = item?.attributes["remote_address"] else { return false }
        return status?.blocked_peers?.contains(address) == true
    }

    func protect(_ operation: String, params: [String: any Sendable]) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            status = try await client.protection(operation, params: params)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func perform(_ operation: String) async {
        guard !busy else { return }
        busy = true
        do {
            switch operation {
            case "scan": status = try await client.scan()
            default:
                status = try await client.setMonitoring(!(status?.monitoring ?? false))
                if status?.monitoring == true { await requestNotifications() }
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
            busy = false
            return
        }
        busy = false
        await refresh()
    }

    func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            if UserDefaults.standard.bool(forKey: "guardian.localMonitoring") {
                await self?.startLocalMonitoring(resume: false)
            }
            await self?.restoreOnStartup()
            while !Task.isCancelled {
                await self?.refresh()
                await self?.pollProgress()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    func stopPolling() { polling?.cancel(); polling = nil }

    func startLocalMonitoring(resume: Bool = true) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if (try? await client.status()) == nil { try LocalRuntime.shared.start() }
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let current = try? await client.status() {
                    status = current
                    UserDefaults.standard.set(true, forKey: "guardian.localMonitoring")
                    if resume && !current.monitoring { status = try await client.setMonitoring(true) }
                    if status?.monitoring == true { await requestNotifications() }
                    error = nil
                    return
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw ClientError(message: "El agente local no estuvo listo. Reinicia Arkangel y vuelve a intentarlo.")
        } catch { self.error = error.localizedDescription }
    }

    func setAutomation(_ enabled: Bool) async {
        do { status = try await client.setAutomation(enabled); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func acknowledge(_ id: String) async {
        do { status = try await client.acknowledge(id); await refresh() }
        catch { self.error = error.localizedDescription }
    }

    func requestNotifications() async {
        guard !notificationRequested else { return }
        notificationRequested = true
        guard Bundle.main.bundleIdentifier != nil else {
            notificationDetail = "Las notificaciones de macOS no están disponibles en esta versión. Revisa las señales desde la barra de menús."
            return
        }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            notificationDetail = granted ? nil : "Notificaciones desactivadas; consulta las señales en la barra de menús."
        } catch {
            notificationDetail = "No se pudieron activar las notificaciones; las señales siguen en la barra de menús."
        }
    }

    private func notifyNewAlerts() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let retained = Set(alerts.map(\.id))
        notified.formIntersection(retained)
        let fresh = alerts.filter { !$0.acknowledged && !notified.contains($0.id) }
        guard !fresh.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let canNotify = await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
            }
        }
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = "Guardian detectó cambios que requieren revisión"
        content.body = "Hay \(fresh.count) señales nuevas. Abre la app para revisar su evidencia."
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: "guardian-alerts", content: content, trigger: nil))
            notified.formUnion(fresh.map(\.id))
            UserDefaults.standard.set(Array(notified), forKey: "guardian.notifiedAlerts")
        } catch { notificationDetail = "No se pudo enviar el aviso; consulta las señales en la app." }
    }

    var detections: [AgentObservation] {
        let baseline = baseline ?? []
        var seen = Set<String>()
        return alerts.filter { !$0.acknowledged }.map(\.signal) + observations.filter {
            $0.kind == "process" && !baseline.contains($0.key) && seen.insert($0.key).inserted
        }
    }

    func setBaseline() {
        baseline = Set(observations.map(\.key))
        baselineDate = Date()
    }

    func pollProgress() async {
        guard let next = try? await client.progress() else { return }
        let finished = progress?.active == true && !next.active
        progress = next
        if finished { await refresh() }
    }

    // Separado de busy para que el estado se siga actualizando durante una solicitud al modelo.
    func investigate() async {
        guard !investigating else { return }
        investigating = true
        defer { investigating = false }
        do {
            let result = try await client.investigate(question)
            investigations.removeAll { $0.id == result.id }
            investigations.insert(result, at: 0)
            investigationsVersion += 1
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }
}

@main
struct GuardianApp: App {
    @NSApplicationDelegateAdaptor(GuardianAppDelegate.self) private var appDelegate
    private var model: GuardianModel { appDelegate.model }
    var body: some Scene {
        Window("Arkangel", id: "dashboard") {
            Dashboard(model: model)
                .frame(minWidth: 860, minHeight: 620)
        }
        .defaultSize(width: 1120, height: 760)
        MenuBarExtra("Arkangel", systemImage: (model.status?.alerts?.unacknowledged ?? 0) > 0 ? "exclamationmark.shield" : model.status == nil ? "shield.slash" : "shield.lefthalf.filled") {
            GuardianMenu(model: model, showDashboard: appDelegate.showDashboard)
        }
    }
}

struct GuardianMenu: View {
    @Bindable var model: GuardianModel
    let showDashboard: () -> Void
    @Environment(\.openWindow) private var openWindow

    private func openDashboard() {
        openWindow(id: "dashboard")
        showDashboard()
    }

    var body: some View {
        Text(model.status == nil ? "Agente desconectado" : "Arkangel · Agente conectado")
        if let status = model.status {
            Text(status.monitoring ? "Monitoreo activado" : "Monitoreo en pausa")
            Text("\(status.observation_count) observaciones registradas")
            Text("\(status.alerts?.unacknowledged ?? 0) señales sin revisar")
        }
        Divider()
        Button("Abrir Arkangel") { openDashboard() }
        Button("Revisar señales") { model.showAlerts = true; openDashboard() }
        Button("Configurar proveedor…") {
            model.setupVisible = true
            openDashboard()
        }
        Button("Abrir registros de diagnóstico…") {
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Arkangel")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if !NSWorkspace.shared.open(directory) {
                    model.error = "No se pudo abrir la carpeta de registros de diagnóstico."
                    openDashboard()
                }
            } catch {
                model.error = "No se pudo abrir la carpeta de registros de diagnóstico."
                openDashboard()
            }
        }
        Button("Actualizar estado") { Task { await model.refresh() } }
            .disabled(model.busy)
        Button("Tomar instantánea local") { Task { await model.perform("scan") } }
            .disabled(model.busy || model.status == nil)
        Button(model.status?.monitoring == true ? "Pausar monitoreo" : "Activar monitoreo") {
            Task { await model.perform("monitoring") }
        }.disabled(model.busy || model.status == nil)
        Divider()
        Button(LocalRuntime.shared.ownsAgent ? "Salir de la app y su agente" : "Salir de la app (el agente externo sigue activo)") { NSApplication.shared.terminate(nil) }
    }
}
