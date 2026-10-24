import SwiftUI

@MainActor
@Observable
final class GuardianModel {
    var status: AgentStatus?
    var observations: [AgentObservation] = []
    var investigations: [Investigation] = []
    var error: String?
    var busy = false
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
                throw ClientError(message: "Claude Agent SDK is missing from the agent environment. Run bash scripts/setup-agent.sh from the Guardian repository, then retry.")
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
            investigations = newInvestigations
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
            case "monitoring": status = try await client.setMonitoring(!(status?.monitoring ?? false))
            default:
                let result = try await client.investigate(question)
                investigations.removeAll { $0.id == result.id }
                investigations.insert(result, at: 0)
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
}

@main
struct GuardianApp: App {
    @NSApplicationDelegateAdaptor(GuardianAppDelegate.self) private var appDelegate
    @State private var model = GuardianModel()
    var body: some Scene {
        WindowGroup("Guardian", id: "dashboard") {
            Dashboard(model: model)
                .frame(minWidth: 860, minHeight: 620)
        }
        .defaultSize(width: 1120, height: 760)
        MenuBarExtra("Guardian", systemImage: "shield.lefthalf.filled") {
            GuardianMenu(model: model)
        }
    }
}

struct GuardianMenu: View {
    @Bindable var model: GuardianModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.status == nil ? "Agent disconnected" : "Guardian · Agent connected")
        if let status = model.status {
            Text(status.monitoring ? "Monitoring enabled" : "Monitoring paused")
            Text("\(status.observation_count) recorded observations")
        }
        Divider()
        Button("Open Guardian") { openWindow(id: "dashboard") }
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

private enum Page: String, CaseIterable, Identifiable {
    case overview = "Overview", observations = "Observations", investigations = "Investigations"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "shield.lefthalf.filled"
        case .observations: "waveform.path"
        case .investigations: "text.magnifyingglass"
        }
    }
}

struct Dashboard: View {
    @Bindable var model: GuardianModel
    @State private var selection: Page? = .overview
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                Label("GUARDIAN", systemImage: "shield.lefthalf.filled")
                    .font(.headline).tracking(2).padding(.horizontal, 12).padding(.top, 20)
                Text("Local defensive investigator")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                List(Page.allCases, selection: $selection) { page in
                    Label(page.rawValue, systemImage: page.symbol).tag(page)
                }.listStyle(.sidebar)
                Label(model.status == nil ? "Disconnected" : "Agent connected", systemImage: model.status == nil ? "circle" : "circle.fill")
                    .font(.caption).foregroundStyle(model.status == nil ? Color.secondary : Color.green)
                    .padding(16)
            }.navigationSplitViewColumnWidth(min: 200, ideal: 225)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text((selection ?? .overview).rawValue).font(.largeTitle.bold())
                            Text("Evidence first. Actions stay proposals.").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.busy { ProgressView().controlSize(.small) }
                        Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                            .help("Refresh recorded agent data").disabled(model.busy)
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if model.needsSetup { onboarding }
                    if model.status == nil {
                        Text("Agent disconnected. Connect starts a foreground agent when needed. Previously loaded evidence may remain below.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    switch selection ?? .overview {
                    case .overview: overview
                    case .observations: observationList
                    case .investigations: investigationList
                    }
                }.padding(30).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
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

    private var onboarding: some View {
        GroupBox("Connect your investigator") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Anthropic · Claude Haiku 5.5").font(.headline)
                Text("Add your Anthropic API key to enable investigations. The agent validates the model before connecting. Your key is saved in macOS Keychain after successful validation; a saved key is never displayed.")
                    .font(.callout).foregroundStyle(.secondary)
                SecureField("Anthropic API key (leave blank to use saved key)", text: $model.apiKey)
                    .textFieldStyle(.roundedBorder).disabled(model.busy)
                Toggle("I allow minimized local telemetry metadata to be sent to Anthropic and understand that investigations incur API charges.", isOn: $model.cloudConsent)
                    .toggleStyle(.checkbox)
                Text("Connect may start Guardian’s foreground Python agent. Monitoring collects local evidence; model investigations run only when requested. Quitting stops an agent started by this app; an external agent keeps running.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Connect", systemImage: "link") { Task { await model.connect() } }
                        .buttonStyle(.borderedProminent).disabled(model.busy || !model.cloudConsent)
                    if model.setupVisible && model.status?.onboarding_required == false {
                        Button("Close setup") { model.setupVisible = false; model.apiKey = "" }
                    }
                    if model.busy { ProgressView().controlSize(.small) }
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let status = model.status {
                HStack(spacing: 16) {
                    metric("Monitoring", status.monitoring ? "Enabled" : "Paused", "eye")
                    metric("Observations", "\(status.observation_count)", "waveform.path")
                    metric("Model provider", status.provider, "brain")
                }
                HStack {
                    Text("Last snapshot: \(status.last_scan ?? "Not collected")").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(status.monitoring ? "Pause monitoring" : "Enable monitoring") { Task { await model.perform("monitoring") } }
                    Button("Take local snapshot") { Task { await model.perform("scan") } }.buttonStyle(.borderedProminent)
                }.disabled(model.busy)
                GroupBox("Collection coverage") {
                    VStack(alignment: .leading, spacing: 14) {
                        if status.coverage.isEmpty { Text("No coverage reported.").foregroundStyle(.secondary) }
                        ForEach(status.coverage) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(item.source).fontWeight(.medium); Spacer(); Text(item.status).foregroundStyle(.secondary) }
                                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            investigatorInput
            Text("Local telemetry is untrusted evidence. Missing coverage or no findings does not establish that this Mac is safe. Remediation is never executed by this app.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, _ value: String, _ symbol: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title3.weight(.semibold)).lineLimit(2)
            }.frame(maxWidth: .infinity, minHeight: 68, alignment: .leading).padding(8)
        }
    }

    private var investigatorInput: some View {
        GroupBox("Ask the investigator") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Investigations use recorded local evidence and the agent’s configured model provider.").font(.callout).foregroundStyle(.secondary)
                TextField("What should Guardian look into? (optional)", text: $model.question, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4)
                Button("Investigate recorded evidence", systemImage: "sparkle.magnifyingglass") {
                    selection = .investigations
                    Task { await model.perform("investigate") }
                }.buttonStyle(.borderedProminent).disabled(model.busy || model.status == nil || model.status?.onboarding_required == true)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var observationList: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Latest recorded observations · \(model.observations.count) loaded").font(.callout).foregroundStyle(.secondary)
            if model.observations.isEmpty {
                ContentUnavailableView("No observations loaded", systemImage: "waveform.path", description: Text("Take a local snapshot to collect evidence."))
            }
            ForEach(model.observations) { item in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Label(item.kind, systemImage: "circle.dotted").font(.headline); Spacer(); Text(item.timestamp).font(.caption).foregroundStyle(.secondary) }
                        Text(item.summary)
                        Text(item.entity).font(.system(.caption, design: .monospaced))
                        if !item.attributes.isEmpty {
                            DisclosureGroup("Recorded metadata") {
                                Text(JSONValue.object(item.attributes).display)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Text("\(item.source) · Evidence \(item.id)").font(.caption2).foregroundStyle(.secondary)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
            }
        }
    }

    private var investigationList: some View {
        VStack(alignment: .leading, spacing: 20) {
            investigatorInput
            if model.investigations.isEmpty {
                ContentUnavailableView("No investigations loaded", systemImage: "text.magnifyingglass", description: Text("Run an investigation to review hypotheses and evidence references."))
            }
            ForEach(model.investigations) { finding in
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack { Text(finding.title).font(.title2.bold()); Spacer(); Text(finding.status).font(.caption).foregroundStyle(.secondary) }
                        Text(finding.created_at).font(.caption).foregroundStyle(.secondary)
                        Text(finding.summary)
                        ForEach(Array(finding.hypotheses.enumerated()), id: \.offset) { _, hypothesis in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Hypothesis · \(hypothesis.status)").font(.headline)
                                Text(hypothesis.statement)
                                Text("Evidence: \(hypothesis.evidence_ids.isEmpty ? "None cited" : hypothesis.evidence_ids.joined(separator: ", "))").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                if !hypothesis.counterevidence.isEmpty { Text("Counterevidence: \(hypothesis.counterevidence)").font(.callout) }
                            }
                        }
                        if !finding.steps.isEmpty {
                            Divider()
                            Text("Investigation steps").font(.headline)
                            ForEach(Array(finding.steps.enumerated()), id: \.offset) { index, step in
                                Text("\(index + 1). \(step.tool) — \(step.summary)").font(.callout)
                            }
                        }
                        ForEach(Array(finding.proposed_actions.enumerated()), id: \.offset) { _, action in
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Proposal · \(action.title)", systemImage: "doc.text").font(.headline)
                                Text(action.description)
                                Text("Not applied").font(.caption).foregroundStyle(.secondary)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                        if !finding.limitations.isEmpty {
                            Text("Limitations").font(.headline)
                            ForEach(Array(finding.limitations.enumerated()), id: \.offset) { _, limitation in
                                Label(limitation, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
            }
        }
    }
}
