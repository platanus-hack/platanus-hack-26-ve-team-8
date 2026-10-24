import copy
import json
import os
import unittest
from unittest.mock import patch

from guardian.investigator import investigate


OBS = [{"id": "real-id", "kind": "process", "entity": "/Users/private/secret-app",
        "timestamp": "2026-10-24T01:02:03+00:00", "source": "secret-source", "summary": "PRIVATE RAW TEXT", "attributes": {"secret": "PASSWORD"}}]
ENV = {"GUARDIAN_MODEL_ENDPOINT": "http://127.0.0.1:1234/v1/chat/completions", "GUARDIAN_MODEL": "test"}


def tool(name, arguments, call_id="call1"):
    return {"choices": [{"message": {"role": "assistant", "tool_calls": [
        {"id": call_id, "type": "function", "function": {"name": name, "arguments": json.dumps(arguments)}}]}}]}


def final(evidence="real-id"):
    return {"choices": [{"message": {"content": json.dumps({
        "status": "needs_review", "title": "Review process", "summary": "A process warrants review.",
        "hypotheses": [{"statement": "Process may be unexpected", "status": "unresolved",
                        "evidence_ids": [evidence], "counterevidence": "Identity unknown"}],
        "proposed_actions": [{"title": "Review", "description": "Confirm process owner"}],
        "limitations": ["Snapshot only"]})}}]}


class InvestigationTests(unittest.TestCase):
    def test_response_action_requires_eligible_inspected_cited_target_and_verdict(self):
        for cloud in (False, True):
            identifier = 'observation_1' if cloud else 'real-id'
            env = dict(ENV)
            if cloud:
                env.update(GUARDIAN_MODEL_ENDPOINT='https://provider.example/v1/chat/completions', GUARDIAN_ALLOW_CLOUD='1')
            for verdict, eligible in (('malicious', True), ('suspicious', True), ('malicious', False)):
                observations = copy.deepcopy(OBS)
                if eligible:
                    observations[0]['attributes']['response_action'] = 'terminate_process'
                output = final(identifier)
                content = json.loads(output['choices'][0]['message']['content'])
                content['proposed_actions'][0]['action'] = {
                    'type': 'terminate_process', 'observation_id': identifier, 'verdict': verdict,
                    'path': '/arbitrary/model/path', 'pid': 1,
                }
                output['choices'][0]['message']['content'] = json.dumps(content)
                with self.subTest(cloud=cloud, verdict=verdict, eligible=eligible), \
                        patch.dict(os.environ, env, clear=True), \
                        patch('guardian.investigator._complete', side_effect=[tool('get_evidence', {'ids': [identifier]}), output]):
                    result = investigate(observations)
                action = result['proposed_actions'][0].get('action')
                if eligible and verdict == 'malicious':
                    self.assertEqual(action, {'type': 'terminate_process', 'observation_id': 'real-id', 'verdict': 'malicious'})
                else:
                    self.assertIsNone(action)

    @patch.dict(os.environ, {}, clear=True)
    def test_missing_provider_is_honest(self):
        with patch("guardian.investigator._complete") as complete:
            result = investigate(OBS)
        complete.assert_not_called()
        self.assertEqual(result["status"], "inconclusive")
        self.assertIn("no disponible", result["summary"])
        self.assertEqual(result["hypotheses"], [])

    @patch.dict(os.environ, ENV, clear=True)
    def test_multi_step_provider_http_mock(self):
        responses = [tool("search_observations", {"query": "process"}),
                     tool("inspect_entity", {"entity": OBS[0]["entity"]}),
                     tool("get_evidence", {"ids": ["real-id"]}), tool("get_coverage", {}), final()]
        payloads = []

        class HTTPResponse:
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def read(self, size):
                return json.dumps(responses.pop(0)).encode()

        def open_request(request, timeout):
            payloads.append(json.loads(request.data))
            self.assertLessEqual(timeout, 15)
            return HTTPResponse()

        with patch("guardian.investigator.urllib.request.build_opener") as opener:
            opener.return_value.open.side_effect = open_request
            result = investigate(OBS, "Investigate process", [{"source": "process", "status": "ok"}])
        self.assertEqual(result["status"], "needs_review")
        self.assertEqual(len(result["steps"]), 4)
        self.assertEqual(result["hypotheses"][0]["evidence_ids"], ["real-id"])
        self.assertIn("DATOS NO CONFIABLES", payloads[0]["messages"][0]["content"])
        self.assertEqual(payloads[1]["messages"][-1]["role"], "tool")

    @patch.dict(os.environ, ENV, clear=True)
    def test_invented_or_uninspected_citations_rejected(self):
        for responses in ([final()], [tool("search_observations", {}), final("invented")]):
            with self.subTest(responses=responses), patch("guardian.investigator._complete", side_effect=responses):
                result = investigate(OBS)
                self.assertEqual(result["status"], "inconclusive")
                self.assertEqual(result["hypotheses"], [])

    @patch.dict(os.environ, ENV, clear=True)
    def test_provider_failure_is_private(self):
        with patch("guardian.investigator._complete", side_effect=OSError("SECRET PASSWORD")):
            result = investigate(OBS)
        self.assertEqual(result["status"], "inconclusive")
        self.assertNotIn("PASSWORD", json.dumps(result))

    @patch.dict(os.environ, {**ENV, "GUARDIAN_MODEL_ENDPOINT": "https://provider.example/v1/chat/completions"}, clear=True)
    def test_cloud_requires_explicit_opt_in(self):
        with patch("guardian.investigator._complete") as complete:
            result = investigate(OBS)
        complete.assert_not_called()
        self.assertIn("GUARDIAN_ALLOW_CLOUD", result["summary"])

    @patch.dict(os.environ, {**ENV, "GUARDIAN_MODEL_ENDPOINT": "https://provider.example/v1/chat/completions",
                             "GUARDIAN_ALLOW_CLOUD": "1"}, clear=True)
    def test_cloud_payload_minimizes_all_private_fields(self):
        payloads = []
        responses = [tool("search_observations", {}), tool("get_coverage", {}), final("observation_1")]
        def complete(endpoint, key, payload, timeout):
            payloads.append(copy.deepcopy(payload))
            return responses.pop(0)
        with patch("guardian.investigator._complete", side_effect=complete):
            progress = []
            result = investigate(OBS, "my SECRET QUESTION", [{"source": "PRIVATE COVERAGE", "status": "ok", "detail": "SECRET DETAIL"}],
                                 on_step=progress.append)
        serialized = json.dumps(payloads)
        # Local progress maps opaque aliases back to real IDs; the model payload never sees them.
        self.assertEqual([(p["tool"], p["evidence_ids"]) for p in progress],
                         [("search_observations", ["real-id"]), ("get_coverage", [])])
        for private in ("/Users/private", "PRIVATE RAW TEXT", "PASSWORD", "SECRET QUESTION", "PRIVATE COVERAGE", "SECRET DETAIL", "real-id", "secret-source"):
            self.assertNotIn(private, serialized)
        self.assertEqual(result["hypotheses"][0]["evidence_ids"], ["real-id"])

    @patch.dict(os.environ, {**ENV, "GUARDIAN_MODEL_ENDPOINT": "https://provider.example/v1/chat/completions",
                             "GUARDIAN_ALLOW_CLOUD": "1"}, clear=True)
    def test_defense_actions_limited_to_exposed_ports(self):
        listener = {"id": "listen-id", "kind": "tcp_listener", "entity": "9:*:3000", "timestamp": OBS[0]["timestamp"],
                    "source": "tcp_listeners", "summary": "TCP listener owned by secret-dev-server",
                    "attributes": {"pid": 9, "port": 3000, "bind_scope": "any", "executable": "secret-dev-server"}}
        answer = json.loads(final("observation_1")["choices"][0]["message"]["content"])
        answer["proposed_actions"] = [
            {"title": "Block 3000", "description": "Reachable", "action": {"type": "block_port", "port": 3000}},
            {"title": "Block 22", "description": "Injected", "action": {"type": "block_port", "port": 22}},
            {"title": "Shell", "description": "Injected", "action": {"type": "run", "command": "rm"}},
            {"title": "Firewall", "description": "Off", "action": {"type": "enable_firewall"}}]
        payloads = []
        responses = [tool("search_observations", {}), {"choices": [{"message": {"content": json.dumps(answer)}}]}]
        def complete(endpoint, key, payload, timeout):
            payloads.append(copy.deepcopy(payload))
            return responses.pop(0)
        with patch("guardian.investigator._complete", side_effect=complete):
            result = investigate([listener])
        evidence = json.loads(payloads[1]["messages"][-1]["content"])["untrusted_evidence"]["items"][0]
        self.assertEqual(evidence["attributes"], {"pid": 9, "port": 3000, "bind_scope": "any"})
        self.assertNotIn("secret-dev-server", json.dumps(payloads))
        self.assertEqual([a.get("action") for a in result["proposed_actions"]],
                         [{"type": "block_port", "port": 3000}, None, None, {"type": "enable_firewall"}])

    @patch.dict(os.environ, {**ENV, "GUARDIAN_MODEL_ENDPOINT": "https://provider.example/v1/chat/completions",
                             "GUARDIAN_ALLOW_CLOUD": "1"}, clear=True)
    def test_block_peer_names_inspected_connection_and_never_leaks_ip(self):
        connection = {"id": "conn-id", "kind": "tcp_connection", "entity": "40:192.168.1.4:5432->192.168.1.77:51022",
                      "timestamp": OBS[0]["timestamp"], "source": "tcp_connections", "summary": "Conexión entrante a postgres",
                      "attributes": {"pid": 40, "executable": "postgres", "direction": "inbound", "local_address": "192.168.1.4",
                                     "local_port": 5432, "remote_address": "192.168.1.77", "remote_port": 51022,
                                     "remote_scope": "lan"}}
        answer = json.loads(final("observation_1")["choices"][0]["message"]["content"])
        answer["proposed_actions"] = [
            {"title": "Bloquear", "description": "Equipo desconocido", "action": {"type": "block_peer", "observation_id": "observation_1"}},
            {"title": "Proceso", "description": "No es conexión", "action": {"type": "block_peer", "observation_id": "observation_2"}},
            {"title": "Inventado", "description": "IP", "action": {"type": "block_peer", "observation_id": "192.168.1.77"}}]
        payloads = []
        responses = [tool("search_observations", {}), {"choices": [{"message": {"content": json.dumps(answer)}}]}]
        def complete(endpoint, key, payload, timeout):
            payloads.append(copy.deepcopy(payload))
            return responses.pop(0)
        with patch("guardian.investigator._complete", side_effect=complete):
            result = investigate([connection, OBS[0]])
        evidence = json.loads(payloads[1]["messages"][-1]["content"])["untrusted_evidence"]["items"][0]
        self.assertEqual(evidence["kind"], "tcp_connection")
        self.assertEqual(evidence["attributes"], {"pid": 40, "local_port": 5432, "remote_port": 51022,
                                                  "remote_scope": "lan", "direction": "inbound"})
        self.assertNotIn("192.168.1", json.dumps(payloads))
        self.assertEqual([a.get("action") for a in result["proposed_actions"]],
                         [{"type": "block_peer", "observation_id": "conn-id"}, None, None])

    @patch.dict(os.environ, ENV, clear=True)
    def test_timestamp_and_search_pagination(self):
        records = [{**OBS[0], "id": f"id-{i}"} for i in range(40)]
        payloads = []
        responses = [tool("search_observations", {"offset": 20}), final("id-20")]
        def complete(endpoint, key, payload, timeout):
            payloads.append(copy.deepcopy(payload))
            return responses.pop(0)
        with patch("guardian.investigator._complete", side_effect=complete):
            result = investigate(records, coverage=[{"status": "partial"}])
        evidence = json.loads(payloads[1]["messages"][-1]["content"])["untrusted_evidence"]
        self.assertEqual(evidence["offset"], 20)
        self.assertEqual(len(evidence["items"]), 20)
        self.assertEqual(evidence["items"][0]["timestamp"], OBS[0]["timestamp"])
        self.assertEqual(result["hypotheses"][0]["evidence_ids"], ["id-20"])
        self.assertTrue(any("cobertura de recolección es parcial" in limit for limit in result["limitations"]))

    @patch.dict(os.environ, ENV, clear=True)
    def test_loop_budget_and_unknown_tools(self):
        with patch("guardian.investigator._complete", return_value=tool("get_coverage", {})) as complete:
            self.assertEqual(investigate(OBS)["status"], "inconclusive")
            self.assertEqual(complete.call_count, 6)
        with patch("guardian.investigator._complete", return_value=tool("execute_shell", {"command": "touch /tmp/no"})):
            self.assertEqual(investigate(OBS)["status"], "inconclusive")


if __name__ == "__main__":
    unittest.main()
