import AppKit
import Security

struct ProviderKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.guardian.anthropic",
         kSecAttrAccount as String: "provider-api-key"]
    }

    static func read() throws -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw ClientError(message: "Could not read the saved key from macOS Keychain.")
        }
        return key
    }

    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw ClientError(message: "Provider connected, but macOS Keychain could not save the key. Retry setup.")
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw ClientError(message: "Provider connected, but macOS Keychain could not save the key. Retry setup.")
        }
    }
}

@MainActor
final class LocalRuntime {
    static let shared = LocalRuntime()
    private var process: Process?
    var ownsAgent: Bool { process?.isRunning == true }

    func start() throws {
        if ownsAgent { return }
        let root: URL
        if let configured = ProcessInfo.processInfo.environment["GUARDIAN_REPO_ROOT"] {
            root = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            // Source lives at apps/macos/Sources/Guardian/LocalRuntime.swift.
            root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }
        let python = root.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw ClientError(message: "Python environment missing. In the Arkangel repository run: bash scripts/setup-agent.sh. Set GUARDIAN_REPO_ROOT if this executable was moved. The app does not install dependencies.")
        }
        let child = Process()
        child.executableURL = python
        child.arguments = ["-m", "guardian", "serve", "--watch"]
        child.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        // Provider credentials travel only in the socket configure request.
        for name in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "GUARDIAN_MODEL_KEY", "GUARDIAN_ALLOW_CLOUD", "GUARDIAN_MODEL_ENDPOINT", "GUARDIAN_MODEL", "GUARDIAN_PROVIDER"] {
            environment.removeValue(forKey: name)
        }
        environment["PYTHONPATH"] = root.appendingPathComponent("services/agent/src").path
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        do { try child.run() } catch {
            throw ClientError(message: "Could not start Arkangel. Check GUARDIAN_REPO_ROOT and the repository Python environment.")
        }
        process = child
    }

    func stopOwnedAgent() {
        if let process, process.isRunning { process.terminate() }
        process = nil
    }
}

@MainActor
final class GuardianAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        LocalRuntime.shared.stopOwnedAgent()
    }
}
