"""Synthetic response checks: never target a real app or call a model."""
import copy
import ctypes
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import platform
import stat
import tempfile
import unittest
from unittest.mock import Mock, patch

from guardian import response
from guardian.service import GuardianService
from guardian.store import Store


class ResponseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.home = Path(self.directory.name).resolve()
        self.path = self.home / 'example.plist'
        self.path.write_bytes(b'INERT TEST FIXTURE')
        self.store = Store(self.home / 'data' / 'guardian.sqlite3')
        self.engine = response.Response(self.store, self.home)
        self.observation = {'id': 'file-one', 'kind': 'file', 'source': 'user_launch_files',
                            'entity': str(self.path), 'timestamp': datetime.now(timezone.utc).isoformat(),
                            'summary': 'Archivo de prueba.',
                            'attributes': {'sha256': hashlib.sha256(self.path.read_bytes()).hexdigest()}}
        self.result = {'id': 'case-one', 'created_at': self.observation['timestamp'], 'status': 'needs_review',
                       'hypotheses': [{'evidence_ids': ['file-one']}],
                       'proposed_actions': [{'action': {'type': 'quarantine_file',
                           'observation_id': 'file-one', 'verdict': 'malicious'}}]}

    def targets(self):
        self.engine.enabled = True
        return self.engine.capture([copy.deepcopy(self.observation)])

    def test_opt_in_required_and_never_restored_on_restart(self):
        self.assertEqual(self.engine.capture([self.observation]), {})
        targets = self.targets()
        self.assertIn('file-one', targets)
        self.engine.enabled = False
        with patch.object(self.engine, 'quarantine') as quarantine:
            self.engine.apply(self.result, targets)
        quarantine.assert_not_called()
        self.assertFalse(response.Response(self.store, self.home).enabled)

    def test_citation_verdict_and_action_must_match(self):
        targets = self.targets()
        for change in ({'verdict': 'suspicious'}, {'observation_id': 'invented'}, {'type': 'terminate_process'}):
            result = copy.deepcopy(self.result)
            result['proposed_actions'][0]['action'].update(change)
            with self.subTest(change=change), patch.object(self.engine, 'quarantine') as quarantine:
                self.engine.apply(result, targets)
                quarantine.assert_not_called()
        for status in ('no_finding', 'inconclusive'):
            with patch.object(self.engine, 'quarantine') as quarantine:
                self.engine.apply(dict(self.result, status=status), targets)
                quarantine.assert_not_called()
        with patch.object(self.engine, 'quarantine') as quarantine:
            self.engine.apply(dict(self.result, hypotheses=[]), targets)
            quarantine.assert_not_called()

    def test_changed_file_is_not_quarantined(self):
        targets = self.targets()
        self.path.write_bytes(b'NEW LEGITIMATE CONTENT')
        with patch.object(self.engine, 'quarantine') as quarantine:
            self.engine.apply(self.result, targets)
        quarantine.assert_not_called()
        self.assertEqual(self.store.response_events()[0]['status'], 'failed')
        self.assertEqual(self.path.read_bytes(), b'NEW LEGITIMATE CONTENT')

    def test_symlinks_hardlinks_and_outside_home_rejected(self):
        link = self.home / 'link'
        link.symlink_to(self.path)
        with self.assertRaises(OSError), response.checked_file(link, self.home, self.engine.data_dir):
            pass
        link.unlink()
        os.link(self.path, link)
        with self.assertRaises(ValueError), response.checked_file(self.path, self.home, self.engine.data_dir):
            pass
        with self.assertRaises(ValueError), response.checked_file('/etc/hosts', self.home, self.engine.data_dir):
            pass
        with self.assertRaises(ValueError), response.checked_file(self.store.path, self.home, self.engine.data_dir):
            pass

    def test_process_signal_uses_versioned_identity_and_rejects_changes(self):
        identity = {'pid': 987654, 'uid': os.getuid(), 'ruid': os.getuid(), 'system': False,
                    'version': 7, 'token': [0, os.getuid(), 0, os.getuid(), 0, 987654, 0, 7]}
        lib = Mock()
        lib.proc_signal_with_audittoken.return_value = 0
        with patch.object(response, 'process_identity', return_value=identity), patch.object(response, 'library', return_value=lib):
            response.stop_process(identity)
        token_pointer, sig = lib.proc_signal_with_audittoken.call_args.args
        self.assertEqual(sig, response.signal.SIGKILL)
        self.assertEqual(ctypes.cast(token_pointer, ctypes.POINTER(ctypes.c_uint32 * 8)).contents[7], 7)
        with patch.object(response, 'process_identity', return_value=dict(identity, version=8)), patch.object(response, 'library') as load:
            with self.assertRaises(ValueError):
                response.stop_process(identity)
            load.assert_not_called()
        with patch.object(response, 'library') as load:
            with self.assertRaises(ValueError):
                response.stop_process(dict(identity, pid=os.getpid()))
            load.assert_not_called()

    def test_session_budget_disables_response(self):
        targets = self.targets()
        self.engine.attempts = 20
        with patch.object(self.engine, 'quarantine') as quarantine:
            self.engine.apply(self.result, targets)
        quarantine.assert_not_called()
        self.assertFalse(self.engine.enabled)

    def test_paused_monitoring_cannot_capture_or_apply(self):
        service = GuardianService(self.store, collector=lambda: ([self.observation], []),
                                  investigator=lambda *a, **k: self.result)
        service.response = self.engine
        self.engine.enabled = True
        service.scan()
        with patch.object(self.engine, 'capture') as capture, patch.object(self.engine, 'apply') as apply:
            service.investigate()
        capture.assert_not_called()
        apply.assert_not_called()

    @unittest.skipUnless(platform.system() == 'Darwin', 'macOS process identity')
    def test_native_identity_layout_without_sending_a_signal(self):
        identity = response.process_identity(os.getpid())
        self.assertEqual(identity['pid'], os.getpid())
        self.assertEqual(identity['uid'], os.getuid())
        self.assertEqual(identity['ppid'], os.getppid())
        self.assertTrue(Path(identity['path']).is_absolute())
        self.assertGreater(identity['start_sec'], 0)

    @unittest.skipUnless(platform.system() == 'Darwin', 'macOS exclusive rename')
    def test_quarantine_restore_and_collision_preserve_data(self):
        self.path.chmod(0o700)
        targets = self.targets()
        self.engine.apply(self.result, targets)
        event = self.store.response_events()[0]
        self.assertEqual(event['status'], 'quarantined')
        self.assertFalse(self.path.exists())
        payload = self.engine.data_dir / 'quarantine' / event['id'] / 'payload'
        self.assertEqual(stat.S_IMODE(payload.stat().st_mode), 0o600)
        self.path.write_text('DO NOT OVERWRITE')
        with self.assertRaises(OSError):
            self.engine.restore(event['id'])
        self.assertEqual(self.path.read_text(), 'DO NOT OVERWRITE')
        self.assertTrue(payload.exists())
        self.path.unlink()
        self.engine.restore(event['id'])
        self.assertEqual(self.path.read_bytes(), b'INERT TEST FIXTURE')
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o700)
        self.assertEqual(self.store.response_event(event['id'])['status'], 'restored')
        self.assertEqual(self.engine.capture([self.observation]), {})

    @unittest.skipUnless(platform.system() == 'Darwin', 'macOS exclusive rename')
    def test_replaced_target_is_retained_for_recovery(self):
        targets = self.targets()
        rename = response.rename_exclusive
        def replace_then_move(*args):
            self.path.unlink()
            self.path.write_bytes(b'CONCURRENT REPLACEMENT')
            rename(*args)
        with patch.object(response, 'rename_exclusive', side_effect=replace_then_move):
            self.engine.apply(self.result, targets)
        event = next(e for e in self.store.response_events() if e['status'] == 'recovery_required')
        payload = self.engine.data_dir / 'quarantine' / event['id'] / 'payload'
        self.assertEqual(payload.read_bytes(), b'CONCURRENT REPLACEMENT')
        with self.assertRaises(ValueError):
            self.engine.restore(event['id'])

    def test_service_requires_consent_and_revocation_invalidates_inflight_result(self):
        def investigate(*args, **kwargs):
            service.dispatch({'method': 'protection.set', 'params': {'enabled': False}})
            service.dispatch({'method': 'protection.set', 'params': {'enabled': True, 'consent': True}})
            return self.result
        service = GuardianService(self.store, collector=lambda: ([self.observation], []), investigator=investigate)
        service.response = self.engine
        service.monitoring = True
        with self.assertRaises(ValueError):
            service.dispatch({'method': 'protection.set', 'params': {'enabled': True}})
        service.dispatch({'method': 'protection.set', 'params': {'enabled': True, 'consent': True}})
        service.scan()
        with patch.object(self.engine, 'apply') as apply:
            service.investigate()
        apply.assert_not_called()

    @unittest.skipUnless(platform.system() == 'Darwin', 'macOS exclusive rename')
    def test_service_investigation_to_quarantine_with_mocked_model(self):
        service = GuardianService(self.store, collector=lambda: ([self.observation], []),
                                  investigator=lambda *a, **k: self.result)
        service.response = self.engine
        service.monitoring = True
        self.engine.enabled = True
        service.scan()
        service.investigate()
        self.assertEqual(self.store.investigations()[0]['id'], 'case-one')
        self.assertEqual(service.status()['protection']['events'][0]['status'], 'quarantined')
        self.assertFalse(self.path.exists())


if __name__ == '__main__':
    unittest.main()
