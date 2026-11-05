"""Automations created from the mobile app: a route drawn on the floor and when to walk it.

Saved in data/automations.json, so they survive a restart and run with the app closed.
Points are in site meters. A slot the dog cannot start within GRACE_S (busy on a mission) is skipped.
"""
import json
import re
import time
from datetime import datetime, timedelta

GRACE_S = 600
REPEATS = ("once", "daily", "weekdays", "days", "interval")
HHMM = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")


def _at(day, hhmm):
    h, m = hhmm.split(":")
    return day.replace(hour=int(h), minute=int(m), second=0, microsecond=0)


def last_slot(a, now):
    """The most recent moment this automation should have started, or None."""
    start = _at(now, a["start"])
    if now < start:
        return None
    if a["repeat"] == "weekdays" and now.weekday() >= 5:
        return None
    if a["repeat"] == "days" and now.isoweekday() not in a.get("days", []):
        return None
    if a["repeat"] != "interval":
        return start
    until = _at(now, a["until"])
    steps = int((min(now, until) - start).total_seconds() // (a["every_min"] * 60))
    return start + timedelta(minutes=steps * a["every_min"])


class Automations:
    def __init__(self, path):
        self.path = path
        self.items = []
        if path.exists():
            try:
                self.items = json.loads(path.read_text())
            except Exception:
                pass

    def _save(self):
        self.path.write_text(json.dumps(self.items, indent=2, ensure_ascii=False))

    def get(self, aid):
        return next((a for a in self.items if a["id"] == aid), None)

    def public(self):
        today = time.strftime("%Y-%m-%d")
        return [{**a, "runs_today": a["runs_today"] if a.get("runs_day") == today else 0} for a in self.items]

    def add(self, body):
        name = str(body.get("name") or "").strip()
        points = body.get("points")
        repeat = body.get("repeat")
        start = body.get("start")
        if not name:
            return {"ok": False, "error": "missing name"}
        if not isinstance(points, list) or len(points) < 2 or not all(
                isinstance(p, (list, tuple)) and len(p) == 2 and all(isinstance(v, (int, float)) for v in p) for p in points):
            return {"ok": False, "error": "points must be at least two [x, y] pairs in meters"}
        if repeat not in REPEATS:
            return {"ok": False, "error": f"repeat must be one of {', '.join(REPEATS)}"}
        if not isinstance(start, str) or not HHMM.match(start):
            return {"ok": False, "error": "start must be HH:MM"}
        days = body.get("days")
        if repeat == "days" and (not isinstance(days, list) or not days or not all(d in range(1, 8) for d in days)):
            return {"ok": False, "error": "days must list the weekdays, 1 = Monday ... 7 = Sunday"}
        every, until = None, None
        if repeat == "interval":
            every, until = body.get("every_min"), body.get("until")
            if not isinstance(every, (int, float)) or every <= 0:
                return {"ok": False, "error": "every_min must be positive"}
            if not isinstance(until, str) or not HHMM.match(until) or until <= start:
                return {"ok": False, "error": "until must be HH:MM, after start"}
        used = [int(a["id"].split("-")[1]) for a in self.items]
        a = {"id": f"AU-{max(used, default=0) + 1:02d}", "name": name, "points": [[float(x), float(y)] for x, y in points],
             "loop": bool(body.get("loop")), "start": start, "repeat": repeat, "every_min": every, "until": until,
             "days": sorted(days) if repeat == "days" else None,
             "active": True, "created": time.time(), "last_run": None, "runs_today": 0, "runs_day": None}
        self.items.append(a)
        self._save()
        return {"ok": True, "automation": a}

    def set_route(self, aid, points, loop):
        a = self.get(aid)
        if not a:
            return {"ok": False, "error": f"unknown automation {aid}"}
        if not isinstance(points, list) or len(points) < 2 or not all(
                isinstance(p, (list, tuple)) and len(p) == 2 and all(isinstance(v, (int, float)) for v in p) for p in points):
            return {"ok": False, "error": "points must be at least two [x, y] pairs in meters"}
        a["points"], a["loop"] = [[float(x), float(y)] for x, y in points], bool(loop)
        self._save()
        return {"ok": True, "automation": a}

    def set_active(self, aid, active):
        a = self.get(aid)
        if not a:
            return {"ok": False, "error": f"unknown automation {aid}"}
        a["active"] = bool(active)
        self._save()
        return {"ok": True, "automation": a}

    def delete(self, aid):
        if not self.get(aid):
            return {"ok": False, "error": f"unknown automation {aid}"}
        self.items = [a for a in self.items if a["id"] != aid]
        self._save()
        return {"ok": True}

    def due(self, now=None):
        """The automations to start now. A slot from before the automation existed never fires."""
        now = now or datetime.now()
        out = []
        for a in self.items:
            if not a["active"]:
                continue
            slot = last_slot(a, now)
            if slot is None:
                continue
            s = slot.timestamp()
            if now.timestamp() - s <= GRACE_S and s >= a["created"] and (a["last_run"] or 0) < s:
                out.append(a)
        return out

    def mark_run(self, a):
        today = time.strftime("%Y-%m-%d")
        a["runs_today"] = a["runs_today"] + 1 if a.get("runs_day") == today else 1
        a["runs_day"] = today
        a["last_run"] = time.time()
        if a["repeat"] == "once":
            a["active"] = False
        self._save()
