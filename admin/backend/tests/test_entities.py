"""The operations layer on the admin backend: alarm, patrols, missions, automations, log, chat, report, live video."""
import asyncio
import base64
import time

import pytest
from starlette.websockets import WebSocketDisconnect

from test_e2e import JPEG, cmd, wait_for


@pytest.fixture(autouse=True)
def clean(client):
    assert cmd(client, "reset_all")["ok"]
    yield
    cmd(client, "reset_all")


def state(client):
    return client.get("/api/state").json()


def test_state_keeps_the_console_contract_and_adds_the_entities(client):
    s = state(client)
    assert {"dog", "cameras", "site", "log", "limits", "dogcam"} <= s.keys()
    assert {"current", "queue", "stats", "alarm", "grok", "alerts", "automations", "events", "chat", "sim"} <= s.keys()


def test_alarm_arms_and_disarms(client):
    assert cmd(client, "arm", delay=0, by="test")["ok"]
    assert wait_for(lambda: state(client)["alarm"]["active"])
    assert cmd(client, "disarm", by="test")["ok"]
    assert state(client)["alarm"]["armed"] is False


def test_patrol_runs_as_a_mission_and_stops(client):
    route = state(client)["site"]["routes"][0]["id"]
    assert cmd(client, "patrol", route=route, loops=0)["ok"]
    assert wait_for(lambda: (state(client)["current"] or {}).get("kind") == "patrol")
    assert cmd(client, "stop_patrol")["ok"]
    assert wait_for(lambda: state(client)["current"] is None)


def test_goto_a_spot_is_a_mission_and_goto_xy_still_drives_directly(client):
    spot = state(client)["site"]["spots"][1]["id"]
    assert cmd(client, "goto", spot=spot)["ok"]
    assert wait_for(lambda: state(client)["current"] is not None)
    assert cmd(client, "goto", spot="nowhere")["ok"] is False
    assert cmd(client, "goto")["ok"] is False
    assert cmd(client, "goto", x=9.0, y=2.0)["target"]["x"] == 9.0
    assert state(client)["current"] is None


def test_automation_lifecycle(client):
    r = client.post("/api/automations", json={"name": "Evening", "points": [[8.3, 1.6], [9.0, 1.6]], "start": "21:00",
                                              "repeat": "days", "days": [1, 3]}).json()
    assert r["ok"]
    aid = r["automation"]["id"]
    assert [a["id"] for a in state(client)["automations"]] == [aid]
    r = client.post(f"/api/automations/{aid}/route", json={"points": [[8.3, 1.6], [9.5, 1.6], [9.5, 2.5]]}).json()
    assert len(r["automation"]["points"]) == 3
    assert client.post(f"/api/automations/{aid}", json={"active": False}).json()["automation"]["active"] is False
    assert client.post(f"/api/automations/{aid}/run").json()["ok"]
    assert wait_for(lambda: (state(client)["current"] or {}).get("label") == "Evening")
    cmd(client, "stop")
    assert client.delete(f"/api/automations/{aid}").json()["ok"]
    assert client.post(f"/api/automations/{aid}/run").status_code == 400


def test_log_survives_as_queries_and_poll_works_without_websocket(client):
    cmd(client, "stand")
    entries = client.get("/api/log.json", params={"since": time.time() - 60}).json()
    assert any(e["kind"] == "dog.posture" for e in entries)
    p = client.get("/api/poll").json()
    assert {"tick", "log", "events", "now"} <= p.keys()
    assert "text/csv" in client.get("/api/log.csv").headers["content-type"]


def test_chat_without_grok_runs_on_keywords_and_report_is_written(client):
    r = client.post("/api/chat", json={"message": "status", "via": "mobile"}).json()
    assert r["by"] == "offline" and r["actions"][0]["tool"] == "get_status"
    assert [m["role"] for m in state(client)["chat"]] == ["user", "assistant"]
    assert "Shift report" in client.post("/api/report").json()["markdown"]


def test_snapshot_names_are_safe(client):
    assert client.get("/api/snapshots/..%2Fsecret.jpg").status_code == 404


def test_phone_gets_its_own_camera_and_a_named_entry(client):
    with client.websocket_connect("/ws/camera/phone-ab12") as cam:
        assert cam.receive_json()["type"] == "config"
        assert cam.receive_json() == {"type": "live", "on": False}
        cam.send_json({"type": "preview", "jpeg": base64.b64encode(JPEG).decode()})
        entry = wait_for(lambda: next((c for c in state(client)["cameras"] if c["id"] == "phone-ab12" and c["online"]), None))
        assert entry["name"] == "Phone ab12"
    assert client.get("/api/public").json()["lan_camera"].endswith(":8443/camera")


def test_event_from_a_phone_with_the_alarm_armed_opens_an_incident(client):
    cmd(client, "arm", delay=0, by="test")
    assert wait_for(lambda: state(client)["alarm"]["active"])
    with client.websocket_connect("/ws/camera/phone-ab12") as cam:
        cam.receive_json()
        cam.send_json({"type": "event", "kind": "intrusion", "score": 0.9, "detections": [], "note": "phone",
                       "jpeg": base64.b64encode(JPEG).decode()})
        ev = wait_for(lambda: next(iter(state(client)["events"]), None))
        assert ev and ev["camera"] == "phone-ab12" and ev["kind"] == "intrusion"


def test_stream_asks_for_fast_frames_only_while_watched():
    from app.cameras import Cameras
    from app.main import site

    class Sock:
        def __init__(self):
            self.sent = []

        async def send_json(self, msg):
            self.sent.append(msg)

    async def run():
        cams = Cameras(site, type("L", (), {"add": lambda *a, **k: None})(), None)
        cam = cams.get("cam-1")
        cam.ws = Sock()
        stream = cams.watch("cam-1")
        first = asyncio.ensure_future(stream.__anext__())
        await asyncio.sleep(0.05)
        assert cam.viewers == 1 and cam.ws.sent[-1] == {"type": "live", "on": True}
        await cams._on(cam, {"type": "preview", "jpeg": base64.b64encode(JPEG).decode()})
        part = await asyncio.wait_for(first, 1)
        assert part.startswith(b"--frame") and JPEG in part
        await stream.aclose()
        await asyncio.sleep(0.01)
        assert cam.viewers == 0 and cam.ws.sent[-1] == {"type": "live", "on": False}

    asyncio.run(run())


def closed_with(ws):
    with pytest.raises(WebSocketDisconnect) as closed:
        while True:
            ws.receive_json()
    return closed.value.code


def test_real_camera_takes_over_from_the_simulator_without_a_fight(client):
    with client.websocket_connect("/ws/camera/cam-fight?sim=1") as sim:
        assert sim.receive_json()["type"] == "config"
        with client.websocket_connect("/ws/camera/cam-fight") as phone:
            assert phone.receive_json()["type"] == "config"
            assert closed_with(sim) == 4409
            # the simulator keeps retrying: the phone must not notice
            with client.websocket_connect("/ws/camera/cam-fight?sim=1") as again:
                assert closed_with(again) == 4409
            phone.send_json({"type": "preview", "jpeg": base64.b64encode(JPEG).decode()})
            assert wait_for(lambda: next(c for c in state(client)["cameras"] if c["id"] == "cam-fight")["online"])
    with client.websocket_connect("/ws/camera/cam-fight?sim=1") as back:
        assert back.receive_json()["type"] == "config", "phone gone: the simulator gets its camera back"


def test_a_camera_without_websocket_also_takes_over(client):
    with client.websocket_connect("/ws/camera/cam-poll?sim=1") as sim:
        assert sim.receive_json()["type"] == "config"
        jpeg = base64.b64encode(JPEG).decode()
        r = client.post("/api/cam/cam-poll", json={"type": "preview", "jpeg": jpeg}).json()
        assert closed_with(sim) == 4409
        assert [m["type"] for m in r["inbox"]][:1] == ["config"], "the phone is told it is on the air"
    with client.websocket_connect("/ws/camera/cam-poll?sim=1") as again:
        assert closed_with(again) == 4409


def test_a_second_real_camera_replaces_the_first_and_tells_it(client):
    with client.websocket_connect("/ws/camera/cam-two") as first:
        assert first.receive_json()["type"] == "config"
        with client.websocket_connect("/ws/camera/cam-two") as second:
            assert second.receive_json()["type"] == "config"
            assert closed_with(first) == 4409
