import asyncio
import copy
import json
import os
import types
import unittest
from unittest.mock import patch

from guardian.claude_runtime import INVESTIGATION_SCHEMA, sdk_available, run_claude
from guardian.investigator import TOOLS, investigate
from guardian.providers import provider_config
from test_investigator import OBS, final


ENV = {"ANTHROPIC_API_KEY": "test-key-never-real", "GUARDIAN_ALLOW_CLOUD": "1"}


class FakeOptions:
    def __init__(self, **kwargs):
        self.__dict__.update(kwargs)


class FakeResult:
    def __init__(self, output, error=False, subtype="success"):
        self.structured_output = output
        self.is_error = error
        self.subtype = subtype
        self.result = None


def fake_sdk(callback_plan=None, output=None, failure=None):
    module = types.ModuleType("claude_agent_sdk")
    captured = {"payloads": [], "prompts": [], "options": None}
    output = output if output is not None else json.loads(final("observation_1")["choices"][0]["message"]["content"])
    plan = callback_plan if callback_plan is not None else [("search_observations", {}), ("get_coverage", {})]

    def tool(name, description, schema):
        def decorate(callback):
            return types.SimpleNamespace(name=name, handler=callback, schema=schema)
        return decorate

    class Client:
        def __init__(self, options):
            captured["options"] = options
        async def __aenter__(self):
            if failure:
                raise failure
            return self
        async def __aexit__(self, *args):
            pass
        async def query(self, prompt):
            captured["prompts"].append(prompt)
        async def receive_response(self):
            tools = {t.name: t for t in captured["options"].mcp_servers["guardian"]["tools"]} if plan else {}
            for name, arguments in plan:
                response = await tools[name].handler(arguments)
                captured["payloads"].append(copy.deepcopy(response))
            yield FakeResult(output)

    module.ClaudeAgentOptions = FakeOptions
    module.ClaudeSDKClient = Client
    module.PermissionResultAllow = lambda: types.SimpleNamespace(behavior="allow")
    module.PermissionResultDeny = lambda **kwargs: types.SimpleNamespace(behavior="deny", **kwargs)
    module.ResultMessage = FakeResult
    module.tool = tool
    module.create_sdk_mcp_server = lambda **kwargs: kwargs
    return module, captured


class AnthropicTests(unittest.TestCase):
    @patch.dict(os.environ, ENV, clear=True)
    def test_default_and_override(self):
        provider = provider_config()
        self.assertEqual(provider.model, "claude-haiku-5-5")
        self.assertEqual(provider.name, "anthropic")
        self.assertNotIn("test-key", repr(provider))
        with patch.dict(os.environ, {"GUARDIAN_MODEL": "custom-model"}):
            self.assertEqual(provider_config().model, "custom-model")

    @patch.dict(os.environ, {"GUARDIAN_PROVIDER": "anthropic", "GUARDIAN_ALLOW_CLOUD": "1"}, clear=True)
    def test_missing_key_does_not_call(self):
        with patch("guardian.investigator.run_claude") as run:
            result = investigate(OBS)
        run.assert_not_called()
        self.assertEqual(result["status"], "inconclusive")

    @patch.dict(os.environ, {"ANTHROPIC_API_KEY": "test-key"}, clear=True)
    def test_cloud_opt_in_still_required(self):
        with patch("guardian.investigator.run_claude") as run:
            result = investigate(OBS)
        run.assert_not_called()
        self.assertIn("GUARDIAN_ALLOW_CLOUD", result["summary"])

    @patch.dict(os.environ, ENV, clear=True)
    def test_sdk_callbacks_structured_result_and_isolation(self):
        sdk, captured = fake_sdk()
        with patch.dict("sys.modules", {"claude_agent_sdk": sdk}), patch("guardian.investigator._complete") as legacy:
            records = copy.deepcopy(OBS)
            records[0]["attributes"].update(pid=123, RunAtLoad=True, Disabled=False)
            result = investigate(records, "PRIVATE QUESTION", [{"source": "processes", "status": "partial"}])
        legacy.assert_not_called()
        self.assertEqual(result["status"], "needs_review")
        self.assertEqual(result["hypotheses"][0]["evidence_ids"], ["real-id"])
        options = captured["options"]
        self.assertEqual(options.tools, [])
        self.assertEqual(options.setting_sources, [])
        self.assertEqual(options.model, "claude-haiku-5-5")
        self.assertEqual(options.max_turns, 6)
        self.assertEqual(options.output_format["schema"], INVESTIGATION_SCHEMA)
        self.assertIn("strict-mcp-config", options.extra_args)
        self.assertIn("no-session-persistence", options.extra_args)
        self.assertEqual(options.env["ANTHROPIC_API_KEY"], ENV["ANTHROPIC_API_KEY"])
        self.assertEqual(options.env["CLAUDE_CODE_OAUTH_TOKEN"], "")
        self.assertFalse(os.path.exists(options.cwd))
        self.assertEqual(options.env["CLAUDE_CONFIG_DIR"], options.cwd)
        serialized = json.dumps(captured["payloads"] + captured["prompts"])
        for private in ("PRIVATE QUESTION", "PRIVATE RAW TEXT", "PASSWORD", "/Users/private", "real-id", ENV["ANTHROPIC_API_KEY"]):
            self.assertNotIn(private, serialized)
        tool_payload = json.loads(captured["payloads"][0]["content"][0]["text"])
        self.assertIn("untrusted_evidence", tool_payload)
        attributes = tool_payload["untrusted_evidence"]["items"][0]["attributes"]
        self.assertEqual(attributes, {"pid": 123, "RunAtLoad": True, "Disabled": False})
        self.assertTrue(any("cobertura de recolección es parcial" in item for item in result["limitations"]))
        self.assertEqual(asyncio.run(options.can_use_tool("Bash", {"command": "anything"}, None)).behavior, "deny")
        self.assertEqual(asyncio.run(options.can_use_tool("mcp__guardian__get_coverage", {}, None)).behavior, "allow")

    @patch.dict(os.environ, ENV, clear=True)
    def test_sdk_citation_validation_and_budget(self):
        cases = [([], None), (None, json.loads(final("invented")["choices"][0]["message"]["content"])),
                 ([("get_coverage", {})] * 17, None)]
        for plan, output in cases:
            sdk, captured = fake_sdk(callback_plan=plan, output=output)
            with self.subTest(plan=plan), patch.dict("sys.modules", {"claude_agent_sdk": sdk}):
                result = investigate(OBS)
            self.assertEqual(result["status"], "inconclusive")
            self.assertEqual(result["hypotheses"], [])
            self.assertNotIn(ENV["ANTHROPIC_API_KEY"], json.dumps(result))

    @patch.dict(os.environ, ENV, clear=True)
    def test_missing_sdk_and_sdk_failure_are_private(self):
        sdk, _ = fake_sdk(failure=RuntimeError("SECRET test-key-never-real"))
        for module in (None, sdk):
            with patch.dict("sys.modules", {"claude_agent_sdk": module}):
                result = investigate(OBS)
            self.assertEqual(result["status"], "inconclusive")
            self.assertNotIn("SECRET", json.dumps(result))
            self.assertNotIn("test-key", json.dumps(result))

    def test_availability_helper(self):
        with patch("guardian.claude_runtime.importlib.util.find_spec", return_value=None):
            self.assertFalse(sdk_available())

    def test_installed_sdk_options_and_mcp_schema_without_launching_cli(self):
        try:
            import claude_agent_sdk as installed
        except ImportError:
            self.skipTest("Pinned SDK not installed in this interpreter")
        fake, captured = fake_sdk(callback_plan=[])
        with patch.object(installed, "ClaudeSDKClient", fake.ClaudeSDKClient), patch.object(installed, "ResultMessage", FakeResult):
            result = run_claude(model="claude-haiku-5-5", key="constructor-test-key", system_prompt="Defensive test",
                                prompt="No private content", tools=TOOLS, execute_tool=lambda *_: {},
                                max_turns=6, timeout=1, max_response_bytes=256_000)
        self.assertEqual(result["status"], "needs_review")
        self.assertIsInstance(captured["options"], installed.ClaudeAgentOptions)
        self.assertEqual(captured["options"].tools, [])

    @patch.dict(os.environ, {"GUARDIAN_MODEL_ENDPOINT": "http://localhost:1234/v1/chat/completions",
                             "GUARDIAN_MODEL": "local-model", "ANTHROPIC_API_KEY": "unused"}, clear=True)
    def test_existing_local_configuration_keeps_precedence(self):
        self.assertEqual(provider_config().name, "openai")
        self.assertEqual(provider_config().key, "")


if __name__ == "__main__":
    unittest.main()
