"""Configuración del proveedor para Claude Agent SDK y endpoints locales heredados."""

import os
from dataclasses import dataclass, field


@dataclass
class Provider:
    name: str
    endpoint: str
    model: str
    key: str = field(repr=False)

    @property
    def configured(self):
        return bool(self.endpoint and self.model and (self.key or self.name == "openai"))


def provider_config() -> Provider:
    endpoint = os.getenv("GUARDIAN_MODEL_ENDPOINT", "").strip()
    name = os.getenv("GUARDIAN_PROVIDER", "").strip() or ("openai" if endpoint else "anthropic")
    model = os.getenv("GUARDIAN_MODEL", "").strip()
    if name == "anthropic":
        return Provider(name, "https://api.anthropic.com/v1/messages",
                        model or "claude-haiku-5-5", os.getenv("ANTHROPIC_API_KEY", "").strip())
    if name == "openai":
        return Provider(name, endpoint, model, os.getenv("GUARDIAN_MODEL_KEY", "").strip())
    return Provider(name, "", "", "")
