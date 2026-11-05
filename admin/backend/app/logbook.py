"""Append-only log of everything that happens, in SQLite, pushed live to every console."""
import csv
import io
import json
import sqlite3
import threading
import time

from .config import DATA
from .hub import Hub


class Logbook:
    def __init__(self, hub: Hub, path=DATA / "ronda.db"):
        self.hub = hub
        self.lock = threading.Lock()
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.execute("""create table if not exists log (
            id integer primary key autoincrement,
            ts real not null,
            kind text not null,
            level text not null default 'info',
            message text not null,
            event_id text, mission_id text,
            data text)""")
        self.db.execute("create index if not exists log_ts on log(ts)")
        self.db.commit()
        self.shift_start = time.time()

    def add(self, kind, message, *, level="info", event_id=None, mission_id=None, data=None):
        ts = time.time()
        payload = json.dumps(data, ensure_ascii=False, default=str) if data is not None else None
        with self.lock:
            cur = self.db.execute(
                "insert into log (ts, kind, level, message, event_id, mission_id, data) values (?,?,?,?,?,?,?)",
                (ts, kind, level, message, event_id, mission_id, payload))
            self.db.commit()
            rid = cur.lastrowid
        entry = {"id": rid, "ts": ts, "kind": kind, "level": level, "message": message,
                 "event_id": event_id, "mission_id": mission_id, "data": data}
        self.hub.publish({"type": "log", "entry": entry})
        return entry

    def query(self, since=None, limit=500, kind=None):
        sql, args = "select id, ts, kind, level, message, event_id, mission_id, data from log where 1=1", []
        if since:
            sql += " and ts >= ?"
            args.append(since)
        if kind:
            sql += " and kind like ?"
            args.append(kind + "%")
        sql += " order by id desc limit ?"
        args.append(limit)
        with self.lock:
            rows = self.db.execute(sql, args).fetchall()
        out = []
        for r in reversed(rows):
            out.append({"id": r[0], "ts": r[1], "kind": r[2], "level": r[3], "message": r[4],
                        "event_id": r[5], "mission_id": r[6], "data": json.loads(r[7]) if r[7] else None})
        return out

    def csv(self, since=None):
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(["id", "time", "kind", "level", "message", "event_id", "mission_id", "data"])
        for e in self.query(since=since, limit=100000):
            w.writerow([e["id"], time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(e["ts"])), e["kind"],
                        e["level"], e["message"], e["event_id"] or "", e["mission_id"] or "",
                        json.dumps(e["data"], ensure_ascii=False) if e["data"] else ""])
        return buf.getvalue()
