import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from guardian import demo
from guardian.store import Store
from guardian.telemetry import _observation


def exclusive_move(source_fd, source, target_fd, target):
    """Portable stand-in; native exclusive rename is covered in test_response."""
    os.link(source, target, src_dir_fd=source_fd, dst_dir_fd=target_fd, follow_symlinks=False)
    os.unlink(source, dir_fd=source_fd)


class DemoLabTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.store = Store(Path(directory.name).resolve() / "test.sqlite3")
        self.lab = demo.DemoLab(self.store)

    def prepare(self):
        self.lab.prepare()
        return Path(self.lab.directory)

    def test_prepare_is_explicit_safe_and_restart_is_disabled(self):
        self.assertFalse(self.lab.status()["enabled"])
        with self.assertRaises(ValueError):
            self.lab.attach()
        root = self.prepare()
        self.assertEqual({p.name for p in root.iterdir()}, {".env", "config.json"})
        self.assertEqual((root / ".env").read_text(), demo.DEMO_CONTENT)
        self.assertEqual(json.loads((root / "config.json").read_text()), demo.SAFE_CONFIG)
        attached = self.lab.attach()
        info = (root / "config.json").stat()
        self.assertEqual(attached["config_device"], str(info.st_dev))
        self.assertEqual(attached["config_inode"], str(info.st_ino))
        self.assertEqual(self.lab.status()["config_state"], "safe")
        self.assertFalse(self.lab.report(self.lab.session_id, "upload_attempt")["allowed"])
        restarted = demo.DemoLab(self.store)
        self.assertFalse(restarted.status()["enabled"])
        before = self.store.count()
        restarted.inspect()
        self.assertEqual(self.store.count(), before)

    def test_attach_refuses_even_valid_replacement_config(self):
        root = self.prepare()
        replacement = root / "replacement.json"
        replacement.write_text(json.dumps(demo.SAFE_CONFIG))
        replacement.replace(root / "config.json")
        with self.assertRaises(ValueError):
            self.lab.attach()
        self.assertTrue(self.lab.uploads_blocked)

    def test_independent_inspection_detects_change_and_records_only_metadata(self):
        root = self.prepare()
        (root / "config.json").write_text(json.dumps(demo.UNSAFE_CONFIG))
        self.lab.inspect()
        self.assertEqual(self.lab.status()["config_state"], "unsafe")
        self.assertTrue(self.lab.report(self.lab.session_id, "upload_attempt")["allowed"])
        self.assertEqual(self.lab.status()["events"][-1]["attributes"]["trust"], "self_reported")
        (root / "config.json").write_text('PRIVATE_CONTENT_MUST_NOT_BE_RECORDED')
        self.lab.inspect()
        self.assertEqual(self.lab.status()["config_state"], "unavailable")
        self.assertFalse(self.lab.report(self.lab.session_id, "upload_attempt")["allowed"])
        recorded = json.dumps(self.store.observations(500))
        self.assertNotIn("PRIVATE_CONTENT_MUST_NOT_BE_RECORDED", recorded)
        self.assertNotIn(demo.DEMO_CONTENT.strip(), recorded)

    def test_untrusted_event_types_and_stale_sessions_rejected(self):
        self.prepare()
        for event in ("execute", {}, [], None, 1):
            with self.subTest(event=event), self.assertRaises(ValueError):
                self.lab.report(self.lab.session_id, event)
        for identifier in ("stale", [], {}, None):
            with self.subTest(identifier=identifier), self.assertRaises(ValueError):
                self.lab.report(identifier, "file_read")
        previous = self.lab.session_id
        self.lab.prepare()
        with self.assertRaises(ValueError):
            self.lab.report(previous, "file_read")
        self.lab.stop()
        with self.assertRaises(ValueError):
            self.lab.report(self.lab.session_id, "file_read")

    def test_repair_preserves_prior_config_and_denies_future_uploads(self):
        root = self.prepare()
        (root / "config.json").write_text(json.dumps(demo.UNSAFE_CONFIG))
        with patch.object(demo, "rename_exclusive", side_effect=exclusive_move):
            result = self.lab.repair(self.lab.session_id)
        self.assertTrue(result["uploads_blocked"])
        self.assertEqual(result["config_state"], "safe")
        self.assertEqual(json.loads((root / "config.json").read_text()), demo.SAFE_CONFIG)
        self.assertEqual(json.loads((root / "config.before-repair.json").read_text()), demo.UNSAFE_CONFIG)
        self.assertFalse(self.lab.report(self.lab.session_id, "upload_attempt")["allowed"])
        # A client cannot undo a repair by writing an unsafe configuration again.
        (root / "config.json").write_text(json.dumps(demo.UNSAFE_CONFIG))
        self.assertFalse(self.lab.report(self.lab.session_id, "upload_attempt")["allowed"])

    def test_linked_or_replaced_targets_leave_unrelated_files_intact(self):
        root = self.prepare()
        other = root.parent / "unrelated.json"
        other.write_text(json.dumps(demo.UNSAFE_CONFIG))
        target = root / "config.json"
        target.unlink()
        target.symlink_to(other)
        self.lab.inspect()
        self.assertEqual(self.lab.config_state, "unavailable")
        with self.assertRaises(ValueError):
            self.lab.repair(self.lab.session_id)
        self.assertTrue(target.is_symlink())
        self.assertEqual(json.loads(other.read_text()), demo.UNSAFE_CONFIG)
        self.assertTrue(self.lab.uploads_blocked)
        target.unlink()
        os.link(other, target)
        with self.assertRaises(ValueError):
            self.lab.repair(self.lab.session_id)
        self.assertEqual(json.loads(other.read_text()), demo.UNSAFE_CONFIG)

    def test_changed_directory_and_failed_repair_fail_closed(self):
        root = self.prepare()
        root.rename(root.with_name(root.name + "-original"))
        root.mkdir(mode=0o700)
        (root / "config.json").write_text(json.dumps(demo.UNSAFE_CONFIG))
        self.lab.inspect()
        self.assertEqual(self.lab.config_state, "unavailable")
        with self.assertRaises(ValueError):
            self.lab.repair(self.lab.session_id)
        self.assertEqual(json.loads((root / "config.json").read_text()), demo.UNSAFE_CONFIG)
        self.assertTrue(self.lab.uploads_blocked)
        self.assertEqual(self.lab.events[-1]["attributes"]["event"], "repair_failed")

    def test_linked_base_directory_is_never_used(self):
        other = self.store.path.parent / "other"
        other.mkdir()
        (self.store.path.parent / "demo").symlink_to(other, target_is_directory=True)
        with self.assertRaises(OSError):
            self.lab.prepare()
        self.assertFalse(self.lab.enabled)
        self.assertEqual(list(other.iterdir()), [])

    def test_concurrent_replacement_is_preserved_and_not_published_over(self):
        root = self.prepare()
        target = root / "config.json"
        target.write_text(json.dumps(demo.UNSAFE_CONFIG))

        def replace_then_move(source_fd, source, target_fd, destination):
            if source == "config.json":
                target.unlink()
                target.write_text("UNRELATED_REPLACEMENT")
            exclusive_move(source_fd, source, target_fd, destination)

        with patch.object(demo, "rename_exclusive", side_effect=replace_then_move), self.assertRaises(ValueError):
            self.lab.repair(self.lab.session_id)
        self.assertEqual((root / "config.before-repair.json").read_text(), "UNRELATED_REPLACEMENT")
        self.assertTrue(self.lab.uploads_blocked)
        self.assertEqual(self.lab.config_state, "unavailable")

    def test_occupied_destination_during_repair_is_not_overwritten(self):
        root = self.prepare()
        target = root / "config.json"
        target.write_text(json.dumps(demo.UNSAFE_CONFIG))

        def occupy_then_move(source_fd, source, target_fd, destination):
            if source == "config.secure.json":
                target.write_text("DO_NOT_OVERWRITE")
            exclusive_move(source_fd, source, target_fd, destination)

        with patch.object(demo, "rename_exclusive", side_effect=occupy_then_move), self.assertRaises(ValueError):
            self.lab.repair(self.lab.session_id)
        self.assertEqual(target.read_text(), "DO_NOT_OVERWRITE")
        self.assertEqual(json.loads((root / "config.before-repair.json").read_text()), demo.UNSAFE_CONFIG)
        self.assertTrue(self.lab.uploads_blocked)

    def test_report_budget_and_recent_status_history_are_bounded(self):
        self.prepare()
        for _ in range(100):
            self.lab.report(self.lab.session_id, "file_read")
        self.assertEqual(len(self.lab.status()["events"]), 12)
        with self.assertRaises(ValueError):
            self.lab.report(self.lab.session_id, "upload_attempt")
        self.assertTrue(self.lab.uploads_blocked)

    def test_each_distinct_demo_behavior_reaches_main_alert_count_once(self):
        root = self.prepare()
        self.assertEqual(self.store.alert_counts(), {"unacknowledged": 0, "pending": 0})
        (root / "config.json").write_text(json.dumps(demo.UNSAFE_CONFIG))
        self.lab.inspect()
        config_alert = self.store.alerts()[0]
        self.assertEqual(config_alert["signal"]["attributes"]["rule"], "demo_config_unsafe")
        self.assertEqual(config_alert["before"]["attributes"]["config_state"], "safe")
        self.assertEqual(config_alert["after"]["attributes"]["config_state"], "unsafe")
        for expected, event in enumerate(("file_read", "upload_attempt", "upload_succeeded"), start=2):
            self.lab.report(self.lab.session_id, event)
            self.assertEqual(self.store.alert_counts(), {"unacknowledged": expected, "pending": 0})
            self.lab.report(self.lab.session_id, event)
            self.assertEqual(self.store.alert_counts()["unacknowledged"], expected)
        (root / "config.json").write_text(json.dumps(demo.SAFE_CONFIG))
        self.lab.inspect()
        (root / "config.json").write_text(json.dumps(demo.UNSAFE_CONFIG))
        self.lab.inspect()
        self.assertEqual(self.store.alert_counts()["unacknowledged"], 4)
        with patch.object(demo, "rename_exclusive", side_effect=OSError), self.assertRaises(ValueError):
            self.lab.repair(self.lab.session_id)
        self.assertEqual(self.store.alert_counts(), {"unacknowledged": 5, "pending": 0})
        with self.assertRaises(ValueError):
            self.lab.repair(self.lab.session_id)
        self.assertEqual(self.store.alert_counts()["unacknowledged"], 5)
        self.assertEqual(self.store.alerts(pending=True), [])
        for alert in self.store.alerts():
            self.assertTrue(alert["signal"]["attributes"]["simulation"])
            self.assertFalse(alert["investigated"])
            self.assertEqual(alert["signal"]["source"], "demo_lab")

    def test_new_session_generates_new_alerts_and_self_reports_stay_labeled(self):
        self.prepare()
        self.lab.report(self.lab.session_id, "file_read")
        alert = self.store.alerts()[0]
        self.assertEqual(alert["signal"]["attributes"]["trust"], "self_reported")
        self.assertIn("informó", alert["reason"])
        self.lab.prepare()
        self.lab.report(self.lab.session_id, "file_read")
        self.assertEqual(self.store.alert_counts(), {"unacknowledged": 2, "pending": 0})
        self.assertEqual(self.store.alerts(pending=True), [])

    def test_demo_alerts_do_not_change_real_pending_queue_or_acknowledgment(self):
        coverage = [{"source": "tcp_listeners", "status": "available"}]
        self.store.detect([], coverage)
        listener = _observation("tcp_listener", "tcp_listeners", "123:*:5432", "Escucha de prueba",
                                {"executable": "postgres", "local_address": "*:5432", "port": 5432,
                                 "bind_scope": "any"})
        self.store.detect([listener], coverage)
        real_alert = self.store.alerts(pending=True)[0]
        self.prepare()
        self.lab.report(self.lab.session_id, "file_read")
        self.assertEqual(self.store.alert_counts(), {"unacknowledged": 2, "pending": 1})
        self.assertEqual([alert["id"] for alert in self.store.alerts(pending=True)], [real_alert["id"]])
        demo_alert = next(alert for alert in self.store.alerts() if alert["signal"]["source"] == "demo_lab")
        self.store.acknowledge(demo_alert["id"])
        self.assertEqual(self.store.alert_counts(), {"unacknowledged": 1, "pending": 1})
        self.store.complete_alerts([real_alert["id"]])
        self.assertEqual(self.store.alert_counts(), {"unacknowledged": 1, "pending": 0})

    def test_missing_source_remains_in_real_pending_queue(self):
        self.store.detect([], [{"source": "tcp_listeners", "status": "available"}])
        listener = _observation("tcp_listener", "tcp_listeners", "123:*:5432", "Escucha de prueba",
                                {"executable": "postgres", "port": 5432, "bind_scope": "any"})
        self.store.detect([listener], [])
        alert = self.store.alerts()[0]
        del alert["signal"]["source"]
        with self.store.connect() as db:
            db.execute("UPDATE alerts SET payload=? WHERE id=?", (json.dumps(alert), alert["id"]))
        self.assertEqual(len(self.store.alerts(pending=True)), 1)
        self.assertEqual(self.store.alert_counts()["pending"], 1)


if __name__ == "__main__":
    unittest.main()
