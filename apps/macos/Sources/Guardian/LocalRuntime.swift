import AppKit
import Security
import UserNotifications

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
            throw ClientError(message: "No se pudo leer la clave guardada en el Llavero de macOS.")
        }
        return key
    }

    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw ClientError(message: "Proveedor conectado, pero el Llavero de macOS no pudo guardar la clave. Repite la configuración.")
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw ClientError(message: "Proveedor conectado, pero el Llavero de macOS no pudo guardar la clave. Repite la configuración.")
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
            // El código fuente está en apps/macos/Sources/Guardian/LocalRuntime.swift.
            root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }
        let python = root.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw ClientError(message: "Falta el entorno de Python. En el repositorio de Arkangel ejecuta: bash scripts/setup-agent.sh. Define GUARDIAN_REPO_ROOT si se movió este ejecutable. La app no instala dependencias.")
        }
        let child = Process()
        child.executableURL = python
        child.arguments = ["-m", "guardian", "serve", "--watch"]
        child.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        // Las credenciales del proveedor viajan solo en la solicitud configure del socket.
        for name in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "GUARDIAN_MODEL_KEY", "GUARDIAN_ALLOW_CLOUD", "GUARDIAN_MODEL_ENDPOINT", "GUARDIAN_MODEL", "GUARDIAN_PROVIDER"] {
            environment.removeValue(forKey: name)
        }
        environment["PYTHONPATH"] = root.appendingPathComponent("services/agent/src").path
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        do { try child.run() } catch {
            throw ClientError(message: "No se pudo iniciar Arkangel. Revisa GUARDIAN_REPO_ROOT y el entorno de Python del repositorio.")
        }
        process = child
    }

    func stopOwnedAgent() {
        if let process, process.isRunning { process.terminate() }
        process = nil
    }
}

@MainActor
final class GuardianAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSWindowDelegate {
    let model = GuardianModel()
    private weak var dashboardWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
        dashboardWindow = NSApplication.shared.windows.first { $0.canBecomeMain }
        dashboardWindow?.delegate = self
        model.startPolling()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if dashboardWindow == nil {
            dashboardWindow = NSApplication.shared.windows.first { $0.canBecomeMain }
            dashboardWindow?.delegate = self
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            self.model.showAlerts = true
            self.dashboardWindow?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopPolling()
        LocalRuntime.shared.stopOwnedAgent()
    }
}
