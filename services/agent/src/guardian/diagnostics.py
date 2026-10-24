"""Local, bounded diagnostics. Callers must pass only fixed messages and safe scalars."""
import logging
from logging.handlers import RotatingFileHandler
from pathlib import Path

logger = logging.getLogger("guardian.diagnostics")
logger.addHandler(logging.NullHandler())
logger.propagate = False


def configure_logging():
    try:
        directory = Path.home() / "Library/Logs/Arkangel"
        directory.mkdir(parents=True, exist_ok=True)
        handler = RotatingFileHandler(directory / "agent.log", maxBytes=512_000,
                                      backupCount=2, encoding="utf-8")
        handler.setFormatter(logging.Formatter("%(asctime)s %(message)s"))
        logger.addHandler(handler)
        logger.setLevel(logging.INFO)
        logger.info("Agente iniciado; diagnóstico local sin credenciales ni evidencia.")
    except OSError:
        # A read-only/full log directory must not prevent local protection.
        pass
