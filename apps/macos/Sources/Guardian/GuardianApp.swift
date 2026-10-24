import SwiftUI

// Los valores del protocolo siguen en inglés; solo se traducen al mostrarlos.
private let spanishLabels = [
    "inconclusive": "No concluyente", "needs_review": "Requiere revisión", "no_finding": "Sin hallazgos",
    "partial": "Parcial", "available": "Disponible", "unavailable": "No disponible", "denied": "Denegado",
    "unknown": "Desconocido", "unsupported": "No compatible", "error": "Error", "ok": "Correcto",
    "processes": "Procesos", "tcp_listeners": "Escuchas TCP", "user_launch_agents": "LaunchAgents del usuario",
    "service": "Servicio", "evidence_window": "Ventana de evidencia",
    "process": "Proceso", "tcp_listener": "Escucha TCP", "launch_agent": "LaunchAgent",
    "application_firewall": "Firewall de aplicaciones", "firewall": "Firewall",
    "search_observations": "Buscar observaciones", "inspect_entity": "Inspeccionar entidad",
    "get_evidence": "Obtener evidencia", "get_coverage": "Leer cobertura", "not_configured": "No configurado",
]
func es(_ value: String) -> String { spanishLabels[value] ?? value }

@MainActor
@Observable
final class GuardianModel {
    var status: AgentStatus?
    var observations: [AgentObservation] = []
    var investigations: [Investigation] = []
    var error: String?
    var busy = false
    var investigating = false
    /// Última investigación del agente, incluidas las iniciadas por `serve --watch`.
    var progress: InvestigationProgress?
    /// Entidades presentes cuando la vista En vivo vio evidencia por primera vez; cualquier otra es una detección.
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
            guard let current else { throw ClientError(message: "El agente no estuvo listo. Revisa la configuración de Python en el README del repositorio y vuelve a pulsar Conectar.") }
            status = current
            guard current.sdk_available != false else {
                throw ClientError(message: "Falta Claude Agent SDK en el entorno del agente. Ejecuta bash scripts/setup-agent.sh desde el repositorio de Arkangel y vuelve a intentarlo.")
            }
            let configuredStatus: AgentStatus
            if restoring && current.onboarding_required == false {
                configuredStatus = current
            } else {
                configuredStatus = try await client.configure(key)
            }
            if !restoring {
                setupVisible = true
                try ProviderKeychain.save(key)
            }
            status = configuredStatus
            if !restoring { apiKey = "" }
            UserDefaults.standard.set(true, forKey: "guardian.cloudConsent")
            setupVisible = false
            restoreAttempted = false
        } catch { self.error = error.localizedDescription }
    }
    let client = AgentClient()

    func refresh() async {
        guard !busy, !setupVisible, apiKey.isEmpty else { return }
        busy = true
        defer { busy = false }
        let version = investigationsVersion
        do {
            let newStatus = try await client.status()
            let newObservations = try await client.observations()
            let newInvestigations = try await client.investigations()
            status = newStatus
            if newStatus.onboarding_required == false { restoreAttempted = false }
            if newStatus.onboarding_required == true && cloudConsent && !restoreAttempted {
                restoreAttempted = true
                if let saved = try ProviderKeychain.read() {
                    status = try await client.configure(saved)
                }
            }
            observations = newObservations
            if version == investigationsVersion { investigations = newInvestigations }
            error = nil
        } catch {
            status = nil
            self.error = error.localizedDescription
        }
    }

    func defend(_ action: String, port: Int? = nil) async {
        guard !busy else { return }
        busy = true
        do {
            status = try await client.applyDefense(action, port: port)
            error = nil
        } catch { self.error = error.localizedDescription }
        busy = false
    }

    func perform(_ operation: String) async {
        guard !busy else { return }
        busy = true
        do {
            switch operation {
            case "scan": status = try await client.scan()
            default: status = try await client.setMonitoring(!(status?.monitoring ?? false))
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

    var detections: [AgentObservation] {
        guard let baseline else { return [] }
        var seen = Set<String>()
        return observations.filter { !baseline.contains($0.key) && seen.insert($0.key).inserted }
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
    @State private var model = GuardianModel()
    var body: some Scene {
        WindowGroup("Arkangel", id: "dashboard") {
            Dashboard(model: model)
                .frame(minWidth: 860, minHeight: 620)
        }
        .defaultSize(width: 1120, height: 760)
        MenuBarExtra("Arkangel", systemImage: model.status == nil ? "shield.slash" : "shield.lefthalf.filled") {
            GuardianMenu(model: model)
        }
    }
}

struct GuardianMenu: View {
    @Bindable var model: GuardianModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.status == nil ? "Agente desconectado" : "Arkangel · Agente conectado")
        if let status = model.status {
            Text(status.monitoring ? "Monitoreo activado" : "Monitoreo en pausa")
            Text("\(status.observation_count) observaciones registradas")
        }
        Divider()
        Button("Abrir Arkangel") { openWindow(id: "dashboard") }
        Button("Configurar proveedor…") {
            model.setupVisible = true
            openWindow(id: "dashboard")
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
