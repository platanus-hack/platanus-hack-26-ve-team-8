import subprocess
import unittest
from unittest.mock import patch

from guardian import defense


class DefenseTests(unittest.TestCase):
    def run_action(self, function, *args, returncode=0, stderr=""):
        with patch.object(defense.subprocess, "run", return_value=subprocess.CompletedProcess([], returncode, "", stderr)) as run:
            function(*args)
        command = run.call_args.args[0]
        self.assertEqual(command[:2], ["/usr/bin/osascript", "-e"])
        self.assertIs(run.call_args.kwargs["shell"], False)
        return command[2]

    def test_block_and_unblock_use_per_port_anchor(self):
        script = self.run_action(defense.block_port, 3000)
        self.assertIn("with administrator privileges", script)
        self.assertIn("block drop in quick on ! lo0 proto tcp to any port 3000 flags S/SA", script)
        self.assertIn("-a com.apple/guardian.3000 -f -", script)
        self.assertIn("-a com.apple/guardian.3000 -F rules", self.run_action(defense.unblock_port, 3000))

    def test_only_integer_ports_reach_a_command(self):
        for port in ("3000; rm -rf /", 0, 70000, True, 3000.0, None):
            with self.subTest(port=port), patch.object(defense.subprocess, "run") as run:
                with self.assertRaises(ValueError):
                    defense.block_port(port)
                run.assert_not_called()

    def test_cancel_and_failure_are_reported(self):
        with self.assertRaisesRegex(ValueError, "Cancelado"):
            self.run_action(defense.block_port, 3000, returncode=1, stderr="User canceled. (-128)")
        with self.assertRaisesRegex(ValueError, "Falló"):
            self.run_action(defense.enable_firewall, returncode=1, stderr="other")

    def test_block_peer_blocks_ip_and_kills_live_sessions(self):
        script = self.run_action(defense.block_peer, "192.168.1.9")
        self.assertIn("block drop in quick from 192.168.1.9 to any", script)
        self.assertIn("-a com.apple/guardian.peer.c0a80109 -f -", script)
        self.assertIn("pfctl -k 192.168.1.9", script)
        self.assertIn("pfctl -k 0.0.0.0/0 -k 192.168.1.9", script)
        self.assertIn("-a com.apple/guardian.peer.c0a80109 -F rules", self.run_action(defense.unblock_peer, "192.168.1.9"))
        script = self.run_action(defense.block_peer, "fe80::2")
        self.assertIn("guardian.peer.fe800000000000000000000000000002 -f -", script)
        self.assertIn("-k ::/0 -k fe80::2", script)

    def test_only_valid_remote_addresses_reach_a_command(self):
        for address in ("1.2.3.4; rm -rf /", "1.2.3.4' | sh", "127.0.0.1", "::1", "0.0.0.0", "224.0.0.1",
                        "fe80::2%en0", 16909060, True, None, ["1.2.3.4"]):
            with self.subTest(address=address), patch.object(defense.subprocess, "run") as run:
                with self.assertRaises(ValueError):
                    defense.block_peer(address)
                run.assert_not_called()

    def test_firewall_enables_stealth_mode(self):
        script = self.run_action(defense.enable_firewall)
        self.assertIn("--setglobalstate on", script)
        self.assertIn("--setstealthmode on", script)


if __name__ == "__main__":
    unittest.main()
