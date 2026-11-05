"""Phones and laptops used as cameras, connected over a websocket. 'dog' is the camera riding on the dog."""
import asyncio
import base64
import json
import time
import uuid
from collections import deque

from .config import DATA

ZONES = DATA / "zones.json"
DOG_CAM = "dog"


# websocket close code: this channel now belongs to another camera. Whoever gets it must not fight back:
# two sources that reconnect at each other swap the picture every second.
TAKEN = 4409

class Cam:
    def __init__(self, cid):
        self.id = cid
        self.ws = None
        self.last_seen = 0.0
        self.preview = None
        self.preview_ts = 0.0
        self.frame = None
        self.frame_ts = 0.0
        self.info = {}
        self.pending = {}
        self.outbox = []        # messages for a camera without websocket, collected by its polling
        self.http = False
        self.http_seen = 0.0
        self.sim = False        # the websocket is the simulator's: it gives way to a real camera
        self.pull = False       # frames pulled by the server (the dog's Jetson stream)
        self.viewers = 0        # open /stream connections: while > 0 the camera sends a fast, larger preview
        self.seq = 0            # counts new frames, so a stream only sends each one once
        self.times = deque(maxlen=30)

    def got_frame(self):
        self.seq += 1
        self.times.append(time.time())

    @property
    def latest(self):
        return self.frame if self.pull else self.preview

    @property
    def rate(self):
        """Frames per second actually received in the last seconds."""
        t = [x for x in self.times if time.time() - x < 3]
        return round((len(t) - 1) / (t[-1] - t[0]), 1) if len(t) > 2 and t[-1] > t[0] else 0.0

    @property
    def real(self):
        """A real camera is sending here now, on its websocket or by polling."""
        return (self.ws is not None and not self.sim) or time.time() - self.http_seen < 6

    @property
    def online(self):
        return (self.ws is not None or self.http or self.pull) and time.time() - self.last_seen < 6

    async def send(self, msg):
        if self.ws is not None:
            await self.ws.send_json(msg)
        elif self.http:
            self.outbox.append(msg)
            del self.outbox[:-20]


class Cameras:
    def __init__(self, site, log, on_event, alarm_fn=None):
        self.alarm_fn = alarm_fn  # () -> {"armed": bool, "active_at": ts}
        # on_event: async (cid, msg, snapshot_jpeg_or_None), called for every detection the camera reports
        self.site = site
        self.log = log
        self.on_event = on_event
        self.cams = {}
        self.zones = json.loads(ZONES.read_text()) if ZONES.exists() else {}

    def get(self, cid):
        if cid not in self.cams:
            self.cams[cid] = Cam(cid)
        return self.cams[cid]

    def name(self, cid):
        meta = self.site.camera(cid)
        if meta:
            return meta["name"]
        if cid == DOG_CAM:
            return "Dog camera"
        return cid.replace("phone-", "Phone ") if cid.startswith("phone-") else cid

    def set_zone(self, cid, zone):
        self.zones[cid] = zone
        ZONES.write_text(json.dumps(self.zones))

    async def handle(self, cid, ws, sim=False):
        cam = self.get(cid)
        if sim and cam.real:
            await ws.close(code=TAKEN)
            return
        if cam.ws is not None:
            try:
                await cam.ws.close(code=TAKEN)
            except Exception:
                pass
        cam.ws, cam.sim = ws, sim
        cam.last_seen = time.time()
        await ws.send_json({"type": "config", "zone": self.zones.get(cid), "name": self.name(cid),
                            "role": "dog" if cid == DOG_CAM else "fixed"})
        await ws.send_json({"type": "live", "on": cam.viewers > 0})
        if self.alarm_fn:
            await ws.send_json({"type": "alarm", **self.alarm_fn()})
        self.log.add("camera.online", f"{self.name(cid)} connected", data={"camera": cid})
        try:
            while True:
                msg = await ws.receive_json()
                cam.last_seen = time.time()
                await self._on(cam, msg)
        except Exception:
            pass
        finally:
            if cam.ws is ws:
                cam.ws = None
                self.log.add("camera.offline", f"{self.name(cid)} disconnected", level="warn", data={"camera": cid})

    async def _on(self, cam, msg):
        t = msg.get("type")
        if t == "preview" and msg.get("jpeg"):
            cam.preview, cam.preview_ts = base64.b64decode(msg["jpeg"]), time.time()
            cam.got_frame()
        elif t == "frame" and msg.get("jpeg"):
            cam.frame, cam.frame_ts = base64.b64decode(msg["jpeg"]), time.time()
            fut = cam.pending.pop(msg.get("req"), None)
            if fut and not fut.done():
                fut.set_result(cam.frame)
        elif t == "status":
            cam.info = {k: msg.get(k) for k in ("fps", "armed", "model", "people", "objects", "w", "h", "detector", "motion")}
        elif t == "log" and msg.get("message"):
            self.log.add("camera.note", f"{cam.id}: {msg['message']}"[:200], level="warn")
        elif t == "zone":
            self.set_zone(cam.id, msg.get("zone"))
        elif t == "event":
            snap = base64.b64decode(msg["jpeg"]) if msg.get("jpeg") else None
            if snap:
                cam.frame, cam.frame_ts = snap, time.time()
            asyncio.create_task(self.on_event(cam.id, msg, snap))

    async def broadcast(self, msg):
        for cam in list(self.cams.values()):
            if cam.ws is not None or cam.http:
                try:
                    await cam.send(msg)
                except Exception:
                    pass

    # cameras whose browser cannot open the websocket (iPhone Safari with the laptop's certificate)
    async def http_message(self, cid, msg):
        cam = self.get(cid)
        first = not cam.online
        cam.http, cam.last_seen = True, time.time()
        cam.http_seen = cam.last_seen
        if cam.sim and cam.ws is not None:
            sim, cam.ws, cam.sim = cam.ws, None, False
            first = True
            try:
                await sim.close(code=TAKEN)
            except Exception:
                pass
        if first:
            cam.outbox.append({"type": "config", "zone": self.zones.get(cid), "name": self.name(cid),
                               "role": "dog" if cid == DOG_CAM else "fixed"})
            cam.outbox.append({"type": "live", "on": cam.viewers > 0})
            if self.alarm_fn:
                cam.outbox.append({"type": "alarm", **self.alarm_fn()})
            self.log.add("camera.online", f"{self.name(cid)} connected (without websocket)",
                         data={"camera": cid, "via": "http"})
        if msg:
            await self._on(cam, msg)

    def http_poll(self, cid):
        cam = self.get(cid)
        out, cam.outbox = cam.outbox, []
        return out

    def ingest(self, cid, jpeg):
        """A frame from a stream the server reads itself. Safe from any thread."""
        cam = self.get(cid)
        now = time.time()
        cam.pull, cam.last_seen, cam.frame, cam.frame_ts = True, now, jpeg, now
        cam.got_frame()
        if now - cam.preview_ts >= 1.0:
            try:
                import io as _io
                from PIL import Image
                im = Image.open(_io.BytesIO(jpeg))
                im.thumbnail((320, 320))
                b = _io.BytesIO()
                im.convert("RGB").save(b, "JPEG", quality=70)
                cam.preview, cam.preview_ts = b.getvalue(), now
            except Exception:
                cam.preview, cam.preview_ts = jpeg, now
        cam.info = {"detector": "jetson stream", "fps": None}

    # live view: the camera sends fast frames only while someone is watching
    def _live(self, cam):
        async def tell():
            try:
                await cam.send({"type": "live", "on": cam.viewers > 0})
            except Exception:
                pass
        asyncio.get_running_loop().create_task(tell())

    async def watch(self, cid):
        """MJPEG stream of a camera. Waits for a camera that is offline, and picks it up when it connects."""
        cam = self.get(cid)
        cam.viewers += 1
        if cam.viewers == 1:
            self._live(cam)
        seen, last = None, time.time()
        try:
            while True:
                img = cam.latest
                if img and cam.seq != seen:
                    seen, last = cam.seq, time.time()
                    yield (b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: " + str(len(img)).encode()
                           + b"\r\n\r\n" + img + b"\r\n")
                elif seen is not None and not cam.online and time.time() - last > 5:
                    return   # the camera went away: a client must not keep showing a frozen picture
                await asyncio.sleep(0.02)
        finally:
            cam.viewers -= 1
            if cam.viewers == 0:
                self._live(cam)

    async def capture(self, cid, timeout=3.0):
        """Ask a camera for a fresh full-resolution frame."""
        cam = self.cams.get(cid)
        if not cam or not cam.online:
            return None
        if cam.pull and cam.frame and time.time() - cam.frame_ts < 2:
            return cam.frame
        rid = uuid.uuid4().hex[:8]
        fut = asyncio.get_running_loop().create_future()
        cam.pending[rid] = fut
        try:
            await cam.send({"type": "capture", "req": rid})
            return await asyncio.wait_for(fut, timeout)
        except Exception:
            cam.pending.pop(rid, None)
            if cam.preview and time.time() - cam.preview_ts < 3:
                return cam.preview
            return None

    def online(self, cid):
        cam = self.cams.get(cid)
        return bool(cam and cam.online)

    def status(self):
        out = []
        ids = [c["id"] for c in self.site.data["cameras"]] + [DOG_CAM]
        for cid in ids + [c for c in self.cams if c not in ids]:
            cam = self.cams.get(cid)
            cal = self.site.calib.get(cid)
            out.append({"id": cid, "name": self.name(cid), "online": bool(cam and cam.online),
                        "info": cam.info if cam else {}, "preview_ts": cam.preview_ts if cam else 0,
                        "zone": self.zones.get(cid), "calib_m": cal.get("rms_m", "set") if cal else None,
                        "viewers": cam.viewers if cam else 0, "stream_fps": cam.rate if cam else 0.0})
        return out
