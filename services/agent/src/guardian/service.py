"""Servicio local solo en primer plano. Sin puerto de red ni registro como servicio del sistema."""

import copy
import json
import os
import socketserver
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

from . import defense
from .store import Store
from .providers import provider_config
from .diagnostics import logger
from .onboarding import sdk_available, validate_key
from .response import Response


def default_socket() -> Path:
    return Path(os.getenv("GUARDIAN_SOCKET") or f"/tmp/guardian-{os.getuid()}/agent.sock")


class GuardianService:
    def __init__(self, store: Store, collector=None, investigator=None, file_collector=None, clock=time.time):
        default_collector = collector is None
        if collector is None:
            from .telemetry import collect_snapshot
            collector = collect_snapshot
        if investigator is None:
            from .investigator import investigate
            investigator = investigate
        if file_collector is None:
            from .surveillance import collect_files
            file_collector = collect_files if default_collector else lambda known: ([], [])
        self.file_collector = file_collector
        self.clock = clock
        self.file_scan_at = None
        self.file_coverage = []
        self.last_file_scan = None
        self.store = store
        self.collector = collector
        self.investigator = investigator
        self.lock = threading.RLock()
        self.investigation_lock = threading.Lock()
        # La recolección puede tardar ~20 s; solo se retiene scan_lock para que status siga respondiendo.
        self.scan_lock = threading.Lock()
        self.monitoring = False
        self.coverage = []
        self.last_scan = None
        self.progress = {"active": False, "started_at": None, "steps": []}
        self.stop = threading.Event()
        self.exposed = []
        self.firewall = None
        # ponytail: en memoria; tras reiniciar el servicio pf conserva los bloqueos hasta reiniciar
        # el Mac, así que status puede omitirlos (nunca inventarlos). Leer las anclas con root si hace falta.
        self.blocked = set()
        self.blocked_peers = set()
        self.defense_lock = threading.Lock()
        self.response_lock = threading.RLock()
        self.response = Response(store)

    def status(self):
        with self.lock:
            provider = provider_config()
            provider_status = "not_configured"
            if provider.configured:
                provider_status = f"{provider.name} / {provider.model}"
                if provider.name == "anthropic" and os.getenv("GUARDIAN_ALLOW_CLOUD") != "1":
                    provider_status += " (nube desactivada)"
            return {"monitoring": self.monitoring, "automation": self.automation_status(),
                    "protection": self.response.status(),
                    "alerts": self.store.alert_counts(), "last_file_scan": self.last_file_scan,
                    "provider": provider_status,
                    "onboarding_required": not provider.configured or (provider.name == "anthropic" and os.getenv("GUARDIAN_ALLOW_CLOUD") != "1"),
                    "sdk_available": sdk_available(),
                    "coverage": self.coverage, "observation_count": self.store.count(),
                    "last_scan": self.last_scan, "firewall": self.firewall,
                    "exposed": [dict(item, blocked=item["port"] in self.blocked) for item in self.exposed],
                    "blocked_ports": sorted(self.blocked), "blocked_peers": sorted(self.blocked_peers)}

    def scan(self, force_files=False):
        with self.scan_lock:
            observations, coverage = self.collector()
            observations, coverage = list(observations), list(coverage)
            now = time.monotonic()
            if force_files or self.file_scan_at is None or now - self.file_scan_at >= 30:
                files, self.file_coverage = self.file_collector(self.store.watch_records())
                observations.extend(files)
                self.file_scan_at = time.monotonic()
                self.last_file_scan = datetime.now(timezone.utc).isoformat()
            coverage.extend(self.file_coverage)
            with self.lock:
                self.store.detect(observations, coverage)
                self.store.ingest(observations)
                self.coverage = coverage
                listeners = {(o["attributes"]["port"], o["attributes"].get("executable", "unknown"), o["attributes"]["bind_scope"])
                             for o in observations if o.get("kind") == "tcp_listener"
                             and o["attributes"].get("bind_scope") in {"any", "interface"} and "port" in o["attributes"]}
                self.exposed = [{"port": port, "executable": executable, "bind_scope": scope}
                                for port, executable, scope in sorted(listeners)]
                self.firewall = next((o["attributes"] for o in observations if o.get("kind") == "firewall"), None)
                self.last_scan = datetime.now(timezone.utc).isoformat()
                self.store.prune(self.clock())
        return self.status()

    def investigate(self, question="", automatic=False):
        if not self.investigation_lock.acquire(blocking=False):
            raise ValueError("Ya hay una investigación en curso")
        try:
            with self.lock:
                if automatic and self.automation_status()["reason"] != "ready":
                    return None
                alerts = self.store.alerts(pending=True)
                if automatic and not self.store.reserve_attempt(self.clock()):
                    return None
                prioritized = []
                for alert in alerts:
                    prioritized.extend(item for item in (alert["signal"], alert["before"], alert["after"]) if item)
                records = {item["id"]: item for item in prioritized}
                for item in self.store.observations(500):
                    records.setdefault(item["id"], item)
                observations = list(records.values())[:500]
                coverage = list(self.coverage)
                total = self.store.count()
                if total > 500 or len(records) > 500 or self.store.alert_counts()["pending"] > len(alerts):
                    coverage.append({"source": "evidence_window", "status": "partial",
                                     "detail": "La ventana prioriza hasta 100 señales con sus estados anterior y posterior; el contexto adicional está limitado a 500 observaciones."})
                self.progress = {"active": True, "started_at": datetime.now(timezone.utc).isoformat(), "steps": []}
            observations = copy.deepcopy(observations)
            with self.response_lock:
                generation = self.response.generation
                targets = self.response.capture(observations) if self.monitoring else {}
            result = self.investigator(observations, question=question, coverage=coverage,
                                       on_step=self.record_step)
            with self.lock:
                self.store.save_investigation(result)
                if result.get("status") != "inconclusive" or result.get("hypotheses"):
                    self.store.complete_alerts([alert["id"] for alert in alerts])
            with self.response_lock:
                if self.monitoring and generation == self.response.generation:
                    self.response.apply(result, targets)
            return result
        finally:
            with self.lock:
                self.progress["active"] = False
            self.investigation_lock.release()

    def record_step(self, step):
        with self.lock:
            if len(self.progress["steps"]) < 50:
                self.progress["steps"].append(step)

    def dispatch(self, request):
        method = request.get("method")
        params = request.get("params", {})
        if not isinstance(params, dict):
            raise ValueError("params debe ser un objeto")
        if method == "alerts":
            limit = params.get("limit", 100)
            if type(limit) is not int or not 1 <= limit <= 500:
                raise ValueError("limit debe estar entre 1 y 500")
            return {"items": self.store.alerts(limit=limit)}
        if method == "alerts.acknowledge":
            identifier = params.get("id")
            if not isinstance(identifier, str) or not 1 <= len(identifier) <= 100:
                raise ValueError("id debe identificar una señal")
            with self.lock:
                self.store.acknowledge(identifier)
            return self.status()
        if method == "automation.set":
            enabled = params.get("enabled")
            if type(enabled) is not bool:
                raise ValueError("enabled debe ser un booleano")
            if enabled and params.get("consent") is not True:
                raise ValueError("Confirma el consentimiento para investigaciones automáticas y sus cargos de API.")
            with self.lock:
                self.store.set_automation(enabled)
            return self.status()
        if method == "status":
            return self.status()
        if isinstance(method, str) and method.startswith("protection."):
            with self.response_lock:
                if method == "protection.set":
                    enabled = params.get('enabled')
                    if type(enabled) is not bool or (enabled and params.get('consent') is not True):
                        raise ValueError('Confirma la respuesta automática y el riesgo de perder trabajo sin guardar.')
                    if enabled and self.response.attempts >= 20:
                        raise ValueError('Se alcanzó el límite de 20 intentos; revisa el historial antes de reiniciar el agente.')
                    if enabled and os.getuid() == 0:
                        raise ValueError('No se admite respuesta activa como root.')
                    self.response.generation += 1
                    self.response.enabled = enabled
                elif method == "protection.restore":
                    identifier = params.get('id')
                    if not isinstance(identifier, str) or not 1 <= len(identifier) <= 100:
                        raise ValueError('Identificador de respuesta no válido.')
                    if params.get('consent') is not True:
                        raise ValueError('Confirma la restauración del archivo.')
                    self.response.restore(identifier)
                else:
                    raise ValueError('Método de protección desconocido.')
            return self.status()
        if method == "provider.configure":
            return self.configure_provider(params)
        if method == "observations":
            limit = params.get("limit", 100)
            if type(limit) is not int or not 1 <= limit <= 500:
                raise ValueError("limit debe estar entre 1 y 500")
            return {"items": self.store.observations(limit)}
        if method == "investigations":
            return {"items": self.store.investigations()}
        if method == "scan":
            return self.scan(force_files=True)
        if method == "investigate":
            question = params.get("question", "")
            if not isinstance(question, str) or len(question) > 4000:
                raise ValueError("question debe ser texto de 4000 caracteres como máximo")
            return self.investigate(question)
        if method == "defense.apply":
            return self.apply_defense(params)
        if method == "investigation.progress":
            with self.lock:
                return {**self.progress, "steps": list(self.progress["steps"])}
        if method == "monitoring.set":
            enabled = params.get("enabled")
            if type(enabled) is not bool:
                raise ValueError("enabled debe ser un booleano")
            with self.response_lock:
                with self.lock:
                    self.monitoring = enabled
                    self.response.generation += 1
            return self.status()
        raise ValueError("Método desconocido")

    def apply_defense(self, params):
        action, port = params.get("action"), params.get("port")
        if action not in {"block_port", "unblock_port", "enable_firewall", "block_peer", "unblock_peer"}:
            raise ValueError("Acción de defensa desconocida")
        address = None
        if action == "block_peer":
            # La IP sale de la evidencia local, nunca del cliente ni del modelo.
            identifier = params.get("observation_id")
            if not isinstance(identifier, str) or not 1 <= len(identifier) <= 100:
                raise ValueError("observation_id debe identificar una conexión entrante")
            with self.lock:
                item = self.store.observation(identifier)
            if item.get("kind") != "tcp_connection" or item["attributes"].get("remote_scope") not in {"lan", "public"}:
                raise ValueError("Solo se puede bloquear el equipo de una conexión entrante observada")
            address = item["attributes"].get("remote_address")
        elif action == "unblock_peer":
            address = params.get("address")
            with self.lock:
                if not isinstance(address, str) or address not in self.blocked_peers:
                    raise ValueError("Ese equipo no fue bloqueado por Guardian en esta sesión")
        if not self.defense_lock.acquire(blocking=False):
            raise ValueError("Otra acción de defensa está esperando aprobación")
        try:
            # Espera mientras el aviso de contraseña de macOS está abierto; status sigue respondiendo.
            if action == "enable_firewall":
                defense.enable_firewall()
            elif action == "block_peer":
                defense.block_peer(address)
                with self.lock:
                    self.blocked_peers.add(address)
            elif action == "unblock_peer":
                defense.unblock_peer(address)
                with self.lock:
                    self.blocked_peers.discard(address)
            elif action == "block_port":
                defense.block_port(port)
                with self.lock:
                    self.blocked.add(port)
            else:
                defense.unblock_port(port)
                with self.lock:
                    self.blocked.discard(port)
        finally:
            self.defense_lock.release()
        return self.scan()

    def configure_provider(self, params):
        if params.get("allow_cloud") is not True:
            raise ValueError("Se requiere consentimiento para el procesamiento de metadatos por Anthropic.")
        if not sdk_available():
            raise ValueError("Falta Claude Agent SDK. Ejecuta scripts/setup-agent.sh y reinicia el servicio local.")
        if not self.investigation_lock.acquire(blocking=False):
            raise ValueError("Espera a que termine la investigación actual antes de cambiar la clave de API.")
        try:
            key = params.get("api_key")
            logger.info("Configuración del proveedor: verificando clave recibida por el socket local.")
            try:
                validate_key(key)
            except ValueError:
                logger.info("Configuración del proveedor: verificación rechazada; se conserva la configuración anterior.")
                raise
            logger.info("Configuración del proveedor: clave verificada; se guarda solo en memoria.")
            with self.lock:
                # Solo el proceso del servicio retiene la credencial. La app nativa gestiona la persistencia en el Llavero.
                os.environ["ANTHROPIC_API_KEY"] = key
                os.environ["GUARDIAN_PROVIDER"] = "anthropic"
                os.environ["GUARDIAN_MODEL"] = "claude-haiku-5-5"
                os.environ["GUARDIAN_ALLOW_CLOUD"] = "1"
                return self.status()
        finally:
            self.investigation_lock.release()

    def automation_status(self):
        quota = self.store.quota(self.clock())
        provider = provider_config()
        enabled = self.store.automation_enabled()
        reason = "ready"
        if not enabled:
            reason = "disabled"
        elif not self.monitoring:
            reason = "paused"
        elif not provider.configured:
            reason = "provider_unavailable"
        elif provider.name == "anthropic" and os.getenv("GUARDIAN_ALLOW_CLOUD") != "1":
            reason = "cloud_disabled"
        elif self.progress["active"]:
            reason = "investigating"
        elif not self.store.alert_counts()["pending"]:
            reason = "no_signals"
        elif quota["remaining"] == 0:
            reason = "quota_exhausted"
        elif quota["cooldown_seconds"]:
            reason = "cooldown"
        return {"enabled": enabled, "reason": reason, **quota}

    def watch(self, auto_investigate: bool):
        # El argumento de CLI es consentimiento explícito; --watch por sí solo no lo es.
        if auto_investigate:
            self.store.set_automation(True)
        while not self.stop.wait(5):
            if not self.monitoring:
                with self.lock:
                    self.store.prune(self.clock())
                continue
            try:
                self.scan()
                with self.lock:
                    ready = self.automation_status()["reason"] == "ready"
                if ready and not self.investigation_lock.locked():
                    threading.Thread(target=self.auto_investigate, daemon=True).start()
            except Exception as error:
                with self.lock:
                    self.coverage = [{"source": "service", "status": "error",
                                      "detail": f"El ciclo de monitoreo falló ({type(error).__name__}); cobertura incompleta."}]

    def auto_investigate(self):
        try:
            self.investigate("Revisa las señales recientes y considera explicaciones benignas.", automatic=True)
        except Exception:
            # Las señales quedan pendientes; el intento ya consumió cuota antes de llamar al modelo.
            pass


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(120)
        request = {}
        try:
            line = self.rfile.readline(65537)
            if len(line) > 65536 or not line.endswith(b"\n"):
                raise ValueError("Solicitud demasiado grande o sin salto de línea final")
            request = json.loads(line)
            if not isinstance(request, dict):
                request = {}
                raise ValueError("La solicitud debe ser un objeto")
            result = self.server.guardian.dispatch(request)
            response = {"id": request.get("id"), "result": result}
        except ValueError as error:
            response = {"id": request.get("id"), "error": {"message": str(error)}}
        except Exception as error:
            response = {"id": request.get("id"), "error": {
                "message": f"La solicitud falló ({type(error).__name__}); revisa la configuración del servicio local."}}
        self.wfile.write(json.dumps(response).encode() + b"\n")


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


def serve(service: GuardianService, socket_path: Path, auto_investigate=False):
    socket_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if socket_path.parent.is_symlink() or socket_path.parent.stat().st_uid != os.getuid():
        raise ValueError("El directorio del socket debe pertenecer al usuario actual y no ser un enlace simbólico")
    socket_path.parent.chmod(0o700)
    if socket_path.exists():
        raise ValueError(f"El socket ya existe: {socket_path}. Detén el servicio existente o elimina el socket obsoleto.")
    with Server(str(socket_path), Handler) as server:
        socket_path.chmod(0o600)
        server.guardian = service
        worker = threading.Thread(target=service.watch, args=(auto_investigate,), daemon=True)
        worker.start()
        print(f"Servicio de Guardian en primer plano: {socket_path}", flush=True)
        try:
            server.serve_forever(poll_interval=0.5)
        finally:
            service.stop.set()
            socket_path.unlink(missing_ok=True)
