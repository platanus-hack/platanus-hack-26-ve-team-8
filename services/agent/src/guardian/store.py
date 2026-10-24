"""Almacén local de evidencia. Quien llama serializa las escrituras con el lock del servicio."""

import hashlib
import math
import json
import sqlite3
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path


class Store:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = path
        with self.connect() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS response_events (id TEXT PRIMARY KEY, payload TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS watch_state (
                    entity_key TEXT PRIMARY KEY, payload TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS watch_sources (source TEXT PRIMARY KEY);
                CREATE TABLE IF NOT EXISTS alerts (
                    id TEXT PRIMARY KEY, created_at TEXT NOT NULL, payload TEXT NOT NULL,
                    acknowledged INTEGER NOT NULL DEFAULT 0, investigated INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS automation_attempts (started_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS observations (
                    id TEXT PRIMARY KEY, timestamp TEXT NOT NULL,
                    payload TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS current_state (
                    entity_key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL,
                    observation_id TEXT
                );
                CREATE TABLE IF NOT EXISTS investigations (
                    id TEXT PRIMARY KEY, created_at TEXT NOT NULL,
                    payload TEXT NOT NULL
                );
            """)
            columns = [row[1] for row in db.execute("PRAGMA table_info(current_state)")]
            if "observation_id" not in columns:
                # Las líneas base antiguas no se pueden vincular a evidencia retenida; prune las elimina.
                db.execute("ALTER TABLE current_state ADD COLUMN observation_id TEXT")
        path.chmod(0o600)

    def connect(self):
        return sqlite3.connect(self.path)

    def response_events(self):
        with self.connect() as db:
            return [json.loads(r[0]) for r in db.execute("""
                SELECT payload FROM response_events
                WHERE json_extract(payload, '$.status') NOT IN ('restored', 'failed', 'termination_requested')
                   OR rowid IN (SELECT rowid FROM response_events ORDER BY rowid DESC LIMIT 100)
                ORDER BY rowid DESC
            """)]

    def unresolved_responses(self):
        with self.connect() as db:
            return db.execute("SELECT COUNT(*) FROM response_events WHERE json_extract(payload, '$.status') "
                              "NOT IN ('restored', 'failed', 'termination_requested')").fetchone()[0]

    def response_event(self, identifier):
        with self.connect() as db:
            row = db.execute("SELECT payload FROM response_events WHERE id=?", (identifier,)).fetchone()
        if row is None:
            raise ValueError('Acción no encontrada.')
        return json.loads(row[0])

    def start_response(self, target, **details):
        identifier = str(uuid.uuid4())
        event = dict(target, id=identifier, observation_id=target['id'], status='pending',
                     created_at=datetime.now(timezone.utc).isoformat(),
                     detail='Acción iniciada; un reinicio puede requerir recuperación manual.', **details)
        with self.connect() as db:
            db.execute("INSERT INTO response_events VALUES (?, ?)", (identifier, json.dumps(event)))
        return identifier

    def finish_response(self, identifier, status, detail):
        with self.connect() as db:
            event = json.loads(db.execute("SELECT payload FROM response_events WHERE id=?", (identifier,)).fetchone()[0])
            event.update(status=status, detail=detail)
            db.execute("UPDATE response_events SET payload=? WHERE id=?", (json.dumps(event), identifier))

    def ingest(self, observations: list[dict]) -> int:
        added = 0
        with self.connect() as db:
            for item in observations:
                key = json.dumps([item["source"], item["kind"], item["entity"]])
                content = json.dumps([item["summary"], item["attributes"]], sort_keys=True)
                fingerprint = hashlib.sha256(content.encode()).hexdigest()
                previous = db.execute(
                    "SELECT fingerprint FROM current_state WHERE entity_key=?", (key,)
                ).fetchone()
                if previous and previous[0] == fingerprint:
                    continue
                db.execute("INSERT OR REPLACE INTO observations VALUES (?, ?, ?)",
                           (item["id"], item["timestamp"], json.dumps(item)))
                db.execute("INSERT OR REPLACE INTO current_state VALUES (?, ?, ?)",
                           (key, fingerprint, item["id"]))
                added += 1
        return added

    def observations(self, limit: int = 100) -> list[dict]:
        with self.connect() as db:
            rows = db.execute(
                "SELECT payload FROM observations ORDER BY timestamp DESC, rowid DESC LIMIT ?",
                (limit,),
            ).fetchall()
        return [json.loads(row[0]) for row in rows]

    def observation(self, identifier):
        with self.connect() as db:
            row = db.execute("SELECT payload FROM observations WHERE id=?", (identifier,)).fetchone()
        if row is None:
            raise ValueError("Observación no encontrada; toma una nueva instantánea.")
        return json.loads(row[0])

    def count(self) -> int:
        with self.connect() as db:
            return db.execute("SELECT COUNT(*) FROM observations").fetchone()[0]

    def save_investigation(self, item: dict):
        with self.connect() as db:
            db.execute("INSERT OR REPLACE INTO investigations VALUES (?, ?, ?)",
                       (item["id"], item["created_at"], json.dumps(item)))

    def investigations(self) -> list[dict]:
        with self.connect() as db:
            rows = db.execute(
                "SELECT payload FROM investigations ORDER BY created_at DESC LIMIT 100"
            ).fetchall()
        return [json.loads(row[0]) for row in rows]

    def prune(self, now=None):
        with self.connect() as db:
            db.execute("DELETE FROM alerts WHERE julianday(created_at) < julianday('now', '-7 days')")
            db.execute("DELETE FROM automation_attempts WHERE started_at < ?", ((time.time() if now is None else now) - 86400,))
            db.execute("DELETE FROM observations WHERE julianday(timestamp) < julianday('now', '-7 days')")
            db.execute("DELETE FROM investigations WHERE julianday(created_at) < julianday('now', '-7 days')")
            # Una línea base sin evidencia retenida suprimiría la entidad para siempre; se vuelve a registrar en el siguiente escaneo.
            db.execute("DELETE FROM current_state WHERE observation_id IS NULL OR observation_id NOT IN (SELECT id FROM observations)")
            # Limita la caché de líneas base independientemente de la retención del historial.
            db.execute("DELETE FROM current_state WHERE rowid NOT IN (SELECT rowid FROM current_state ORDER BY rowid DESC LIMIT 20000)")

    def watch_records(self):
        with self.connect() as db:
            return [json.loads(row[0]) for row in db.execute("SELECT payload FROM watch_state")]

    def detect(self, observations, coverage):
        """La referencia y sus señales se confirman juntas; el historial no borra la referencia."""
        from .surveillance import FILE_SOURCES
        with self.connect() as db:
            initialized = {row[0] for row in db.execute("SELECT source FROM watch_sources")}
            seen_sources = set()
            for item in observations:
                kind, source, attributes = item["kind"], item["source"], item["attributes"]
                if kind not in {"file", "firewall", "tcp_listener", "tcp_connection"}:
                    continue
                if kind == "tcp_listener":
                    if attributes.get("bind_scope") not in {"any", "interface"}:
                        continue
                    # Un reinicio del mismo servidor no crea una señal solo por cambiar de PID.
                    identity = [attributes.get("executable"), attributes.get("local_address"), attributes.get("port"), attributes.get("bind_scope")]
                elif kind == "tcp_connection":
                    # Un equipo alerta una vez por servicio, no por cada puerto efímero o reconexión.
                    identity = [attributes.get("executable"), attributes.get("local_port"), attributes.get("remote_address")]
                else:
                    identity = item["entity"]
                key = json.dumps([source, kind, identity], sort_keys=True)
                row = db.execute("SELECT payload FROM watch_state WHERE entity_key=?", (key,)).fetchone()
                previous = json.loads(row[0]) if row else None
                old = previous["attributes"] if previous else {}
                if kind == "file" and attributes.get("readable") is False:
                    # Una entrada nunca legible no debe parecer recién creada cuando recupera permisos.
                    if previous is None:
                        db.execute("INSERT INTO watch_state VALUES (?, ?)", (key, json.dumps(item)))
                    continue
                rule = None
                change = "modified"
                if source in initialized:
                    if kind == "file" and old != attributes and old.get("readable") is not False:
                        if attributes.get("present") and not old.get("present"):
                            change = "created"
                        elif old.get("present") and not attributes.get("present"):
                            change = "deleted"
                        if previous or attributes.get("present"):
                            rule = "file_changed"
                    elif kind == "firewall" and previous and any(
                            old.get(field) is True and attributes.get(field) is False
                            for field in ("firewall_enabled", "stealth_mode")):
                        rule = "firewall_weakened"
                    elif kind == "tcp_listener" and previous is None:
                        rule, change = "listener_exposed", "created"
                    elif kind == "tcp_connection" and previous is None:
                        rule, change = "inbound_connection", "created"
                if previous is None or old != attributes:
                    db.execute("INSERT OR REPLACE INTO watch_state VALUES (?, ?)", (key, json.dumps(item)))
                if rule:
                    identifier = str(uuid.uuid4())
                    reason = {"file_changed": "Cambió un archivo de persistencia o configuración.",
                              "firewall_weakened": "Se desactivó el firewall o el modo sigiloso.",
                              "listener_exposed": "Apareció una escucha TCP fuera de loopback.",
                              "inbound_connection": "Un equipo de la red se conectó a un servicio local."}[rule]
                    signal_attributes = {"rule": rule, "change": change}
                    if kind == "file":
                        signal_attributes["category"] = attributes.get("category", old.get("category"))
                        for field in ("mode", "owner"):
                            if field in old:
                                signal_attributes["previous_" + field] = old[field]
                            if field in attributes:
                                signal_attributes[field] = attributes[field]
                    signal = {"id": identifier, "timestamp": item["timestamp"], "kind": "detection",
                              "source": source, "entity": item["entity"], "summary": reason,
                              "attributes": signal_attributes}
                    alert = {"id": identifier, "created_at": item["timestamp"], "reason": reason,
                             "signal": signal, "before": previous, "after": item}
                    db.execute("INSERT INTO alerts(id, created_at, payload) VALUES (?, ?, ?)",
                               (identifier, item["timestamp"], json.dumps(alert)))
                seen_sources.add(source)
            # Un directorio vacío inspeccionado correctamente también establece una referencia.
            seen_sources.update(c["source"] for c in coverage if c["source"] in FILE_SOURCES and c["status"] == "available")
            seen_sources.update(c["source"] for c in coverage
                                if c["source"] in {"tcp_listeners", "tcp_connections", "ssh_logins"} and c["status"] in {"available", "partial"})
            for source in seen_sources:
                db.execute("INSERT OR IGNORE INTO watch_sources VALUES (?)", (source,))

    def alerts(self, pending=False, limit=100):
        with self.connect() as db:
            rows = db.execute("SELECT payload, acknowledged, investigated FROM alerts " +
                              ("WHERE investigated=0 " if pending else "") +
                              "ORDER BY created_at " + ("ASC" if pending else "DESC") + " LIMIT ?", (limit,)).fetchall()
        return [dict(json.loads(row[0]), acknowledged=bool(row[1]), investigated=bool(row[2])) for row in rows]

    def alert_counts(self):
        with self.connect() as db:
            row = db.execute("SELECT COALESCE(SUM(acknowledged=0),0), COALESCE(SUM(investigated=0),0) FROM alerts").fetchone()
        return {"unacknowledged": row[0], "pending": row[1]}

    def acknowledge(self, identifier):
        with self.connect() as db:
            if db.execute("UPDATE alerts SET acknowledged=1 WHERE id=?", (identifier,)).rowcount != 1:
                raise ValueError("Señal no encontrada")

    def complete_alerts(self, identifiers):
        with self.connect() as db:
            db.executemany("UPDATE alerts SET investigated=1 WHERE id=?", [(identifier,) for identifier in identifiers])

    def automation_enabled(self):
        with self.connect() as db:
            row = db.execute("SELECT value FROM preferences WHERE key='automation'").fetchone()
        return bool(row and row[0] == "1")

    def set_automation(self, enabled):
        with self.connect() as db:
            db.execute("INSERT OR REPLACE INTO preferences VALUES ('automation', ?)", ("1" if enabled else "0",))

    def quota(self, now):
        with self.connect() as db:
            count, latest = db.execute("SELECT COUNT(*), MAX(started_at) FROM automation_attempts WHERE started_at > ?", (now - 86400,)).fetchone()
        return {"remaining": max(0, 12 - count), "cooldown_seconds": max(0, math.ceil(300 - (now - latest))) if latest is not None else 0}

    def reserve_attempt(self, now):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            count, latest = db.execute("SELECT COUNT(*), MAX(started_at) FROM automation_attempts WHERE started_at > ?", (now - 86400,)).fetchone()
            if count >= 12 or (latest is not None and now - latest < 300):
                return False
            db.execute("INSERT INTO automation_attempts VALUES (?)", (now,))
        return True
