import logging
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from guardian.diagnostics import configure_logging, logger


class DiagnosticsTests(unittest.TestCase):
    def test_local_log_is_bounded_and_does_not_capture_sdk_logs(self):
        previous_handlers, previous_level = logger.handlers[:], logger.level
        with tempfile.TemporaryDirectory() as temporary, patch("guardian.diagnostics.Path.home", return_value=Path(temporary)):
            try:
                configure_logging()
                handler = logger.handlers[-1]
                self.assertEqual(handler.maxBytes, 512_000)
                self.assertEqual(handler.backupCount, 2)
                logger.info("Investigación fallida; código=authentication_failed")
                with patch.object(logging.getLogger("claude_agent_sdk"), "propagate", False):
                    logging.getLogger("claude_agent_sdk").info("PRIVATE SDK CONTENT")
                data = (Path(temporary) / "Library/Logs/Arkangel/agent.log").read_text()
                self.assertIn("authentication_failed", data)
                self.assertNotIn("PRIVATE", data)
            finally:
                for handler in logger.handlers:
                    if handler not in previous_handlers:
                        handler.close()
                logger.handlers = previous_handlers
                logger.setLevel(previous_level)

    def test_unwritable_directory_does_not_stop_agent(self):
        with patch("guardian.diagnostics.Path.mkdir", side_effect=PermissionError("PRIVATE")):
            configure_logging()
