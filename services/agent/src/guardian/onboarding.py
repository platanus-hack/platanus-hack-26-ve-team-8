"""Verificación de la clave de API durante la configuración iniciada por el usuario; nunca repite credenciales."""

import json
import ssl
import urllib.error
import urllib.request
from .claude_runtime import sdk_available
from .diagnostics import logger


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("La verificación de la clave de Anthropic no puede seguir redirecciones.")


def validate_key(key: str):
    if not isinstance(key, str) or not 10 <= len(key) <= 4096 or any(c.isspace() for c in key):
        raise ValueError("Introduce una clave de API de Anthropic válida y sin espacios.")
    request = urllib.request.Request(
        "https://api.anthropic.com/v1/models/claude-haiku-5-5",
        headers={"x-api-key": key, "anthropic-version": "2023-06-01"},
    )
    try:
        import truststore
        # Usa la confianza de certificados de macOS; las instalaciones de Python.org pueden no tener paquete de CA.
        https = urllib.request.HTTPSHandler(context=truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT))
        with urllib.request.build_opener(NoRedirect, https).open(request, timeout=15) as response:
            raw = response.read(65537)
        if len(raw) > 65536:
            raise ValueError("Respuesta de verificación inesperada")
        model = json.loads(raw)
        if model.get("type") != "model" or not str(model.get("id", "")).startswith("claude-haiku-5-5"):
            raise ValueError("Respuesta de verificación inesperada")
    except urllib.error.HTTPError as error:
        logger.info("Verificación de Anthropic rechazada; HTTP=%d", error.code)
        if error.code in (401, 403):
            raise ValueError("Anthropic rechazó esta clave. Revisa la clave y los permisos de su espacio de trabajo.") from None
        if error.code == 404:
            raise ValueError("Haiku 5.5 no está disponible para esta clave de API.") from None
        if error.code == 429:
            raise ValueError("Anthropic está limitando la frecuencia de solicitudes. Inténtalo de nuevo en breve.") from None
        raise ValueError("Anthropic no pudo verificar la clave. Inténtalo más tarde.") from None
    except ImportError:
        logger.info("Verificación de Anthropic fallida: falta el componente TLS truststore.")
        raise ValueError("La instalación está incompleta: falta el componente TLS. Reinstala Arkangel.") from None
    except (OSError, ValueError, TypeError, AttributeError):
        logger.info("Verificación de Anthropic fallida: conexión, TLS o respuesta no válida.")
        raise ValueError("No se pudo verificar la clave con Anthropic. Revisa tu conexión e inténtalo de nuevo.") from None
