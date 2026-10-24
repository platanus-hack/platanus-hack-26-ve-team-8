import AppKit
import Security
import OSLog
import UserNotifications

let diagnosticLogger = Logger(subsystem: "local.guardian.app", category: "diagnostics")

struct ProviderKeychain {
    // ponytail: demo-only key shipped inside the app binary; anyone with the .app can extract it. Remove for real releases.
    static let demoKey = "PASTE_ANTHROPIC_API_KEY_HERE"

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
        diagnosticLogger.info("Lectura del Llavero; estado=\(status, privacy: .public)")
        // Sin clave propia guardada, se usa la clave de demostración incluida en la app.
        if status == errSecItemNotFound { return demoKey }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw ClientError(message: "No se pudo leer la clave guardada en el Llavero de macOS.")
        }
        return key
    }

    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        diagnosticLogger.info("Actualización del Llavero; estado=\(updated, privacy: .public)")
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw ClientError(message: "Proveedor conectado, pero el Llavero de macOS no pudo guardar la clave. Repite la configuración.")
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        diagnosticLogger.info("Guardado del Llavero; estado=\(added, privacy: .public)")
        guard added == errSecSuccess else {
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
        let bundled = Bundle.main.bundleURL.pathExtension == "app"
        let root: URL
        let python: URL
        if bundled {
            guard let resources = Bundle.main.resourceURL else {
                throw ClientError(message: "La instalación de Arkangel está incompleta. Reinstala la app.")
            }
            root = resources.appendingPathComponent("Python", isDirectory: true)
            python = root.appendingPathComponent("bin/python3")
        } else {
            root = ProcessInfo.processInfo.environment["GUARDIAN_REPO_ROOT"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            python = root.appendingPathComponent(".venv/bin/python")
        }
        diagnosticLogger.info("Inicio del agente; incluido=\(bundled, privacy: .public)")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            diagnosticLogger.error("No se encontró un Python ejecutable para el agente.")
            throw ClientError(message: bundled
                ? "La instalación de Arkangel está incompleta. Reinstala la app para recuperar el agente incluido."
                : "Falta el entorno de desarrollo. Ejecuta bash scripts/setup-agent.sh desde el repositorio o usa la app instalada.")
        }
        let child = Process()
        child.executableURL = python
        child.arguments = (bundled ? ["-I"] : []) + ["-m", "guardian", "serve", "--watch"]
        child.currentDirectoryURL = bundled ? FileManager.default.homeDirectoryForCurrentUser : root
        var environment = ProcessInfo.processInfo.environment
        // Las credenciales del proveedor viajan solo en la solicitud configure del socket.
        for name in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "GUARDIAN_MODEL_KEY", "GUARDIAN_ALLOW_CLOUD", "GUARDIAN_MODEL_ENDPOINT", "GUARDIAN_MODEL", "GUARDIAN_PROVIDER", "PYTHONHOME", "PYTHONPATH"] {
            environment.removeValue(forKey: name)
        }
        if !bundled { environment["PYTHONPATH"] = root.appendingPathComponent("services/agent/src").path }
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        child.terminationHandler = { terminated in
            diagnosticLogger.notice("Agente terminado; estado=\(terminated.terminationStatus, privacy: .public)")
        }
        do { try child.run() } catch {
            diagnosticLogger.error("No se pudo iniciar el proceso del agente.")
            throw ClientError(message: "No se pudo iniciar el agente de Arkangel. Reinicia la app; si el problema continúa, reinstálala.")
        }
        diagnosticLogger.info("Agente iniciado; pid=\(child.processIdentifier, privacy: .public)")
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Unbundled executables launched by swift run default to background-only apps.
        NSApplication.shared.setActivationPolicy(.regular)
        if Bundle.main.bundleURL.pathExtension != "app" {
            let icon = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Icon/AppIcon.icns")
            NSApplication.shared.applicationIconImage = NSImage(contentsOf: icon)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
        dashboardWindow = NSApplication.shared.windows.first { $0.canBecomeMain }
        dashboardWindow?.delegate = self
        showDashboard()
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

    func showDashboard() {
        dashboardWindow = dashboardWindow ?? NSApplication.shared.windows.first { $0.canBecomeMain }
        dashboardWindow?.delegate = self
        dashboardWindow?.deminiaturize(nil)
        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            self.model.showAlerts = true
            self.showDashboard()
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
