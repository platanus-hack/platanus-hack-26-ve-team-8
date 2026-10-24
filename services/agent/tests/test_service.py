import json
import socket
import tempfile
import threading
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

from guardian.service import GuardianService, Handler, Server
from guardian.store import Store


def observation(identifier="one", summary="Process example"):
    return {"id": identifier, "timestamp": datetime.now(timezone.utc).isoformat(),
            "kind": "process", "source": "processes", "entity": "123",
            "summary": summary, "attributes": {"pid": 123}}


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.store = Store(Path(self.directory.name) / "test.sqlite3")
        self.coverage = [{"source": "processes", "status": "partial", "detail": "Snapshot only"}]
        self.service = GuardianService(self.store, collector=lambda: ([observation()], self.coverage),
                                       investigator=self.investigate)

    def investigate(self, observations, question, coverage, on_step=None):
        return {"id": "case-one", "created_at": datetime.now(timezone.utc).isoformat(),
                "status": "inconclusive", "title": question, "summary": "Fixture",
                "hypotheses": [], "steps": [], "proposed_actions": [],
                "limitations": [coverage[0]["detail"]]}

    def test_records_changes_not_repeated_snapshots(self):
        self.assertEqual(self.store.ingest([observation()]), 1)
        self.assertEqual(self.store.ingest([observation("two")]), 0)
        self.assertEqual(self.store.ingest([observation("three", "Changed")]), 1)
        self.assertEqual(self.store.count(), 2)

    def test_unchanged_entity_rerecorded_after_retention_expires(self):
        old = observation("old")
        old["timestamp"] = (datetime.now(timezone.utc) - timedelta(days=8)).isoformat()
        self.assertEqual(self.store.ingest([old]), 1)
        self.store.prune()
        self.assertEqual(self.store.count(), 0)
        self.assertEqual(self.store.ingest([observation("new")]), 1)
        self.store.prune()
        self.assertEqual(self.store.ingest([observation("again")]), 0)

    def test_status_not_blocked_by_slow_collection(self):
        collecting, release = threading.Event(), threading.Event()
        def slow_collector():
            collecting.set()
            release.wait(5)
            return [observation()], self.coverage
        self.service.collector = slow_collector
        worker = threading.Thread(target=self.service.scan)
        worker.start()
        try:
            self.assertTrue(collecting.wait(3))
            done = threading.Event()
            threading.Thread(target=lambda: (self.service.status(), done.set()), daemon=True).start()
            self.assertTrue(done.wait(1))
        finally:
            release.set()
            worker.join(5)

    def test_scan_then_investigate_persists_evidence_and_case(self):
        self.service.dispatch({"method": "scan"})
        result = self.service.dispatch({"method": "investigate", "params": {"question": "What changed?"}})
        self.assertEqual(result["title"], "What changed?")
        self.assertEqual(result["limitations"], ["Snapshot only"])
        self.assertEqual(len(self.store.investigations()), 1)

    def test_no_remediation_or_arbitrary_command_method(self):
        for method in ("execute", "remediate", "shell"):
            with self.assertRaises(ValueError):
                self.service.dispatch({"method": method})

    def test_monitoring_requires_boolean_and_observations_bounded(self):
        with self.assertRaises(ValueError):
            self.service.dispatch({"method": "monitoring.set", "params": {"enabled": "true"}})
        with self.assertRaises(ValueError):
            self.service.dispatch({"method": "observations", "params": {"limit": 99999}})
        self.assertTrue(self.service.dispatch({"method": "monitoring.set", "params": {"enabled": True}})["monitoring"])

    def test_exposed_listeners_and_user_approved_block(self):
        listener = {"id": "l1", "timestamp": datetime.now(timezone.utc).isoformat(), "kind": "tcp_listener",
                    "source": "tcp_listeners", "entity": "9:*:3000", "summary": "TCP listener owned by node",
                    "attributes": {"pid": 9, "executable": "node", "port": 3000, "bind_scope": "any"}}
        local = dict(listener, id="l2", entity="9:127.0.0.1:5173",
                     attributes={"pid": 9, "executable": "node", "port": 5173, "bind_scope": "loopback"})
        self.service.collector = lambda: ([listener, local], self.coverage)
        status = self.service.dispatch({"method": "scan"})
        self.assertEqual(status["exposed"], [{"port": 3000, "executable": "node", "bind_scope": "any", "blocked": False}])
        with patch("guardian.service.defense.block_port") as block:
            status = self.service.dispatch({"method": "defense.apply", "params": {"action": "block_port", "port": 3000}})
        block.assert_called_once_with(3000)
        self.assertTrue(status["exposed"][0]["blocked"])
        with patch("guardian.service.defense.unblock_port", side_effect=ValueError("Cancelado; no se cambió nada.")):
            with self.assertRaises(ValueError):
                self.service.dispatch({"method": "defense.apply", "params": {"action": "unblock_port", "port": 3000}})
        self.assertEqual(self.service.status()["blocked_ports"], [3000])
        with self.assertRaises(ValueError):
            self.service.dispatch({"method": "defense.apply", "params": {"action": "open_port", "port": 22}})

    def test_concurrent_investigation_rejected(self):
        self.service.investigation_lock.acquire()
        try:
            with self.assertRaisesRegex(ValueError, "en curso"):
                self.service.investigate()
        finally:
            self.service.investigation_lock.release()

    def test_socket_protocol_with_synthetic_evidence(self):
        path = str(Path(self.directory.name) / "test.sock")
        server = Server(path, Handler)
        server.guardian = self.service
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            for method in ("scan", "observations", "investigate", "investigations"):
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                    client.settimeout(3)
                    client.connect(path)
                    client.sendall(json.dumps({"id": "request", "method": method}).encode() + b"\n")
                    response = json.loads(client.makefile("rb").readline())
                    self.assertEqual(response["id"], "request")
                    self.assertIn("result", response)
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=3)


if __name__ == "__main__":
    unittest.main()
