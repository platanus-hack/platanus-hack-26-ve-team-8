"""Python outputs must match packages/contracts/fixtures.json, which the Swift models decode."""
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
        # Empty lists and null last_scan carry no element type; compare keys there, shapes elsewhere.
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

    def test_observation_matches_fixture(self):
        self.assertMatches(_observation("process", "processes", "123", "Process example", {"pid": 123}),
                           FIXTURES["observation"])

    def test_investigation_matches_fixture(self):
        self.assertMatches(_result("Fixture"), FIXTURES["investigation"])


if __name__ == "__main__":
    unittest.main()
