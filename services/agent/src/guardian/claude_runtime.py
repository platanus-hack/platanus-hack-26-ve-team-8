"""Official Claude Agent SDK runtime with only recorded-evidence MCP tools.

Imports are lazy so local endpoint mode remains usable without the optional runtime
being installed. No SDK transcripts, credentials, or provider errors are surfaced.
"""
from __future__ import annotations

import asyncio
import importlib.util
import json
import tempfile


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
            "type": "object", "properties": {"title": {"type": "string"}, "description": {"type": "string"}},
            "required": ["title", "description"], "additionalProperties": False}},
        "limitations": {"type": "array", "items": {"type": "string"}, "maxItems": 20}},
    "required": ["status", "title", "summary", "hypotheses", "proposed_actions", "limitations"],
    "additionalProperties": False,
}


async def _run(*, model, key, system_prompt, prompt, tools, execute_tool,
               max_turns, timeout, max_response_bytes):
    from claude_agent_sdk import (ClaudeAgentOptions, ClaudeSDKClient, PermissionResultAllow,
                                 PermissionResultDeny, ResultMessage, create_sdk_mcp_server, tool)

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
                return {"is_error": True, "content": [{"type": "text", "text": "Evidence tool rejected the request."}]}

        return tool(name, function["description"], function["parameters"])(callback)

    for definition in tools:
        registered.append(register(definition))

    async def permission(tool_name, arguments, context):
        if tool_name in allowed:
            return PermissionResultAllow()
        return PermissionResultDeny(message="Only Guardian recorded-evidence tools are permitted.", interrupt=True)

    server = create_sdk_mcp_server(name="guardian", version="1.0.0", tools=registered)
    # The SDK launches its bundled CLI, never an arbitrary command supplied by a
    # model. Fresh config/cwd excludes existing login sessions and project files.
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
                        raise ValueError("Claude response or tool budget exceeded")
                    if isinstance(message, ResultMessage):
                        if message.is_error or message.subtype != "success":
                            raise ValueError("Claude investigation did not complete")
                        final = getattr(message, "structured_output", None)
                        if final is None:
                            final = json.loads(message.result or "")
                        if not isinstance(final, dict):
                            raise ValueError("Invalid structured investigation")
                        return final
    raise ValueError("Claude returned no structured result")


def run_claude(**kwargs) -> dict:
    try:
        return asyncio.run(_run(**kwargs))
    except Exception:
        # SDK error strings can include subprocess output. Return only a fixed
        # local error; neither logs nor investigation output include that content.
        raise ValueError("Claude Agent SDK unavailable or investigation failed") from None
