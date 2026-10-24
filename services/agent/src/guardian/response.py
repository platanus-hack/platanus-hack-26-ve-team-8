"""Respuesta a veredictos de IA con autorización de sesión y objetivos verificados localmente."""
from contextlib import contextmanager
import ctypes
import hashlib
import os
from pathlib import Path
import platform
import signal
import stat
import sys
from datetime import datetime

from .surveillance import _identity, _open_directory

MAX_BYTES = 100 * 1024 * 1024


class BSDInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in (
        'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid', 'rgid', 'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ('nfiles', 'pgid', 'jobc', 'tdev', 'tpgid', 'nice')]
    _fields_ += [('start_sec', ctypes.c_uint64), ('start_usec', ctypes.c_uint64)]


class UniqueInfo(ctypes.Structure):
    # Apple XNU proc_info_private.h: PROC_PIDT_BSDINFOWITHUNIQID (18).
    _fields_ = [('uuid', ctypes.c_ubyte * 16), ('uniqueid', ctypes.c_uint64),
                ('parent_uniqueid', ctypes.c_uint64), ('version', ctypes.c_int32),
                ('parent_version', ctypes.c_int32), ('reserved', ctypes.c_uint64 * 2)]


class ProcessInfo(ctypes.Structure):
    _fields_ = [('bsd', BSDInfo), ('unique', UniqueInfo)]


def library():
    if platform.system() != 'Darwin':
        raise ValueError('La respuesta activa requiere macOS.')
    lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    lib.proc_pidpath_audittoken.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32]
    lib.proc_signal_with_audittoken.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    return lib


def process_identity(pid):
    if type(pid) is not int or pid <= 1:
        raise ValueError('PID no válido para respuesta activa.')
    lib = library()
    info = ProcessInfo()
    if lib.proc_pidinfo(pid, 18, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
        raise ValueError('No se pudo verificar la identidad del proceso.')
    token = (ctypes.c_uint32 * 8)(0, info.bsd.uid, info.bsd.gid, info.bsd.ruid,
                                  info.bsd.rgid, pid, 0, info.unique.version)
    path = ctypes.create_string_buffer(4096)
    if lib.proc_pidpath_audittoken(ctypes.byref(token), path, len(path)) <= 0:
        raise ValueError('No se pudo verificar el ejecutable del proceso.')
    return {'pid': pid, 'uid': info.bsd.uid, 'ruid': info.bsd.ruid, 'ppid': info.bsd.ppid,
            'system': bool(info.bsd.flags & 1), 'version': info.unique.version,
            'path': os.fsdecode(path.value), 'token': list(token), 'start_sec': info.bsd.start_sec}


def stop_process(identity):
    if identity['pid'] in {1, os.getpid(), os.getppid()} or identity['system'] or \
            identity['uid'] != os.getuid() or identity['ruid'] != os.getuid():
        raise ValueError('No se permite detener este proceso protegido o de otro usuario.')
    if process_identity(identity['pid']) != identity:
        raise ValueError('La identidad del proceso cambió; no se envió ninguna señal.')
    token = (ctypes.c_uint32 * 8)(*identity['token'])
    # The kernel checks PID version atomically; never fall back to kill(pid).
    error = library().proc_signal_with_audittoken(ctypes.byref(token), signal.SIGKILL)
    if error:
        raise ValueError(f'No se pudo solicitar la terminación del proceso (código {error}).')


@contextmanager
def checked_file(path, home, data_dir):
    path = Path(path)
    home = Path(home)
    if not path.is_absolute() or '..' in path.parts or not path.is_relative_to(home) or path == home:
        raise ValueError('Selecciona una ruta absoluta dentro de tu carpeta personal, sin enlaces.')
    if path.is_relative_to(data_dir) or path == Path(sys.executable).resolve():
        raise ValueError('Los archivos de Guardian están protegidos.')
    parent = _open_directory(path.parent)
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        with os.fdopen(fd, 'rb') as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_nlink != 1 \
                    or before.st_size > MAX_BYTES or before.st_mode & (stat.S_ISUID | stat.S_ISGID):
                raise ValueError('Solo se admiten archivos regulares propios de hasta 100 MiB, sin enlaces múltiples ni privilegios especiales.')
            digest = hashlib.sha256()
            remaining = MAX_BYTES + 1
            while remaining:
                chunk = stream.read(min(1024 * 1024, remaining))
                if not chunk:
                    break
                digest.update(chunk)
                remaining -= len(chunk)
            after = os.fstat(stream.fileno())
            if not remaining or _identity(before) != _identity(after) or \
                    _identity(after) != _identity(os.stat(path.name, dir_fd=parent, follow_symlinks=False)):
                raise ValueError('El archivo cambió durante la verificación.')
            yield parent, stream.fileno(), before, digest.hexdigest()
    finally:
        os.close(parent)


def rename_exclusive(source_fd, source, target_fd, target):
    lib = library()
    if lib.renameatx_np(source_fd, os.fsencode(source), target_fd, os.fsencode(target), 4) != 0:
        raise OSError(ctypes.get_errno(), 'No se pudo mover el archivo sin sobrescribir el destino.')


class Response:
    def __init__(self, store, home=None):
        self.store = store
        self.home = Path(home or Path.home())
        self.data_dir = store.path.parent.resolve()
        self.enabled = False  # Each service launch requires renewed authorization.
        self.attempts = 0
        self.signaled = set()
        self.restored = set()
        self.generation = 0

    def status(self):
        return {'enabled': self.enabled, 'remaining': max(0, 20 - self.attempts),
                'events': self.store.response_events()}

    def capture(self, observations):
        """Targets stay local; only eligibility is added to the model's evidence."""
        targets = {}
        if not self.enabled:
            return targets
        protected = {os.getpid(), os.getppid(), 1}
        parents = {o['attributes'].get('pid'): o['attributes'].get('parent_pid')
                   for o in observations if o.get('kind') == 'process'}
        while True:
            ancestors = {parents[p] for p in protected if p in parents}
            if ancestors <= protected:
                break
            protected.update(ancestors)
        for item in observations:
            attributes = item.get('attributes', {})
            try:
                identity = None
                if item.get('kind') == 'process' and attributes.get('uid') == os.getuid():
                    pid = attributes.get('pid')
                    if pid in protected:
                        continue
                    identity = process_identity(pid)
                    # Do not bind a historical observation to a recycled PID.
                    observed_start = int(datetime.strptime(attributes.get('start_time_local', ''),
                                                          '%a %b %d %H:%M:%S %Y').timestamp())
                    if observed_start != identity['start_sec'] or identity['system'] or \
                            identity['uid'] != os.getuid() or identity['ruid'] != os.getuid():
                        continue
                    path, action = identity['path'], 'terminate_process'
                elif item.get('kind') == 'file' and item.get('source') in {'user_launch_files', 'shell_files'}:
                    path, action = item['entity'], 'quarantine_file'
                else:
                    continue
                with checked_file(path, self.home, self.data_dir) as (_, _, info, digest):
                    if action == 'quarantine_file' and digest != attributes.get('sha256'):
                        continue
                    if (str(path), digest) in self.restored:
                        continue
                    targets[item['id']] = {'id': item['id'], 'action': action, 'path': str(path),
                                           'sha256': digest, 'fingerprint': _identity(info), 'identity': identity}
                item['attributes'] = dict(attributes, response_action=action)
            except (OSError, ValueError, AttributeError, TypeError):
                continue
            if len(targets) >= 20:
                break
        return targets

    def apply(self, result, targets):
        if not self.enabled or result.get('status') != 'needs_review':
            return
        cited = {i for h in result.get('hypotheses', []) for i in h.get('evidence_ids', [])}
        actions = [p.get('action', {}) for p in result.get('proposed_actions', [])]
        actions.sort(key=lambda a: a.get('type') != 'terminate_process')
        handled = set()
        for action in actions:
            if not self.enabled:
                return
            if self.attempts >= 20:
                self.enabled = False
                return
            identifier = action.get('observation_id')
            target = targets.get(identifier)
            if not target or identifier not in cited or identifier in handled or \
                    action.get('verdict') != 'malicious' or action.get('type') != target['action']:
                continue
            handled.add(identifier)
            target = dict(target, investigation_id=result['id'])
            try:
                with checked_file(target['path'], self.home, self.data_dir) as (_, _, info, digest):
                    if digest != target['sha256'] or _identity(info) != target['fingerprint']:
                        raise ValueError('El objetivo cambió desde el inicio de la investigación.')
                if (target['path'], target['sha256']) in self.restored:
                    raise ValueError('Archivo restaurado por el usuario; no se repite la respuesta en esta sesión.')
                if target['action'] == 'quarantine_file':
                    self.quarantine(target)
                else:
                    identity = target['identity']
                    key = (identity['pid'], identity['version'])
                    if key in self.signaled:
                        continue
                    event = self.store.start_response(target, pid=identity['pid'])
                    self.attempts += 1
                    try:
                        stop_process(identity)
                    except Exception:
                        self.store.finish_response(event, 'failed', 'No se pudo solicitar la terminación.')
                        raise
                    self.signaled.add(key)
                    self.store.finish_response(event, 'termination_requested', 'SIGKILL enviado a la identidad verificada; no confirma la salida ni impide reinicios.')
            except (OSError, ValueError, AttributeError) as error:
                event = self.store.start_response(target)
                detail = str(error) if isinstance(error, ValueError) else 'No se pudo verificar o modificar el objetivo.'
                self.store.finish_response(event, 'failed', detail)
        if self.attempts >= 20:
            self.enabled = False

    def quarantine(self, target):
        if self.store.unresolved_responses() >= 100:
            raise ValueError('Revisa las acciones pendientes: se alcanzó el límite de 100 archivos o acciones sin resolver.')
        with checked_file(target['path'], self.home, self.data_dir) as (parent, fd, info, digest):
            if digest != target['sha256'] or _identity(info) != target['fingerprint']:
                raise ValueError('El archivo cambió desde el inicio de la investigación.')
            root = self.data_dir / 'quarantine'
            root.mkdir(mode=0o700, exist_ok=True)
            root_fd = _open_directory(root)
            try:
                if os.fstat(root_fd).st_uid != os.getuid() or stat.S_IMODE(os.fstat(root_fd).st_mode) != 0o700:
                    raise ValueError('La carpeta de cuarentena no es privada.')
                event = self.store.start_response(target, mode=stat.S_IMODE(info.st_mode))
                self.attempts += 1
                os.mkdir(event, mode=0o700, dir_fd=root_fd)
                target_fd = os.open(event, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
                try:
                    rename_exclusive(parent, Path(target['path']).name, target_fd, 'payload')
                    moved = os.stat('payload', dir_fd=target_fd, follow_symlinks=False)
                    if (moved.st_dev, moved.st_ino, moved.st_nlink, moved.st_uid, moved.st_mode) != \
                            (info.st_dev, info.st_ino, 1, info.st_uid, info.st_mode):
                        # Preserve an unexpected moved file; never unlink or overwrite it.
                        self.store.finish_response(event, 'recovery_required', 'La ruta cambió durante el movimiento. Archivo conservado en cuarentena; requiere revisión manual.')
                        raise ValueError('La identidad cambió durante el movimiento.')
                    os.lseek(fd, 0, os.SEEK_SET)
                    with os.fdopen(os.dup(fd), 'rb') as stream:
                        moved_digest = hashlib.sha256(stream.read(MAX_BYTES + 1)).hexdigest()
                    if moved_digest != digest:
                        self.store.finish_response(event, 'recovery_required', 'El contenido cambió durante el movimiento; archivo conservado para revisión manual.')
                        raise ValueError('El contenido cambió durante el movimiento.')
                    os.fchmod(fd, 0o600)
                    os.fsync(fd)
                    self.store.finish_response(event, 'quarantined', 'Archivo movido a cuarentena sin permiso de ejecución.')
                    if self.attempts >= 20:
                        self.enabled = False
                finally:
                    os.close(target_fd)
            finally:
                os.close(root_fd)

    def restore(self, identifier):
        event = self.store.response_event(identifier)
        if event['status'] != 'quarantined':
            raise ValueError('Solo se pueden restaurar cuarentenas completadas.')
        path = Path(event['path'])
        parent = _open_directory(path.parent)
        source = None
        try:
            source = _open_directory(self.data_dir / 'quarantine' / event['id'])
            fd = os.open('payload', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=source)
            with os.fdopen(fd, 'rb') as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_size > MAX_BYTES:
                    raise ValueError('El archivo en cuarentena cambió.')
                if hashlib.sha256(stream.read(MAX_BYTES + 1)).hexdigest() != event['sha256']:
                    raise ValueError('El archivo en cuarentena no coincide con su SHA-256.')
                if _identity(info) != _identity(os.fstat(stream.fileno())) or \
                        _identity(info) != _identity(os.stat('payload', dir_fd=source, follow_symlinks=False)):
                    raise ValueError('El archivo en cuarentena cambió durante la verificación.')
                self.store.finish_response(identifier, 'restoring', 'Restauración iniciada.')
                try:
                    rename_exclusive(source, 'payload', parent, path.name)
                except OSError:
                    self.store.finish_response(identifier, 'quarantined', 'No se restauró: el destino existe o no se pudo mover.')
                    raise
                moved = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
                if (moved.st_dev, moved.st_ino) != (info.st_dev, info.st_ino):
                    self.store.finish_response(identifier, 'recovery_required', 'La identidad cambió durante la restauración; requiere revisión manual.')
                    raise ValueError('La identidad cambió durante la restauración.')
                os.fchmod(stream.fileno(), event['mode'])
                self.restored.add((str(path), event['sha256']))
                self.store.finish_response(identifier, 'restored', 'Archivo restaurado; excluido de respuestas automáticas durante esta sesión. No se ejecutó.')
        finally:
            if source is not None:
                os.close(source)
            os.close(parent)
