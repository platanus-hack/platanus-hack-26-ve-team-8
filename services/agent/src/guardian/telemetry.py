"""Instantáneas locales de solo lectura y solo metadatos. Las cadenas observadas no son confiables."""
from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import uuid
from xml.parsers.expat import ExpatError

PS_COMMAND = ("/bin/ps", "-axo", "pid=,ppid=,uid=,lstart=,comm=")
LSOF_COMMAND = ("/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn")
FIREWALL_COMMAND = ("/usr/libexec/ApplicationFirewall/socketfilterfw", "--getglobalstate", "--getstealthmode")


def _observation(kind: str, source: str, entity: str, summary: str, attributes: dict) -> dict:
    return {"id": str(uuid.uuid4()), "timestamp": datetime.now(timezone.utc).isoformat(),
            "kind": kind, "source": source, "entity": entity,
            "summary": summary, "attributes": attributes}


def parse_processes(output: str) -> list[dict]:
    """Analiza la salida comm de ps sin pedir nunca argv ni el entorno."""
    observations = []
    for line in output.splitlines():
        fields = line.strip().split(None, 8)
        if len(fields) != 9:
            continue
        try:
            pid, parent_pid, uid = map(int, fields[:3])
        except ValueError:
            continue
        start_time = " ".join(fields[3:8])
        executable = fields[8].rsplit("/", 1)[-1]
        observations.append(_observation("process", "processes", f"{pid}:{start_time}",
                                        f"Proceso {executable}",
                                        {"pid": pid, "parent_pid": parent_pid,
                                         "uid": uid, "executable": executable,
                                         "start_time_local": start_time}))
    return observations


def parse_listeners(output: str) -> list[dict]:
    """Analiza la salida por campos de lsof. Las direcciones de sockets TCP son metadatos locales."""
    observations = []
    pid = None
    executable = "unknown"
    for line in output.splitlines():
        if not line:
            continue
        field, value = line[0], line[1:]
        if field == "p":
            pid = int(value) if value.isdigit() else None
            executable = "unknown"
        elif field == "c":
            executable = value.rsplit("/", 1)[-1]
        elif field == "n" and pid is not None:
            host, _, port = value.rpartition(":")
            host = host.strip("[]")
            # "*" escucha en todas las interfaces, así que otros dispositivos de la red pueden conectarse.
            scope = ("any" if host == "*" else
                     "loopback" if host.startswith("127.") or host == "::1" or host == "localhost" else "interface")
            attributes = {"pid": pid, "executable": executable, "local_address": value, "bind_scope": scope}
            if port.isdigit():
                attributes["port"] = int(port)
            observations.append(_observation("tcp_listener", "tcp_listeners", f"{pid}:{value}",
                                            f"Escucha TCP de {executable}", attributes))
    return observations


def parse_firewall(output: str) -> list[dict]:
    """Analiza el estado de socketfilterfw; State 1 es activado y 2 bloquea todo lo entrante."""
    if "State = " not in output:
        return []
    enabled = "State = 0" not in output
    stealth = "stealth mode is on" in output.lower()
    return [_observation("firewall", "application_firewall", "application_firewall",
                         f"Firewall de aplicaciones {'activado' if enabled else 'desactivado'}; modo sigiloso {'activado' if stealth else 'desactivado'}",
                         {"firewall_enabled": enabled, "stealth_mode": stealth})]


def _coverage(source: str, status: str, detail: str) -> dict:
    return {"source": source, "status": status, "detail": detail}


def _command_snapshot(source: str, command: tuple[str, ...], parser) -> tuple[list[dict], dict]:
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=10,
                                check=False, shell=False)
    except FileNotFoundError:
        return [], _coverage(source, "unavailable", "El comando de inspección no está disponible.")
    except PermissionError:
        return [], _coverage(source, "denied", "Permiso denegado para el comando de inspección.")
    except (OSError, subprocess.TimeoutExpired):
        return [], _coverage(source, "unknown", "El comando de inspección falló o agotó el tiempo.")
    observations = parser(result.stdout)
    # lsof devuelve 1 sin salida cuando no hay sockets visibles que coincidan.
    if source == "tcp_listeners" and result.returncode == 1 and not result.stdout and not result.stderr:
        return [], _coverage(source, "partial", "No hay escuchas TCP visibles; los sockets de otros usuarios pueden estar ocultos.")
    if result.returncode != 0 or result.stderr.strip():
        return observations, _coverage(source, "partial" if observations else "unknown",
                                       "La inspección informó un error; la visibilidad es incompleta.")
    return observations, _coverage(source, "partial", "Visibilidad del usuario actual; la instantánea es incompleta y no es un veredicto de seguridad.")


def _launch_agents(directory: Path) -> tuple[list[dict], dict]:
    source = "user_launch_agents"
    observations = []
    try:
        paths = list(directory.iterdir())
    except FileNotFoundError:
        return [], _coverage(source, "available", "El directorio LaunchAgents del usuario no existe; no se inspecciona la persistencia del sistema.")
    except PermissionError:
        return [], _coverage(source, "denied", "Acceso denegado al directorio LaunchAgents del usuario.")
    except OSError:
        return [], _coverage(source, "unknown", "No se pudo inspeccionar el directorio LaunchAgents del usuario.")
    incomplete = False
    for path in sorted(paths):
        if path.suffix != ".plist":
            continue
        try:
            # Evita seguir enlaces fuera del directorio de metadatos seleccionado.
            if path.is_symlink() or not path.is_file() or path.stat().st_size > 1_048_576:
                incomplete = True
                continue
            with path.open("rb") as stream:
                metadata = plistlib.load(stream)
            if not isinstance(metadata, dict):
                incomplete = True
                continue
            attributes = {"filename": path.name}
            label = metadata.get("Label")
            if isinstance(label, str):
                attributes["label"] = label
            program = metadata.get("Program")
            if not isinstance(program, str):
                arguments = metadata.get("ProgramArguments")
                if isinstance(arguments, list) and arguments and isinstance(arguments[0], str):
                    program = arguments[0]
            if isinstance(program, str):
                attributes["executable"] = program.rsplit("/", 1)[-1]
            for key in ("RunAtLoad", "Disabled"):
                if isinstance(metadata.get(key), bool):
                    attributes[key] = metadata[key]
            keep_alive = metadata.get("KeepAlive")
            if isinstance(keep_alive, (bool, dict)):
                attributes["keep_alive_configured"] = bool(keep_alive)
            observations.append(_observation("launch_agent", source, path.name,
                                            "Configuración de LaunchAgent del usuario presente; estado de carga desconocido.", attributes))
        except (OSError, ValueError, TypeError, plistlib.InvalidFileException, OverflowError, ExpatError):
            incomplete = True
    detail = "Solo metadatos de LaunchAgents del usuario; el estado de carga y la persistencia del sistema son desconocidos."
    if incomplete:
        detail += " Algunas entradas no se pudieron leer o analizar."
    return observations, _coverage(source, "partial", detail)


def collect_snapshot() -> tuple[list[dict], list[dict]]:
    """Inspecciona solo este Mac. Sin cambios, escaneos, shell, daemon ni estado almacenado."""
    sources = ("processes", "tcp_listeners", "application_firewall", "user_launch_agents")
    if platform.system() != "Darwin":
        return [], [_coverage(source, "unsupported", "Este recolector requiere macOS.") for source in sources]
    observations = []
    coverage = []
    for source, command, parser in (("processes", PS_COMMAND, parse_processes),
                                    ("tcp_listeners", LSOF_COMMAND, parse_listeners),
                                    ("application_firewall", FIREWALL_COMMAND, parse_firewall)):
        items, status = _command_snapshot(source, command, parser)
        observations.extend(items)
        coverage.append(status)
    items, status = _launch_agents(Path.home() / "Library" / "LaunchAgents")
    observations.extend(items)
    coverage.append(status)
    coverage.append(_coverage("osquery", "available" if shutil.which("osqueryi") else "unavailable",
                              "Solo disponibilidad del ejecutable; osquery no se ejecuta y no se inicia ningún daemon."))
    return observations, coverage
