"""Foreground-only local service. No network port or system service registration."""

import json
import os
import socketserver
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

from .store import Store
from .providers import provider_config
from .onboarding import sdk_available, validate_key


def default_socket() -> Path:
    return Path(f"/tmp/guardian-{os.getuid()}/agent.sock")


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
        self.monitoring = False
        self.coverage = []
        self.last_scan = None
        self.dirty = False
        self.stop = threading.Event()

    def status(self):
        with self.lock:
            provider = provider_config()
            provider_status = "not_configured"
            if provider.configured:
                provider_status = f"{provider.name} / {provider.model}"
                if provider.name == "anthropic" and os.getenv("GUARDIAN_ALLOW_CLOUD") != "1":
                    provider_status += " (cloud disabled)"
            return {"monitoring": self.monitoring,
                    "provider": provider_status,
                    "onboarding_required": not provider.configured or (provider.name == "anthropic" and os.getenv("GUARDIAN_ALLOW_CLOUD") != "1"),
                    "sdk_available": sdk_available(),
                    "coverage": self.coverage, "observation_count": self.store.count(),
                    "last_scan": self.last_scan}

    def scan(self):
        with self.lock:
            observations, coverage = self.collector()
            self.dirty = bool(self.store.ingest(observations)) or self.dirty
            self.coverage = coverage
            self.last_scan = datetime.now(timezone.utc).isoformat()
            self.store.prune()
            return self.status()

    def investigate(self, question=""):
        if not self.investigation_lock.acquire(blocking=False):
            raise ValueError("An investigation is already running")
        try:
            with self.lock:
                observations = self.store.observations(500)
                coverage = list(self.coverage)
                total = self.store.count()
                if total > len(observations):
                    coverage.append({"source": "evidence_window", "status": "partial",
                                     "detail": f"Investigation sees the latest {len(observations)} of {total} retained observations."})
                self.dirty = False
            try:
                result = self.investigator(observations, question=question, coverage=coverage)
            except Exception:
                with self.lock:
                    self.dirty = True
                raise
            with self.lock:
                self.store.save_investigation(result)
            return result
        finally:
            self.investigation_lock.release()

    def dispatch(self, request):
        method = request.get("method")
        params = request.get("params", {})
        if not isinstance(params, dict):
            raise ValueError("params must be an object")
        if method == "status":
            return self.status()
        if method == "provider.configure":
            return self.configure_provider(params)
        if method == "observations":
            limit = params.get("limit", 100)
            if type(limit) is not int or not 1 <= limit <= 500:
                raise ValueError("limit must be between 1 and 500")
            return {"items": self.store.observations(limit)}
        if method == "investigations":
            return {"items": self.store.investigations()}
        if method == "scan":
            return self.scan()
        if method == "investigate":
            question = params.get("question", "")
            if not isinstance(question, str) or len(question) > 4000:
                raise ValueError("question must be text of at most 4000 characters")
            return self.investigate(question)
        if method == "monitoring.set":
            enabled = params.get("enabled")
            if type(enabled) is not bool:
                raise ValueError("enabled must be a boolean")
            with self.lock:
                self.monitoring = enabled
            return self.status()
        raise ValueError("Unknown method")

    def configure_provider(self, params):
        if params.get("allow_cloud") is not True:
            raise ValueError("Consent to Anthropic metadata processing is required.")
        if not sdk_available():
            raise ValueError("Claude Agent SDK is missing. Run scripts/setup-agent.sh, then restart the local service.")
        if not self.investigation_lock.acquire(blocking=False):
            raise ValueError("Wait for the current investigation before changing the API key.")
        try:
            key = params.get("api_key")
            validate_key(key)
            with self.lock:
                # Only the service process retains the credential. The native app owns Keychain persistence.
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
                                      "detail": f"Monitoring cycle failed ({type(error).__name__}); coverage incomplete."}]

    def auto_investigate(self):
        try:
            self.investigate("Review recent changes. Form and test hypotheses; consider benign explanations.")
        except Exception:
            # A failed investigation must not stop collection or erase telemetry coverage.
            with self.lock:
                self.dirty = True


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(120)
        request = {}
        try:
            line = self.rfile.readline(65537)
            if len(line) > 65536 or not line.endswith(b"\n"):
                raise ValueError("Request too large or not newline terminated")
            request = json.loads(line)
            if not isinstance(request, dict):
                request = {}
                raise ValueError("Request must be an object")
            result = self.server.guardian.dispatch(request)
            response = {"id": request.get("id"), "result": result}
        except ValueError as error:
            response = {"id": request.get("id"), "error": {"message": str(error)}}
        except Exception as error:
            response = {"id": request.get("id"), "error": {
                "message": f"Request failed ({type(error).__name__}); inspect local service configuration."}}
        self.wfile.write(json.dumps(response).encode() + b"\n")


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


def serve(service: GuardianService, socket_path: Path, auto_investigate=False):
    socket_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if socket_path.parent.is_symlink() or socket_path.parent.stat().st_uid != os.getuid():
        raise ValueError("Socket directory must be owned by the current user and not a symlink")
    socket_path.parent.chmod(0o700)
    if socket_path.exists():
        raise ValueError(f"Socket already exists: {socket_path}. Stop the existing service or remove a stale socket.")
    with Server(str(socket_path), Handler) as server:
        socket_path.chmod(0o600)
        server.guardian = service
        worker = threading.Thread(target=service.watch, args=(auto_investigate,), daemon=True)
        worker.start()
        print(f"Guardian foreground service: {socket_path}", flush=True)
        try:
            server.serve_forever(poll_interval=0.5)
        finally:
            service.stop.set()
            socket_path.unlink(missing_ok=True)
