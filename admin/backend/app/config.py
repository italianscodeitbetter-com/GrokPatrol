"""Settings, secrets and the site map (rooms, spots, cameras, routes) for the admin backend."""
import json
import math
import os
import threading
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent          # admin/backend
REPO = ROOT.parent.parent                              # repository root
DATA = Path(os.environ.get("RONDA_DATA") or ROOT / "data")
SNAPS = DATA / "snapshots"


def _load_env_file(path: Path) -> None:
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


# admin/backend/secrets/.env wins, the repo-root secrets/.env fills the rest
_load_env_file(ROOT / "secrets" / ".env")
_load_env_file(REPO / "secrets" / ".env")
DATA.mkdir(parents=True, exist_ok=True)
SNAPS.mkdir(exist_ok=True)

SITE_FILE = Path(os.environ.get("SITE_FILE") or REPO / "config" / "site.pad3.json")
if not SITE_FILE.is_absolute():
    SITE_FILE = REPO / SITE_FILE
SITE_LOCAL = DATA / f"{SITE_FILE.stem}.local.json"  # spots taught on site override the defaults


def env(key: str, default=None):
    v = os.environ.get(key)
    return default if v in (None, "") else v


def env_float(key: str, default: float) -> float:
    try:
        return float(env(key, default))
    except (TypeError, ValueError):
        return default


def env_bool(key: str, default: bool) -> bool:
    v = env(key)
    if v is None:
        return default
    return str(v).lower() in ("1", "true", "yes", "on")


DOG_KIND = env("DOG", "sim")            # sim (kinematic, no 3D) | mujoco (physics, ./sim.sh) | go1 (real dog)
GO1_LINK = env("GO1_LINK", "mqtt")      # mqtt (the app's channel, works without L1 + START) | wifi | wired (UDP SDK)
VMAX = env_float("VMAX", 0.5)          # m/s, museum-safe cap
WMAX = env_float("WMAX", 0.8)           # rad/s
SPECULATIVE = env_bool("SPECULATIVE_DISPATCH", True)
# simulation: the dog checks every camera event on site, even when Grok calls it a false alarm (the verdict stays
# in the log). Off with the real Go1 unless ALWAYS_CHECK=1.
ALWAYS_CHECK = env_bool("ALWAYS_CHECK", DOG_KIND != "go1")
DWELL_S = env_float("PATROL_DWELL_S", 3.0)
PATROL_CHECKS = env_bool("PATROL_CHECKS", True)
AUTO_HOME_S = env_float("AUTO_HOME_S", 0.0 if DOG_KIND == "go1" else 45.0)   # 0: stays where it is when idle
LANG = env("ALERT_LANG", None)


class Site:
    """The map. Coordinates in meters from the dog's home pose."""

    def __init__(self):
        self.lock = threading.Lock()
        self.data = json.loads(SITE_FILE.read_text())
        for key in ("spots", "rooms", "cameras", "routes"):
            self.data.setdefault(key, [])
        if SITE_LOCAL.exists():
            local = json.loads(SITE_LOCAL.read_text())
            by_id = {s["id"]: s for s in self.data["spots"]}
            for s in local.get("spots", []):
                by_id[s["id"]] = s
            self.data["spots"] = list(by_id.values())
            for key in ("routes", "cameras"):
                if key in local:
                    self.data[key] = local[key]
        self.lang = LANG or self.data.get("language", "it")
        self.planner = None
        model = self.data.get("model")
        if model and model.get("dir"):
            mdir = REPO / model["dir"]
            plan = mdir / "plan.json"
            if plan.exists():
                self.data["plan"] = json.loads(plan.read_text())
            if (mdir / "grid.npz").exists():
                from .planner import Planner
                extra = [(e["x"], e["y"], e["w"], e["d"], e.get("yaw", 0.0)) for e in self.data.get("exhibits", [])]
                self.planner = Planner(mdir / "grid.npz", extra=extra)
        self.sim = False  # set while the 3D simulator is connected
        self.temp_spots = {}  # where a person was seen: created per event
        from .calib import Calibrations
        self.calib = Calibrations(DATA / f"{SITE_FILE.stem}.calib.json")

    @property
    def rules(self):
        r = self.data.get("security_rules", "")
        if self.data.get("normal_objects"):
            r += " Normal furniture and exhibits, never anomalies: " + self.data["normal_objects"]
        if self.sim and self.data.get("sim_note"):
            r += " " + self.data["sim_note"]
        return r

    # lookups
    def spot(self, sid):
        return self.temp_spots.get(sid) or next((s for s in self.data["spots"] if s["id"] == sid), None)

    def pixel_to_floor(self, cam, u, v, aspect):
        """Floor point seen at image position (u, v) in 0..1 from the top left. A calibration made in the
        console wins; otherwise the camera pose from the site file (x, y, z, look, fovy)."""
        if cam and self.calib.get(cam.get("id")):
            p = self.calib.to_floor(cam["id"], u, v)
            b = (self.data.get("plan") or {}).get("bounds")
            if p and (not b or (b[0] - 0.2 <= p[0] <= b[2] + 0.2 and b[1] - 0.2 <= p[1] <= b[3] + 0.2)):
                return (round(p[0], 2), round(p[1], 2))
            return None
        if not cam or cam.get("z") is None or not cam.get("look"):
            return None
        c = (cam["x"], cam["y"], cam["z"])
        f = [cam["look"][i] - c[i] for i in range(3)]
        n = math.sqrt(sum(x * x for x in f))
        f = [x / n for x in f]
        r = [f[1], -f[0], 0.0]                       # right = forward x up(z)
        rn = math.hypot(r[0], r[1]) or 1.0
        r = [r[0] / rn, r[1] / rn, 0.0]
        up = [r[1] * f[2] - r[2] * f[1], r[2] * f[0] - r[0] * f[2], r[0] * f[1] - r[1] * f[0]]
        ty = math.tan(math.radians(cam.get("fovy", 66)) / 2)
        px, py = (2 * u - 1) * ty * aspect, (1 - 2 * v) * ty
        d = [f[i] + px * r[i] + py * up[i] for i in range(3)]
        if d[2] >= -1e-3:
            return None
        t = -c[2] / d[2]
        x, y = c[0] + t * d[0], c[1] + t * d[1]
        if t > 30:
            return None
        b = (self.data.get("plan") or {}).get("bounds")
        if b and not (b[0] - 0.2 <= x <= b[2] + 0.2 and b[1] - 0.2 <= y <= b[3] + 0.2):
            return None   # outside the hall: never send the dog there
        return (round(x, 2), round(y, 2))

    def floor_to_pixel(self, cam, x, y, aspect):
        """Where a floor point appears in the camera image (u, v in 0..1), or None if out of view."""
        cal = self.calib.get(cam.get("id")) if cam else None
        if cal:
            from .calib import apply
            q = apply(cal["Hinv"], x, y)
            if q is None:
                return None
            # the same side of the horizon as the calibration points
            p0 = cal["points"][0]
            ref = apply(cal["Hinv"], p0["x"], p0["y"])
            import numpy as np
            w = (np.asarray(cal["Hinv"]) @ np.array([x, y, 1.0]))[2]
            w0 = (np.asarray(cal["Hinv"]) @ np.array([p0["x"], p0["y"], 1.0]))[2]
            if ref is None or np.sign(w) != np.sign(w0):
                return None
            u, v = q
        else:
            if not cam or cam.get("z") is None or not cam.get("look"):
                return None
            c = (cam["x"], cam["y"], cam["z"])
            f = [cam["look"][i] - c[i] for i in range(3)]
            n = math.sqrt(sum(a * a for a in f))
            f = [a / n for a in f]
            r = [f[1], -f[0], 0.0]
            rn = math.hypot(r[0], r[1]) or 1.0
            r = [r[0] / rn, r[1] / rn, 0.0]
            up = [r[1] * f[2] - r[2] * f[1], r[2] * f[0] - r[0] * f[2], r[0] * f[1] - r[1] * f[0]]
            d = [x - c[0], y - c[1], -c[2]]
            zc = sum(d[i] * f[i] for i in range(3))
            if zc <= 0:
                return None
            ty = math.tan(math.radians(cam.get("fovy", 66)) / 2)
            u = (sum(d[i] * r[i] for i in range(3)) / zc / (ty * aspect) + 1) / 2
            v = (1 - sum(d[i] * up[i] for i in range(3)) / zc / ty) / 2
        return (u, v) if -0.05 <= u <= 1.05 and -0.05 <= v <= 1.05 else None

    def approach_spot(self, pose, target, sid, name, stop_short=1.0):
        """A spot just short of the target, on free floor, facing it."""
        tx, ty = target
        dx, dy = tx - pose[0], ty - pose[1]
        dist = math.hypot(dx, dy) or 1.0
        k = max(0.0, dist - stop_short) / dist
        x, y = pose[0] + dx * k, pose[1] + dy * k
        if self.planner:
            cell = self.planner.nearest_free(*self.planner.cell(x, y))
            if cell:
                x, y = self.planner.world(*cell)
        spot = {"id": sid, "name": name, "x": round(x, 2), "y": round(y, 2),
                "yaw": round(math.atan2(ty - y, tx - x), 3), "temp": True}
        self.temp_spots[sid] = spot
        return spot

    def camera(self, cid):
        return next((c for c in self.data["cameras"] if c["id"] == cid), None)

    def route(self, rid):
        return next((r for r in self.data["routes"] if r["id"] == rid), None)

    def home_pose(self):
        h = self.spot(self.data.get("home", "home")) or {"x": 0.0, "y": 0.0}
        return (h["x"], h["y"], h.get("yaw", 0.0) or 0.0)

    def room_at(self, x, y):
        for r in self.data["rooms"]:
            if r["x"] <= x <= r["x"] + r["w"] and r["y"] <= y <= r["y"] + r["h"]:
                return r["id"]
        return None

    def room(self, rid):
        return next((r for r in self.data["rooms"] if r["id"] == rid), None)

    def find_spot(self, text):
        """Loose match by id or name, used by the console."""
        if not text:
            return None
        t = str(text).strip().lower()
        for s in self.data["spots"]:
            if s["id"].lower() == t or s.get("name", "").lower() == t:
                return s
        return next((s for s in self.data["spots"] if t in s.get("name", "").lower()), None)

    def path_to(self, pose, spot):
        """Waypoints from the current pose to a spot: around walls and pillars when the real room is loaded,
        otherwise through the doors of the rectangular rooms."""
        x, y = pose[0], pose[1]
        if self.planner:
            pts = self.planner.plan((x, y), (spot["x"], spot["y"]))
            if pts:
                return [(px, py, None, "via") for px, py in pts[:-1]] + [(spot["x"], spot["y"], spot.get("yaw"), spot["id"])]
        here = self.room_at(x, y)
        there = spot.get("room") or self.room_at(spot["x"], spot["y"])
        pts = []
        if here and there and here != there:
            prev, frontier, seen = {}, deque([here]), {here}
            while frontier:
                cur = frontier.popleft()
                if cur == there:
                    break
                for d in self.data.get("doors", []):
                    if cur in d["rooms"]:
                        for nxt in d["rooms"]:
                            if nxt not in seen:
                                seen.add(nxt)
                                prev[nxt] = (cur, d)
                                frontier.append(nxt)
            if there in prev:
                chain, cur = [], there
                while cur != here:
                    cur, door = prev[cur]
                    chain.append(door)
                for d in reversed(chain):
                    pts.append((d["x"], d["y"], None, d["id"]))
        pts.append((spot["x"], spot["y"], spot.get("yaw"), spot["id"]))
        return pts

    # teaching spots on site
    def save_spot(self, sid, name, room, x, y, yaw=None):
        with self.lock:
            spot = {"id": sid, "name": name or sid, "room": room or self.room_at(x, y),
                    "x": round(x, 3), "y": round(y, 3)}
            if yaw is not None:
                spot["yaw"] = round(yaw, 3)
            self.data["spots"] = [s for s in self.data["spots"] if s["id"] != sid] + [spot]
            local = json.loads(SITE_LOCAL.read_text()) if SITE_LOCAL.exists() else {}
            spots = [s for s in local.get("spots", []) if s["id"] != sid] + [spot]
            local["spots"] = spots
            SITE_LOCAL.write_text(json.dumps(local, indent=2))
            return spot

    def summary_for_prompt(self):
        d = self.data
        return json.dumps({
            "rooms": [{"id": r["id"], "name": r["name"]} for r in d["rooms"]],
            "spots": [{"id": s["id"], "name": s["name"], "room": s.get("room")} for s in d["spots"]],
            "cameras": [{"id": c["id"], "name": c["name"], "room": c.get("room"),
                         "inspect_spot": c.get("inspect_spot")} for c in d["cameras"]],
            "routes": [{"id": r["id"], "name": r["name"], "spots": r["spots"]} for r in d["routes"]],
        }, ensure_ascii=False)


def wrap(a: float) -> float:
    return (a + math.pi) % (2 * math.pi) - math.pi
