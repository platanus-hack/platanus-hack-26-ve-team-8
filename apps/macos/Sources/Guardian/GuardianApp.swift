import SwiftUI

@MainActor
@Observable
final class GuardianModel {
    var status: AgentStatus?
    var observations: [AgentObservation] = []
    var investigations: [Investigation] = []
    var error: String?
    var busy = false
    var investigating = false
    /// Latest agent-side investigation, including ones started by `serve --watch`.
    var progress: InvestigationProgress?
    /// Entities present when the Live view first saw evidence; anything else is a detection.
    var baseline: Set<String>?
    var baselineDate: Date?
    // Bumped when a local investigation result lands so an older in-flight refresh cannot drop it.
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
            guard cloudConsent else { throw ClientError(message: "Confirm cloud metadata and paid inference consent to connect.") }
            let enteredKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let key: String
            if let savedKey { key = savedKey }
            else if !enteredKey.isEmpty { key = enteredKey }
            else if let saved = try ProviderKeychain.read() { key = saved }
            else { throw ClientError(message: "Enter your Anthropic API key.") }
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
            guard let current else { throw ClientError(message: "Agent did not become ready. Check the Python setup in the repository README, then retry Connect.") }
            status = current
            guard current.sdk_available != false else {
                throw ClientError(message: "Claude Agent SDK is missing from the agent environment. Run bash scripts/setup-agent.sh from the Arkangel repository, then retry.")
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

    // Separate from busy so status refresh continues during a model request.
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
        Text(model.status == nil ? "Agent disconnected" : "Arkangel · Agent connected")
        if let status = model.status {
            Text(status.monitoring ? "Monitoring enabled" : "Monitoring paused")
            Text("\(status.observation_count) recorded observations")
        }
        Divider()
        Button("Open Arkangel") { openWindow(id: "dashboard") }
        Button("Provider setup…") {
            model.setupVisible = true
            openWindow(id: "dashboard")
        }
        Button("Refresh status") { Task { await model.refresh() } }
            .disabled(model.busy)
        Button("Take local snapshot") { Task { await model.perform("scan") } }
            .disabled(model.busy || model.status == nil)
        Button(model.status?.monitoring == true ? "Pause monitoring" : "Enable monitoring") {
            Task { await model.perform("monitoring") }
        }.disabled(model.busy || model.status == nil)
        Divider()
        Button(LocalRuntime.shared.ownsAgent ? "Quit app and its agent" : "Quit app (external agent keeps running)") { NSApplication.shared.terminate(nil) }
    }
}
