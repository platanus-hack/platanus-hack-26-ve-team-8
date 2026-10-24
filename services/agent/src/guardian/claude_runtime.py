"""Runtime oficial de Claude Agent SDK con solo herramientas MCP de evidencia registrada.

Las importaciones son diferidas para que el modo de endpoint local funcione sin el
runtime opcional. No se exponen transcripciones del SDK, credenciales ni errores del proveedor.
"""
from __future__ import annotations

import asyncio
import importlib.util
import json
import tempfile


FAILURES = {
    "authentication_failed": "Anthropic rechazó la clave. Vuelve a configurar el proveedor con una clave válida en este Mac.",
    "billing_error": "Anthropic rechazó la solicitud por facturación. Revisa el saldo y los límites de gasto de la cuenta de API.",
    "rate_limit": "Anthropic limitó las solicitudes. Espera un momento y vuelve a intentarlo.",
    "model_not_found": "El modelo configurado no está disponible para esta clave de API.",
    "invalid_request": "Anthropic rechazó la solicitud. Revisa el modelo y los permisos de la cuenta de API.",
    "server_error": "Anthropic no está disponible temporalmente. Inténtalo más tarde.",
    "connection_error": "No se pudo completar la conexión de Claude. Revisa la red, el proxy y los certificados de este Mac.",
    "timeout": "La investigación agotó el tiempo disponible. Revisa la conexión y vuelve a intentarlo.",
    "sdk_missing": "Falta Claude Agent SDK. Reinstala Arkangel.",
    "cli_unavailable": "No se pudo iniciar el runtime de Claude incluido. Reinstala Arkangel y revisa los registros de macOS.",
    "turn_limit": "Claude agotó el límite de turnos sin completar la investigación.",
    "budget": "Claude superó el límite de respuesta o una herramienta rechazó la solicitud.",
    "invalid_output": "Claude no devolvió una investigación estructurada válida.",
    "runtime_error": "El runtime de Claude falló. Revisa la conexión y los registros de diagnóstico; si persiste, reinstala Arkangel.",
}


class ClaudeFailure(ValueError):
    def __init__(self, code):
        self.code = code if isinstance(code, str) and code in FAILURES else "runtime_error"
        super().__init__(f"{FAILURES[self.code]} [{self.code}]")


def sdk_available() -> bool:
    return importlib.util.find_spec("claude_agent_sdk") is not None


INVESTIGATION_SCHEMA = {
    "type": "object",
    "properties": {
        "status": {"type": "string", "enum": ["inconclusive", "needs_review", "no_finding"]},
        "title": {"type": "string"}, "summary": {"type": "string"},
        "hypotheses": {"type": "array", "maxItems": 20, "items": {
            "type": "object", "properties": {
                "statement": {"type": "string"}, "status": {"type": "string"},
                "evidence_ids": {"type": "array", "items": {"type": "string"}, "minItems": 1},
                "counterevidence": {"type": "string"}},
            "required": ["statement", "status", "evidence_ids", "counterevidence"],
            "additionalProperties": False}},
        "proposed_actions": {"type": "array", "maxItems": 10, "items": {
            "type": "object", "properties": {
                "title": {"type": "string"}, "description": {"type": "string"},
                "action": {"type": "object", "properties": {
                    "type": {"type": "string", "enum": ["block_port", "enable_firewall"]},
                    "port": {"type": "integer", "minimum": 1, "maximum": 65535}},
                    "required": ["type"], "additionalProperties": False}},
            "required": ["title", "description"], "additionalProperties": False}},
        "limitations": {"type": "array", "items": {"type": "string"}, "maxItems": 20}},
    "required": ["status", "title", "summary", "hypotheses", "proposed_actions", "limitations"],
    "additionalProperties": False,
}


async def _run(*, model, key, system_prompt, prompt, tools, execute_tool,
               max_turns, timeout, max_response_bytes):
    from claude_agent_sdk import (ClaudeAgentOptions, ClaudeSDKClient, PermissionResultAllow,
                                 PermissionResultDeny, AssistantMessage, ResultMessage, create_sdk_mcp_server, tool)

    registered = []
    allowed = set()
    callback_failed = False

    def register(definition):
        function = definition["function"]
        name = function["name"]
        allowed.add("mcp__guardian__" + name)

        async def callback(arguments):
            nonlocal callback_failed
            try:
                payload = execute_tool(name, arguments)
                return {"content": [{"type": "text", "text": json.dumps(payload)}]}
            except Exception:
                callback_failed = True
                return {"is_error": True, "content": [{"type": "text", "text": "La herramienta de evidencia rechazó la solicitud."}]}

        return tool(name, function["description"], function["parameters"])(callback)

    for definition in tools:
        registered.append(register(definition))

    async def permission(tool_name, arguments, context):
        if tool_name in allowed:
            return PermissionResultAllow()
        return PermissionResultDeny(message="Solo se permiten las herramientas de evidencia registrada de Guardian.", interrupt=True)

    server = create_sdk_mcp_server(name="guardian", version="1.0.0", tools=registered)
    # El SDK lanza su CLI incluida, nunca un comando arbitrario propuesto por un
    # modelo. Config/cwd nuevos excluyen sesiones existentes y archivos del proyecto.
    with tempfile.TemporaryDirectory(prefix="guardian-claude-") as isolated:
        options = ClaudeAgentOptions(
            model=model, system_prompt=system_prompt, tools=[], allowed_tools=sorted(allowed),
            mcp_servers={"guardian": server}, can_use_tool=permission,
            permission_mode="default", setting_sources=[], settings='{"disableAllHooks":true}',
            cwd=isolated, max_turns=max_turns, max_buffer_size=max_response_bytes,
            output_format={"type": "json_schema", "schema": INVESTIGATION_SCHEMA},
            extra_args={"strict-mcp-config": None, "no-session-persistence": None},
            env={"ANTHROPIC_API_KEY": key, "ANTHROPIC_AUTH_TOKEN": "", "CLAUDE_CODE_OAUTH_TOKEN": "",
                 "CLAUDE_CONFIG_DIR": isolated, "ANTHROPIC_BASE_URL": "https://api.anthropic.com",
                 "CLAUDE_CODE_USE_BEDROCK": "0", "CLAUDE_CODE_USE_VERTEX": "0",
                 "CLAUDE_CODE_USE_FOUNDRY": "0", "DISABLE_TELEMETRY": "1",
                 "DISABLE_ERROR_REPORTING": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"},
            stderr=lambda _: None,
        )
        async with asyncio.timeout(timeout):
            async with ClaudeSDKClient(options=options) as client:
                await client.query(prompt)
                received_bytes = 0
                async for message in client.receive_response():
                    received_bytes += len(repr(message).encode())
                    if received_bytes > max_response_bytes or callback_failed:
                        raise ClaudeFailure("budget")
                    if isinstance(message, AssistantMessage) and message.error:
                        raise ClaudeFailure(message.error)
                    if isinstance(message, ResultMessage):
                        if message.is_error or message.subtype != "success":
                            status = getattr(message, "api_error_status", None)
                            code = {401: "authentication_failed", 403: "authentication_failed",
                                    402: "billing_error", 404: "model_not_found", 429: "rate_limit",
                                    500: "server_error", 503: "server_error", 529: "server_error"}.get(status, "runtime_error")
                            if message.subtype == "error_max_turns":
                                code = "turn_limit"
                            raise ClaudeFailure(code)
                        final = getattr(message, "structured_output", None)
                        if final is None:
                            final = json.loads(message.result or "")
                        if not isinstance(final, dict):
                            raise ClaudeFailure("invalid_output")
                        return final
    raise ClaudeFailure("invalid_output")


def run_claude(**kwargs) -> dict:
    try:
        return asyncio.run(_run(**kwargs))
    except ClaudeFailure:
        raise
    except Exception as error:
        # Never forward SDK exception text, stderr, transcripts, or provider bodies.
        if isinstance(error, ImportError):
            code = "sdk_missing"
        elif isinstance(error, TimeoutError):
            code = "timeout"
        elif isinstance(error, json.JSONDecodeError):
            code = "invalid_output"
        elif type(error).__name__ in {"CLINotFoundError", "CLIConnectionError", "ProcessError"} or isinstance(error, (FileNotFoundError, PermissionError)):
            code = "cli_unavailable"
        elif isinstance(error, OSError):
            code = "connection_error"
        else:
            code = "runtime_error"
        raise ClaudeFailure(code) from None
