"""Servicio local solo en primer plano. Sin puerto de red ni registro como servicio del sistema."""

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
from .onboarding import sdk_available, validate_key


def default_socket() -> Path:
    return Path(os.getenv("GUARDIAN_SOCKET") or f"/tmp/guardian-{os.getuid()}/agent.sock")


class GuardianService:
    def __init__(self, store: Store, collector=None, investigator=None):
        if collector is None:
            from .telemetry import collect_snapshot
            collector = collect_snapshot
        if investigator is None:
            from .investigator import investigate
            investigator = investigate
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
        self.dirty = False
        self.progress = {"active": False, "started_at": None, "steps": []}
        self.stop = threading.Event()
        self.exposed = []
        self.firewall = None
        # ponytail: en memoria; tras reiniciar el servicio pf conserva los bloqueos hasta reiniciar
        # el Mac, así que status puede omitirlos (nunca inventarlos). Leer las anclas con root si hace falta.
        self.blocked = set()
        self.defense_lock = threading.Lock()

    def status(self):
        with self.lock:
            provider = provider_config()
            provider_status = "not_configured"
            if provider.configured:
                provider_status = f"{provider.name} / {provider.model}"
                if provider.name == "anthropic" and os.getenv("GUARDIAN_ALLOW_CLOUD") != "1":
                    provider_status += " (nube desactivada)"
            return {"monitoring": self.monitoring,
                    "provider": provider_status,
                    "onboarding_required": not provider.configured or (provider.name == "anthropic" and os.getenv("GUARDIAN_ALLOW_CLOUD") != "1"),
                    "sdk_available": sdk_available(),
                    "coverage": self.coverage, "observation_count": self.store.count(),
                    "last_scan": self.last_scan, "firewall": self.firewall,
                    "exposed": [dict(item, blocked=item["port"] in self.blocked) for item in self.exposed],
                    "blocked_ports": sorted(self.blocked)}

    def scan(self):
        with self.scan_lock:
            observations, coverage = self.collector()
            with self.lock:
                self.dirty = bool(self.store.ingest(observations)) or self.dirty
                self.coverage = coverage
                listeners = {(o["attributes"]["port"], o["attributes"].get("executable", "unknown"), o["attributes"]["bind_scope"])
                             for o in observations if o.get("kind") == "tcp_listener"
                             and o["attributes"].get("bind_scope") in {"any", "interface"} and "port" in o["attributes"]}
                self.exposed = [{"port": port, "executable": executable, "bind_scope": scope}
                                for port, executable, scope in sorted(listeners)]
                self.firewall = next((o["attributes"] for o in observations if o.get("kind") == "firewall"), None)
                self.last_scan = datetime.now(timezone.utc).isoformat()
                self.store.prune()
        return self.status()

    def investigate(self, question=""):
        if not self.investigation_lock.acquire(blocking=False):
            raise ValueError("Ya hay una investigación en curso")
        try:
            with self.lock:
                observations = self.store.observations(500)
                coverage = list(self.coverage)
                total = self.store.count()
                if total > len(observations):
                    coverage.append({"source": "evidence_window", "status": "partial",
                                     "detail": f"La investigación ve las {len(observations)} observaciones más recientes de {total} retenidas."})
                self.dirty = False
                self.progress = {"active": True, "started_at": datetime.now(timezone.utc).isoformat(), "steps": []}
            try:
                result = self.investigator(observations, question=question, coverage=coverage,
                                           on_step=self.record_step)
            except Exception:
                with self.lock:
                    self.dirty = True
                raise
            with self.lock:
                self.store.save_investigation(result)
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
        if method == "status":
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
            return self.scan()
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
            with self.lock:
                self.monitoring = enabled
            return self.status()
        raise ValueError("Método desconocido")

    def apply_defense(self, params):
        action, port = params.get("action"), params.get("port")
        if action not in {"block_port", "unblock_port", "enable_firewall"}:
            raise ValueError("Acción de defensa desconocida")
        if not self.defense_lock.acquire(blocking=False):
            raise ValueError("Otra acción de defensa está esperando aprobación")
        try:
            # Espera mientras el aviso de contraseña de macOS está abierto; status sigue respondiendo.
            if action == "enable_firewall":
                defense.enable_firewall()
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
            validate_key(key)
            with self.lock:
                # Solo el proceso del servicio retiene la credencial. La app nativa gestiona la persistencia en el Llavero.
                os.environ["ANTHROPIC_API_KEY"] = key
                os.environ["GUARDIAN_PROVIDER"] = "anthropic"
                os.environ["GUARDIAN_MODEL"] = "claude-haiku-5-5"
                os.environ["GUARDIAN_ALLOW_CLOUD"] = "1"
                return self.status()
        finally:
            self.investigation_lock.release()

    def watch(self, auto_investigate: bool):
        last_investigation = 0.0
        while not self.stop.wait(5):
            if not self.monitoring:
                continue
            try:
                self.scan()
                elapsed = time.monotonic() - last_investigation
                if (auto_investigate and (self.dirty or elapsed >= 900)
                        and provider_config().configured
                        and elapsed >= 60 and not self.investigation_lock.locked()):
                    last_investigation = time.monotonic()
                    threading.Thread(target=self.auto_investigate, daemon=True).start()
            except Exception as error:
                with self.lock:
                    self.coverage = [{"source": "service", "status": "error",
                                      "detail": f"El ciclo de monitoreo falló ({type(error).__name__}); cobertura incompleta."}]

    def auto_investigate(self):
        try:
            self.investigate("Revisa los cambios recientes. Formula y pon a prueba hipótesis; considera explicaciones benignas.")
        except Exception:
            # Una investigación fallida no debe detener la recolección ni borrar la cobertura de telemetría.
            with self.lock:
                self.dirty = True


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
