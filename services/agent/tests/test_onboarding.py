import io
import json
import os
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

from guardian.onboarding import validate_key
from guardian.service import GuardianService
from guardian.store import Store


class OnboardingTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.store = Store(Path(self.directory.name) / "state.sqlite3")
        self.service = GuardianService(self.store, collector=lambda: ([], []), investigator=lambda **kwargs: {})

    @patch("guardian.service.sdk_available", return_value=True)
    @patch("guardian.service.validate_key")
    def test_configures_only_after_validation_without_persisting_key(self, validate, sdk):
        key = "fake-test-key-no-secret"
        self.assertTrue(self.service.status()["onboarding_required"])
        result = self.service.dispatch({"method": "provider.configure", "params": {"api_key": key, "allow_cloud": True}})
        validate.assert_called_once_with(key)
        self.assertFalse(result["onboarding_required"])
        self.assertIn("claude-haiku-5-5", result["provider"])
        self.assertNotIn(key, json.dumps(result))
        self.assertNotIn(key.encode(), self.store.path.read_bytes())
        self.assertEqual(os.environ["ANTHROPIC_API_KEY"], key)

    @patch("guardian.service.sdk_available", return_value=True)
    @patch("guardian.service.validate_key", side_effect=ValueError("Key rejected"))
    def test_failed_validation_preserves_previous_configuration(self, validate, sdk):
        os.environ["ANTHROPIC_API_KEY"] = "old-test-key"
        with self.assertRaisesRegex(ValueError, "Key rejected"):
            self.service.configure_provider({"api_key": "new-test-key", "allow_cloud": True})
        self.assertEqual(os.environ["ANTHROPIC_API_KEY"], "old-test-key")
        self.assertFalse(self.service.investigation_lock.locked())

    @patch("guardian.service.validate_key")
    def test_missing_consent_or_sdk_never_contacts_anthropic(self, validate):
        with self.assertRaisesRegex(ValueError, "consentimiento"):
            self.service.configure_provider({"api_key": "fake-test-key", "allow_cloud": False})
        with patch("guardian.service.sdk_available", return_value=False):
            with self.assertRaisesRegex(ValueError, "Falta Claude Agent SDK"):
                self.service.configure_provider({"api_key": "fake-test-key", "allow_cloud": True})
        validate.assert_not_called()

    def test_missing_tls_dependency_has_actionable_private_error(self):
        with patch.dict("sys.modules", {"truststore": None}):
            with self.assertRaisesRegex(ValueError, "componente TLS"):
                validate_key("fake-test-key")

    @patch("guardian.onboarding.urllib.request.build_opener")
    def test_verification_is_metadata_get_not_paid_inference(self, opener):
        response = io.BytesIO(json.dumps({"type": "model", "id": "claude-haiku-5-5"}).encode())
        opener.return_value.open.return_value = response
        validate_key("fake-test-key")
        request = opener.return_value.open.call_args.args[0]
        self.assertEqual(request.get_method(), "GET")
        self.assertEqual(request.full_url, "https://api.anthropic.com/v1/models/claude-haiku-5-5")
        self.assertIsNone(request.data)
        self.assertEqual(request.get_header("X-api-key"), "fake-test-key")

    @patch("guardian.onboarding.urllib.request.build_opener")
    def test_verification_errors_do_not_echo_provider_body_or_key(self, opener):
        for code, message in ((401, "rechazó"), (404, "no está disponible"), (429, "limitando"), (500, "no pudo verificar")):
            opener.return_value.open.side_effect = urllib.error.HTTPError("url", code, "PRIVATE", {}, io.BytesIO(b"PRIVATE"))
            with self.subTest(code=code), self.assertRaisesRegex(ValueError, message) as error:
                validate_key("fake-test-key")
            self.assertNotIn("PRIVATE", str(error.exception))


if __name__ == "__main__":
    unittest.main()
