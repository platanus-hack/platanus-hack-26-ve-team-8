"""API-key verification for user-initiated onboarding; never echoes credentials."""

import json
import ssl
import urllib.error
import urllib.request
from .claude_runtime import sdk_available


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("Anthropic key verification cannot follow redirects.")


def validate_key(key: str):
    if not isinstance(key, str) or not 10 <= len(key) <= 4096 or any(c.isspace() for c in key):
        raise ValueError("Enter a valid Anthropic API key without spaces.")
    request = urllib.request.Request(
        "https://api.anthropic.com/v1/models/claude-haiku-5-5",
        headers={"x-api-key": key, "anthropic-version": "2023-06-01"},
    )
    try:
        import truststore
        # Use macOS certificate trust; Python.org installations may have no CA bundle.
        https = urllib.request.HTTPSHandler(context=truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT))
        with urllib.request.build_opener(NoRedirect, https).open(request, timeout=15) as response:
            raw = response.read(65537)
        if len(raw) > 65536:
            raise ValueError("Unexpected verification response")
        model = json.loads(raw)
        if model.get("type") != "model" or not str(model.get("id", "")).startswith("claude-haiku-5-5"):
            raise ValueError("Unexpected verification response")
    except urllib.error.HTTPError as error:
        if error.code in (401, 403):
            raise ValueError("Anthropic rejected this key. Check the key and its workspace permissions.") from None
        if error.code == 404:
            raise ValueError("Haiku 5.5 is not available for this API key.") from None
        if error.code == 429:
            raise ValueError("Anthropic is rate limiting requests. Try again shortly.") from None
        raise ValueError("Anthropic could not verify the key. Try again later.") from None
    except (OSError, ValueError, TypeError, AttributeError):
        raise ValueError("Could not verify the key with Anthropic. Check your connection and try again.") from None
