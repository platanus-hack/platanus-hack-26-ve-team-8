import Foundation
import Darwin

struct Coverage: Decodable, Identifiable, Sendable {
    var id: String { source }
    let source: String
    let status: String
    let detail: String
}
struct AgentStatus: Decodable, Sendable {
    let protection: ProtectionState?
    let automation: AutomationState?
    let alerts: AlertCounts?
    let last_file_scan: String?
    let monitoring: Bool
    let provider: String
    let coverage: [Coverage]
    let observation_count: Int
    let last_scan: String?
    let onboarding_required: Bool?
    let sdk_available: Bool?
    let firewall: FirewallState?
    let exposed: [ExposedPort]?
    let blocked_ports: [Int]?
    let blocked_peers: [String]?
}
struct ProtectionState: Decodable, Sendable {
    let enabled: Bool
    let remaining: Int
    let events: [ResponseEvent]
}
struct ResponseEvent: Decodable, Identifiable, Sendable {
    let id: String
    let action: String
    let path: String
    let status: String
    let detail: String
    let created_at: String
}
struct AutomationState: Decodable, Sendable {
    let enabled: Bool
    let reason: String
    let remaining: Int
    let cooldown_seconds: Int
}
struct AlertCounts: Decodable, Sendable {
    let unacknowledged: Int
    let pending: Int
}
struct AgentAlert: Decodable, Identifiable, Sendable {
    let id: String
    let created_at: String
    let reason: String
    let signal: AgentObservation
    let before: AgentObservation?
    let after: AgentObservation
    let acknowledged: Bool
    let investigated: Bool
}
struct FirewallState: Decodable, Sendable {
    let firewall_enabled: Bool
    let stealth_mode: Bool
}
struct ExposedPort: Decodable, Identifiable, Sendable {
    var id: String { "\(port)-\(executable)-\(bind_scope)" }
    let port: Int
    let executable: String
    let bind_scope: String
    let blocked: Bool
}
struct DefenseAction: Decodable, Sendable {
    let type: String
    let port: Int?
    let observation_id: String?
    let verdict: String?
}
enum JSONValue: Decodable, Sendable {
    case string(String), number(Double), boolean(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let text = try? value.decode(String.self) { self = .string(text) }
        else if let flag = try? value.decode(Bool.self) { self = .boolean(flag) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let object = try? value.decode([String: JSONValue].self) { self = .object(object) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }

    var display: String {
        switch self {
        case .string(let text): es(text)
        case .number(let number): String(number)
        case .boolean(let flag): String(flag)
        case .null: "null"
        case .array(let values): "[" + values.map(\.display).joined(separator: ", ") + "]"
        case .object(let values): values.keys.sorted().map { "\($0): \(values[$0]!.display)" }.joined(separator: "\n")
        }
    }
}

struct AgentObservation: Decodable, Identifiable, Sendable {
    let id: String
    let timestamp: String
    let kind: String
    let source: String
    let entity: String
    let summary: String
    let attributes: [String: JSONValue]
    var key: String { kind + "|" + entity }
}
struct Hypothesis: Decodable, Sendable {
    let statement: String
    let status: String
    let evidence_ids: [String]
    let counterevidence: String
}
struct InvestigationStep: Decodable, Sendable {
    let tool: String
    let summary: String
}
struct ProposedAction: Decodable, Sendable {
    let title: String
    let description: String
    let action: DefenseAction?
}
struct Investigation: Decodable, Identifiable, Sendable {
    let id: String
    let created_at: String
    let status: String
    let title: String
    let summary: String
    let hypotheses: [Hypothesis]
    let steps: [InvestigationStep]
    let proposed_actions: [ProposedAction]
    let limitations: [String]
}
struct ProgressStep: Decodable, Sendable {
    let tool: String
    let summary: String
    let evidence_ids: [String]
}
struct InvestigationProgress: Decodable, Sendable {
    let active: Bool
    let started_at: String?
    let steps: [ProgressStep]
}
private struct Items<T: Decodable & Sendable>: Decodable, Sendable { let items: [T] }
private struct Envelope<T: Decodable>: Decodable {
    let id: String
    let result: T?
    let error: AgentError?
}
private struct AgentError: Decodable { let message: String }
struct ClientError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct AgentClient: Sendable {
    let path = ProcessInfo.processInfo.environment["GUARDIAN_SOCKET"] ?? "/tmp/guardian-\(getuid())/agent.sock"

    func status() async throws -> AgentStatus { try await request("status") }
    func protection(_ operation: String, params: [String: any Sendable]) async throws -> AgentStatus {
        try await request("protection." + operation, params: params)
    }
    func configure(_ key: String) async throws -> AgentStatus {
        try await request("provider.configure", params: ["api_key": key, "allow_cloud": true])
    }
    func scan() async throws -> AgentStatus { try await request("scan") }
    func setMonitoring(_ enabled: Bool) async throws -> AgentStatus {
        try await request("monitoring.set", params: ["enabled": enabled])
    }
    func alerts() async throws -> [AgentAlert] {
        let result: Items<AgentAlert> = try await request("alerts", params: ["limit": 500])
        return result.items
    }
    func acknowledge(_ id: String) async throws -> AgentStatus {
        try await request("alerts.acknowledge", params: ["id": id])
    }
    func setAutomation(_ enabled: Bool) async throws -> AgentStatus {
        try await request("automation.set", params: ["enabled": enabled, "consent": enabled])
    }
    func observations() async throws -> [AgentObservation] {
        let result: Items<AgentObservation> = try await request("observations", params: ["limit": 500])
        return result.items
    }
    func investigations() async throws -> [Investigation] {
        let result: Items<Investigation> = try await request("investigations")
        return result.items
    }
    func progress() async throws -> InvestigationProgress { try await request("investigation.progress") }
    func investigate(_ question: String) async throws -> Investigation {
        try await request("investigate", params: ["question": question])
    }
    func applyDefense(_ action: String, port: Int?, observation: String? = nil, address: String? = nil) async throws -> AgentStatus {
        var params: [String: any Sendable] = ["action": action]
        if let port { params["port"] = port }
        if let observation { params["observation_id"] = observation }
        if let address { params["address"] = address }
        return try await request("defense.apply", params: params)
    }

    private func request<T: Decodable & Sendable>(_ method: String, params: [String: any Sendable] = [:]) async throws -> T {
        let socketPath = path
        return try await Task.detached(priority: .utility) {
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw ClientError(message: "No se pudo abrir el socket local.") }
            defer { close(descriptor) }
            var noSignal: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
            // La E/S no bloqueante comparte un único plazo, incluidas la conexión y la respuesta.
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
            // Un escaneo puede esperar a uno de monitoreo en curso; cada uno ejecuta dos recolectores de 10 s.
            // defense.apply espera al usuario en el aviso de administrador de macOS.
            let seconds: TimeInterval = switch method {
            case "investigate": 120
            case "defense.apply": 150
            case "scan": 60
            case "protection.restore", "protection.set": 60
            case "provider.configure": 30
            default: 10
            }
            let deadline = Date().addingTimeInterval(seconds)
            func ready(_ events: Int16) throws {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw ClientError(message: "La solicitud al agente agotó el tiempo.") }
                var descriptorState = pollfd(fd: descriptor, events: events, revents: 0)
                let outcome = poll(&descriptorState, 1, Int32(min(remaining * 1000, 120_000)))
                guard outcome > 0 else { throw ClientError(message: "La solicitud al agente agotó el tiempo o fue interrumpida.") }
            }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(socketPath.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw ClientError(message: "La ruta del socket es demasiado larga.")
            }
            withUnsafeMutableBytes(of: &address.sun_path) { target in
                target.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
            }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connected != 0 {
                guard errno == EINPROGRESS else { throw ClientError(message: "Agente desconectado. Inicia el agente local por separado.") }
                try ready(Int16(POLLOUT))
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else {
                    throw ClientError(message: "No se pudo conectar con el agente local.")
                }
            }
            let requestID = UUID().uuidString
            var payload = try JSONSerialization.data(withJSONObject: ["id": requestID, "method": method, "params": params])
            payload.append(10)
            try payload.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    try ready(Int16(POLLOUT))
                    let count = send(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                    if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                    guard count > 0 else { throw ClientError(message: "No se pudo enviar la solicitud al agente.") }
                    offset += count
                }
            }
            var response = Data()
            var chunk = [UInt8](repeating: 0, count: 8192)
            while true {
                try ready(Int16(POLLIN))
                let count = recv(descriptor, &chunk, chunk.count, 0)
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard count > 0 else { throw ClientError(message: "El agente cerró la conexión antes de responder.") }
                response.append(contentsOf: chunk.prefix(count))
                guard response.count <= 8 * 1024 * 1024 else { throw ClientError(message: "La respuesta del agente supera el límite de 8 MB.") }
                if let newline = response.firstIndex(of: 10) {
                    let envelope = try JSONDecoder().decode(Envelope<T>.self, from: response[..<newline])
                    guard envelope.id == requestID else { throw ClientError(message: "El ID de la respuesta del agente no coincide.") }
                    if let error = envelope.error { throw ClientError(message: error.message) }
                    guard let result = envelope.result else { throw ClientError(message: "El agente no devolvió ningún resultado.") }
                    return result
                }
            }
        }.value
    }
}
