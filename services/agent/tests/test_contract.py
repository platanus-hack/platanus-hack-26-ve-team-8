"""La salida de Python debe coincidir con los ejemplos que decodifica Swift."""
import json
import tempfile
import unittest
from pathlib import Path

from guardian.investigator import _result
from guardian.service import GuardianService
from guardian.store import Store
from guardian.telemetry import _observation

FIXTURES = json.loads((Path(__file__).parents[3] / "packages/contracts/fixtures.json").read_text())


def shape(value):
    if isinstance(value, dict):
        return {key: shape(item) for key, item in value.items()}
    if isinstance(value, list):
        return [shape(value[0])] if value else []
    return type(value).__name__


class ContractTests(unittest.TestCase):
    def assertMatches(self, actual, fixture):
        # Las listas vacías y los valores nulos no proporcionan tipos de elementos.
        self.assertEqual(set(actual), set(fixture))
        for key, value in actual.items():
            if value not in ([], None):
                self.assertEqual(shape(value), shape(fixture[key]), key)

    def test_status_matches_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            service = GuardianService(Store(Path(directory) / "test.sqlite3"),
                                      collector=lambda: ([], FIXTURES["status"]["coverage"]),
                                      investigator=lambda *a, **k: None)
            self.assertMatches(service.scan(), FIXTURES["status"])

    def test_alert_and_automation_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(Path(directory) / "test.sqlite3")
            service = GuardianService(store, collector=lambda: ([], []))
            example = FIXTURES["alert"]
            store.detect([example["before"]], [])
            store.detect([example["after"]], [])
            result = service.dispatch({"method": "alerts"})["items"][0]
            self.assertMatches(result, example)
            status = service.dispatch({"method": "alerts.acknowledge", "params": {"id": result["id"]}})
            self.assertEqual(status["alerts"], {"unacknowledged": 0, "pending": 1})
            status = service.dispatch({"method": "automation.set", "params": {"enabled": True, "consent": True}})
            self.assertTrue(status["automation"]["enabled"])
            self.assertEqual(status["automation"]["reason"], "paused")
            for request in ({"method": "alerts", "params": {"limit": True}},
                            {"method": "alerts.acknowledge", "params": {"id": "inexistente"}},
                            {"method": "automation.set", "params": {"enabled": "true", "consent": True}}):
                with self.assertRaises(ValueError):
                    service.dispatch(request)

    def test_observation_matches_fixture(self):
        self.assertMatches(_observation("process", "processes", "123", "Proceso de ejemplo", {"pid": 123}),
                           FIXTURES["observation"])

    def test_progress_matches_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            seen = []

            def investigator(observations, question, coverage, on_step):
                on_step(FIXTURES["progress"]["steps"][0])
                seen.append(service.dispatch({"method": "investigation.progress"}))
                return _result("Ejemplo")

            service = GuardianService(Store(Path(directory) / "test.sqlite3"),
                                      collector=lambda: ([], []), investigator=investigator)
            service.investigate()
            self.assertMatches(seen[0], FIXTURES["progress"])
            self.assertFalse(service.dispatch({"method": "investigation.progress"})["active"])

    def test_investigation_matches_fixture(self):
        self.assertMatches(_result("Ejemplo"), FIXTURES["investigation"])


if __name__ == "__main__":
    unittest.main()
