"""Acciones aprobadas por el usuario que solo reducen la exposición de red. Ningún texto
del modelo llega a un comando.

Cada acción ejecuta un comando fijo tras el aviso de administrador de macOS; ese aviso
es la aprobación del usuario. Los bloqueos de puerto se cargan en un ancla de pf por
puerto bajo com.apple/*, que el /etc/pf.conf de serie ya evalúa, así que no se edita
ningún archivo del sistema. Los bloqueos duran hasta desbloquearlos o reiniciar.
"""
import subprocess

PFCTL = "/sbin/pfctl"
SOCKETFILTERFW = "/usr/libexec/ApplicationFirewall/socketfilterfw"


def _port(port) -> int:
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError("port debe ser un entero entre 1 y 65535")
    return port


def _admin(command: str):
    # Solo se interpolan rutas fijas y enteros validados; las comillas no pueden romperse.
    script = f'do shell script "{command}" with administrator privileges'
    try:
        result = subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True,
                                text=True, timeout=120, check=False, shell=False)
    except subprocess.TimeoutExpired:
        raise ValueError("Se agotó el tiempo de aprobación; no se cambió nada.") from None
    if result.returncode != 0:
        if "-128" in result.stderr:
            raise ValueError("Cancelado; no se cambió nada.")
        raise ValueError("Falló la acción privilegiada; es posible que el cambio no se aplicara.")


def block_rule(port: int) -> str:
    # Descarta solo conexiones entrantes nuevas de otros equipos; el propio Mac (lo0) y las
    # respuestas a sus conexiones salientes siguen funcionando. Drop hace que el puerto parezca filtrado.
    return f"block drop in quick on ! lo0 proto tcp to any port {_port(port)} flags S/SA"


def block_port(port):
    port = _port(port)
    _admin(f"{PFCTL} -E >/dev/null 2>&1; echo '{block_rule(port)}' | {PFCTL} -a com.apple/guardian.{port} -f -")


def unblock_port(port):
    _admin(f"{PFCTL} -a com.apple/guardian.{_port(port)} -F rules")


def enable_firewall():
    # El modo sigiloso deja de responder a sondeos de puertos cerrados y a pings.
    _admin(f"{SOCKETFILTERFW} --setglobalstate on && {SOCKETFILTERFW} --setstealthmode on")
