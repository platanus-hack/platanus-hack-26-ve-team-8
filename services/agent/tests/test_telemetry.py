import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from guardian import telemetry


class TelemetryTests(unittest.TestCase):
    def test_processes_only_keep_executable_name(self):
        items = telemetry.parse_processes("12 1 501 Sat Oct 24 09:00:00 2026 /Applications/My App/Contents/MacOS/App\ninvalid\n")
        self.assertEqual(items[0]["attributes"], {"pid": 12, "parent_pid": 1, "uid": 501, "executable": "App", "start_time_local": "Sat Oct 24 09:00:00 2026"})
        self.assertNotIn("args", telemetry.PS_COMMAND)

    def test_process_lifetimes_have_distinct_entities(self):
        first = telemetry.parse_processes("12 1 501 Sat Oct 24 09:00:00 2026 /bin/tool")[0]
        second = telemetry.parse_processes("12 1 501 Sat Oct 24 10:00:00 2026 /bin/tool")[0]
        self.assertNotEqual(first["entity"], second["entity"])

    def test_launch_agent_arguments_only_exposes_first_basename(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "agent.plist").write_bytes(plistlib.dumps({"ProgramArguments": ["/private/location/tool", "secret"]}))
            items, _ = telemetry._launch_agents(path)
        self.assertEqual(items[0]["attributes"]["executable"], "tool")
        self.assertNotIn("secret", str(items))
        self.assertNotIn("/private/location", str(items))

    def test_listeners_multiple_addresses(self):
        items = telemetry.parse_listeners("p12\ncExample\nn*:8080\nn[::1]:8081\npbad\nn*:9000\n")
        self.assertEqual(len(items), 2)
        self.assertEqual(items[1]["attributes"]["local_address"], "[::1]:8081")

    def test_plist_secret_fields_are_not_returned(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "agent.plist").write_bytes(plistlib.dumps({"Label": "test.agent", "Program": "/bin/tool", "ProgramArguments": ["tool", "secret"], "EnvironmentVariables": {"KEY": "secret"}, "KeepAlive": {"PathState": {"private": True}}}))
            (path / "bad.plist").write_bytes(b"invalid")
            (path / "malformed.plist").write_bytes(b'<?xml version="1.0"?><plist><dict>')
            items, coverage = telemetry._launch_agents(path)
        self.assertEqual(items[0]["attributes"]["executable"], "tool")
        self.assertNotIn("secret", str(items))
        self.assertNotIn("private", str(items))
        self.assertIn("no se pudieron", coverage["detail"])

    def test_command_denial_and_timeout(self):
        for exception, expected in ((PermissionError(), "denied"), (subprocess.TimeoutExpired("ps", 10), "unknown"), (FileNotFoundError(), "unavailable")):
            with self.subTest(expected=expected), patch.object(telemetry.subprocess, "run", side_effect=exception):
                items, coverage = telemetry._command_snapshot("processes", telemetry.PS_COMMAND, telemetry.parse_processes)
                self.assertEqual(items, [])
                self.assertEqual(coverage["status"], expected)

    def test_partial_output_is_not_called_complete(self):
        result = subprocess.CompletedProcess([], 1, "1 0 0 Sat Oct 24 09:00:00 2026 /bin/launchd\n", "denied")
        with patch.object(telemetry.subprocess, "run", return_value=result):
            items, coverage = telemetry._command_snapshot("processes", telemetry.PS_COMMAND, telemetry.parse_processes)
        self.assertEqual(len(items), 1)
        self.assertEqual(coverage["status"], "partial")

    def test_directory_denied(self):
        with patch.object(Path, "iterdir", side_effect=PermissionError()):
            self.assertEqual(telemetry._launch_agents(Path("unused"))[1]["status"], "denied")

    def test_unsupported_platform_does_not_execute(self):
        with patch.object(telemetry.platform, "system", return_value="Linux"), patch.object(telemetry.subprocess, "run") as run:
            items, coverage = telemetry.collect_snapshot()
        run.assert_not_called()
        self.assertEqual(items, [])
        self.assertTrue(all(item["status"] == "unsupported" for item in coverage))

    def test_snapshot_contract_and_fixed_commands(self):
        with patch.object(telemetry.platform, "system", return_value="Darwin"), patch.object(telemetry.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run, patch.object(telemetry, "_launch_agents", return_value=([], {"source": "user_launch_agents", "status": "partial", "detail": "fixture"})), patch.object(telemetry.shutil, "which", return_value=None):
            items, coverage = telemetry.collect_snapshot()
        self.assertEqual(items, [])
        self.assertEqual(len(coverage), 4)
        self.assertEqual([call.args[0] for call in run.call_args_list], [telemetry.PS_COMMAND, telemetry.LSOF_COMMAND])
        self.assertTrue(all(call.kwargs["shell"] is False for call in run.call_args_list))


if __name__ == "__main__":
    unittest.main()
