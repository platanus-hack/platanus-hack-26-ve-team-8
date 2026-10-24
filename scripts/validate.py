#!/usr/bin/env python3
"""Simulacro sin interfaz: comprueba detección, investigación y defensa contra el servicio local.

Habla el mismo protocolo que la app (packages/contracts/protocol.md) por el socket Unix.
Nunca llama a defense.apply: los bloqueos se aprueban en la app y aquí solo se verifican.

  python3 scripts/validate.py watch                     # telemetría de red y alertas en directo
  python3 scripts/validate.py drill ssh                 # espera la alerta, informa PASS/FAIL
  python3 scripts/validate.py drill postgres --investigate   # además pide una investigación (puede tener coste)
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import uuid

# Alerta esperada, comando para el otro equipo y fuente de telemetría que debe existir.
SCENARIOS = {
    "ssh": ("inbound_connection", 22, "sh ssh-attacker.sh {ip}", "ssh_logins"),
    "postgres": ("inbound_connection", 5432, "sh postgres-attacker.sh {ip}", "tcp_connections"),
    "listener": ("listener_exposed", None, None, "tcp_listeners"),  # cualquier escucha nueva fuera de loopback
}


def local_ip():
    """IP en la red local. Una VPN puede ser la ruta predeterminada, así que primero las interfaces físicas."""
    for interface in ("en0", "en1"):  # en0 es el Wi-Fi en los portátiles; en1 en Macs con Ethernet
        address = subprocess.run(["/usr/sbin/ipconfig", "getifaddr", interface],
                                 capture_output=True, text=True, check=False).stdout.strip()
        if address:
            return address
    return "<ip-de-tu-mac>"


def call(sock, method, **params):
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(300)  # una investigación puede tardar
        client.connect(str(sock))
        client.sendall(json.dumps({"id": str(uuid.uuid4()), "method": method, "params": params}).encode() + b"\n")
        response = json.loads(client.makefile().readline())
    if "error" in response:
        raise RuntimeError(response["error"]["message"])
    return response["result"]


def when(value):
    return datetime.fromisoformat(value).timestamp()


def open_connections(remote):
    """Comprobación independiente de Guardian: conexiones TCP establecidas ahora con ese equipo."""
    output = subprocess.run(["/usr/sbin/netstat", "-an", "-p", "tcp"], capture_output=True, text=True, check=False).stdout
    count = 0
    for line in output.splitlines():
        fields = line.split()
        if len(fields) >= 6 and fields[5] == "ESTABLISHED":
            host = fields[4].rpartition(".")[0].split("%", 1)[0]
            count += host == remote or host == f"::ffff:{remote}"
    return count


def describe(alert):
    after = alert["after"]["attributes"]
    port = after.get("local_port", after.get("port"))
    extra = f", {after['auth_failures']} fallos SSH" if "auth_failures" in after else ""
    return (f"{alert['signal']['attributes']['rule']}: {after.get('executable', '?')} :{port} "
            f"desde {after.get('remote_address', '-')}{extra}")


def matches(alert, rule, port):
    after = alert["after"]["attributes"]
    return alert["signal"]["attributes"]["rule"] == rule and port in (None, after.get("local_port"), after.get("port"))


def network(observation):
    """Telemetría de red que importa en los simulacros: conexiones entrantes, intentos SSH y escuchas expuestas."""
    a = observation["attributes"]
    if observation["kind"] == "tcp_connection":
        extra = f", {a['auth_failures']} fallos SSH" if "auth_failures" in a else ""
        return f"{observation['source']}: {a.get('remote_address')} → {a.get('executable')} :{a.get('local_port')}{extra}"
    if observation["kind"] == "tcp_listener" and a.get("bind_scope") in {"any", "interface"}:
        return f"{observation['source']}: {a.get('executable')} escucha en {a.get('local_address')}"
    return None


def watch(sock):
    seen = {a["id"] for a in call(sock, "alerts")["items"]}
    # Solo se registran observaciones nuevas o cambiadas, así que lo nuevo aquí es telemetría que cambió.
    observed = {o["id"] for o in call(sock, "observations", limit=500)["items"]}
    sources = {c["source"]: c["status"] for c in call(sock, "status")["coverage"]}
    print("Cobertura: " + ", ".join(f"{k} {v}" for k, v in sources.items()))
    print("Vigilando telemetría de red y alertas; Ctrl-C para salir.")
    while True:
        status = call(sock, "status")
        if not status["monitoring"]:
            print("Aviso: la vigilancia está en pausa; actívala en la app.")
        for item in reversed(call(sock, "observations", limit=500)["items"]):
            if item["id"] not in observed:
                observed.add(item["id"])
                line = network(item)
                if line:
                    print(f"{item['timestamp'][11:19]}  telemetría  {line}")
        for alert in reversed(call(sock, "alerts")["items"]):
            if alert["id"] not in seen:
                seen.add(alert["id"])
                print(f"{alert['created_at'][11:19]}  ALERTA      {describe(alert)}")
        time.sleep(2)


def drill(sock, scenario, timeout, investigate, report):
    rule, port, command, source = SCENARIOS[scenario]
    checks = []
    def check(name, ok, detail=""):
        checks.append({"check": name, "ok": bool(ok), "detail": detail})
        print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f": {detail}" if detail else ""))

    status = call(sock, "status")
    check("vigilancia activa", status["monitoring"], "actívala en la app" if not status["monitoring"] else "")
    sources = {item["source"]: item["status"] for item in status["coverage"]}
    check(f"telemetría {source} activa", sources.get(source) in {"available", "partial"},
          sources.get(source) or "falta: el servicio no es la versión de esta rama")
    seen = {a["id"] for a in call(sock, "alerts")["items"]}
    if command:
        input(f"Escenario {scenario}: en el otro equipo ejecuta `{command.format(ip=local_ip())}` y pulsa Enter.")
    else:
        input(f"Escenario {scenario}: abre una escucha fuera de loopback y pulsa Enter.")
    started = time.time()
    alert = None
    while time.time() - started < timeout and alert is None:
        time.sleep(2)
        alert = next((a for a in call(sock, "alerts")["items"] if a["id"] not in seen and matches(a, rule, port)), None)
    check("alerta detectada", alert, f"{describe(alert)} en {when(alert['created_at']) - started:.0f} s" if alert
          else f"sin alerta {rule} en {timeout} s")
    if alert is None:
        return checks

    if investigate:
        result = call(sock, "investigate", question="Revisa la conexión entrante más reciente.")
        print(f"      {result['status']}: {result['title']}")
        cited = {e for h in result["hypotheses"] for e in h["evidence_ids"]}
        actions = [p["action"] for p in result["proposed_actions"] if p.get("action")]
        check("la IA marca el caso para revisión", result["status"] == "needs_review", result["status"])
        check("la IA cita la evidencia de la alerta", alert["after"]["id"] in cited or alert["signal"]["id"] in cited)
        check("la IA propone bloquear el equipo", any(a["type"] == "block_peer" for a in actions),
              json.dumps(actions, ensure_ascii=False))
        check("la IA no propone terminar procesos del servicio", not any(a["type"] == "terminate_process" for a in actions))

    remote = alert["after"]["attributes"].get("remote_address")
    if remote:
        input(f"Pulsa Bloquear equipo en la app para {remote}, aprueba el aviso de macOS y pulsa Enter.")
        check("equipo bloqueado", remote in call(sock, "status")["blocked_peers"])
        time.sleep(3)
        live = open_connections(remote)
        check("sesión cortada tras el bloqueo", not live, f"{live} conexiones aún abiertas" if live else "")
    if report:
        report.write_text(json.dumps({"scenario": scenario, "at": datetime.now(timezone.utc).isoformat(),
                                      "checks": checks}, indent=2, ensure_ascii=False))
    return checks


def main():
    parser = argparse.ArgumentParser(description="Simulacro de detección y defensa de Guardian")
    parser.add_argument("command", choices=["watch", "drill"])
    parser.add_argument("scenario", nargs="?", choices=sorted(SCENARIOS))
    parser.add_argument("--socket", type=Path, default=Path(os.getenv("GUARDIAN_SOCKET") or f"/tmp/guardian-{os.getuid()}/agent.sock"))
    parser.add_argument("--timeout", type=int, default=90)
    parser.add_argument("--investigate", action="store_true", help="Pide una investigación; con Claude tiene coste")
    parser.add_argument("--report", type=Path, help="Guarda los resultados en JSON")
    args = parser.parse_args()
    try:
        if args.command == "watch":
            watch(args.socket)
        else:
            if not args.scenario:
                parser.error("drill necesita un escenario")
            checks = drill(args.socket, args.scenario, args.timeout, args.investigate, args.report)
            sys.exit(0 if all(c["ok"] for c in checks) else 1)
    except (OSError, RuntimeError) as error:
        sys.exit(f"No se pudo hablar con el servicio local ({error}). ¿Está abierta la app?")
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
