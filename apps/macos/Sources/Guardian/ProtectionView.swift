import SwiftUI

struct ProtectionView: View {
    @Bindable var model: GuardianModel
    let protection: ProtectionState
    @State private var enabling = false
    @State private var restoring: ResponseEvent?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Protección guiada por IA", systemImage: "shield.lefthalf.filled").font(.headline)
            Text("Tras una investigación, un veredicto malicioso con evidencia citada puede detener un proceso o poner un archivo en cuarentena automáticamente. La IA puede equivocarse.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Autorizar respuesta automática durante esta sesión", isOn: Binding(
                get: { protection.enabled },
                set: { enabled in
                    if enabled { enabling = true }
                    else { Task { await model.protect("set", params: ["enabled": false]) } }
                }
            )).disabled(model.busy)
            Text("\(protection.remaining) intentos disponibles. Requiere vigilancia activa. Para investigar sin intervención, activa Investigación automática arriba; sus límites de frecuencia siguen vigentes.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Historial de respuesta y cuarentena") {
                if protection.events.isEmpty { Text("Aún no se intentaron acciones.").foregroundStyle(.secondary) }
                ForEach(protection.events) { event in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(es(event.action)) · \(es(event.status))").font(.callout.weight(.medium))
                        Text(event.path).textSelection(.enabled)
                        Text(event.detail).font(.caption)
                        Text(event.created_at).font(.caption).foregroundStyle(.secondary)
                        if event.status == "quarantined" {
                            Button("Restaurar archivo") { restoring = event }.disabled(model.busy)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
            }
            DisclosureGroup("Alcance y límites") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Solo archivos propios dentro de tu carpeta personal: archivos vigilados de inicio del shell y LaunchAgents, y ejecutables de procesos propios. No actúa sobre archivos del sistema ni interpreta scripts para identificar su proceso.")
                    Text("El objetivo se verifica antes y después de la investigación. SIGKILL puede perder trabajo sin guardar; un supervisor puede reiniciar el proceso. La cuarentena conserva el archivo sin permiso de ejecución, pero no aísla procesos activos ni impide que otros procesos de tu usuario lo lean.")
                    Text("Los bloqueos de red siguen requiriendo aprobación de macOS en Exposición de red. Filtran conexiones TCP entrantes nuevas; no bloquean todos los ataques ni conexiones salientes.")
                    Text("La protección se desactiva al reiniciar el agente o tras 20 intentos. Desactivarla o pausar la vigilancia impide nuevas respuestas; una acción iniciada puede terminar. No reactiva archivos ni procesos automáticamente.")
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
        .card(padding: 22)
        .alert("¿Autorizar respuestas de la IA?", isPresented: $enabling) {
            Button("Cancelar", role: .cancel) {}
            Button("Autorizar") { Task { await model.protect("set", params: ["enabled": true, "consent": true]) } }
        } message: {
            Text("La IA podrá ordenar terminaciones forzadas y cuarentenas sin confirmar cada acción. Un falso positivo puede cerrar una app legítima, perder trabajo sin guardar o alterar tu configuración. Podrás restaurar archivos desde el historial. Esto no garantiza protección contra ataques.")
        }
        .alert("¿Restaurar el archivo?", isPresented: Binding(
            get: { restoring != nil }, set: { if !$0 { restoring = nil } }
        ), presenting: restoring) { event in
            Button("Cancelar", role: .cancel) {}
            Button("Restaurar") { Task { await model.protect("restore", params: ["id": event.id, "consent": true]) } }
        } message: { event in
            Text("Se restaurará \(event.path) con sus permisos originales, sin sobrescribir archivos existentes ni ejecutarlo. Quedará excluido de respuestas automáticas durante esta sesión.")
        }
    }
}
