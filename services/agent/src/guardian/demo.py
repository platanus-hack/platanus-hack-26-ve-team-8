"""Laboratorio local explícito; su telemetría nunca autoriza respuestas de IA."""
from contextlib import contextmanager
import json
import os
import stat
import uuid

from .response import rename_exclusive
from .surveillance import _identity, _open_directory
from .telemetry import _observation

DEMO_CONTENT = "GUARDIAN_DEMO_TOKEN=NO_ES_UN_SECRETO\n"
SAFE_CONFIG = {"allow_uploads": False, "redact_secrets": True}
UNSAFE_CONFIG = {"allow_uploads": True, "redact_secrets": False}
REPORTS = {
    "file_read": "Frame informó una lectura del archivo .env ficticio.",
    "upload_attempt": "Frame informó un intento de envío del archivo .env ficticio.",
    "upload_succeeded": "Frame informó un envío completado al recolector local.",
    "upload_blocked": "Frame informó que detuvo los envíos del laboratorio.",
}
ALERT_EVENTS = {"config_unsafe", "file_read", "upload_attempt", "upload_succeeded", "repair_failed"}


class DemoLab:
    def __init__(self, store):
        self.store = store
        self.enabled = False
        self.session_id = None
        self.directory = None
        self.uploads_blocked = True
        self.config_state = "not_prepared"
        self.events = []
        self.reports = 0
        self._root_identity = None
        self._config_identity = None
        self._config = None
        self._config_observation = None
        self._alerted = set()

    def status(self):
        return {"enabled": self.enabled, "session_id": self.session_id,
                "directory": str(self.directory) if self.directory else None,
                "uploads_blocked": self.uploads_blocked, "config_state": self.config_state,
                "events": list(self.events)}

    def _record(self, event, summary, trust="local_check", **attributes):
        item = _observation("demo_config" if event.startswith("config_") else "demo_activity",
                            "demo_lab", f"demo:{self.session_id}:{uuid.uuid4()}", summary,
                            {"simulation": True, "event": event, "trust": trust, **attributes})
        self.store.ingest([item])
        if event in ALERT_EVENTS and event not in self._alerted:
            self.store.record_demo_alert(item, "demo_" + event,
                                         before=self._config_observation if event == "config_unsafe" else None)
            self._alerted.add(event)
        if item["kind"] == "demo_config":
            self._config_observation = item
        self.events = (self.events + [item])[-12:]

    def prepare(self):
        self.enabled = False
        self.uploads_blocked = True
        base = self.store.path.parent.resolve() / "demo"
        parent = _open_directory(base.parent)
        try:
            try:
                os.mkdir("demo", mode=0o700, dir_fd=parent)
            except FileExistsError:
                pass
            base_fd = os.open("demo", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            try:
                info = os.fstat(base_fd)
                if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
                    raise ValueError("La carpeta del laboratorio debe ser privada y pertenecer a tu usuario.")
                session = str(uuid.uuid4())
                os.mkdir(session, mode=0o700, dir_fd=base_fd)
                directory_fd = os.open(session, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=base_fd)
                try:
                    for name, content in ((".env", DEMO_CONTENT), ("config.json", json.dumps(SAFE_CONFIG))):
                        descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                             0o600, dir_fd=directory_fd)
                        with os.fdopen(descriptor, "w") as stream:
                            stream.write(content)
                            stream.flush()
                            os.fsync(stream.fileno())
                            if name == "config.json":
                                info = os.fstat(stream.fileno())
                                self._config_identity = (info.st_dev, info.st_ino)
                    info = os.fstat(directory_fd)
                    self._root_identity = (info.st_dev, info.st_ino)
                finally:
                    os.close(directory_fd)
            finally:
                os.close(base_fd)
        finally:
            os.close(parent)
        self.session_id, self.directory = session, base / session
        self.events, self.reports = [], 0
        self._config, self.config_state = None, "not_prepared"
        self._config_observation, self._alerted = None, set()
        self.enabled, self.uploads_blocked = True, False
        self._record("prepared", "Laboratorio preparado con archivos ficticios; no contiene credenciales reales.")
        self.inspect()
        return self.status()

    @contextmanager
    def _directory(self):
        descriptor = _open_directory(self.directory)
        try:
            info = os.fstat(descriptor)
            if (info.st_dev, info.st_ino) != self._root_identity or info.st_uid != os.getuid() or \
                    stat.S_IMODE(info.st_mode) != 0o700:
                raise ValueError("La carpeta del laboratorio cambió; prepara una sesión nueva.")
            yield descriptor
        finally:
            os.close(descriptor)

    def _read_config(self, directory_fd, name="config.json"):
        descriptor = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=directory_fd)
        with os.fdopen(descriptor, "rb") as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_nlink != 1 or \
                    before.st_size > 4096 or before.st_mode & (stat.S_ISUID | stat.S_ISGID):
                raise ValueError("La configuración del laboratorio no es un archivo propio elegible.")
            content = stream.read(4097)
            after = os.fstat(stream.fileno())
        final = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if len(content) > 4096 or _identity(before) != _identity(after) or _identity(after) != _identity(final):
            raise ValueError("La configuración cambió durante la lectura.")
        try:
            value = json.loads(content)
        except (ValueError, RecursionError):
            raise ValueError("La configuración no tiene el formato fijo del laboratorio.") from None
        if type(value) is not dict or set(value) != set(SAFE_CONFIG) or any(type(v) is not bool for v in value.values()):
            raise ValueError("La configuración no tiene el formato fijo del laboratorio.")
        return value, after

    def inspect(self):
        if not self.enabled:
            return
        try:
            with self._directory() as directory_fd:
                config, _ = self._read_config(directory_fd)
            state = "safe" if config == SAFE_CONFIG else "unsafe"
        except (OSError, ValueError):
            config, state = None, "unavailable"
        if state != self.config_state or config != self._config:
            self._config, self.config_state = config, state
            summary = {"safe": "Guardian comprobó que la configuración ficticia es segura.",
                       "unsafe": "Guardian detectó una configuración ficticia que permite envíos o desactiva la ocultación de secretos.",
                       "unavailable": "Guardian no pudo verificar la configuración ficticia; los envíos quedan denegados."}[state]
            self._record("config_" + state, summary, config_state=state, **(config or {}))

    def _session(self, identifier):
        if not self.enabled or type(identifier) is not str or identifier != self.session_id:
            raise ValueError("La sesión del laboratorio no está activa; prepárala de nuevo en Guardian.")

    def attach(self):
        self._session(self.session_id)
        try:
            with self._directory() as directory_fd:
                _, info = self._read_config(directory_fd)
                if (info.st_dev, info.st_ino) != self._config_identity:
                    raise ValueError("La identidad de la configuración cambió.")
        except (OSError, ValueError):
            self.uploads_blocked = True
            raise ValueError("La configuración original del laboratorio cambió; prepara una sesión nueva.") from None
        return {"session_id": self.session_id, "directory": str(self.directory),
                "config_device": str(self._config_identity[0]), "config_inode": str(self._config_identity[1])}

    def report(self, session_id, event):
        self._session(session_id)
        if type(event) is not str or event not in REPORTS:
            raise ValueError("Evento del laboratorio no válido.")
        if self.reports >= 100:
            self.uploads_blocked = True
            raise ValueError("Se alcanzó el límite de 100 informes; prepara una sesión nueva.")
        self.reports += 1
        self.inspect()
        self._record(event, REPORTS[event], trust="self_reported")
        return {"allowed": not self.uploads_blocked and self._config == UNSAFE_CONFIG}

    def repair(self, session_id):
        self._session(session_id)
        self.uploads_blocked = True
        self._record("repair_attempt", "Reparación autorizada: se deniegan los siguientes envíos del laboratorio.")
        try:
            with self._directory() as directory_fd:
                previous, info = self._read_config(directory_fd)
                temporary = "config.secure.json"
                descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                     0o600, dir_fd=directory_fd)
                with os.fdopen(descriptor, "w") as stream:
                    json.dump(SAFE_CONFIG, stream)
                    stream.flush()
                    os.fsync(stream.fileno())
                # Preserve the prior file; a concurrent replacement must never be discarded.
                rename_exclusive(directory_fd, "config.json", directory_fd, "config.before-repair.json")
                moved_config, moved = self._read_config(directory_fd, "config.before-repair.json")
                if (moved.st_dev, moved.st_ino) != (info.st_dev, info.st_ino) or moved_config != previous:
                    raise ValueError("La configuración cambió durante el movimiento; se conservó para revisión manual.")
                rename_exclusive(directory_fd, temporary, directory_fd, "config.json")
            self.inspect()
            if self.config_state != "safe":
                raise ValueError("No se pudo verificar la reparación.")
            self._record("repair_succeeded", "Configuración ficticia reparada y verificada; los envíos siguen bloqueados.")
        except (OSError, ValueError):
            self.inspect()
            self._record("repair_failed", "Falló la reparación. Los envíos siguen bloqueados; conserva los archivos de la sesión para revisión manual.")
            raise ValueError("No se pudo reparar el laboratorio. Los envíos siguen bloqueados; prepara una sesión nueva y conserva la anterior para revisión.") from None
        return self.status()

    def stop(self):
        self.enabled = False
        self.uploads_blocked = True
        if self.session_id:
            self._record("stopped", "Laboratorio detenido; los archivos ficticios se conservan para revisión.")
        return self.status()
