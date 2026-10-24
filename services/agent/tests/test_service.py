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

    def test_ssh_brute_force_alerts_once_and_can_be_blocked(self):
        def failures(identifier, count):
            return {"id": identifier, "timestamp": datetime.now(timezone.utc).isoformat(), "kind": "tcp_connection",
                    "source": "ssh_logins", "entity": "ssh:192.168.1.9", "summary": "Intentos de acceso SSH fallidos desde la red",
                    "attributes": {"executable": "sshd", "direction": "inbound", "local_port": 22,
                                   "remote_address": "192.168.1.9", "remote_scope": "lan", "auth_failures": count}}
        coverage = [{"source": "ssh_logins", "status": "partial", "detail": "Snapshot only"}]
        snapshots = [[observation()], [failures("s1", 3)], [failures("s2", 9)]]
        self.service.collector = lambda: (snapshots.pop(0) if snapshots else [], coverage)
        for _ in range(3):
            self.service.scan()
        alerts = self.store.alerts()
        # More guesses from the same device update the evidence without a new alert.
        self.assertEqual([(a["signal"]["attributes"]["rule"], a["after"]["id"]) for a in alerts], [("inbound_connection", "s1")])
        with patch("guardian.service.defense.block_peer") as block:
            status = self.service.dispatch({"method": "defense.apply", "params": {"action": "block_peer", "observation_id": "s1"}})
        block.assert_called_once_with("192.168.1.9")
        self.assertEqual(status["blocked_peers"], ["192.168.1.9"])

    def test_inbound_peer_alerts_once_and_can_be_blocked(self):
        def connection(identifier, remote_port, remote="192.168.1.9"):
            return {"id": identifier, "timestamp": datetime.now(timezone.utc).isoformat(), "kind": "tcp_connection",
                    "source": "tcp_connections", "entity": f"40:192.168.1.4:5432->{remote}:{remote_port}",
                    "summary": "Conexión entrante de la red a postgres",
                    "attributes": {"pid": 40, "executable": "postgres", "direction": "inbound",
                                   "local_address": "192.168.1.4", "local_port": 5432, "remote_address": remote,
                                   "remote_port": remote_port, "remote_scope": "lan"}}
        coverage = [{"source": "tcp_connections", "status": "partial", "detail": "Snapshot only"}]
        snapshots = [[observation()], [connection("c1", 51022)], [connection("c2", 51023)]]
        self.service.collector = lambda: (snapshots.pop(0) if snapshots else [], coverage)
        for _ in range(3):
            self.service.scan()
        alerts = self.store.alerts()
        # Reconnecting from a new ephemeral port is the same device: one alert.
        self.assertEqual([a["signal"]["attributes"]["rule"] for a in alerts], ["inbound_connection"])
        self.assertEqual(alerts[0]["after"]["id"], "c1")
        with patch("guardian.service.defense.block_peer") as block:
            status = self.service.dispatch({"method": "defense.apply", "params": {"action": "block_peer", "observation_id": "c1"}})
        block.assert_called_once_with("192.168.1.9")
        self.assertEqual(status["blocked_peers"], ["192.168.1.9"])
        for params in ({"action": "block_peer", "observation_id": "one"},      # a process, not a connection
                       {"action": "block_peer", "observation_id": "missing"},
                       {"action": "block_peer", "address": "192.168.1.9"},     # raw IPs are not accepted
                       {"action": "unblock_peer", "address": "10.0.0.1"}):     # not blocked by Guardian
            with self.subTest(params=params), patch("guardian.service.defense.block_peer") as block:
                with self.assertRaises(ValueError):
                    self.service.dispatch({"method": "defense.apply", "params": params})
                block.assert_not_called()
        with patch("guardian.service.defense.unblock_peer") as unblock:
            status = self.service.dispatch({"method": "defense.apply", "params": {"action": "unblock_peer", "address": "192.168.1.9"}})
        unblock.assert_called_once_with("192.168.1.9")
        self.assertEqual(status["blocked_peers"], [])

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
