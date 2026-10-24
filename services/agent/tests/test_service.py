import json
import socket
import tempfile
import threading
import unittest
from datetime import datetime, timezone
from pathlib import Path

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

    def investigate(self, observations, question, coverage):
        return {"id": "case-one", "created_at": datetime.now(timezone.utc).isoformat(),
                "status": "inconclusive", "title": question, "summary": "Fixture",
                "hypotheses": [], "steps": [], "proposed_actions": [],
                "limitations": [coverage[0]["detail"]]}

    def test_records_changes_not_repeated_snapshots(self):
        self.assertEqual(self.store.ingest([observation()]), 1)
        self.assertEqual(self.store.ingest([observation("two")]), 0)
        self.assertEqual(self.store.ingest([observation("three", "Changed")]), 1)
        self.assertEqual(self.store.count(), 2)

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

    def test_concurrent_investigation_rejected(self):
        self.service.investigation_lock.acquire()
        try:
            with self.assertRaisesRegex(ValueError, "already running"):
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
