"""Read-only, metadata-only local snapshots. Observed strings are untrusted."""
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


def _observation(kind: str, source: str, entity: str, summary: str, attributes: dict) -> dict:
    return {"id": str(uuid.uuid4()), "timestamp": datetime.now(timezone.utc).isoformat(),
            "kind": kind, "source": source, "entity": entity,
            "summary": summary, "attributes": attributes}


def parse_processes(output: str) -> list[dict]:
    """Parse ps comm output, never requesting argv or environment."""
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
                                        f"Process {executable}",
                                        {"pid": pid, "parent_pid": parent_pid,
                                         "uid": uid, "executable": executable,
                                         "start_time_local": start_time}))
    return observations


def parse_listeners(output: str) -> list[dict]:
    """Parse lsof field output. TCP socket addresses are local metadata."""
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
            observations.append(_observation("tcp_listener", "tcp_listeners", f"{pid}:{value}",
                                            f"TCP listener owned by {executable}",
                                            {"pid": pid, "executable": executable,
                                             "local_address": value}))
    return observations


def _coverage(source: str, status: str, detail: str) -> dict:
    return {"source": source, "status": status, "detail": detail}


def _command_snapshot(source: str, command: tuple[str, ...], parser) -> tuple[list[dict], dict]:
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=10,
                                check=False, shell=False)
    except FileNotFoundError:
        return [], _coverage(source, "unavailable", "Inspection command is unavailable.")
    except PermissionError:
        return [], _coverage(source, "denied", "Inspection command permission denied.")
    except (OSError, subprocess.TimeoutExpired):
        return [], _coverage(source, "unknown", "Inspection command failed or timed out.")
    observations = parser(result.stdout)
    # lsof returns 1 without output when no matching visible sockets exist.
    if source == "tcp_listeners" and result.returncode == 1 and not result.stdout and not result.stderr:
        return [], _coverage(source, "partial", "No visible TCP listeners; other users' sockets may be hidden.")
    if result.returncode != 0 or result.stderr.strip():
        return observations, _coverage(source, "partial" if observations else "unknown",
                                       "Inspection reported an error; visibility is incomplete.")
    return observations, _coverage(source, "partial", "Current-user visibility; snapshot is incomplete and is not a safety verdict.")


def _launch_agents(directory: Path) -> tuple[list[dict], dict]:
    source = "user_launch_agents"
    observations = []
    try:
        paths = list(directory.iterdir())
    except FileNotFoundError:
        return [], _coverage(source, "available", "User LaunchAgents directory does not exist; system persistence is not inspected.")
    except PermissionError:
        return [], _coverage(source, "denied", "User LaunchAgents directory access denied.")
    except OSError:
        return [], _coverage(source, "unknown", "User LaunchAgents directory could not be inspected.")
    incomplete = False
    for path in sorted(paths):
        if path.suffix != ".plist":
            continue
        try:
            # Avoid following links outside the selected metadata directory.
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
                                            "User LaunchAgent configuration present; loaded state unknown.", attributes))
        except (OSError, ValueError, TypeError, plistlib.InvalidFileException, OverflowError, ExpatError):
            incomplete = True
    detail = "Only user LaunchAgents metadata; loaded state and system persistence are unknown."
    if incomplete:
        detail += " Some entries could not be read or parsed."
    return observations, _coverage(source, "partial", detail)


def collect_snapshot() -> tuple[list[dict], list[dict]]:
    """Inspect this Mac only. No changes, scans, shell, daemon, or stored state."""
    sources = ("processes", "tcp_listeners", "user_launch_agents")
    if platform.system() != "Darwin":
        return [], [_coverage(source, "unsupported", "This collector requires macOS.") for source in sources]
    observations = []
    coverage = []
    for source, command, parser in (("processes", PS_COMMAND, parse_processes),
                                    ("tcp_listeners", LSOF_COMMAND, parse_listeners)):
        items, status = _command_snapshot(source, command, parser)
        observations.extend(items)
        coverage.append(status)
    items, status = _launch_agents(Path.home() / "Library" / "LaunchAgents")
    observations.extend(items)
    coverage.append(status)
    coverage.append(_coverage("osquery", "available" if shutil.which("osqueryi") else "unavailable",
                              "Executable availability only; osquery is not run and no daemon is started."))
    return observations, coverage
