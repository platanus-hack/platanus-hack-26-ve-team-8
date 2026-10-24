"""Vigilancia con archivos temporales, reloj y proveedores simulados; sin inferencias reales."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from guardian.investigator import _result, investigate
from guardian.service import GuardianService
from guardian.store import Store
from guardian.surveillance import collect_files, MAX_FILE_BYTES
from guardian.telemetry import _observation
from test_anthropic import fake_sdk


class FileWatchTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.home = Path(directory.name).resolve()
        self.library = self.home / "sistema"
        self.agents = self.home / "Library/LaunchAgents"
        self.agents.mkdir(parents=True)
        self.store = Store(self.home / "test.sqlite3")
        platform = patch("guardian.surveillance.platform.system", return_value="Darwin")
        platform.start()
        self.addCleanup(platform.stop)

    def scan(self):
        records, coverage = collect_files(self.store.watch_records(), self.home, self.library)
        self.store.detect(records, coverage)
        return records, coverage

    def test_baseline_changes_deletion_and_restart(self):
        target = self.home / ".zshrc"
        target.write_text("contenido privado inicial")
        self.scan()
        self.assertEqual(self.store.alerts(), [])
        target.write_text("contenido privado modificado")
        self.scan()
        self.scan()
        alerts = self.store.alerts()
        self.assertEqual(len(alerts), 1)
        self.assertEqual(alerts[0]["signal"]["attributes"]["change"], "modified")
        self.assertNotEqual(alerts[0]["before"]["attributes"]["sha256"], alerts[0]["after"]["attributes"]["sha256"])
        self.assertNotIn("contenido privado", json.dumps(alerts))
        self.store = Store(self.store.path)
        self.scan()
        self.assertEqual(len(self.store.alerts()), 1)
        target.unlink()
        self.scan()
        self.assertEqual(self.store.alerts()[0]["signal"]["attributes"]["change"], "deleted")
        self.store.acknowledge(alerts[0]["id"])
        self.assertEqual(len(self.store.watch_records()), 7)
        self.assertEqual(self.store.alert_counts()["pending"], 2)

    def test_empty_directory_new_file_and_retention(self):
        self.scan()
        target = self.agents / "ejemplo.plist"
        target.write_text("metadatos de prueba")
        self.scan()
        self.assertEqual(self.store.alerts()[0]["signal"]["attributes"]["change"], "created")
        with self.store.connect() as db:
            db.execute("UPDATE alerts SET created_at='2000-01-01T00:00:00+00:00'")
        self.store.prune()
        self.assertEqual(self.store.alerts(), [])
        self.scan()
        self.assertEqual(self.store.alerts(), [])
        target.unlink()
        self.scan()
        self.assertEqual(len(self.store.alerts()), 1)

    def test_symlink_large_file_and_type_change(self):
        target = self.home / ".zshrc"
        target.write_text("referencia")
        self.scan()
        target.unlink()
        target.symlink_to(self.home / "destino-privado")
        records, coverage = self.scan()
        self.assertEqual(self.store.alerts()[0]["after"]["attributes"]["file_type"], "symlink")
        self.assertNotIn("destino-privado", json.dumps(records))
        self.assertTrue(any(c["status"] == "partial" for c in coverage))
        target.unlink()
        target.write_bytes(b"x" * (MAX_FILE_BYTES + 1))
        records, coverage = self.scan()
        attributes = next(r["attributes"] for r in records if r["entity"] == str(target))
        self.assertNotIn("sha256", attributes)
        self.assertFalse(attributes["hash_available"])
        self.assertEqual(len(self.store.alerts()), 2)

    def test_permission_failure_preserves_reference(self):
        target = self.home / ".zshrc"
        target.write_text("referencia")
        self.scan()
        previous = self.store.watch_records()
        with patch("guardian.surveillance._file", side_effect=PermissionError):
            records, coverage = self.scan()
        self.assertTrue(all(r["attributes"].get("readable") is False for r in records))
        self.assertEqual(self.store.watch_records(), previous)
        self.assertEqual(self.store.alerts(), [])
        self.assertTrue(any(c["status"] == "partial" for c in coverage))
        self.scan()
        self.assertEqual(self.store.alerts(), [])

    def test_directory_permission_failure_is_not_deletion(self):
        target = self.agents / "ejemplo.plist"
        target.write_text("referencia")
        self.scan()
        previous = self.store.watch_records()
        with patch("guardian.surveillance._open_directory", side_effect=PermissionError):
            records, coverage = self.scan()
        self.assertEqual(records, [])
        self.assertEqual(self.store.watch_records(), previous)
        self.assertEqual(self.store.alerts(), [])
        self.assertTrue(all(c["status"] == "partial" for c in coverage))

    def test_initial_unreadable_file_does_not_become_false_creation(self):
        target = self.home / ".zshrc"
        target.write_text("referencia")
        with patch("guardian.surveillance._file", side_effect=PermissionError):
            self.scan()
        self.scan()
        self.assertEqual(self.store.alerts(), [])
        target.write_text("cambio posterior")
        self.scan()
        self.assertEqual(len(self.store.alerts()), 1)

    def test_directory_symlink_is_not_followed(self):
        self.agents.rmdir()
        destination = self.home / "otro-directorio"
        destination.mkdir()
        (destination / "privado.plist").write_text("privado")
        self.agents.symlink_to(destination, target_is_directory=True)
        records, coverage = self.scan()
        self.assertFalse(any("privado.plist" in r["entity"] for r in records))
        self.assertEqual(next(c["status"] for c in coverage if c["source"] == "user_launch_files"), "partial")

    def test_changed_during_read_preserves_reference(self):
        target = self.home / ".zshrc"
        target.write_text("referencia")
        self.scan()
        original = os.fstat
        calls = 0
        def racing_stat(fd):
            nonlocal calls
            calls += 1
            if calls == 2:
                target.write_text("otro contenido durante lectura")
            return original(fd)
        with patch("guardian.surveillance.os.fstat", side_effect=racing_stat):
            records, coverage = self.scan()
        self.assertFalse(next(r for r in records if r["entity"] == str(target))["attributes"]["readable"])
        self.assertEqual(self.store.alerts(), [])
        self.scan()
        self.assertEqual(len(self.store.alerts()), 1)


class AutomationTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.store = Store(Path(directory.name) / "test.sqlite3")
        self.now = 100000.0
        self.calls = []
        self.records = []
        self.coverage = [{"source": "tcp_listeners", "status": "partial", "detail": "Solo escuchas visibles."}]
        self.service = GuardianService(self.store, collector=lambda: (self.records, self.coverage),
                                       investigator=self.investigator, clock=lambda: self.now)
        self.service.monitoring = True
        environment = patch.dict(os.environ, {"ANTHROPIC_API_KEY": "clave-simulada", "GUARDIAN_ALLOW_CLOUD": "1"}, clear=True)
        environment.start()
        self.addCleanup(environment.stop)

    def investigator(self, observations, **kwargs):
        self.calls.append(observations)
        self.last_coverage = kwargs["coverage"]
        return _result("Proveedor simulado sin conexión.")

    def signal(self):
        self.service.scan()
        self.records.append(_observation("tcp_listener", "tcp_listeners", "1:*:4567", "Escucha de prueba", {
            "pid": 1, "port": 4567, "executable": "servidor", "local_address": "*:4567", "bind_scope": "any"}))
        self.service.scan()

    def enable(self):
        self.service.dispatch({"method": "automation.set", "params": {"enabled": True, "consent": True}})

    def test_separate_consent_and_no_periodic_calls(self):
        self.service.auto_investigate()
        self.assertEqual(self.calls, [])
        with self.assertRaises(ValueError):
            self.service.dispatch({"method": "automation.set", "params": {"enabled": True}})
        self.enable()
        self.service.auto_investigate()
        self.assertEqual(self.calls, [])
        self.assertEqual(self.store.quota(self.now)["remaining"], 12)

    def test_limits_failures_restart_and_recovery(self):
        self.signal()
        self.enable()
        for i in range(12):
            self.service.auto_investigate()
            self.service.auto_investigate()
            self.assertEqual(len(self.calls), i + 1)
            self.now += 300
        self.assertEqual(self.store.alert_counts()["pending"], 1)
        self.assertEqual(self.store.quota(self.now)["remaining"], 0)
        restarted = Store(self.store.path)
        self.assertTrue(restarted.automation_enabled())
        self.assertEqual(restarted.quota(self.now)["remaining"], 0)
        self.service.auto_investigate()
        self.assertEqual(len(self.calls), 12)
        self.now += 86400
        def success(observations, **kwargs):
            result = _result("Sin hallazgos en esta evidencia.")
            result["status"] = "no_finding"
            return result
        self.service.investigator = success
        self.service.auto_investigate()
        self.assertEqual(self.store.alert_counts()["pending"], 0)
        self.assertEqual(self.store.alert_counts()["unacknowledged"], 1)

    def test_pause_missing_key_and_concurrent_manual_investigation(self):
        self.signal()
        self.enable()
        self.service.monitoring = False
        self.service.auto_investigate()
        self.service.monitoring = True
        with patch.dict(os.environ, {}, clear=True):
            self.service.auto_investigate()
        self.service.investigation_lock.acquire()
        try:
            self.service.auto_investigate()
        finally:
            self.service.investigation_lock.release()
        self.assertEqual(self.calls, [])
        self.assertEqual(self.store.quota(self.now)["remaining"], 12)

    def test_relevant_evidence_prioritized_and_new_signals_survive(self):
        self.signal()
        self.enable()
        for i in range(510):
            self.store.ingest([_observation("process", "processes", str(i), "Proceso de prueba", {"pid": i})])
        self.service.auto_investigate()
        self.assertEqual(self.calls[0][0]["kind"], "detection")
        self.assertEqual(len(self.calls[0]), 500)
        self.assertTrue(any(c["source"] == "evidence_window" for c in self.last_coverage))
        def success(observations, **kwargs):
            self.records.append(_observation("tcp_listener", "tcp_listeners", "2:*:4568", "Otra escucha", {
                "pid": 2, "port": 4568, "executable": "otro", "local_address": "*:4568", "bind_scope": "any"}))
            self.service.scan()
            result = _result("Sin hallazgos.")
            result["status"] = "no_finding"
            return result
        self.service.investigator = success
        self.now += 300
        self.service.auto_investigate()
        self.assertEqual(self.store.alert_counts()["pending"], 1)

    def test_process_noise_firewall_and_listener_deduplication(self):
        self.signal()
        self.records[0]["attributes"]["pid"] = 2
        self.records[0]["entity"] = "2:*:4567"
        self.records.append(_observation("process", "processes", "3", "Proceso nuevo", {"pid": 3}))
        firewall = _observation("firewall", "application_firewall", "firewall", "Firewall", {"firewall_enabled": True, "stealth_mode": True})
        self.records.append(firewall)
        self.service.scan()
        self.assertEqual(len(self.store.alerts()), 1)
        firewall["attributes"]["stealth_mode"] = False
        self.service.scan()
        self.service.scan()
        self.assertEqual(len(self.store.alerts()), 2)

    def test_file_scan_interval(self):
        with patch("guardian.service.time.monotonic", return_value=0), patch.object(self.service, "file_collector", return_value=([], [])) as collector:
            self.service.scan()
            self.service.scan()
            self.assertEqual(collector.call_count, 1)
            with patch("guardian.service.time.monotonic", return_value=30):
                self.service.scan()
            self.assertEqual(collector.call_count, 2)
            self.service.dispatch({"method": "scan"})
            self.assertEqual(collector.call_count, 3)

    def test_cloud_receives_only_validated_change_metadata(self):
        sdk, captured = fake_sdk()
        item = _observation("detection", "shell_files", "/Users/privado/.zshrc", "TEXTO PRIVADO", {
            "category": "shell_startup", "change": "modified", "rule": "file_changed",
            "mode": 0o644, "previous_mode": 0o600, "owner": 501, "sha256": "HUELLA PRIVADA",
            "filename": "NOMBRE PRIVADO", "content": "SECRETO", "previous_owner": -1})
        with patch.dict("sys.modules", {"claude_agent_sdk": sdk}):
            investigate([item])
        serialized = json.dumps(captured["payloads"] + captured["prompts"])
        for private in ("/Users/privado", "TEXTO PRIVADO", "HUELLA PRIVADA", "NOMBRE PRIVADO", "SECRETO"):
            self.assertNotIn(private, serialized)
        attributes = json.loads(captured["payloads"][0]["content"][0]["text"])["untrusted_evidence"]["items"][0]["attributes"]
        self.assertEqual(attributes, {"category": "shell_startup", "change": "modified", "rule": "file_changed",
                                     "mode": 0o644, "previous_mode": 0o600, "owner": 501})


if __name__ == "__main__":
    unittest.main()
