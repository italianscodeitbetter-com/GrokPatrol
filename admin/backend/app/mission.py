"""Event -> mission -> check -> alert. Patrols, priorities, the mission queue and the timings."""
import asyncio
import base64
import math
import time
import uuid

from .automations import Automations
from .cameras import DOG_CAM
import json

from .config import ALWAYS_CHECK, AUTO_HOME_S, DATA, DWELL_S, PATROL_CHECKS, SNAPS, SPECULATIVE, env_float

ALARM_FILE = DATA / "alarm.json"
ARM_DELAY_S = env_float("ARM_DELAY_S", 15.0)

OPEN = ("received", "assessing", "dispatched", "verifying")
KIND_SEVERITY = {"intrusion": 4, "abandoned_object": 3, "manual": 3, "patrol_finding": 3, "person": 4, "motion": 3}
ARMED_KINDS = ("motion", "person")   # raised by the cameras only while the alarm is armed


def closeup(jpeg, detections, min_side=0.32, out_w=640):
    """Zoomed crop around what the detector saw, so Grok can judge feet against the tape."""
    if not jpeg or not detections:
        return None
    try:
        import io
        from PIL import Image
        im = Image.open(io.BytesIO(jpeg))
        W, H = im.size
        boxes = [d["box"] for d in detections if d.get("box")]
        if not boxes:
            return None
        x0 = min(b[0] for b in boxes); y0 = min(b[1] for b in boxes)
        x1 = max(b[0] + b[2] for b in boxes); y1 = max(b[1] + b[3] for b in boxes)
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2 + (y1 - y0) * 0.15
        side = max(min_side, (x1 - x0) * 2.6, (y1 - y0) * 1.9)
        hw, hh = side / 2, side * 0.75 / 2
        box = (max(0, cx - hw) * W, max(0, cy - hh) * H, min(1, cx + hw) * W, min(1, cy + hh) * H)
        crop = im.crop(tuple(int(v) for v in box))
        crop = crop.resize((out_w, int(out_w * crop.height / max(1, crop.width))), Image.LANCZOS)
        buf = io.BytesIO()
        crop.save(buf, "JPEG", quality=88)
        return buf.getvalue()
    except Exception:
        return None


def short_id(prefix):
    return f"{prefix}-{uuid.uuid4().hex[:5]}"


class Event:
    def __init__(self, camera, kind, score=0.0, detections=None, note="", snapshot=None):
        self.id = short_id("ev")
        self.ts = time.time()
        self.camera, self.kind, self.score = camera, kind, float(score or 0)
        self.detections = detections or []
        self.note = note
        self.snapshot = snapshot      # clean frame: what Grok sees
        self.annotated = None         # with the detector boxes: what the console shows
        self.images = {}
        self.status = "received"
        self.assessment = None
        self.verification = None
        self.alert = None
        self.alert_results = None
        self.mission_id = None
        self.t = {"received": self.ts}
        self.assessed = asyncio.Event()
        self.duplicates = 0

    def save_image(self, name, data):
        if not data:
            return None
        fn = f"{self.id}-{name}.jpg"
        (SNAPS / fn).write_bytes(data)
        self.images[name] = f"/api/snapshots/{fn}"
        return self.images[name]

    def elapsed(self, key):
        return round(self.t[key] - self.ts, 2) if key in self.t else None

    def public(self):
        return {"id": self.id, "ts": self.ts, "camera": self.camera, "kind": self.kind, "score": self.score,
                "detections": self.detections, "note": self.note, "status": self.status,
                "assessment": self.assessment, "verification": self.verification, "alert": self.alert,
                "alert_results": self.alert_results, "mission_id": self.mission_id, "images": self.images,
                "timings": {k: round(v - self.ts, 2) for k, v in self.t.items()}, "duplicates": self.duplicates}


class Mission:
    def __init__(self, kind, stops, priority=0, label="", loops=1, event_ids=None, route_id=None):
        self.id = short_id("m")
        self.kind = kind              # patrol | inspect | goto | home
        self.stops = stops            # spot ids
        self.priority = priority      # 0 patrol, 1 operator moves, 2-5 events by severity
        self.label = label
        self.loops = loops            # patrol rounds, 0 = until stopped
        self.loop_count = 0
        self.idx = 0
        self.event_ids = event_ids or []
        self.route_id = route_id
        self.status = "queued"        # queued | active | paused | verifying | done | cancelled
        self.phase = "idle"           # moving | dwell
        self.path = []
        self.created = time.time()
        self.started = None
        self.ended = None
        self.dwell_until = 0.0
        self.speculative = False
        self.note = ""

    def public(self):
        return {"id": self.id, "kind": self.kind, "stops": self.stops, "priority": self.priority,
                "label": self.label, "loops": self.loops, "loop_count": self.loop_count, "idx": self.idx,
                "event_ids": self.event_ids, "status": self.status, "phase": self.phase,
                "path": [(round(p[0], 2), round(p[1], 2)) for p in self.path], "speculative": self.speculative,
                "route_id": self.route_id,
                "created": self.created, "started": self.started, "ended": self.ended, "note": self.note}


class Manager:
    def __init__(self, site, dog, grok, alerts, log, hub):
        self.site, self.dog, self.grok, self.alerts, self.log, self.hub = site, dog, grok, alerts, log, hub
        self.cams = None
        self.events = {}
        self.missions = {}
        self.queue = []
        self.current = None
        self.schedules = {}           # route_id -> {"every_min", "next"}
        self.automations = Automations(DATA / "automations.json")
        self.idle_since = time.time()
        self.tasks = set()
        self.patrol_seen = {}         # spot -> last finding, so the same thing is reported once
        # the alarm: armed = nobody should be here, any movement is checked; disarmed = no events
        self.alarm = {"armed": False, "since": None, "active_at": None, "by": None}
        if ALARM_FILE.exists():
            try:
                self.alarm.update(json.loads(ALARM_FILE.read_text()))
            except Exception:
                pass
        self.suppressed = 0
        self.dog_ignored = {}

    # helpers ----------------------------------------------------------------------------
    def spawn(self, coro):
        t = asyncio.create_task(coro)
        self.tasks.add(t)
        t.add_done_callback(self.tasks.discard)
        return t

    def push_event(self, ev):
        self.hub.publish({"type": "event", "event": ev.public()})

    def push_missions(self):
        self.hub.publish({"type": "missions", "current": self.current.public() if self.current else None,
                          "queue": [m.public() for m in self.queue]})

    def cam_name(self, cid):
        if cid == DOG_CAM:
            return "Dog camera"
        c = self.site.camera(cid)
        return c["name"] if c else cid.replace("phone-", "Phone ")

    def stats(self):
        evs = list(self.events.values())
        cam_evs = [e for e in evs if e.kind != "patrol_finding"]  # the dog finds these itself, already on the spot
        arrivals = [e.t["arrived"] - e.ts for e in cam_evs if "arrived" in e.t]
        return {
            "events": len(evs),
            "dispatched": sum(1 for e in cam_evs if "dispatched" in e.t),
            "patrol_findings": sum(1 for e in evs if e.kind == "patrol_finding"),
            "filtered": sum(1 for e in evs if e.status == "dismissed"),
            "confirmed": sum(1 for e in evs if e.verification and e.verification.get("confirmed") is True),
            "cleared": sum(1 for e in evs if e.status == "cleared"),
            "alerts": sum(1 for e in evs if e.status == "alerted"),
            "avg_arrival_s": round(sum(arrivals) / len(arrivals), 1) if arrivals else None,
            "best_arrival_s": round(min(arrivals), 1) if arrivals else None,
            "open": sum(1 for e in evs if e.status in OPEN),
        }

    # mission control --------------------------------------------------------------------
    def submit(self, m: Mission):
        self.missions[m.id] = m
        cur = self.current
        if cur and cur.status in ("active",) and m.priority > cur.priority:
            cur.status = "paused"
            self.queue.append(cur)
            self.dog.stop()
            self.log.add("mission.paused", f"{cur.label} paused for {m.label}", mission_id=cur.id)
            self.current = None
        self.queue.append(m)
        self.log.add("mission.queued", f"{m.label} queued (priority {m.priority})", mission_id=m.id,
                     data={"kind": m.kind, "stops": m.stops})
        self.push_missions()
        return m

    def cancel(self, m: Mission, why=""):
        if m.status in ("done", "cancelled"):
            return
        m.status, m.ended, m.note = "cancelled", time.time(), why
        if m in self.queue:
            self.queue.remove(m)
        if self.current is m:
            self.dog.stop()
            self.current = None
        self.log.add("mission.cancelled", f"{m.label} cancelled{': ' + why if why else ''}", mission_id=m.id)
        # events left without their check are closed too, so nothing stays open forever
        if "false alarm" not in why:
            for eid in m.event_ids:
                ev = self.events.get(eid)
                if ev and ev.status in OPEN:
                    ev.status = "cancelled"
                    ev.t["cancelled"] = time.time()
                    self.log.add("event.cancelled", f"Check not completed: {why or 'mission cancelled'}",
                                 event_id=ev.id, mission_id=m.id)
                    self.push_event(ev)
        self.push_missions()

    def finish(self, m: Mission, note=""):
        m.status, m.ended, m.note = "done", time.time(), note or m.note
        if self.current is m:
            self.current = None
        self.idle_since = time.time()
        self.log.add("mission.done", f"{m.label} done{': ' + note if note else ''}", mission_id=m.id)
        self.push_missions()

    def _pick_next(self):
        if not self.queue:
            return None
        self.queue.sort(key=lambda m: (-m.priority, m.created))
        return self.queue.pop(0)

    def _start_leg(self, m, spot_id):
        spot = self.site.spot(spot_id)
        if not spot:
            self.log.add("mission.error", f"Unknown spot {spot_id}", level="error", mission_id=m.id)
            self.finish(m, "unknown spot")
            return
        m.path = self.site.path_to(self.dog.pose(), spot)
        m.phase = "moving"
        x, y, yaw, _ = m.path[0]
        self.dog.go_to(x, y, yaw)

    def _activate(self, m):
        resumed = m.status == "paused"
        m.status = "active"
        m.started = m.started or time.time()
        self.current = m
        self.log.add("mission.resumed" if resumed else "mission.started",
                     f"{m.label} {'resumed' if resumed else 'started'}", mission_id=m.id)
        self._start_leg(m, m.stops[m.idx])
        self.push_missions()

    async def loop(self):
        while True:
            await asyncio.sleep(0.1)
            try:
                self.tick()
            except Exception as e:  # keep the loop alive whatever happens
                self.log.add("system.error", f"tick: {e}", level="error")

    def tick(self):
        now = time.time()
        if not self.dog.armed:
            return
        if self.current is None:
            m = self._pick_next()
            if m:
                self._activate(m)
            else:
                self._schedules_due(now)
                if not self.queue:
                    for a in self.automations.due()[:1]:
                        self.run_automation(a)
                if self.current is None and not self.queue:
                    self._maybe_home(now)
            return
        m = self.current
        if m.status != "active" or self.dog.manual_active():
            return
        if m.phase == "moving" and self.dog.arrived():
            m.path.pop(0)
            if m.path:
                x, y, yaw, _ = m.path[0]
                self.dog.go_to(x, y, yaw)
                return
            self._at_stop(m)
        elif m.phase == "moving" and self.dog.target is None and not self.dog.arrived():
            # target dropped (operator stop or teleop): re-issue the current leg
            self._start_leg(m, m.stops[m.idx])
        elif m.phase == "dwell" and now >= m.dwell_until:
            self._next_stop(m)

    def _at_stop(self, m):
        spot = self.site.spot(m.stops[m.idx])
        if m.kind == "patrol":
            m.phase = "dwell"
            m.dwell_until = time.time() + DWELL_S
            self.log.add("patrol.checkpoint", f"{m.label}: at {spot['name']}", mission_id=m.id,
                         data={"spot": spot["id"], "round": m.loop_count + 1})
            if PATROL_CHECKS and self.cams and self.cams.online(DOG_CAM) and self.grok.enabled:
                self.spawn(self._patrol_check(m, spot))
            self.push_missions()
        elif m.kind == "inspect":
            m.status, m.phase = "verifying", "idle"
            now = time.time()
            for eid in m.event_ids:
                ev = self.events.get(eid)
                if ev and "arrived" not in ev.t:
                    ev.t["arrived"] = now
                    self.log.add("mission.arrived", f"Dog on {spot['name']} {ev.elapsed('arrived')} s after the event",
                                 event_id=ev.id, mission_id=m.id, data={"event_to_arrival_s": ev.elapsed("arrived")})
                    self.push_event(ev)
            if not m.event_ids:
                self.log.add("mission.arrived", f"Dog on {spot['name']}", mission_id=m.id)
            self.spawn(self._verify(m, spot))
            self.push_missions()
        else:
            self.finish(m, f"at {spot['name']}")

    def _next_stop(self, m):
        m.idx += 1
        if m.idx >= len(m.stops):
            m.loop_count += 1
            m.idx = 0
            if m.loops and m.loop_count >= m.loops:
                self.finish(m, f"{m.loop_count} round(s)")
                return
            self.log.add("patrol.round", f"{m.label}: round {m.loop_count} complete", mission_id=m.id)
        self._start_leg(m, m.stops[m.idx])
        self.push_missions()

    def _schedules_due(self, now):
        for rid, s in self.schedules.items():
            if now >= s["next"]:
                s["next"] = now + s["every_min"] * 60
                route = self.site.route(rid)
                if route:
                    self.log.add("patrol.scheduled", f"Scheduled {route['name']} (every {s['every_min']} min)")
                    self.submit(Mission("patrol", list(route["spots"]), 0, route["name"], loops=1, route_id=rid))
                return

    def run_automation(self, a):
        """Walks the route drawn in the app: its points become temporary spots, like the places where a person was seen."""
        stops = []
        for i, (x, y) in enumerate(a["points"]):
            sid = f"{a['id'].lower()}-{i}"
            self.site.temp_spots[sid] = {"id": sid, "name": f"{a['name']} {chr(65 + i)}", "x": x, "y": y, "temp": True}
            stops.append(sid)
        if a["loop"]:
            stops.append(stops[0])
        self.automations.mark_run(a)
        self.log.add("automation.run", f"Automation {a['name']} started", data={"id": a["id"], "stops": len(stops)})
        return self.submit(Mission("patrol", stops, 0, a["name"], loops=1, route_id=a["id"]))

    def _maybe_home(self, now):
        if not AUTO_HOME_S or now - self.idle_since < AUTO_HOME_S:
            return
        home = self.site.spot(self.site.data.get("home", "home"))
        x, y, _ = self.dog.pose()
        if home and math.hypot(x - home["x"], y - home["y"]) > 0.5:
            self.submit(Mission("home", [home["id"]], 1, "Return to base"))
        self.idle_since = now

    # operator commands -------------------------------------------------------------------
    def start_patrol(self, route_id=None, loops=0):
        route = self.site.route(route_id) if route_id else self.site.data["routes"][0]
        if not route:
            return {"ok": False, "error": f"unknown route {route_id}"}
        for m in [self.current, *self.queue]:
            if m and m.kind == "patrol":
                self.cancel(m, "replaced by a new patrol")
        m = self.submit(Mission("patrol", list(route["spots"]), 0, route["name"], loops=loops, route_id=route["id"]))
        return {"ok": True, "mission": m.id, "route": route["name"], "spots": route["spots"], "loops": loops or "continuous"}

    def stop_patrol(self):
        n = 0
        for m in [self.current, *list(self.queue)]:
            if m and m.kind == "patrol":
                self.cancel(m, "stopped by operator")
                n += 1
        return {"ok": True, "stopped": n}

    def schedule(self, route_id, every_min):
        route = self.site.route(route_id)
        if not route:
            return {"ok": False, "error": f"unknown route {route_id}"}
        if not every_min:
            self.schedules.pop(route_id, None)
            self.log.add("patrol.unscheduled", f"{route['name']} schedule removed")
            return {"ok": True, "route": route["name"], "schedule": None}
        self.schedules[route_id] = {"every_min": float(every_min), "next": time.time()}
        self.log.add("patrol.schedule", f"{route['name']} every {every_min} min")
        return {"ok": True, "route": route["name"], "every_min": every_min}

    def send_to(self, spot_id, inspect=True, reason="operator request"):
        spot = self.site.spot(spot_id) or self.site.find_spot(spot_id)
        if not spot:
            return {"ok": False, "error": f"unknown spot {spot_id}"}
        kind = "inspect" if inspect else "goto"
        m = self.submit(Mission(kind, [spot["id"]], 2 if inspect else 1,
                                f"{'Check' if inspect else 'Go to'} {spot['name']}"))
        m.note = reason
        return {"ok": True, "mission": m.id, "spot": spot["name"]}

    def go_home(self):
        home = self.site.spot(self.site.data.get("home", "home"))
        for m in [self.current, *list(self.queue)]:
            if m and m.kind in ("patrol", "goto", "home"):
                self.cancel(m, "returning to base")
        m = self.submit(Mission("home", [home["id"]], 1, "Return to base"))
        return {"ok": True, "mission": m.id}

    def stop_all(self, why="operator stop"):
        for m in [self.current, *list(self.queue)]:
            if m:
                self.cancel(m, why)
        self.dog.stop()
        self.idle_since = time.time() + 3600
        return {"ok": True}

    def estop(self):
        self.dog.estop()
        self.stop_all("emergency stop")
        self.log.add("dog.estop", "EMERGENCY STOP", level="error")
        return {"ok": True}

    # alarm ---------------------------------------------------------------------------------
    @property
    def alarm_active(self):
        a = self.alarm
        return bool(a["armed"]) and time.time() >= (a.get("active_at") or 0)

    def alarm_state(self):
        a = self.alarm
        left = max(0, round((a.get("active_at") or 0) - time.time())) if a["armed"] else 0
        return {"armed": bool(a["armed"]), "active": self.alarm_active, "exit_delay_s": left,
                "since": a.get("since"), "by": a.get("by"), "suppressed": self.suppressed}

    def set_alarm(self, armed, by="console", delay=None):
        now = time.time()
        delay = ARM_DELAY_S if delay is None else float(delay)
        if armed and self.alarm["armed"]:
            return {"ok": True, **self.alarm_state()}
        self.alarm = {"armed": bool(armed), "since": now, "by": by, "active_at": now + delay if armed else None}
        ALARM_FILE.write_text(json.dumps(self.alarm))
        if armed:
            self.log.add("alarm.armed", f"Alarm armed by {by}: active in {delay:.0f} s", level="warn",
                         data={"by": by, "delay_s": delay})
        else:
            self.log.add("alarm.disarmed", f"Alarm disarmed by {by}", data={"by": by})
            self.suppressed = 0
        self.hub.publish({"type": "alarm", **self.alarm_state()})
        if self.cams:
            self.spawn(self.cams.broadcast({"type": "alarm", "armed": bool(armed), "active_at": self.alarm["active_at"]}))
        return {"ok": True, **self.alarm_state()}

    def _mission_near(self, spot_id, radius=3.0):
        """An inspect mission already going to a place within radius meters of this spot."""
        sp = self.site.spot(spot_id)
        if not sp:
            return None
        for m in [self.current, *self.queue]:
            if m and m.kind == "inspect" and m.status in ("queued", "active", "paused"):
                other = self.site.spot(m.stops[0])
                if other and other["id"] != sp["id"] and math.hypot(other["x"] - sp["x"], other["y"] - sp["y"]) <= radius:
                    return m
        return None

    def _only_our_dog(self, cam_id, msg, snapshot):
        """True when the moving area is around the dog and no person is detected."""
        dets = msg.get("detections") or []
        if any(d.get("label") == "person" for d in dets):
            return False
        box = msg.get("motion_box")
        cam = self.site.camera(cam_id)
        if not box or not cam or not snapshot:
            return False
        try:
            import io
            from PIL import Image
            w, h = Image.open(io.BytesIO(snapshot)).size
        except Exception:
            return False
        x, y, _ = self.dog.pose()
        uv = self.site.floor_to_pixel(cam, x, y, w / h)
        if not uv:
            return False
        bx, by, bw, bh = box
        m = 0.08
        feet_in = bx - m <= uv[0] <= bx + bw + m and by - m <= uv[1] <= by + bh + m
        small = bw * bh < 0.6    # a change over most of the image (lights) is never put down to the dog
        return feet_in and small

    def _target_for(self, ev, cam, a):
        """Where the person is: the feet in the image projected on the floor, through the camera's pose.
        Only for cameras whose pose is known: calibrated ones, or simulated ones. A real phone that was not
        calibrated sends the dog to its camera's inspect spot instead."""
        info = (self.cams.cams.get(ev.camera).info if self.cams and self.cams.cams.get(ev.camera) else {}) or {}
        if info.get("detector") != "simulated" and not self.site.calib.get(ev.camera):
            self.log.add("event.located", f"{self.cam_name(ev.camera)} is not calibrated: the dog goes to its inspect spot",
                         event_id=ev.id)
            return None
        feet = None
        people = [d for d in ev.detections if d.get("label") == "person" and d.get("box")]
        if people:
            b = max(people, key=lambda d: d["box"][2] * d["box"][3])["box"]
            feet = (b[0] + b[2] / 2, b[1] + b[3])
        elif isinstance(a.get("where"), (list, tuple)) and len(a["where"]) == 2 and all(isinstance(v, (int, float)) for v in a["where"]):
            feet = (float(a["where"][0]), float(a["where"][1]))
        else:
            moving = [d for d in ev.detections if d.get("label") == "motion" and d.get("box")]
            if moving:
                b = moving[0]["box"]
                feet = (b[0] + b[2] / 2, b[1] + b[3])
        if feet is None or not ev.snapshot:
            return None
        try:
            import io
            from PIL import Image
            w, h = Image.open(io.BytesIO(ev.snapshot)).size
        except Exception:
            return None
        p = self.site.pixel_to_floor(cam, feet[0], feet[1], w / h)
        if p is None:
            return None
        what = {"person": "Persona", "object": "Oggetto"}.get(a.get("what"), "Movimento")
        spot = self.site.approach_spot(self.dog.pose(), p, f"pt-{ev.id}", f"{what} vista da {cam.get('name', ev.camera)}")
        self.log.add("event.located", f"{ {'person': 'Person', 'object': 'Object'}.get(a.get('what'), 'Movement') } on the floor at ({p[0]:.1f}, {p[1]:.1f}) m: the dog stops at "
                     f"({spot['x']:.1f}, {spot['y']:.1f}) facing it", event_id=ev.id, data={"point": p, "spot": spot})
        return spot["id"]

    # events ------------------------------------------------------------------------------
    def open_events(self, exclude=None):
        return [{"id": e.id, "camera": e.camera, "kind": e.kind, "status": e.status}
                for e in self.events.values() if e.status in OPEN and e.id != exclude]

    async def on_camera_event(self, cam_id, msg, snapshot):
        kind = msg.get("kind", "manual")
        if kind != "manual" and not self.alarm_active:
            self.suppressed += 1   # disarmed (or exit delay running): cameras are watched, nothing is raised
            return
        # one open event per camera and kind: later detections are duplicates of the same incident
        for e in reversed(list(self.events.values())):
            if e.camera == cam_id and e.kind == kind and e.status in OPEN and time.time() - e.ts < 90:
                e.duplicates += 1
                self.push_event(e)
                return
        if kind == "motion" and self._only_our_dog(cam_id, msg, snapshot):
            now = time.time()
            if now - self.dog_ignored.get(cam_id, 0) > 30:
                self.log.add("event.ignored", f"{self.cam_name(cam_id)}: what moved is our robot dog, ignored",
                             data={"camera": cam_id})
            self.dog_ignored[cam_id] = now
            return
        ev = Event(cam_id, kind, msg.get("score"), msg.get("detections"), msg.get("note", ""), snapshot)
        if msg.get("motion_box"):
            ev.detections = list(ev.detections) + [{"label": "motion", "score": 1.0, "box": msg["motion_box"]}]
        if msg.get("jpeg_annotated"):
            ev.annotated = base64.b64decode(msg["jpeg_annotated"])
        await self.handle_event(ev)

    async def handle_event(self, ev: Event, pre_assessed=None):
        self.events[ev.id] = ev
        ev.save_image("camera", ev.annotated or ev.snapshot)
        cam = self.site.camera(ev.camera) or {"id": ev.camera, "name": self.cam_name(ev.camera)}
        self.log.add("event.received", f"{cam['name']}: {ev.kind.replace('_', ' ')} (score {ev.score:.2f})",
                     level="warn", event_id=ev.id, data={"camera": ev.camera, "kind": ev.kind, "score": ev.score,
                                                         "detections": ev.detections[:6]})
        self.push_event(ev)
        spot_id = cam.get("inspect_spot") or (msg_spot if (msg_spot := ev.note.startswith("spot:") and ev.note[5:]) else None)
        if ev.camera == DOG_CAM and self.current:
            spot_id = self.current.stops[self.current.idx]

        # speculative dispatch: the dog starts moving while Grok looks at the snapshot.
        # Plain movement waits for Grok: light changes and shadows would move the dog for nothing.
        m = None
        if spot_id and SPECULATIVE and pre_assessed is None and ev.kind != "motion":
            m = self._dispatch(ev, spot_id, KIND_SEVERITY.get(ev.kind, 3), speculative=True)

        ev.status = "assessing"
        if pre_assessed is not None:
            a = pre_assessed
        else:
            a = await self._assess(ev, cam)
        if self.events.get(ev.id) is not ev:
            return  # reset while Grok was looking
        ev.assessment, ev.t["assessed"] = a, time.time()
        ev.assessed.set()
        self.log.add("event.assessed",
                     f"{a.get('by', 'grok')}: {a.get('verdict')} · severity {a.get('severity')} · "
                     f"{'dispatch' if a.get('dispatch') else 'no dispatch'} · {a.get('reason', '')}",
                     event_id=ev.id, data=a)

        if not a.get("dispatch") and ALWAYS_CHECK:
            # simulation: Grok's "false alarm" is kept as its opinion, the dog goes and the check on site decides
            a = {**a, "dispatch": True, "override": "always_check", "severity": max(2, int(a.get("severity") or 2))}
            ev.assessment = a
            self.log.add("event.checked_anyway", "Grok says false alarm: the dog checks on site anyway (simulation)",
                         event_id=ev.id, data={"verdict": a.get("verdict"), "reason": a.get("reason")})
        if not a.get("dispatch"):
            ev.status = "dismissed"
            ev.t.pop("dispatched", None)
            if m and ev.id in m.event_ids:
                m.event_ids.remove(ev.id)
            ev.mission_id = None
            if m and m.kind == "inspect" and m.status in ("queued", "active", "paused"):
                others = [e for e in m.event_ids if e in self.events and self.events[e].status != "dismissed"]
                if others:
                    self.log.add("mission.kept", f"{m.label} continues for the other {len(others)} event(s)",
                                 event_id=ev.id, mission_id=m.id)
                else:
                    self.cancel(m, "false alarm, recalled")
                    self.log.add("mission.recalled", "Dog recalled: Grok marked it a false alarm", event_id=ev.id,
                                 mission_id=m.id)
            self.log.add("event.dismissed", "False alarm filtered, nothing forwarded", event_id=ev.id)
            self.push_event(ev)
            return
        sev = int(a.get("severity") or 3)
        if m and m.status in ("cancelled", "done"):
            m = None  # recalled for another event meanwhile: send it again
        if m:
            m.priority = max(m.priority, max(2, min(5, sev)))
            m.speculative = False
            self.push_missions()
        if ev.kind in ARMED_KINDS:
            target = self._target_for(ev, cam, a)
            same = self._mission_near(target) if target else None
            if same and same is not m:
                # another camera saw the same thing: one check, one alert
                same.event_ids.append(ev.id)
                same.priority = max(same.priority, max(2, min(5, sev)))
                ev.mission_id, ev.t["dispatched"] = same.id, time.time()
                self.log.add("mission.merged", f"Same place as {same.label}: joined that check", event_id=ev.id,
                             mission_id=same.id)
                if m and m.status in ("queued", "active", "paused"):
                    self.cancel(m, "merged with a check of the same place")
                ev.status = "dispatched"
                self.push_event(ev)
                self.push_missions()
                return
            if target:
                if m and m.status in ("queued", "active", "paused"):
                    # the dog left early for the camera's spot: send the same mission to where the person is
                    m.stops, m.idx = [target], 0
                    m.label = f"Check {self.site.spot(target)['name']}"
                    if self.current is m and m.status == "active":
                        self._start_leg(m, target)
                    self.push_missions()
                else:
                    m, spot_id = None, target
        if m and m.status not in ("cancelled", "done"):
            pass
        elif spot_id:
            self._dispatch(ev, spot_id, sev)
        ev.status = "dispatched" if ev.status == "assessing" else ev.status
        self.push_event(ev)

    def _dispatch(self, ev, spot_id, severity, speculative=False):
        # several events on the same spot share one mission
        for m in [self.current, *self.queue]:
            if m and m.kind == "inspect" and m.stops == [spot_id] and m.status in ("queued", "active", "paused"):
                m.event_ids.append(ev.id)
                m.priority = max(m.priority, severity)
                ev.mission_id, ev.t["dispatched"] = m.id, time.time()
                self.log.add("mission.merged", f"Event joined {m.label}", event_id=ev.id, mission_id=m.id)
                return m
        spot = self.site.spot(spot_id)
        m = Mission("inspect", [spot_id], max(2, min(5, severity)), f"Check {spot['name'] if spot else spot_id}",
                    event_ids=[ev.id])
        m.speculative = speculative
        ev.mission_id, ev.t["dispatched"] = m.id, time.time()
        self.submit(m)
        self.log.add("mission.dispatched",
                     f"Dog sent to {spot['name'] if spot else spot_id}{' (moving while Grok assesses)' if speculative else ''}",
                     event_id=ev.id, mission_id=m.id, data={"speculative": speculative})
        return m

    async def _assess(self, ev, cam):
        if self.grok.enabled and ev.snapshot:
            try:
                a = await self.grok.assess(ev, cam, self.open_events(ev.id))
                a["by"] = "grok"
                a["dispatch"] = bool(a.get("dispatch"))
                # a missed intrusion costs more than a wasted walk: a "false alarm" needs a second opinion
                if not a["dispatch"] and self.grok.vision != self.grok.fast:
                    self.log.add("event.second_opinion", f"Fast triage says false alarm ({a.get('reason', '')}): "
                                 f"asking {self.grok.vision}", event_id=ev.id)
                    try:
                        b = await self.grok.assess(ev, cam, self.open_events(ev.id), model=self.grok.vision)
                        b["dispatch"] = bool(b.get("dispatch"))
                        b["by"] = "grok, second opinion"
                        b["first_look"] = {k: a.get(k) for k in ("verdict", "reason")}
                        return b
                    except Exception as e:
                        self.log.add("grok.error", f"second opinion: {e!r}"[:300], level="error", event_id=ev.id)
                        # no second opinion: keep the dog going, the check on site decides
                        return {**a, "by": "grok, unconfirmed", "verdict": "suspicious", "dispatch": True,
                                "severity": max(2, int(a.get("severity") or 2)),
                                "reason": "Secondo parere non disponibile: il cane verifica sul posto",
                                "first_look": {k: a.get(k) for k in ("verdict", "reason")}}
                return a
            except Exception as e:
                self.log.add("grok.error", f"assess: {e!r}"[:300], level="error", event_id=ev.id)
        sev = KIND_SEVERITY.get(ev.kind, 3)
        return {"by": "rules", "verdict": "suspicious", "category": ev.kind, "severity": sev,
                "confidence": ev.score, "dispatch": ev.score >= 0.5 or ev.kind == "manual",
                "reason": "Grok unavailable: dispatch on detector confidence", "check_for": ev.kind}

    async def _frame_for_check(self, cam_ids):
        # a simulated dog cannot see a real person: when the event came from a real phone, the check on
        # arrival uses a fresh frame of that phone
        if self.dog.kind in ("sim", "mujoco"):
            for cid in cam_ids:
                cam = self.cams.cams.get(cid)
                if cid and cid != DOG_CAM and cam and cam.online and (cam.info or {}).get("detector") != "simulated":
                    img = await self.cams.capture(cid)
                    if img:
                        return img, cid
        if self.cams.online(DOG_CAM):
            img = await self.cams.capture(DOG_CAM)
            if img:
                return img, DOG_CAM
        for cid in cam_ids:
            if cid and cid != DOG_CAM:
                img = await self.cams.capture(cid)
                if img:
                    return img, cid
        return None, None

    async def _verify(self, m, spot):
        evs = [self.events[e] for e in m.event_ids if e in self.events]
        for ev in evs:
            ev.status = "verifying"
            self.push_event(ev)
        await asyncio.sleep(1.0)  # let the dog settle and the camera focus
        for ev in evs:
            try:
                await asyncio.wait_for(ev.assessed.wait(), 10)
            except asyncio.TimeoutError:
                pass
        if self.current is not m and m.status != "verifying":
            return
        had_events = bool(evs)
        evs = [e for e in evs if e.status != "dismissed"]
        if had_events and not evs:
            self.finish(m, "false alarm, nothing left to check")
            return
        img, src = await self._frame_for_check([e.camera for e in evs])
        primary = evs[0] if evs else None
        if primary:
            primary.save_image("dog" if src == DOG_CAM else "check", img)
        summary = {"spot": spot["name"], "operator_reason": m.note or None,
                   "events": [{"camera": self.cam_name(e.camera), "kind": e.kind,
                               "triage": (e.assessment or {}).get("reason"),
                               "check_for": (e.assessment or {}).get("check_for")} for e in evs]}
        v = None
        if self.grok.enabled and img:
            try:
                v = await self.grok.verify(summary, img, primary.snapshot if primary else None,
                                           dog_is_fixed_cam=src != DOG_CAM)
                v["by"] = "grok"
            except Exception as e:
                self.log.add("grok.error", f"verify: {e!r}"[:300], level="error", mission_id=m.id)
        if v is None:
            v = {"by": "rules", "confirmed": None, "risk": "medium" if evs else "none", "people": None, "objects": [],
                 "description": "No image or Grok unavailable: manual check needed" if evs else "No image available",
                 "action": "Check the camera feed"}
        if m.status == "cancelled":
            return  # reset or stopped while Grok was looking
        v["source"] = src
        now = time.time()
        self.log.add("mission.verified", f"{spot['name']}: {v.get('description', '')}", mission_id=m.id,
                     event_id=primary.id if primary else None, data=v)
        for ev in evs:
            ev.verification, ev.t["verified"] = v, now

        must_alert = v.get("confirmed") is True or (v.get("confirmed") is None and evs) \
            or (not evs and v.get("risk") in ("medium", "high"))
        if must_alert:
            await self._alert(m, spot, evs, v, img)
        else:
            for ev in evs:
                ev.status = "cleared"
                self.log.add("event.cleared", "Checked on site: false alarm, no alert sent", event_id=ev.id,
                             mission_id=m.id)
                self.push_event(ev)
        self.finish(m, "alert sent" if must_alert else "all clear")

    async def _alert(self, m, spot, evs, v, img):
        sev = max([int((e.assessment or {}).get("severity") or 3) for e in evs] or [3])
        payload = {"site": self.site.data.get("name"), "where": spot["name"], "time": time.strftime("%H:%M"),
                   "events": [{"camera": self.cam_name(e.camera), "kind": e.kind,
                               "triage": (e.assessment or {}).get("reason")} for e in evs],
                   "dog_saw": v.get("description"), "risk": v.get("risk"), "confirmed": v.get("confirmed"),
                   "action": v.get("action")}
        alert = None
        if self.grok.enabled:
            try:
                alert = await self.grok.compose_alert(payload)
                alert["by"] = "grok"
            except Exception as e:
                self.log.add("grok.error", f"alert: {e}", level="error", mission_id=m.id)
        if not alert:
            what = ", ".join(sorted({e.kind.replace("_", " ") for e in evs})) or "check requested"
            alert = {"by": "template", "title": f"Allarme: {what}",
                     "sms": f"{spot['name']} ore {payload['time']}: {v.get('description', '')}. {v.get('action', '')}",
                     "voice": f"Messaggio automatico del sistema di ronda. {what} in {spot['name']}. "
                              f"{v.get('description', '')}"}
        first = evs[0] if evs else None
        ctx = {"events": [{"id": e.id, "kind": e.kind, "camera": self.cam_name(e.camera)} for e in evs],
               "spot": spot["name"], "spot_id": spot["id"], "ts": first.ts if first else time.time(),
               "arrival_s": first.elapsed("arrived") if first else None, "verification": v, "mission_id": m.id}
        results = await self.alerts.send(alert, img, sev, ctx)
        now = time.time()
        for ev in evs:
            ev.alert, ev.alert_results, ev.t["alerted"], ev.status = alert, results, now, "alerted"
            self.push_event(ev)
        self.log.add("alert.sent", f"{alert.get('title')}: {alert.get('sms')}", level="alert",
                     mission_id=m.id, event_id=evs[0].id if evs else None,
                     data={"alert": alert, "results": results, "severity": sev})
        self.hub.publish({"type": "alert", "alert": alert, "spot": spot["name"], "results": results,
                          "image": evs[0].images.get("dog") or evs[0].images.get("check") if evs else None})

    async def _patrol_check(self, m, spot):
        img = await self.cams.capture(DOG_CAM)
        if not img:
            return
        try:
            r = await self.grok.patrol_check(img, spot)
        except Exception as e:
            self.log.add("grok.error", f"patrol check: {e}", level="error", mission_id=m.id)
            return
        self.log.add("patrol.look", f"{spot['name']}: {r.get('description', '')}", mission_id=m.id, data=r)
        if r.get("anomaly") and int(r.get("severity") or 0) >= 3 and r.get("category") in ("intrusion", "abandoned_object"):
            if time.time() - self.patrol_seen.get(spot["id"], 0) < 600:
                self.log.add("patrol.known", f"{spot['name']}: already reported in the last 10 minutes", mission_id=m.id)
                return
            self.patrol_seen[spot["id"]] = time.time()
            ev = Event(DOG_CAM, "patrol_finding", 0.9, [], r.get("description", ""), img)
            a = {"by": "grok", "verdict": "suspicious", "category": r.get("category"),
                 "severity": int(r.get("severity") or 3), "confidence": 0.8, "dispatch": True,
                 "reason": r.get("description", ""), "check_for": r.get("category")}
            await self.handle_event(ev, pre_assessed=a)
