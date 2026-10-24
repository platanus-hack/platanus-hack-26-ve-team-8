import Foundation
import Darwin

struct Coverage: Decodable, Identifiable, Sendable {
    var id: String { source }
    let source: String
    let status: String
    let detail: String
}
struct AgentStatus: Decodable, Sendable {
    let monitoring: Bool
    let provider: String
    let coverage: [Coverage]
    let observation_count: Int
    let last_scan: String?
    let onboarding_required: Bool?
    let sdk_available: Bool?
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
        case .string(let text): text
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
    func configure(_ key: String) async throws -> AgentStatus {
        try await request("provider.configure", params: ["api_key": key, "allow_cloud": true])
    }
    func scan() async throws -> AgentStatus { try await request("scan") }
    func setMonitoring(_ enabled: Bool) async throws -> AgentStatus {
        try await request("monitoring.set", params: ["enabled": enabled])
    }
    func observations() async throws -> [AgentObservation] {
        let result: Items<AgentObservation> = try await request("observations", params: ["limit": 500])
        return result.items
    }
    func investigations() async throws -> [Investigation] {
        let result: Items<Investigation> = try await request("investigations")
        return result.items
    }
    func investigate(_ question: String) async throws -> Investigation {
        try await request("investigate", params: ["question": question])
    }

    private func request<T: Decodable & Sendable>(_ method: String, params: [String: any Sendable] = [:]) async throws -> T {
        let socketPath = path
        return try await Task.detached(priority: .utility) {
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw ClientError(message: "Could not open local socket.") }
            defer { close(descriptor) }
            var noSignal: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
            // Nonblocking IO shares one deadline, including connection and response.
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
            // A scan may wait for an in-flight monitoring scan; each runs two 10s collectors.
            let seconds: TimeInterval = switch method {
            case "investigate": 120
            case "scan": 60
            case "provider.configure": 30
            default: 10
            }
            let deadline = Date().addingTimeInterval(seconds)
            func ready(_ events: Int16) throws {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw ClientError(message: "Agent request timed out.") }
                var descriptorState = pollfd(fd: descriptor, events: events, revents: 0)
                let outcome = poll(&descriptorState, 1, Int32(min(remaining * 1000, 120_000)))
                guard outcome > 0 else { throw ClientError(message: "Agent request timed out or was interrupted.") }
            }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(socketPath.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw ClientError(message: "Socket path is too long.")
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
                guard errno == EINPROGRESS else { throw ClientError(message: "Agent disconnected. Start the local agent separately.") }
                try ready(Int16(POLLOUT))
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else {
                    throw ClientError(message: "Could not connect to the local agent.")
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
                    guard count > 0 else { throw ClientError(message: "Could not send request to agent.") }
                    offset += count
                }
            }
            var response = Data()
            var chunk = [UInt8](repeating: 0, count: 8192)
            while true {
                try ready(Int16(POLLIN))
                let count = recv(descriptor, &chunk, chunk.count, 0)
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard count > 0 else { throw ClientError(message: "Agent closed the connection before replying.") }
                response.append(contentsOf: chunk.prefix(count))
                guard response.count <= 8 * 1024 * 1024 else { throw ClientError(message: "Agent response exceeds the 8 MB limit.") }
                if let newline = response.firstIndex(of: 10) {
                    let envelope = try JSONDecoder().decode(Envelope<T>.self, from: response[..<newline])
                    guard envelope.id == requestID else { throw ClientError(message: "Agent response ID did not match.") }
                    if let error = envelope.error { throw ClientError(message: error.message) }
                    guard let result = envelope.result else { throw ClientError(message: "Agent returned no result.") }
                    return result
                }
            }
        }.value
    }
}
