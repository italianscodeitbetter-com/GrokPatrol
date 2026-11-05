"""Admin backend: the dog, the cameras, the simulator bridge, the event pipeline, missions and Grok."""
import asyncio
import os
import json
import re
import socket
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, WebSocket
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, PlainTextResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles

from . import auth
from .alerts import Alerts
from .cameras import Cameras
from .config import DOG_KIND, GO1_LINK, ROOT, SNAPS, VMAX, WMAX, Site
from .grok import Grok
from .hub import Hub
from .logbook import Logbook
from .mission import Event, Manager
from .telegram import TelegramBot

site = Site()
hub = Hub()
log = Logbook(hub)
if DOG_KIND == "go1" and GO1_LINK == "mqtt":
    from .dogs.go1mqtt import Go1MqttDog
    dog = Go1MqttDog()
elif DOG_KIND == "go1":
    from .dogs.go1 import Go1Dog
    dog = Go1Dog()
elif DOG_KIND == "mujoco":
    from .dogs.mujoco import MujocoDog
    dog = MujocoDog()
else:
    from .dogs.sim import SimDog
    dog = SimDog()
dog.home_pose = site.home_pose()
if hasattr(dog, "teleport"):
    dog.teleport(*dog.home_pose)  # simulated dogs start on the home spot
grok = Grok(site)
alerts = Alerts()
mgr = Manager(site, dog, grok, alerts, log, hub)


async def on_camera_event(cid, msg, snap):
    hub.publish({"type": "camera_event", "camera": cid, "kind": msg.get("kind"), "ts": time.time(),
                 "has_snapshot": snap is not None})
    await mgr.on_camera_event(cid, msg, snap)


cams = Cameras(site, log, on_camera_event,
               alarm_fn=lambda: {"armed": mgr.alarm["armed"], "active_at": mgr.alarm.get("active_at")})
mgr.cams = cams
from .dogcam import DogCamera
dogcam = DogCamera(cams, log)
tg = TelegramBot(site, log)
alerts.bot = tg
sim = {"ws": None, "actors": [], "scenarios": [], "view": "follow"}
chat_history = []
LIMITS = {"vmax": VMAX, "wmax": WMAX}


def snapshot():
    return {
        "dog": dog.status(),
        "limits": LIMITS,
        "current": mgr.current.public() if mgr.current else None,
        "queue": [m.public() for m in mgr.queue],
        "stats": mgr.stats(),
        "alarm": mgr.alarm_state(),
        "shift": log.shift_start,   # changes on Reset and New shift: open consoles reload
        "grok": grok.status(),
        "alerts": alerts.channels(),
        "telegram": tg.status(),
        "dogcam": dogcam.status() if dog.kind == "go1" else None,
        "schedules": {k: {"every_min": v["every_min"], "next_in_s": round(v["next"] - time.time())}
                      for k, v in mgr.schedules.items()},
        "automations": mgr.automations.public(),
        "cameras": [c for c in cams.status() if c["id"] != "sim-view"],   # the simulator's own overview, not a camera
        "sim": {"connected": sim["ws"] is not None, "actors": sim["actors"], "scenarios": sim["scenarios"],
                "view": sim["view"]},
    }


async def ticker():
    while True:
        await asyncio.sleep(0.25)
        try:
            hub.publish({"type": "tick", **snapshot()})
        except Exception as e:  # never let the live updates stop
            print("tick failed:", repr(e))


async def sim_pose_stream():
    while True:
        await asyncio.sleep(1 / 30)
        ws = sim["ws"]
        if ws is None:
            continue
        x, y, yaw = dog.pose()
        try:
            tp = getattr(dog, "pending_teleport", None)
            if tp:
                dog.pending_teleport = None
                await ws.send_json({"type": "teleport", "x": tp[0], "y": tp[1], "yaw": tp[2]})
            await ws.send_json({"type": "pose", "x": x, "y": y, "yaw": yaw, "cmd": dog.cmd, "posture": dog.posture})
        except Exception:
            pass


@asynccontextmanager
async def lifespan(app):
    loop = asyncio.get_running_loop()
    hub.start(loop)
    dog.start()
    tasks = [loop.create_task(mgr.loop()), loop.create_task(ticker()), loop.create_task(sim_pose_stream()),
             loop.create_task(tg.run())]
    log.add("system.start", f"Admin backend started · dog: {dog.kind} · Grok: {'on' if grok.enabled else 'off'}",
            data={"dog": dog.kind, "models": grok.status()["models"]})
    yield
    for t in tasks:
        t.cancel()


app = FastAPI(lifespan=lifespan)
app.mount("/static", StaticFiles(directory=ROOT / "web"), name="static")
clients_seen = {}   # user agent -> last time, to see which browsers open the console


@app.middleware("http")
async def pin_and_no_cache(request: Request, call_next):
    """From outside the laptop: PIN first. Never serve a cached camera page or script."""
    p = request.url.path
    # /open/... only bounces to the mobile app (no data): it must work from a Telegram button without the PIN
    if request.method != "OPTIONS" and auth.is_remote(request.headers, request.headers.get("host")) and p != "/login" \
            and not p.startswith("/open/"):
        if not auth.authorized(request.headers, request.cookies, request.query_params):
            if p.startswith("/api/") or p.startswith("/static/"):
                return JSONResponse({"ok": False, "error": "PIN required"}, status_code=401)
            return auth.login_page(str(request.url.path) + (("?" + str(request.url.query)) if request.url.query else ""))
        if request.query_params.get("pin"):
            # the QR code carries the PIN once: remember it and drop it from the address
            clean = str(request.url.path) + "".join(f"{'?' if i == 0 else '&'}{k}={v}" for i, (k, v) in
                                                     enumerate((k, v) for k, v in request.query_params.items() if k != "pin"))
            return auth.redirect_after_login(clean, request.url.scheme == "https" or request.headers.get("x-forwarded-proto") == "https")
    response = await call_next(request)
    p = request.url.path
    if p in ("/", "/camera", "/guida", "/controller") or p.startswith("/static/") and p.endswith((".js", ".css", ".html")):
        response.headers["Cache-Control"] = "no-store"
    if p in ("/api/state", "/api/poll") or p.startswith("/api/cam/"):
        clients_seen[request.headers.get("user-agent", "?")[:160]] = {"t": time.time(), "via": "polling" if p != "/api/state" else "page", "host": request.url.netloc, "path": p[:30]}
    return response


# added after the PIN middleware so it is the outermost layer: preflights and 401s carry CORS headers
app.add_middleware(CORSMiddleware, allow_origins=["http://localhost:3000", "http://127.0.0.1:3000"],
                   allow_credentials=True, allow_methods=["*"], allow_headers=["*"])


@app.post("/login")
async def login(req: Request):
    from urllib.parse import parse_qs
    raw = parse_qs((await req.body()).decode("utf-8", "replace"))
    form = {k: v[0] for k, v in raw.items()}
    ip = (req.headers.get("x-forwarded-for") or (req.client.host if req.client else "?")).split(",")[0].strip()
    nxt = str(form.get("next") or "/camera")
    if auth.blocked(ip):
        return auth.login_page(nxt, "Troppi tentativi: riprova tra 10 minuti.")
    if str(form.get("pin", "")).strip() != auth.PIN:
        auth.failed(ip)
        log.add("access.denied", f"Wrong PIN from {ip}", level="warn")
        return auth.login_page(nxt, "PIN sbagliato.")
    log.add("access.granted", f"Remote access from {ip}", data={"ua": req.headers.get("user-agent", "")[:120]})
    return auth.redirect_after_login(nxt, req.headers.get("x-forwarded-proto") == "https")


def ws_allowed(ws):
    return not auth.is_remote(ws.headers, ws.headers.get("host")) or auth.authorized(ws.headers, ws.cookies, ws.query_params)


@app.get("/api/public")
async def public_info():
    """The tunnel address, read from the local ngrok agent, for the phones."""
    url = None
    try:
        import httpx as _h
        r = await _h.AsyncClient(timeout=2).get("http://127.0.0.1:4040/api/tunnels")
        tunnels = r.json().get("tunnels", [])
        url = next((t["public_url"] for t in tunnels if t.get("public_url", "").startswith("https")), None)
    except Exception:
        pass
    return {"url": url, "camera": f"{url}/camera" if url else None, "pin": auth.PIN if url else None,
            "lan_camera": lan_camera()}


def lan_camera():
    """The camera page on the local network: phones need https to open their camera."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))     # sends nothing: it only picks the outgoing interface
            ip = s.getsockname()[0]
    except OSError:
        return None
    return f"https://{ip}:{os.environ.get('HTTPS_PORT', 8443)}/camera"


@app.get("/open/{kind}/{oid}")
async def open_in_app(kind: str, oid: str):
    """Landing page of the Telegram button: opens the GrokPatrol app (grokpatrol://open/<kind>/<id>)."""
    if kind not in ("mission", "event") or not re.fullmatch(r"[\w-]{1,40}", oid):
        return Response(status_code=404)
    app_url = f"grokpatrol://open/{kind}/{oid}"
    label = "la missione" if kind == "mission" else "l'evento"
    return HTMLResponse(f"""<!doctype html><html lang="it"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>GrokPatrol · {oid}</title>
<style>body{{margin:0;min-height:100vh;display:grid;place-items:center;background:#0b0c0e;color:#e8e9eb;
font:16px -apple-system,BlinkMacSystemFont,system-ui,sans-serif;padding:16px}}main{{width:min(360px,100%);display:grid;gap:14px;text-align:center}}
h1{{font-size:20px;margin:0}}p{{margin:0;color:#8b9099}}a{{display:block;padding:13px;border-radius:12px;text-decoration:none;font-weight:600}}
.app{{background:#e8e9eb;color:#0b0c0e}}.web{{border:1px solid #2e3138;color:#e8e9eb}}</style></head>
<body><main><h1>GrokPatrol</h1><p>Apro {label} <b>{oid}</b> nell'app.</p>
<a class="app" href="{app_url}">Apri nell'app</a>
<a class="web" href="/">Apri la console sul Mac</a>
<p style="font-size:13px">Se non succede niente, l'app GrokPatrol non è installata su questo telefono.</p></main>
<script>location.href = {json.dumps(app_url)};</script></body></html>""")


@app.get("/api/qr.png")
async def qr_png(data: str):
    import io as _io
    import qrcode
    img = qrcode.make(data, box_size=8, border=2)
    buf = _io.BytesIO()
    img.save(buf, format="PNG")
    return Response(buf.getvalue(), media_type="image/png", headers={"Cache-Control": "no-store"})


@app.get("/camera")
async def camera_page():
    return FileResponse(ROOT / "web" / "camera.html")


# the Mac console of the original Ronda: calibration, staged scenes, chat, report (the Next console is admin/web)
@app.get("/")
async def console_page():
    return FileResponse(ROOT / "web" / "console.html")


@app.get("/guida")
async def guide_page():
    return FileResponse(ROOT / "web" / "guida.html")


@app.get("/controller")
async def controller_page():
    return FileResponse(ROOT / "web" / "controller.html")


@app.get("/api/state")
async def state():
    return {**snapshot(), "site": site.data, "events": [e.public() for e in list(mgr.events.values())[-100:]],
            "log": log.query(since=log.shift_start, limit=300), "chat": chat_history[-20:]}


@app.get("/api/poll")
async def poll(log_after: int = 0, ev_after: float = 0):
    """Fallback when the websocket cannot connect: the same live state, asked for every second."""
    evs = [e.public() for e in mgr.events.values() if max(e.t.values()) > ev_after - 1]
    return {"tick": snapshot(), "log": [e for e in log.query(since=log.shift_start, limit=200) if e["id"] > log_after],
            "events": evs, "now": time.time()}


@app.get("/api/debug/clients")
async def debug_clients():
    return {"websocket_consoles": len(hub.clients),
            "seen": sorted(({"ua": k, **v, "ago_s": round(time.time() - v["t"])} for k, v in clients_seen.items()),
                           key=lambda c: c["ago_s"])}


@app.get("/api/snapshots/{name}")
async def snap(name: str):
    p = SNAPS / name
    if not re.fullmatch(r"[\w.-]+\.jpg", name) or not p.exists():
        return Response(status_code=404)
    return FileResponse(p, media_type="image/jpeg")


@app.get("/api/cameras/{cid}/preview.jpg")
async def preview(cid: str):
    cam = cams.cams.get(cid)
    if not cam or not cam.preview:
        return Response(status_code=404)
    return Response(cam.preview, media_type="image/jpeg", headers={"Cache-Control": "no-store"})


@app.get("/api/cameras/{cid}/live.jpg")
async def camera_live(cid: str):
    """The latest full frame, for the live view (the dog's Jetson stream)."""
    cam = cams.cams.get(cid)
    img = cam and (cam.frame if cam.pull else cam.preview)
    if not img:
        return Response(status_code=404)
    return Response(img, media_type="image/jpeg", headers={"Cache-Control": "no-store"})


@app.get("/api/cameras/{cid}/stream")
async def camera_stream(cid: str):
    """Live video as MJPEG: works in a plain <img> and in the app. The camera sends fast frames only while watched."""
    return StreamingResponse(cams.watch(cid), media_type="multipart/x-mixed-replace; boundary=frame",
                             headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"})


@app.post("/api/dogcam/{action}")
async def dogcam_action(action: str):
    """Start or stop the head camera stream of the real Go1."""
    if action == "start":
        return await asyncio.to_thread(dogcam.start)
    if action == "stop":
        return await asyncio.to_thread(dogcam.stop)
    return dogcam.status()


@app.get("/api/cameras/{cid}/frame.jpg")
async def camera_frame(cid: str):
    """A fresh full-size frame, for calibration."""
    img = await cams.capture(cid, timeout=4.0) if cams.online(cid) else None
    if not img:
        cam = cams.cams.get(cid)
        img = cam.frame or cam.preview if cam else None
    if not img:
        return Response(status_code=404)
    return Response(img, media_type="image/jpeg", headers={"Cache-Control": "no-store"})


@app.get("/api/calib")
async def calib_all():
    return site.calib.data


@app.post("/api/calib/solve")
async def calib_solve(req: Request):
    from .calib import solve
    body = await req.json()
    return solve(body.get("points", []))


@app.post("/api/calib/{cid}")
async def calib_save(cid: str, req: Request):
    body = await req.json()
    r = site.calib.save(cid, body.get("points", []), body.get("aspect"))
    if r.get("ok"):
        log.add("camera.calibrated", f"{mgr.cam_name(cid)} calibrated on the floor: {r['n']} pairs"
                + (f", error {r['rms_m']:.2f} m" if r.get("rms_m") is not None else ""), data={"camera": cid, "rms_m": r.get("rms_m")})
    return r


@app.delete("/api/calib/{cid}")
async def calib_delete(cid: str):
    site.calib.delete(cid)
    log.add("camera.uncalibrated", f"{mgr.cam_name(cid)}: calibration removed")
    return {"ok": True}


@app.get("/api/log.json")
async def log_json(since: float | None = None, kind: str | None = None):
    return log.query(since=since, kind=kind, limit=100000)


@app.get("/api/log.csv")
async def log_csv(since: float | None = None):
    return PlainTextResponse(log.csv(since), media_type="text/csv",
                             headers={"Content-Disposition": f"attachment; filename=ronda-log-{time.strftime('%Y%m%d-%H%M')}.csv"})


# commands ------------------------------------------------------------------------------
async def sim_send(msg):
    if sim["ws"] is None:
        return {"ok": False, "error": "simulator not connected (run ./sim.sh)"}
    await sim["ws"].send_json(msg)
    return {"ok": True}


async def command(action, a):
    if action == "arm":
        r = mgr.set_alarm(True, a.get("by") or "console", a.get("delay"))
        if tg.enabled and a.get("by") != "telegram":
            asyncio.create_task(tg.broadcast(f"🔒 Allarme inserito ({a.get('by') or 'console'}) alle {time.strftime('%H:%M')}. Attivo tra {r['exit_delay_s']} s."))
        return r
    if action == "disarm":
        r = mgr.set_alarm(False, a.get("by") or "console")
        if tg.enabled and a.get("by") != "telegram":
            asyncio.create_task(tg.broadcast(f"🔓 Allarme disinserito ({a.get('by') or 'console'}) alle {time.strftime('%H:%M')}."))
        return r
    if action == "patrol":
        return mgr.start_patrol(a.get("route") or a.get("route_id"), int(a.get("loops") or 0))
    if action == "stop_patrol":
        return mgr.stop_patrol()
    if action == "schedule":
        return mgr.schedule(a.get("route") or a.get("route_id"), float(a.get("every_min") or 0))
    if action == "goto" and not a.get("spot") and not a.get("spot_id"):
        if a.get("x") is None or a.get("y") is None:
            return {"ok": False, "error": "goto needs a spot or x and y"}
        x, y = float(a["x"]), float(a["y"])
        yaw = None if a.get("yaw") is None else float(a["yaw"])
        mgr.stop_all("operator goto")
        dog.go_to(x, y, yaw)
        log.add("dog.goto", f"Go to ({x:.2f}, {y:.2f})", data={"x": x, "y": y, "yaw": yaw})
        return {"ok": True, "target": {"x": x, "y": y, "yaw": yaw}}
    if action in ("send", "inspect", "goto"):
        return mgr.send_to(a.get("spot") or a.get("spot_id"), inspect=action != "goto" and a.get("inspect", True))
    if action == "home":
        return mgr.go_home()
    if action == "stop":
        r = mgr.stop_all()
        log.add("dog.stop", "Operator stop: missions cancelled, dog standing")
        return r
    if action == "estop":
        r = mgr.estop()
        if tg.enabled:
            asyncio.create_task(tg.broadcast(f"⛔ Arresto di emergenza attivato alle {time.strftime('%H:%M:%S')}. Il cane è fermo."))
        return r
    if action == "reset":
        dog.reset_estop()
        mgr.idle_since = time.time()
        log.add("dog.reset", "Emergency stop released")
        return {"ok": True}
    if action == "lie":
        dog.lie_down()
        log.add("dog.posture", "Dog lying down")
        return {"ok": True}
    if action == "stand":
        dog.stand_up()
        log.add("dog.posture", "Dog standing up")
        return {"ok": True}
    if action == "zero":
        dog.zero_here()
        log.add("dog.zero", "Odometry reset: the current position is now home (0, 0)")
        return {"ok": True}
    if action == "teach":
        x, y, yaw = dog.pose()
        sid = re.sub(r"[^\w-]", "", (a.get("id") or "").strip().lower()) or f"s{int(time.time()) % 10000}"
        spot = site.save_spot(sid, a.get("name"), a.get("room"), x, y, yaw if a.get("keep_yaw") else None)
        log.add("site.spot", f"Spot {spot['name']} saved at ({spot['x']}, {spot['y']})", data=spot)
        hub.publish({"type": "site", "site": site.data})
        return {"ok": True, "spot": spot}
    if action == "drive":
        dog.drive(float(a.get("vx", 0)), float(a.get("vy", 0)), float(a.get("wz", 0)))
        return {"ok": True}
    if action == "stage":
        r = await sim_send({"type": "stage", "scenario": a.get("scenario"), "camera": a.get("camera")})
        if r.get("ok"):
            log.add("sim.stage", f"Simulation: {a.get('scenario')} at {a.get('camera') or 'random camera'}",
                    data={"scenario": a.get("scenario"), "camera": a.get("camera")})
        return r
    if action == "view":
        sim["view"] = a.get("mode", "follow")
        return await sim_send({"type": "view", "mode": sim["view"]})
    if action == "reset_all":
        if mgr.alarm["armed"]:
            mgr.set_alarm(False, "reset")
        mgr.stop_all("reset")
        mgr.schedules.clear()
        mgr.patrol_seen.clear()
        mgr.events.clear()
        dog.reset_estop()
        if dog.posture != "standing":
            dog.stand_up()
        if hasattr(dog, "teleport"):
            dog.teleport(*site.home_pose())
        if sim["ws"] is not None:
            await sim_send({"type": "stage", "scenario": "clear"})
        chat_history.clear()
        log.shift_start = time.time()
        mgr.idle_since = time.time()
        log.add("system.reset", "Reset: alarm disarmed, missions, schedules, scene, incidents and counters cleared"
                + ("; dog back at home" if hasattr(dog, "teleport") else "; dog stopped where it is"))
        hub.publish({"type": "reset"})
        return {"ok": True}
    if action == "new_shift":
        log.shift_start = time.time()
        mgr.events.clear()
        chat_history.clear()
        log.add("shift.start", "New shift: counters and incident list reset")
        return {"ok": True}
    if action == "grok_retry":
        grok.set_key(grok.key)
        log.add("grok.retry", "Grok re-enabled")
        return {"ok": True}
    if action == "test_event":
        cid = a.get("camera") or site.data["cameras"][0]["id"]
        img = await cams.capture(cid) if cams.online(cid) else None
        ev = Event(cid, a.get("kind", "manual"), 0.99, [], "test event from the console", img)
        asyncio.create_task(mgr.handle_event(ev))
        return {"ok": True, "event": ev.id}
    return {"ok": False, "error": f"unknown action {action}"}


@app.post("/api/command")
async def api_command(req: Request):
    body = await req.json()
    try:
        return await command(body.get("action"), body)
    except Exception as e:
        log.add("system.error", f"command {body.get('action')}: {e}", level="error")
        return JSONResponse({"ok": False, "error": str(e)}, status_code=400)


# automations -----------------------------------------------------------
def automation_reply(r):
    return r if r.get("ok") else JSONResponse(r, status_code=400)


@app.get("/api/automations")
async def automations_list():
    return mgr.automations.public()


@app.post("/api/automations")
async def automations_add(req: Request):
    r = mgr.automations.add(await req.json())
    if r.get("ok"):
        log.add("automation.created", f"Automation {r['automation']['name']} created", data=r["automation"])
    return automation_reply(r)


@app.post("/api/automations/{aid}/run")
async def automations_run(aid: str):
    a = mgr.automations.get(aid)
    if not a:
        return automation_reply({"ok": False, "error": f"unknown automation {aid}"})
    return {"ok": True, "mission": mgr.run_automation(a).id}


@app.post("/api/automations/{aid}/route")
async def automations_route(aid: str, req: Request):
    body = await req.json()
    r = mgr.automations.set_route(aid, body.get("points"), body.get("loop"))
    if r.get("ok"):
        log.add("automation.route", f"Automation {r['automation']['name']}: path changed")
    return automation_reply(r)


@app.post("/api/automations/{aid}")
async def automations_active(aid: str, req: Request):
    body = await req.json()
    r = mgr.automations.set_active(aid, body.get("active"))
    if r.get("ok"):
        log.add("automation.active", f"Automation {r['automation']['name']} {'resumed' if body.get('active') else 'paused'}")
    return automation_reply(r)


@app.delete("/api/automations/{aid}")
async def automations_delete(aid: str):
    a = mgr.automations.get(aid)
    r = mgr.automations.delete(aid)
    if r.get("ok"):
        log.add("automation.deleted", f"Automation {a['name']} deleted")
    return automation_reply(r)


# natural-language console ------------------------------------------------------------------
TOOLS = [
    {"type": "function", "name": "start_patrol", "description": "Start a patrol on a route. loops=0 means continuous.",
     "parameters": {"type": "object", "properties": {"route_id": {"type": "string"}, "loops": {"type": "integer"}},
                    "required": ["route_id"]}},
    {"type": "function", "name": "stop_patrol", "description": "Stop the patrol.",
     "parameters": {"type": "object", "properties": {}}},
    {"type": "function", "name": "schedule_patrol",
     "description": "Run one round of a route every N minutes. every_minutes=0 removes the schedule.",
     "parameters": {"type": "object", "properties": {"route_id": {"type": "string"}, "every_minutes": {"type": "number"}},
                    "required": ["route_id", "every_minutes"]}},
    {"type": "function", "name": "send_dog",
     "description": "Send the dog to a spot. inspect=true: look with the camera and report (default).",
     "parameters": {"type": "object", "properties": {"spot_id": {"type": "string"}, "inspect": {"type": "boolean"}},
                    "required": ["spot_id"]}},
    {"type": "function", "name": "return_home", "description": "Send the dog back to its base.",
     "parameters": {"type": "object", "properties": {}}},
    {"type": "function", "name": "stop_dog", "description": "Stop the dog now and cancel every mission.",
     "parameters": {"type": "object", "properties": {}}},
    {"type": "function", "name": "arm_alarm",
     "description": "Arm the alarm: after the exit delay any movement seen by a camera is checked and, if it is a person, the dog goes there.",
     "parameters": {"type": "object", "properties": {"delay_seconds": {"type": "number"}}}},
    {"type": "function", "name": "disarm_alarm", "description": "Disarm the alarm: cameras stop raising events.",
     "parameters": {"type": "object", "properties": {}}},
    {"type": "function", "name": "get_status", "description": "Alarm, dog, mission, queue, cameras and counters.",
     "parameters": {"type": "object", "properties": {}}},
    {"type": "function", "name": "recent_events", "description": "Events of the last N minutes with their outcome.",
     "parameters": {"type": "object", "properties": {"minutes": {"type": "number"}}}},
    {"type": "function", "name": "stage_scenario",
     "description": "SIMULATION ONLY: stage a scene in the 3D museum. scenario: intruder | bag | staff | visitor | clear.",
     "parameters": {"type": "object", "properties": {"scenario": {"type": "string"}, "camera_id": {"type": "string"}},
                    "required": ["scenario"]}},
]


def brief_status():
    s = snapshot()
    d = s["dog"]
    return {"alarm": s["alarm"], "dog": {k: d[k] for k in ("kind", "connected", "armed", "x", "y", "posture", "battery")},
            "mission": s["current"] and {k: s["current"][k] for k in ("label", "kind", "status", "stops", "idx")},
            "queue": [m["label"] for m in s["queue"]], "stats": s["stats"], "schedules": s["schedules"],
            "cameras_online": [c["id"] for c in s["cameras"] if c["online"]], "simulator": s["sim"]["connected"]}


async def run_tool(name, args):
    if name == "start_patrol":
        return await command("patrol", {"route": args.get("route_id"), "loops": args.get("loops", 0)})
    if name == "stop_patrol":
        return await command("stop_patrol", {})
    if name == "schedule_patrol":
        return await command("schedule", {"route": args.get("route_id"), "every_min": args.get("every_minutes")})
    if name == "send_dog":
        return await command("send", {"spot": args.get("spot_id"), "inspect": args.get("inspect", True)})
    if name == "return_home":
        return await command("home", {})
    if name == "stop_dog":
        return await command("stop", {})
    if name == "arm_alarm":
        return await command("arm", {"by": "voice console", "delay": args.get("delay_seconds")})
    if name == "disarm_alarm":
        return await command("disarm", {"by": "voice console"})
    if name == "get_status":
        return brief_status()
    if name == "recent_events":
        since = time.time() - float(args.get("minutes") or 60) * 60
        return [{"time": time.strftime("%H:%M:%S", time.localtime(e.ts)), "camera": mgr.cam_name(e.camera),
                 "kind": e.kind, "status": e.status, "triage": (e.assessment or {}).get("reason"),
                 "dog_saw": (e.verification or {}).get("description"), "event_to_arrival_s": e.elapsed("arrived")}
                for e in mgr.events.values() if e.ts >= since]
    if name == "stage_scenario":
        return await command("stage", {"scenario": args.get("scenario"), "camera": args.get("camera_id")})
    return {"ok": False, "error": "unknown tool"}


def offline_console(text):
    """Keyword fallback so the console still works when Grok is down."""
    t = text.lower()
    if re.search(r"(disinserisci|disattiva|disarm)", t):
        return "disarm_alarm", {}
    if re.search(r"(inserisci|attiva l.allarme|\barm\b)", t):
        return "arm_alarm", {}
    if re.search(r"\b(stop|ferma|fermo|alt)\b", t):
        return "stop_dog", {}
    if re.search(r"(home|base|casa|rientra|torna)", t):
        return "return_home", {}
    if re.search(r"(patrol|pattuglia|ronda|giro)", t):
        m = re.search(r"(?:room|sala|stanza)\s*(\d+)", t)
        route = site.data["routes"][0]["id"]
        if m:
            room = f"sala{m.group(1)}"
            route = next((r["id"] for r in site.data["routes"] if r.get("room") == room), route)
        return "start_patrol", {"route_id": route, "loops": 0}
    for s in site.data["spots"]:
        if s["name"].lower() in t or re.search(rf"\b{re.escape(s['id'])}\b", t):
            return "send_dog", {"spot_id": s["id"], "inspect": True}
    if re.search(r"(status|stato|dove)", t):
        return "get_status", {}
    return None, None


async def dog_photo():
    img = await cams.capture("dog") if cams.online("dog") else None
    if not img:
        cam = cams.cams.get("dog")
        img = cam.preview if cam and cam.preview and time.time() - cam.preview_ts < 5 else None
    return img


tg.command = command
tg.status_fn = brief_status
tg.photo_fn = dog_photo


@app.post("/api/chat")
async def api_chat(req: Request):
    body = await req.json()
    msg = (body.get("message") or "").strip()
    if not msg:
        return {"reply": "", "actions": []}
    chat_history.append({"role": "user", "text": msg, "ts": time.time()})
    log.add("console.command", msg, data={"via": body.get("via", "text")})
    reply, actions, by = None, [], "grok"
    if grok.enabled:
        try:
            reply, actions = await grok.console(msg, chat_history[:-1], TOOLS, run_tool, brief_status())
        except Exception as e:
            log.add("grok.error", f"console: {e}", level="error")
    if reply is None:
        by = "offline"
        name, args = offline_console(msg)
        if name:
            result = await run_tool(name, args)
            actions = [{"tool": name, "args": args, "result": result}]
            reply = f"Grok offline. Executed {name.replace('_', ' ')}: {'ok' if result and (not isinstance(result, dict) or result.get('ok', True)) else result}"
        else:
            reply = "Grok offline: try 'patrol', 'stop', 'home' or the name of a spot."
    chat_history.append({"role": "assistant", "text": reply, "ts": time.time(), "actions": actions, "by": by})
    log.add("console.reply", reply, data={"actions": [a["tool"] for a in actions], "by": by})
    return {"reply": reply, "actions": actions, "by": by}


@app.post("/api/report")
async def api_report():
    entries = [{"t": time.strftime("%H:%M:%S", time.localtime(e["ts"])), "kind": e["kind"], "msg": e["message"]}
               for e in log.query(since=log.shift_start, limit=600)
               if not e["kind"].startswith(("console.", "camera.", "system."))]
    stats = mgr.stats()
    md = None
    if grok.enabled:
        try:
            md = await grok.report(entries, stats)
        except Exception as e:
            log.add("grok.error", f"report: {e}", level="error")
    if not md:
        lines = [f"# Shift report {time.strftime('%d/%m/%Y %H:%M')}", "",
                 f"Events {stats['events']} · dispatched {stats['dispatched']} · filtered {stats['filtered']} · "
                 f"confirmed {stats['confirmed']} · alerts {stats['alerts']} · average event to arrival "
                 f"{stats['avg_arrival_s']} s", "", "## Events"]
        for e in mgr.events.values():
            lines.append(f"- {time.strftime('%H:%M:%S', time.localtime(e.ts))} · {mgr.cam_name(e.camera)} · "
                         f"{e.kind} · {e.status} · arrival {e.elapsed('arrived')} s")
        md = "\n".join(lines)
    log.add("report.shift", "End-of-shift report generated", data={"stats": stats})
    return {"markdown": md, "stats": stats}


# websockets --------------------------------------------------------------------------------
@app.websocket("/ws/console")
async def ws_console(ws: WebSocket):
    if not ws_allowed(ws):
        await ws.close(code=4401)
        return
    await ws.accept()
    hub.clients.add(ws)
    clients_seen[ws.headers.get("user-agent", "?")[:160]] = {"t": time.time(), "via": "websocket", "host": ws.url.netloc}
    try:
        while True:
            msg = await ws.receive_json()
            if msg.get("type") == "drive":
                dog.drive(float(msg.get("vx", 0)), float(msg.get("vy", 0)), float(msg.get("wz", 0)))
    except Exception:
        pass
    finally:
        hub.clients.discard(ws)


@app.post("/api/cam/{cid}")
async def cam_http_message(cid: str, req: Request):
    """Same messages a camera sends on its websocket, for browsers that cannot open one."""
    body = await req.json()
    await cams.http_message(cid, body if body.get("type") else None)
    return {"ok": True, "inbox": cams.http_poll(cid)}


@app.websocket("/ws/camera/{cid}")
async def ws_camera(ws: WebSocket, cid: str):
    if not ws_allowed(ws):
        await ws.close(code=4401)
        return
    await ws.accept()
    await cams.handle(cid, ws, sim=ws.query_params.get("sim") == "1")


@app.websocket("/ws/sim")
async def ws_sim(ws: WebSocket):
    if not ws_allowed(ws):
        await ws.close(code=4401)
        return
    await ws.accept()
    sim["ws"] = ws
    site.sim = True
    log.add("sim.online", "MuJoCo simulator connected" + (" · physics with the trained Go1 policy" if dog.kind == "mujoco" else " · following the kinematic dog"))
    try:
        await ws.send_json({"type": "site", "site": site.data})
        await ws.send_json({"type": "mode", "physics": dog.kind == "mujoco"})
        await ws.send_json({"type": "view", "mode": sim["view"]})
        while True:
            msg = await ws.receive_json()
            if msg.get("type") == "odom":
                if dog.kind == "mujoco":
                    dog.update(msg["x"], msg["y"], msg["yaw"])
            elif msg.get("type") == "actors":
                sim["actors"] = msg.get("actors", [])
            elif msg.get("type") == "hello":
                sim["scenarios"] = msg.get("scenarios", [])
            elif msg.get("type") == "log":
                log.add("sim." + msg.get("kind", "note"), msg.get("message", ""))
    except Exception:
        pass
    finally:
        if sim["ws"] is ws:
            sim["ws"] = None
            site.sim = False
            log.add("sim.offline", "3D simulator disconnected", level="warn")
