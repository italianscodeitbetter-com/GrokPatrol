"""End-to-end checks of the admin backend with the kinematic dog (DOG=sim): real app, real threads, real websockets."""
import base64
import time

# 1x1 white JPEG
JPEG = base64.b64decode(
    "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/"
    "yQALCAABAAEBAREA/8wABgAQEAX/2gAIAQEAAD8A0s8g/9k=")


def cmd(client, action, **kw):
    r = client.post("/api/command", json={"action": action, **kw})
    return r.json()


def wait_for(fn, timeout=5.0):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(0.1)
    return fn()


def test_state(client):
    s = client.get("/api/state").json()
    assert {"dog", "cameras", "site", "log", "limits"} <= s.keys()
    assert s["dog"]["kind"] == "sim" and s["dog"]["connected"]
    ids = [c["id"] for c in s["cameras"]]
    assert "dog" in ids and len(ids) >= 2


def test_goto_moves_the_dog(client):
    cmd(client, "reset")
    d0 = client.get("/api/state").json()["dog"]
    assert cmd(client, "goto", x=d0["x"] + 1.0, y=d0["y"])["ok"]
    moved = wait_for(lambda: abs(client.get("/api/state").json()["dog"]["x"] - d0["x"]) > 0.2)
    assert moved
    assert cmd(client, "stop")["ok"]


def test_estop_blocks_motion(client):
    assert cmd(client, "estop")["ok"]
    assert client.get("/api/state").json()["dog"]["armed"] is False
    cmd(client, "drive", vx=0.4)
    time.sleep(0.3)
    assert client.get("/api/state").json()["dog"]["cmd"] == [0.0, 0.0, 0.0]
    assert cmd(client, "reset")["ok"]
    assert client.get("/api/state").json()["dog"]["armed"] is True


def test_posture(client):
    assert cmd(client, "lie")["ok"]
    assert client.get("/api/state").json()["dog"]["posture"] == "down"
    assert cmd(client, "stand")["ok"]
    assert wait_for(lambda: client.get("/api/state").json()["dog"]["posture"] == "standing")


def test_unknown_action(client):
    assert cmd(client, "bogus")["ok"] is False


def test_console_ws_ticks_and_drive(client):
    with client.websocket_connect("/ws/console") as ws:
        msg = ws.receive_json()
        while msg.get("type") != "tick":
            msg = ws.receive_json()
        assert {"dog", "cameras", "limits"} <= msg.keys()
        ws.send_json({"type": "drive", "vx": 0.3, "vy": 0, "wz": 0})
        assert wait_for(lambda: client.get("/api/state").json()["dog"]["manual"], 2.0)


def test_phone_camera_goes_online_and_streams(client):
    cid = client.get("/api/state").json()["site"]["cameras"][0]["id"]
    with client.websocket_connect(f"/ws/camera/{cid}") as cam:
        assert cam.receive_json()["type"] == "config"
        cam.send_json({"type": "preview", "jpeg": base64.b64encode(JPEG).decode()})
        cam.send_json({"type": "status", "fps": 12})
        online = wait_for(lambda: next(c for c in client.get("/api/state").json()["cameras"] if c["id"] == cid)["online"])
        assert online
        r = wait_for(lambda: (lambda r: r if r.status_code == 200 else None)(client.get(f"/api/cameras/{cid}/preview.jpg")))
        assert r and r.headers["content-type"] == "image/jpeg"


def test_phone_page_and_qr(client):
    r = client.get("/camera")
    assert r.status_code == 200 and "<html" in r.text.lower()
    assert client.get("/api/qr.png", params={"data": "https://x/camera"}).headers["content-type"] == "image/png"
