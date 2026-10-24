"""Small local evidence store. Callers serialize writes through the service lock."""

import hashlib
import json
import sqlite3
from pathlib import Path


class Store:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = path
        with self.connect() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS observations (
                    id TEXT PRIMARY KEY, timestamp TEXT NOT NULL,
                    payload TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS current_state (
                    entity_key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS investigations (
                    id TEXT PRIMARY KEY, created_at TEXT NOT NULL,
                    payload TEXT NOT NULL
                );
            """)
        path.chmod(0o600)

    def connect(self):
        return sqlite3.connect(self.path)

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
                db.execute("INSERT OR REPLACE INTO current_state VALUES (?, ?)",
                           (key, fingerprint))
                added += 1
        return added

    def observations(self, limit: int = 100) -> list[dict]:
        with self.connect() as db:
            rows = db.execute(
                "SELECT payload FROM observations ORDER BY timestamp DESC, rowid DESC LIMIT ?",
                (limit,),
            ).fetchall()
        return [json.loads(row[0]) for row in rows]

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

    def prune(self):
        with self.connect() as db:
            db.execute("DELETE FROM observations WHERE julianday(timestamp) < julianday('now', '-7 days')")
            db.execute("DELETE FROM investigations WHERE julianday(created_at) < julianday('now', '-7 days')")
            # Bound the baseline cache independently of history retention.
            db.execute("DELETE FROM current_state WHERE rowid NOT IN (SELECT rowid FROM current_state ORDER BY rowid DESC LIMIT 20000)")
