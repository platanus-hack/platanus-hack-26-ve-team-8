import SwiftUI

struct DemoLabView: View {
    @Bindable var model: GuardianModel
    let demo: DemoState
    @State private var preparing = false
    @State private var repairing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Laboratorio local con Frame", systemImage: "testtube.2").font(.headline)
            Text("Demuestra lectura y envío de un .env ficticio y reparación de una configuración vulnerable. Funciona sin modelo ni clave de API.")
                .font(.callout).foregroundStyle(.secondary)
            Text(es(demo.config_state)).font(.callout.weight(.semibold))
                .foregroundStyle(demo.config_state == "unsafe" ? Color.warning : Color.primary)
            if let directory = demo.directory {
                Text(directory).font(.caption.monospaced()).textSelection(.enabled)
                Text(demo.uploads_blocked ? "Los siguientes envíos cooperativos están detenidos." :
                    demo.config_state == "unsafe" ? "Frame puede enviar únicamente el marcador ficticio al receptor local." :
                    "La configuración actual no autoriza envíos.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack { controls }
                VStack(alignment: .leading) { controls }
            }
            if !demo.events.isEmpty {
                DisclosureGroup("Evidencia de la demo · últimas \(demo.events.count) entradas") {
                    ForEach(demo.events.reversed()) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.summary).font(.callout)
                            Text("\(event.timestamp) · \(event.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    }
                }
            }
            Text("La configuración se comprueba localmente. Las lecturas y envíos son declarados por Frame: no son telemetría del sistema operativo. Cada comportamiento nuevo añade una alerta al contador y al orbe, una vez por sesión. La reparación solo cambia config.json de esta demo y detiene los siguientes envíos cooperativos; no revierte entregas anteriores ni bloquea otras apps. La evidencia se excluye de las investigaciones de IA.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card(padding: 22)
        .alert("¿Preparar un laboratorio nuevo?", isPresented: $preparing) {
            Button("Cancelar", role: .cancel) {}
            Button("Preparar") { Task { await model.demo("prepare", params: ["consent": true]) } }
        } message: {
            Text("Se crearán un .env sin secretos y una configuración segura dentro de una carpeta nueva de Guardian. La sesión anterior dejará de aceptar envíos. Después pulsa Iniciar asistente con Guardian en Frame.")
        }
        .alert("¿Reparar y detener los envíos de demo?", isPresented: $repairing) {
            Button("Cancelar", role: .cancel) {}
            Button("Reparar") {
                if let session = demo.session_id {
                    Task { await model.demo("repair", params: ["session_id": session, "consent": true]) }
                }
            }
        } message: {
            Text("Se bloquearán los siguientes envíos de Frame y se reemplazará solo la configuración generada por Guardian con valores seguros. Una solicitud ya iniciada puede terminar. No se cambian archivos ni permisos del sistema.")
        }
    }

    @ViewBuilder private var controls: some View {
        Button("Preparar laboratorio nuevo") { preparing = true }.disabled(model.busy)
        if demo.enabled {
            Button("Reparar y detener envíos") { repairing = true }.disabled(model.busy || demo.uploads_blocked)
            Button("Detener laboratorio") { Task { await model.demo("stop") } }.disabled(model.busy)
        }
    }
}
