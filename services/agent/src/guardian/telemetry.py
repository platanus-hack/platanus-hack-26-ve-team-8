"""Instantáneas locales de solo lectura y solo metadatos. Las cadenas observadas no son confiables."""
from __future__ import annotations

from datetime import datetime, timezone
import ipaddress
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import uuid
from xml.parsers.expat import ExpatError

PS_COMMAND = ("/bin/ps", "-axo", "pid=,ppid=,uid=,lstart=,comm=")
LSOF_COMMAND = ("/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn")
CONNECTIONS_COMMAND = ("/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:ESTABLISHED", "-Fpcn")
FIREWALL_COMMAND = ("/usr/libexec/ApplicationFirewall/socketfilterfw", "--getglobalstate", "--getstealthmode")
# netstat lista sockets de todos los usuarios con su proceso, sin root: así se ve el sshd de root
# (Inicio de sesión remoto) que lsof oculta.
NETSTAT_COMMAND = ("/usr/sbin/netstat", "-anv", "-p", "tcp")
# ponytail: ventana fija; los intentos entre escaneos más separados que esto se pierden.
SSH_LOG_COMMAND = ("/usr/bin/log", "show", "--last", "2m", "--style", "compact",
                   "--predicate", 'process BEGINSWITH "sshd"')
# Proto Recv-Q Send-Q local remoto estado rxbytes txbytes rhiwat shiwat proceso:pid estado-hex ...
# El nombre del proceso puede tener espacios. ponytail: macOS sin la columna proceso:pid no coincide.
NETSTAT_LINE = re.compile(r"tcp(?:4|6|46)\s+\d+\s+\d+\s+(\S+)\s+(\S+)\s+(LISTEN|ESTABLISHED)\s+"
                          r"(?:\d+\s+){4}(.+?):(\d+)\s+[0-9a-f]+\s")
SSH_FAILURE = re.compile(r"Failed |Invalid user |\[preauth\]")


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


def _endpoint(value: str):
    host, _, port = value.rpartition(":")
    # La zona IPv6 (%en0) no forma parte de la dirección del equipo remoto.
    address = ipaddress.ip_address(host.strip("[]").split("%", 1)[0])
    return getattr(address, "ipv4_mapped", None) or address, int(port)


def parse_connections(output: str, listening_ports: set[int]) -> list[dict]:
    """Conexiones TCP entrantes desde otro equipo hacia un puerto local en escucha."""
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
        elif field == "n" and pid is not None and "->" in value:
            local, _, remote = value.partition("->")
            try:
                (local_host, local_port), (remote_host, remote_port) = _endpoint(local), _endpoint(remote)
            except ValueError:
                continue
            # El propio Mac conectándose a sí mismo, aunque use su IP de red, no es otro equipo.
            if local_port not in listening_ports or remote_host.is_loopback or remote_host == local_host:
                continue
            observations.append(_observation("tcp_connection", "tcp_connections", f"{pid}:{value}",
                                            f"Conexión entrante de la red a {executable}",
                                            {"pid": pid, "executable": executable, "direction": "inbound",
                                             "local_address": str(local_host), "local_port": local_port,
                                             "remote_address": str(remote_host), "remote_port": remote_port,
                                             "remote_scope": _scope(remote_host)}))
    return observations


def _scope(address) -> str:
    return "lan" if address.is_private or address.is_link_local else "public"


def _lsof_address(value: str) -> str:
    host, _, port = value.rpartition(".")
    return f"[{host}]:{port}" if ":" in host else f"{host}:{port}"


def netstat_as_lsof(output: str, state: str, skip_pids: set[int]) -> str:
    """Convierte los sockets de netstat en campos de lsof para reutilizar sus analizadores."""
    lines = []
    for line in output.splitlines():
        match = NETSTAT_LINE.match(line)
        if not match or match[3] != state or int(match[5]) in skip_pids:
            continue
        local, remote, _, executable, pid = match.groups()
        name = _lsof_address(local) if state == "LISTEN" else f"{_lsof_address(local)}->{_lsof_address(remote)}"
        lines += [f"p{pid}", f"c{executable}", f"n{name}"]
    return "\n".join(lines)


def parse_ssh_failures(output: str) -> list[dict]:
    """Intentos de acceso SSH fallidos por equipo remoto. Solo se cuentan; el usuario probado no se guarda."""
    attempts = {}
    for line in output.splitlines():
        if not SSH_FAILURE.search(line):
            continue
        # El nombre de usuario lo elige el atacante; sshd escribe la IP real al final, así que vale la última.
        peers = re.findall(r"(\S+) port (\d+)", line)
        if not peers:
            continue
        try:
            address = ipaddress.ip_address(peers[-1][0].strip("[]").split("%", 1)[0])
        except ValueError:
            continue
        address = getattr(address, "ipv4_mapped", None) or address
        if not address.is_loopback:
            # Varias líneas describen el mismo intento; el puerto de origen distingue intentos.
            attempts.setdefault(address, set()).add(peers[-1][1])
    return [_observation("tcp_connection", "ssh_logins", f"ssh:{address}",
                         "Intentos de acceso SSH fallidos desde la red",
                         # Inicio de sesión remoto de macOS escucha en el 22.
                         {"executable": "sshd", "direction": "inbound", "local_port": 22,
                          "remote_address": str(address), "remote_scope": _scope(address),
                          "auth_failures": len(ports)})
            for address, ports in attempts.items()]


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
    if source == "ssh_logins" and result.returncode == 0:
        return observations, _coverage(source, "partial", "Intentos fallidos de SSH de los últimos dos minutos en el registro del sistema; solo si Inicio de sesión remoto está activado.")
    # lsof devuelve 1 sin salida cuando no hay sockets visibles que coincidan.
    if source in {"tcp_listeners", "tcp_connections"} and result.returncode == 1 and not result.stdout and not result.stderr:
        return [], _coverage(source, "partial", "No hay escuchas TCP visibles; los sockets de otros usuarios pueden estar ocultos.")
    if result.returncode != 0 or result.stderr.strip():
        return observations, _coverage(source, "partial" if observations else "unknown",
                                       "La inspección informó un error; la visibilidad es incompleta.")
    return observations, _coverage(source, "partial", "Visibilidad del usuario actual; la instantánea es incompleta y no es un veredicto de seguridad.")


def _netstat() -> str:
    try:
        result = subprocess.run(NETSTAT_COMMAND, capture_output=True, text=True, timeout=10,
                                check=False, shell=False)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout if result.returncode == 0 else ""


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
    sources = ("processes", "tcp_listeners", "tcp_connections", "ssh_logins", "application_firewall", "user_launch_agents")
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
    # lsof ya ve los procesos propios; netstat solo añade los de otros usuarios, como el sshd de root.
    own = {o["attributes"]["pid"] for o in observations if o["kind"] == "process" and o["attributes"]["uid"] == os.getuid()}
    sockets = _netstat()
    observations.extend(parse_listeners(netstat_as_lsof(sockets, "LISTEN", own)))
    ports = {o["attributes"]["port"] for o in observations if o["kind"] == "tcp_listener" and "port" in o["attributes"]}
    items, status = _command_snapshot("tcp_connections", CONNECTIONS_COMMAND,
                                      lambda output: parse_connections(output, ports))
    observations.extend(items + parse_connections(netstat_as_lsof(sockets, "ESTABLISHED", own), ports))
    coverage.append(status)
    if sockets:
        for item in coverage:
            if item["source"] in {"tcp_listeners", "tcp_connections"}:
                item["detail"] += " Incluye sockets de otros usuarios (como sshd) vistos con netstat."
    items, status = _command_snapshot("ssh_logins", SSH_LOG_COMMAND, parse_ssh_failures)
    observations.extend(items)
    coverage.append(status)
    items, status = _launch_agents(Path.home() / "Library" / "LaunchAgents")
    observations.extend(items)
    coverage.append(status)
    coverage.append(_coverage("osquery", "available" if shutil.which("osqueryi") else "unavailable",
                              "Solo disponibilidad del ejecutable; osquery no se ejecuta y no se inicia ningún daemon."))
    return observations, coverage
