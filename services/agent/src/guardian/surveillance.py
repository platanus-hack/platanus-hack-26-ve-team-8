"""Cambios de archivos seleccionados; nunca conserva su contenido ni sigue enlaces."""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import platform
import stat

from .telemetry import _coverage, _observation

MAX_FILE_BYTES = 1_048_576
SHELL_FILES = (".zshenv", ".zprofile", ".zshrc", ".zlogin", ".bash_profile", ".bashrc", ".profile")
FILE_SOURCES = {"user_launch_files", "system_launch_agents", "system_launch_daemons", "shell_files"}


def _file(directory_fd: int, name: str, entity: str, source: str, category: str) -> dict:
    try:
        info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return _observation("file", source, entity, "Archivo seleccionado ausente.",
                            {"present": False, "category": category})
    kind = "regular" if stat.S_ISREG(info.st_mode) else "symlink" if stat.S_ISLNK(info.st_mode) else "other"
    attributes = {"present": True, "category": category, "file_type": kind,
                  "owner": info.st_uid, "mode": stat.S_IMODE(info.st_mode), "size": info.st_size}
    if kind == "regular" and info.st_size > MAX_FILE_BYTES:
        attributes["hash_available"] = False
    elif kind == "regular":
        descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd)
        with os.fdopen(descriptor, "rb") as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode) or _identity(before) != _identity(info):
                raise ValueError("El archivo cambió antes de leerlo")
            content = stream.read(MAX_FILE_BYTES + 1)
            after = os.fstat(stream.fileno())
        final = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if len(content) > MAX_FILE_BYTES or _identity(before) != _identity(after) or _identity(after) != _identity(final):
            raise ValueError("El archivo cambió durante la lectura")
        attributes["sha256"] = hashlib.sha256(content).hexdigest()
    return _observation("file", source, entity, "Metadatos de archivo seleccionado.", attributes)


def _identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _open_directory(directory: Path) -> int:
    """No sigue enlaces ni siquiera en los directorios antecesores seleccionados."""
    descriptor = os.open(directory.anchor, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in directory.parts[1:]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def collect_files(known: list[dict], home: Path | None = None, library: Path = Path("/Library")):
    home = home or Path.home()
    if platform.system() != "Darwin":
        return [], [_coverage(source, "unsupported", "La vigilancia de archivos requiere macOS.") for source in sorted(FILE_SOURCES)]
    observations, coverage = [], []
    locations = ((home / "Library/LaunchAgents", "user_launch_files", "launch_agent"),
                 (library / "LaunchAgents", "system_launch_agents", "launch_agent"),
                 (library / "LaunchDaemons", "system_launch_daemons", "launch_daemon"),
                 (home, "shell_files", "shell_startup"))
    for directory, source, category in locations:
        names = set(SHELL_FILES) if source == "shell_files" else {
            Path(item["entity"]).name for item in known if item["source"] == source}
        descriptor = None
        incomplete = False
        try:
            descriptor = _open_directory(directory)
            if source != "shell_files":
                names.update(name for name in os.listdir(descriptor) if name.endswith(".plist"))
            for name in sorted(names):
                try:
                    item = _file(descriptor, name, str(directory / name), source, category)
                    observations.append(item)
                    if item["attributes"].get("file_type") in {"symlink", "other"} or item["attributes"].get("hash_available") is False:
                        incomplete = True
                except (OSError, ValueError):
                    incomplete = True
                    observations.append(_observation("file", source, str(directory / name),
                        "Lectura no disponible; se conserva la referencia anterior.",
                        {"category": category, "readable": False}))
        except FileNotFoundError:
            for name in sorted(names):
                observations.append(_observation("file", source, str(directory / name), "Archivo seleccionado ausente.",
                                                 {"present": False, "category": category}))
        except OSError:
            incomplete = True
        finally:
            if descriptor is not None:
                os.close(descriptor)
        coverage.append(_coverage(source, "partial" if incomplete else "available",
            "Solo archivos seleccionados; sin contenido almacenado. " +
            ("Hay entradas inaccesibles, enlaces, tipos no regulares, archivos mayores de 1 MiB o lecturas inestables; se conserva la referencia anterior cuando no se puede leer." if incomplete else
             "La primera lectura establece una referencia, no garantiza seguridad.")))
    return observations, coverage
