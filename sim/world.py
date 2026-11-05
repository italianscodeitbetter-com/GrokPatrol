"""3D museum in MuJoCo for the demo: the whole environment is a physical MuJoCo scene.

The Unitree Go1 walks with MuJoCo physics and a trained policy (MuJoCo Playground), driven by the same
velocity commands the real dog receives. Walls, display cases, pedestals and the bench are solid; the
suitcase is a rigid body with mass that falls, rests and can be pushed; people are mocap bodies (moved
along a path) whose bodies the dog bumps into. Fixed cameras look at the restricted zones from above at
an angle; a camera sits on the dog's head. Every camera connects to the server exactly like a phone does.

Run with ./sim.sh, or ./sim.sh --viewer to also open the native MuJoCo viewer.
"""
import argparse
import asyncio
import base64
import io
import json
import math
import os
import queue
import random
import sys
import threading
import time
import xml.etree.ElementTree as ET
from pathlib import Path

if "--viewer" in sys.argv:
    os.environ["MUJOCO_GL"] = "cgl"  # the viewer owns the main thread on macOS: offscreen renders go through CGL
os.environ.setdefault("MUJOCO_GL", "glfw")

import mujoco  # noqa: E402
import numpy as np  # noqa: E402
import websockets  # noqa: E402
from PIL import Image, ImageDraw  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "admin" / "backend"))
from app.config import Site  # noqa: E402
from sim.room import CAMERA_GROUPS, OVERVIEW_GROUPS, add_real_room  # noqa: E402

GO1 = ROOT / "sim" / "assets" / "unitree_go1"
PG = ROOT / "sim" / "assets" / "go1_playground"   # MuJoCo Playground model + trained walking policy (Apache 2.0)
HOME_Q = [0.1, 0.9, -1.8, -0.1, 0.9, -1.8, 0.1, 0.9, -1.8, -0.1, 0.9, -1.8]
LIE_Q = [0.15, 1.2, -2.72, -0.15, 1.2, -2.72, 0.15, 1.2, -2.72, -0.15, 1.2, -2.72]
HIDDEN = (-6.0, -8.0)
HIDDEN_BAG = (-20.0, -20.0)   # the suitcase is a physical body: parked on the floor far outside the building
# collision bits: 1 = static world and suitcase, 2 = people. The dog's feet and body accept both (3).
LIVE_W, LIVE_H, LIVE_FPS = 1280, 720, 15   # what a viewer gets while watching a camera
SOLID = dict(contype=1, conaffinity=0)
PEOPLE = dict(contype=2, conaffinity=0)
HUMAN = {
    "intruder": {"top": "0.42 0.43 0.45 1", "pants": "0.22 0.30 0.48 1", "hair": "0.08 0.08 0.09 1"},
    "staff": {"top": "0.95 0.86 0.05 1", "pants": "0.10 0.10 0.12 1", "hair": "0.35 0.25 0.15 1",
              "sleeves": "0.22 0.28 0.38 1"},
    "visitor": {"top": "0.72 0.25 0.22 1", "pants": "0.62 0.56 0.46 1", "hair": "0.55 0.40 0.22 1"},
    "carrier": {"top": "0.25 0.45 0.35 1", "pants": "0.25 0.25 0.28 1", "hair": "0.15 0.10 0.08 1"},
}
SKIN = "0.80 0.62 0.50 1"
SCENARIOS = ["intruder", "visitor", "bag", "lights", "clear"]


# scene -----------------------------------------------------------------------------------
def fmt(*v):
    return " ".join(f"{x:.4f}" for x in v)


def look_axes(pos, target):
    f = np.array(target, float) - np.array(pos, float)
    f /= np.linalg.norm(f)
    right = np.cross(f, [0, 0, 1.0])
    right /= np.linalg.norm(right)
    up = np.cross(right, f)
    return fmt(*right, *up)


def wall_segments(site):
    segs = set()
    for r in site.data["rooms"]:
        x0, y0, x1, y1 = r["x"], r["y"], r["x"] + r["w"], r["y"] + r["h"]
        for a, b in (((x0, y0), (x1, y0)), ((x1, y0), (x1, y1)), ((x0, y1), (x1, y1)), ((x0, y0), (x0, y1))):
            segs.add((round(a[0], 3), round(a[1], 3), round(b[0], 3), round(b[1], 3)))
    out = []
    half_door = 0.65
    for (ax, ay, bx, by) in segs:
        horiz = abs(ay - by) < 1e-6
        lo, hi = (min(ax, bx), max(ax, bx)) if horiz else (min(ay, by), max(ay, by))
        cuts = []
        for d in site.data.get("doors", []):
            on = abs(d["y"] - ay) < 0.2 if horiz else abs(d["x"] - ax) < 0.2
            c = d["x"] if horiz else d["y"]
            if on and lo < c < hi:
                cuts.append((c - half_door, c + half_door))
        pieces, start = [], lo
        for c0, c1 in sorted(cuts):
            pieces.append((start, c0))
            start = c1
        pieces.append((start, hi))
        for p0, p1 in pieces:
            if p1 - p0 > 0.05:
                out.append(((p0, ay, p1, ay) if horiz else (ax, p0, ax, p1)))
    return out


def add(parent, tag, **kw):
    return ET.SubElement(parent, tag, {k.rstrip("_"): str(v) for k, v in kw.items()})


def human(world, name, colors):
    b = add(world, "body", name=f"actor_{name}", mocap="true", pos=fmt(*HIDDEN, 0))
    g = PEOPLE
    top, pants = colors["top"], colors["pants"]
    sleeves = colors.get("sleeves", top)
    for s in (1, -1):
        add(b, "geom", type="capsule", fromto=fmt(0, 0.09 * s, 0.10, 0, 0.09 * s, 0.82), size=0.075, rgba=pants, **g)
        add(b, "geom", type="box", pos=fmt(0.04, 0.09 * s, 0.04), size=fmt(0.12, 0.055, 0.04), rgba="0.08 0.08 0.08 1", **g)
        add(b, "geom", type="capsule", fromto=fmt(0, 0.26 * s, 1.36, 0.03, 0.30 * s, 0.90), size=0.055, rgba=sleeves, **g)
        add(b, "geom", type="sphere", pos=fmt(0.03, 0.30 * s, 0.85), size=0.05, rgba=SKIN, **g)
    add(b, "geom", type="capsule", fromto=fmt(0, -0.1, 0.86, 0, 0.1, 0.86), size=0.11, rgba=pants, **g)
    add(b, "geom", type="ellipsoid", pos=fmt(0, 0, 1.13), size=fmt(0.14, 0.22, 0.30), rgba=top, **g)
    add(b, "geom", type="capsule", fromto=fmt(0, 0, 1.38, 0, 0, 1.50), size=0.05, rgba=SKIN, **g)
    add(b, "geom", type="sphere", pos=fmt(0, 0, 1.60), size=0.115, rgba=SKIN, **g)
    add(b, "geom", type="sphere", pos=fmt(-0.025, 0, 1.645), size=0.112, rgba=colors["hair"], **g)


def suitcase(world):
    """A hard-shell suitcase, about 6 kg: it falls, rests on its four wheels and can be pushed."""
    b = add(world, "body", name="actor_bag", pos=fmt(*HIDDEN_BAG, 0))
    add(b, "freejoint", name="bag_free")
    shell = dict(contype=1, conaffinity=1, condim=3, friction="0.8 0.01 0.001")
    deco = dict(contype=0, conaffinity=0)
    add(b, "geom", type="box", pos=fmt(0, 0, 0.36), size=fmt(0.21, 0.12, 0.30), rgba="0.12 0.34 0.66 1", mass=5.6, **shell)
    add(b, "geom", type="box", pos=fmt(0, 0, 0.36), size=fmt(0.215, 0.125, 0.02), rgba="0.07 0.20 0.42 1", mass=0.1, **deco)
    add(b, "geom", type="capsule", fromto=fmt(-0.08, 0, 0.72, 0.08, 0, 0.72), size=0.018, rgba="0.1 0.1 0.1 1", mass=0.05, **deco)
    for s in (1, -1):
        add(b, "geom", type="capsule", fromto=fmt(0.08 * s, 0, 0.66, 0.08 * s, 0, 0.72), size=0.012, rgba="0.1 0.1 0.1 1", mass=0.03, **deco)
        for t in (1, -1):
            add(b, "geom", type="sphere", pos=fmt(0.16 * s, 0.08 * t, 0.03), size=0.03, rgba="0.05 0.05 0.05 1", mass=0.05, **shell)


def build_xml(site):
    root = ET.parse(PG / "go1_mjx_feetonly.xml").getroot()
    root.set("model", "ronda museum")
    root.find("compiler").set("meshdir", str(GO1 / "assets"))
    for mesh in root.find("asset").findall("mesh"):
        mesh.set("file", Path(mesh.get("file")).name)
    kf = add(root, "keyframe")
    add(kf, "key", name="home", qpos=fmt(0, 0, 0.278, 1, 0, 0, 0, *HOME_Q, *HIDDEN_BAG, 0.001, 1, 0, 0, 0),
        ctrl=fmt(*HOME_Q))
    trunk = root.find(".//body[@name='trunk']")
    for geom in trunk.findall("geom"):
        if geom.get("class") == "collision":
            geom.set("conaffinity", "3")      # the body hits walls, furniture, the suitcase and people
    for geom in root.iter("geom"):
        if geom.get("class") == "foot":
            geom.set("conaffinity", "3")      # floor as in training, plus the rest of the world
    add(trunk, "camera", name="dogcam", pos=fmt(0.36, 0, 0.09), xyaxes="0 -1 0 -0.10 0 1", fovy=80)
    add(trunk, "geom", type="box", pos=fmt(0.335, 0, 0.09), size=fmt(0.01, 0.036, 0.018), rgba="0.05 0.05 0.06 1",
        contype=0, conaffinity=0)  # phone clipped on the head
    vis = add(root, "visual")
    add(vis, "headlight", ambient="0.46 0.46 0.47", diffuse="0.22 0.22 0.22", specular="0.04 0.04 0.04")
    for light in root.iter("light"):
        if light.get("name") == "spotlight":   # follows the dog from one fixed point: a hot spot sliding on the walls
            light.set("diffuse", "0.10 0.10 0.10")
            light.set("castshadow", "false")
    add(vis, "global", offwidth=LIVE_W, offheight=LIVE_H, fovy=50)
    add(vis, "quality", shadowsize=4096, offsamples=4)
    add(vis, "map", znear=0.01, zfar=60, shadowclip="2.4", shadowscale="0.8")
    real = bool(site.data.get("model"))   # the real room from the CAD model, or the generated test museum
    add(root, "statistic", extent=14 if real else 12, center=fmt(8, 8, 1) if real else fmt(7, 0, 1))
    asset = root.find("asset")
    add(asset, "texture", name="sky", type="skybox", builtin="gradient", rgb1="0.30 0.31 0.33", rgb2="0.20 0.21 0.23",
        width=256, height=1536)
    # large polished stone slabs with a thin joint: the old checker was the first thing anyone noticed
    add(asset, "texture", name="tiles", type="2d", builtin="checker", rgb1="0.60 0.59 0.56", rgb2="0.58 0.57 0.54",
        mark="edge", markrgb="0.44 0.43 0.41", width=512, height=512)
    add(asset, "material", name="floor", texture="tiles", texuniform="true", texrepeat="0.4 0.4", reflectance="0.05",
        specular="0.35", shininess="0.5")
    add(asset, "material", name="wall", rgba="0.70 0.69 0.66 1")
    add(asset, "material", name="wood", rgba="0.30 0.20 0.13 1")
    add(asset, "material", name="glass", rgba="0.75 0.88 0.95 0.22", specular="0.9", shininess="0.9")
    add(asset, "material", name="gold", rgba="0.86 0.66 0.22 1", specular="0.8", shininess="0.8")
    add(asset, "material", name="marble", rgba="0.92 0.91 0.88 1", specular="0.4")
    add(asset, "material", name="tape", rgba="0.86 0.10 0.10 1")

    w = root.find("worldbody")
    rooms = site.data["rooms"]
    xs = [r["x"] for r in rooms] + [r["x"] + r["w"] for r in rooms]
    ys = [r["y"] for r in rooms] + [r["y"] + r["h"] for r in rooms]
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    add(w, "geom", name="floor", type="plane", size=fmt(40, 40, 0.1), material="floor", contype=1, conaffinity=0,
        priority=1, friction="0.6", condim=3)  # the feet collide with the floor, as in training
    g = dict(contype=0, conaffinity=0)   # decoration: tape, paintings, camera housings
    if real:
        add_real_room(root, site)
    else:
        add(w, "light", pos=fmt(cx, cy, 9), dir="0 0 -1", directional="true", diffuse="0.35 0.35 0.35", castshadow="false")
        for i, r in enumerate(rooms):
            add(w, "light", pos=fmt(r["x"] + r["w"] / 2, r["y"] + r["h"] / 2, 3.4), dir="0 0 -1",
                diffuse="0.45 0.44 0.42", attenuation="1 0.05 0.01", castshadow="true" if i == 0 else "false")
    for (ax, ay, bx, by) in ([] if real else wall_segments(site)):
        mx, my = (ax + bx) / 2, (ay + by) / 2
        hx, hy = max(abs(bx - ax) / 2, 0.06), max(abs(by - ay) / 2, 0.06)
        add(w, "geom", type="box", pos=fmt(mx, my, 1.4), size=fmt(hx, hy, 1.4), material="wall", **SOLID)
        add(w, "geom", type="box", pos=fmt(mx, my, 0.06), size=fmt(hx + 0.01, hy + 0.01, 0.06), rgba="0.4 0.38 0.35 1", **SOLID)

    # zones on the floor: red tape
    for c in site.data["cameras"]:
        z = c.get("zone_world")
        if not z:
            continue
        x0, y0, x1, y1 = z
        t = 0.03
        for (px, py, sx, sy) in (((x0 + x1) / 2, y0 + t, (x1 - x0) / 2, t), ((x0 + x1) / 2, y1 - t, (x1 - x0) / 2, t),
                                 (x0 + t, (y0 + y1) / 2, t, (y1 - y0) / 2), (x1 - t, (y0 + y1) / 2, t, (y1 - y0) / 2)):
            add(w, "geom", type="box", pos=fmt(px, py, 0.003), size=fmt(sx, sy, 0.003), material="tape", **g)

    # exhibits
    def pedestal(x, y, top="marble", h=1.0, s=0.28):
        add(w, "geom", type="box", pos=fmt(x, y, h / 2), size=fmt(s, s, h / 2), material="marble", **SOLID)
        return h

    def painting(x, y, along="x", rgba="0.3 0.4 0.6 1", wdt=0.7, hgt=0.5):
        sx, sy = (wdt, 0.02) if along == "x" else (0.02, wdt)
        add(w, "geom", type="box", pos=fmt(x, y, 1.6), size=fmt(sx + 0.05, sy + 0.005, hgt + 0.05), material="wood", **g)
        add(w, "geom", type="box", pos=fmt(x, y, 1.6), size=fmt(sx, sy + 0.012, hgt), rgba=rgba, **g)

    for c in ([] if real else site.data["cameras"]):
        z = c.get("zone_world")
        if not z or c["id"] == "cam-2":
            continue
        x0, y0, x1, y1 = z
        ex, ey = (x0 + x1) / 2, (y0 + y1) / 2
        # display case against the nearest wall of the zone
        wall_y = y0 + 0.45 if abs(y0 - site.room(c["room"])["y"]) < 0.3 else y1 - 0.45
        add(w, "geom", type="box", pos=fmt(ex, wall_y, 0.45), size=fmt(0.6, 0.3, 0.45), material="wood", **SOLID)
        add(w, "geom", type="box", pos=fmt(ex, wall_y, 1.22), size=fmt(0.6, 0.3, 0.32), material="glass", **SOLID)
        add(w, "geom", type="ellipsoid", pos=fmt(ex - 0.2, wall_y, 1.08), size=fmt(0.1, 0.1, 0.17), material="gold", **g)
        add(w, "geom", type="cylinder", pos=fmt(ex + 0.22, wall_y, 0.98), size=fmt(0.09, 0.07), material="gold", **g)
    for r in ([] if real else rooms):
        x0, y0, x1, y1 = r["x"], r["y"], r["x"] + r["w"], r["y"] + r["h"]
        n = max(1, int(r["w"] // 3))
        palette = ["0.55 0.27 0.20 1", "0.20 0.33 0.50 1", "0.62 0.55 0.30 1", "0.25 0.42 0.30 1"]
        for i in range(n):
            px = x0 + (i + 0.5) * r["w"] / n
            painting(px, y1 - 0.08, "x", palette[(i + len(r["id"])) % len(palette)])
        h = pedestal(x0 + 0.7, y1 - 0.7)
        add(w, "geom", type="sphere", pos=fmt(x0 + 0.7, y1 - 0.7, h + 0.2), size=0.2, material="marble", **SOLID)
    # bench in room 2
    if len(rooms) > 1 and not real:
        r = rooms[1]
        add(w, "geom", type="box", pos=fmt(r["x"] + r["w"] / 2, r["y"] + 1.3, 0.23), size=fmt(0.9, 0.22, 0.23),
            material="wood", **SOLID)

    # fixed cameras: on the wall, high, looking down at an angle at their zone
    for c in site.data["cameras"]:
        pos = (c["x"], c["y"], c.get("z", 2.6))
        target = c.get("look") or [site.spot(c["inspect_spot"])["x"], site.spot(c["inspect_spot"])["y"], 0.5]
        add(w, "camera", name=c["id"], pos=fmt(*pos), xyaxes=look_axes(pos, target), fovy=c.get("fovy", 68))
        add(w, "geom", type="box", pos=fmt(*pos), size=fmt(0.07, 0.07, 0.05), rgba="0.1 0.1 0.12 1", **g)

    for name, colors in HUMAN.items():
        human(w, name, colors)
    suitcase(w)
    return ET.tostring(root, encoding="unicode")


# actors ----------------------------------------------------------------------------------
class Actor:
    """People are mocap bodies moved along a path. The suitcase is a free rigid body: it is only
    positioned when staged or carried, otherwise MuJoCo moves it."""

    def __init__(self, name, kind, body_id, model):
        self.name, self.kind = name, kind
        self.body = body_id
        self.mocap = model.body_mocapid[body_id]
        self.physical = self.mocap < 0
        if self.physical:
            j = model.body_jntadr[body_id]
            self.qadr, self.dadr = model.jnt_qposadr[j], model.jnt_dofadr[j]
        self.x, self.y = HIDDEN_BAG if self.physical else HIDDEN
        self.z = 0.0
        self.yaw = 0.0
        self.steps = []
        self.carry = None
        self.visible = False
        self.wait_until = 0.0
        self.pending = False   # suitcase: write the pose once, then let physics run

    def hide(self):
        self.x, self.y = HIDDEN_BAG if self.physical else HIDDEN
        self.z, self.visible, self.steps, self.carry, self.pending = 0.001, False, [], None, True

    def place(self, x, y, yaw=0.0, z=0.001):
        self.x, self.y, self.yaw, self.z, self.visible, self.pending = x, y, yaw, z, True, True

    def update(self, dt, world):
        if not self.steps:
            return
        step = self.steps[0]
        if step[0] == "goto":
            tx, ty = step[1]
            dx, dy = tx - self.x, ty - self.y
            d = math.hypot(dx, dy)
            v = step[2] if len(step) > 2 else 1.0
            if d < 0.05:
                self.steps.pop(0)
                return
            self.yaw = math.atan2(dy, dx)
            k = min(1.0, v * dt / d)
            self.x += dx * k
            self.y += dy * k
        elif step[0] == "face":
            self.yaw = step[1]
            self.steps.pop(0)
        elif step[0] == "wait":
            if not self.wait_until:
                self.wait_until = time.time() + step[1]
            elif time.time() >= self.wait_until:
                self.wait_until = 0.0
                self.steps.pop(0)
        elif step[0] == "drop":
            bag = world.actors["bag"]
            # released a few centimetres above the floor: MuJoCo lets it fall and settle
            bag.place(self.x - 0.38 * math.sin(self.yaw), self.y + 0.38 * math.cos(self.yaw), self.yaw + 0.25,
                      z=0.06 if world.physics else 0.001)
            self.carry = None
            world.say("note", f"{self.name} left the suitcase on the floor")
            self.steps.pop(0)
        elif step[0] == "hide":
            self.hide()

    def apply(self, data):
        if not self.physical:
            z = 0.0 if self.visible else -5.0
            data.mocap_pos[self.mocap] = (self.x, self.y, z)
            data.mocap_quat[self.mocap] = (math.cos(self.yaw / 2), 0, 0, math.sin(self.yaw / 2))
            return
        q = data.qpos
        if self.pending or self.carry_lock:
            q[self.qadr:self.qadr + 3] = (self.x, self.y, self.z)
            q[self.qadr + 3:self.qadr + 7] = (math.cos(self.yaw / 2), 0, 0, math.sin(self.yaw / 2))
            data.qvel[self.dadr:self.dadr + 6] = 0
            self.pending = False
        else:  # read back where physics put it (pushed by the dog, slid, fell)
            self.x, self.y, self.z = float(q[self.qadr]), float(q[self.qadr + 1]), float(q[self.qadr + 2])
            w, x, y, z = q[self.qadr + 3:self.qadr + 7]
            self.yaw = math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))

    carry_lock = False   # set on the suitcase while someone carries it


# world -----------------------------------------------------------------------------------
class World:
    def __init__(self, server, viewer=False):
        self.site = Site()
        self.viewer_wanted = viewer
        self.viewer = None
        xml = build_xml(self.site)
        (GO1 / "_ronda_scene.xml").write_text(xml)
        self.model = mujoco.MjModel.from_xml_path(str(GO1 / "_ronda_scene.xml"))
        self.data = mujoco.MjData(self.model)
        mujoco.mj_resetDataKeyframe(self.model, self.data, 0)
        m = self.model
        # the policy reads qpos[7:19] and qvel[6:18]: the dog must be the first free body
        assert m.jnt_type[0] == mujoco.mjtJoint.mjJNT_FREE and m.jnt_qposadr[0] == 0 and m.nq == 26 and m.nv == 24, \
            (m.nq, m.nv)
        self.actors = {}
        for name in list(HUMAN) + ["bag"]:
            bid = mujoco.mj_name2id(m, mujoco.mjtObj.mjOBJ_BODY, f"actor_{name}")
            self.actors[name] = Actor(name, "bag" if name == "bag" else "person", bid, m)
        # geom -> actor lookup for the segmentation "detector"
        self.actor_names = list(self.actors)
        self.dog_index = len(self.actor_names)
        trunk = mujoco.mj_name2id(m, mujoco.mjtObj.mjOBJ_BODY, "trunk")
        self.lut = np.full(m.ngeom + 1, -1, dtype=np.int32)
        for gi in range(m.ngeom):
            bid = m.geom_bodyid[gi]
            bname = mujoco.mj_id2name(m, mujoco.mjtObj.mjOBJ_BODY, bid) or ""
            if bname.startswith("actor_"):
                self.lut[gi] = self.actor_names.index(bname[6:])
            elif bid != 0 and m.body_rootid[bid] == trunk:
                self.lut[gi] = self.dog_index
        self.r_small = mujoco.Renderer(m, 240, 320)
        self.r_full = mujoco.Renderer(m, 480, 640)
        self.r_view = mujoco.Renderer(m, 450, 800)
        self.r_live = mujoco.Renderer(m, LIVE_H, LIVE_W)
        self.live = {}   # channel -> a viewer asked for fast frames. sim-view stays on for servers that never ask
        self.opt_camera, self.opt_overview = mujoco.MjvOption(), mujoco.MjvOption()
        for k in range(6):
            self.opt_camera.geomgroup[k] = CAMERA_GROUPS[k]
            self.opt_overview.geomgroup[k] = OVERVIEW_GROUPS[k]
        self.free = mujoco.MjvCamera()
        self.free.type = mujoco.mjtCamera.mjCAMERA_FREE
        self.view = "follow"
        self.pose = (0.0, 0.0, 0.0)
        self.cmd = (0.0, 0.0, 0.0)
        self.posture = "standing"
        self.phase = 0.0
        self.amp = 0.0
        self.low = 0.0
        self.az = None
        # --no-cameras (or SIM_CAMERAS=0): the fixed cameras are real phones, the simulator only has the dog
        self.cam_ids = [] if os.environ.get("SIM_CAMERAS", "1") == "0" else [c["id"] for c in self.site.data["cameras"]]
        self.alarm = {"armed": False, "active_at": None}
        self.det = {cid: {"intr_t": 0.0, "intr_fired": False, "intr_clear": 0.0,
                          "bag_t": 0.0, "bag_fired": False, "bag_clear": 0.0} for cid in self.cam_ids}
        self.net = Net(server, self.cam_ids + ["dog", "sim-view"])
        # physics: the server sends velocity commands, the trained policy walks, MuJoCo integrates
        import onnxruntime as rt
        self.policy = rt.InferenceSession(str(PG / "go1_policy.onnx"), providers=["CPUExecutionProvider"])
        self.physics = True
        self.default_q = np.array(HOME_Q, dtype=np.float32)
        self.last_action = np.zeros(12, dtype=np.float32)
        self.imu = m.site("imu").id
        self.n_step = 0
        self.debt = 0.0
        self.falls = 0
        self.reset_dog(0.0, 0.0, 0.0)

    def reset_dog(self, x, y, yaw):
        m, d = self.model, self.data
        bag = self.actors.get("bag")
        keep = (d.qpos[bag.qadr:bag.qadr + 7].copy(), d.qvel[bag.dadr:bag.dadr + 6].copy()) if bag else None
        mujoco.mj_resetDataKeyframe(m, d, 0)
        if keep:
            d.qpos[bag.qadr:bag.qadr + 7], d.qvel[bag.dadr:bag.dadr + 6] = keep
        d.qpos[0:2] = (x, y)
        d.qpos[3:7] = (math.cos(yaw / 2), 0, 0, math.sin(yaw / 2))
        self.last_action[:] = 0
        for a in self.actors.values():
            if not a.physical:
                a.apply(d)
        mujoco.mj_forward(m, d)

    def odom(self):
        q = self.data.qpos
        w, x, y, z = q[3:7]
        yaw = math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))
        return float(q[0]), float(q[1]), yaw

    def control(self):
        d = self.data
        if self.posture == "down":
            d.ctrl[:] = LIE_Q
            self.last_action[:] = 0
            return
        if self.posture == "rising":
            d.ctrl[:] = HOME_Q
            self.last_action[:] = 0
            return
        xmat = d.site_xmat[self.imu].reshape(3, 3)
        cmd = np.array([np.clip(self.cmd[0], -1.0, 1.0), np.clip(self.cmd[1], -0.6, 0.6), np.clip(self.cmd[2], -1.2, 1.2)])
        obs = np.hstack([d.sensor("local_linvel").data, d.sensor("gyro").data, xmat.T @ np.array([0, 0, -1.0]),
                         d.qpos[7:19] - self.default_q, d.qvel[6:18], self.last_action, cmd]).astype(np.float32)
        act = self.policy.run(["continuous_actions"], {"obs": obs.reshape(1, -1)})[0][0]
        self.last_action = act.astype(np.float32)
        d.ctrl[:] = act * 0.5 + self.default_q

    def physics_step(self, dt):
        m, d = self.model, self.data
        self.debt += dt
        steps = 0
        while self.debt >= m.opt.timestep and steps < 50:
            if self.n_step % 5 == 0:   # policy at 50 Hz, physics at 250 Hz
                self.control()
            mujoco.mj_step(m, d)
            self.n_step += 1
            self.debt -= m.opt.timestep
            steps += 1
        if steps >= 50:
            self.debt = 0.0
        up = d.site_xmat[self.imu].reshape(3, 3)[:, 2]
        if self.posture == "standing" and (up[2] < 0.35 or d.qpos[2] < 0.12):
            self.falls += 1
            x, y, yaw = self.odom()
            self.say("fall", f"the dog fell over (fall {self.falls}), set back on its feet")
            self.reset_dog(x, y, yaw)
        self.pose = self.odom()

    # dog -----------------------------------------------------------------------------
    def animate_dog(self, dt):
        x, y, yaw = self.pose
        vx, vy, wz = self.cmd
        speed = abs(vx) + 0.25 * abs(wz) + abs(vy)
        target_amp = 0.0 if speed < 0.02 else min(1.0, 0.45 + speed / 0.6)
        self.amp += (target_amp - self.amp) * min(1.0, dt * 6)
        freq = 1.6 + 1.6 * min(1.0, speed / 0.5)
        self.phase = (self.phase + 2 * math.pi * freq * dt) % (2 * math.pi) if self.amp > 0.02 else self.phase
        down = 1.0 if self.posture == "down" else 0.0
        self.low += (down - self.low) * min(1.0, dt * 2.5)
        direction = -1.0 if vx < -0.02 else 1.0
        q = self.data.qpos
        z = 0.27 + 0.006 * math.cos(2 * self.phase) * self.amp
        z = z * (1 - self.low) + 0.105 * self.low
        q[0:3] = (x, y, z)
        q[3:7] = (math.cos(yaw / 2), 0, 0, math.sin(yaw / 2))
        for i, off in enumerate((0.0, math.pi, math.pi, 0.0)):  # FR, FL, RR, RL: diagonal pairs trot together
            p = self.phase + off
            lift = max(0.0, math.sin(p)) * self.amp
            thigh = 0.9 + direction * 0.32 * self.amp * math.cos(p)
            calf = -1.8 - 0.55 * lift
            turn = 0.08 * self.amp * math.copysign(1, wz) * math.sin(p) if abs(wz) > 0.1 else 0.0
            thigh = thigh * (1 - self.low) + 1.25 * self.low
            calf = calf * (1 - self.low) - 2.72 * self.low
            q[7 + 3 * i: 10 + 3 * i] = (turn * (1 - self.low), thigh, calf)

    # cameras -------------------------------------------------------------------------
    def render(self, renderer, camera):
        # cameras on site see full walls and ceiling, the views from above see walls cut at 1.1 m
        opt = self.opt_overview if isinstance(camera, mujoco.MjvCamera) else self.opt_camera
        renderer.update_scene(self.data, camera=camera, scene_option=opt)
        return renderer.render()

    def view_camera(self):
        x, y, yaw = self.pose
        if self.view in self.cam_ids or self.view == "dog":
            return "dogcam" if self.view == "dog" else self.view
        f = self.free
        if self.view == "map":
            rooms = self.site.data["rooms"]
            xs = [r["x"] for r in rooms] + [r["x"] + r["w"] for r in rooms]
            ys = [r["y"] for r in rooms] + [r["y"] + r["h"] for r in rooms]
            f.lookat[:] = ((min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2 - 0.4, 0)
            span = max((max(xs) - min(xs)) * 0.56, max(ys) - min(ys))   # 16:9 frame
            f.distance, f.elevation, f.azimuth = 1.12 * span + 1.5, -78, 90
            return f
        target_az = math.degrees(yaw) + 35
        if self.az is None:
            self.az = target_az
        diff = (target_az - self.az + 180) % 360 - 180
        self.az += diff * 0.04
        f.lookat[:] = (x, y, 0.35)
        f.distance, f.elevation, f.azimuth = 4.2, -46, self.az
        return f

    @staticmethod
    def jpeg(img, q=72):
        buf = io.BytesIO()
        Image.fromarray(img).save(buf, "JPEG", quality=q)
        return base64.b64encode(buf.getvalue()).decode()

    def detect(self, cid):
        """Ground-truth detector from segmentation: what a phone detector would report."""
        r = self.r_small
        r.enable_segmentation_rendering()
        try:
            seg = self.render(r, cid)
        finally:
            r.disable_segmentation_rendering()
        ids, types = seg[..., 0], seg[..., 1]
        geom = (types == int(mujoco.mjtObj.mjOBJ_GEOM)) & (ids >= 0)
        idx = np.where(geom, self.lut[np.clip(ids, 0, len(self.lut) - 1)], -1)
        h, w = idx.shape
        dets = []
        for k, name in enumerate(self.actor_names):
            mask = idx == k
            n = int(mask.sum())
            if n < 40:
                continue
            ys, xs = np.nonzero(mask)
            a = self.actors[name]
            px, py = (float(v) for v in self.data.xpos[a.body][:2])  # where MuJoCo has the body now
            dets.append({"actor": name, "label": "suitcase" if a.kind == "bag" else "person",
                         "score": round(min(0.98, 0.55 + n / 2500), 2), "pixels": n,
                         "box": [round(xs.min() / w, 3), round(ys.min() / h, 3),
                                 round((xs.max() - xs.min()) / w, 3), round((ys.max() - ys.min()) / h, 3)],
                         "x": px, "y": py})
        mask = idx == self.dog_index
        n = int(mask.sum())
        if n >= 40:   # a phone detector usually calls the Go1 a "dog"
            ys, xs = np.nonzero(mask)
            dets.append({"actor": "robot", "label": "dog", "score": round(min(0.9, 0.4 + n / 3000), 2), "pixels": n,
                         "box": [round(xs.min() / w, 3), round(ys.min() / h, 3),
                                 round((xs.max() - xs.min()) / w, 3), round((ys.max() - ys.min()) / h, 3)],
                         "x": float(self.data.qpos[0]), "y": float(self.data.qpos[1])})
        return dets

    def alarm_active(self):
        return self.alarm["armed"] and time.time() >= (self.alarm.get("active_at") or 0)

    def check_rules(self, cid, dt):
        """Same behaviour as a phone: nothing while the alarm is disarmed; armed, anything that moves or appears
        in the frame (people, a bag, our own dog) raises 'motion'. Grok decides what needs checking."""
        if not self.alarm_active():
            self.det[cid].pop("prev", None)
            return
        dets = self.detect(cid)
        st = self.det[cid]
        now_pos = {d["actor"]: (d["x"], d["y"], d["pixels"]) for d in dets}
        prev = st.get("prev")
        st["prev"] = now_pos
        if prev is None:      # just armed: what is there now is the background
            return
        moving = [d for d in dets if d["actor"] not in prev
                  or math.hypot(d["x"] - prev[d["actor"]][0], d["y"] - prev[d["actor"]][1]) > 0.04]
        st["mov_t"] = st.get("mov_t", 0.0) + dt if moving else 0.0
        if moving and st["mov_t"] >= 0.5 and time.time() - st.get("last_fire", 0) > 12:
            st["last_fire"], st["mov_t"] = time.time(), 0.0
            x0 = min(d["box"][0] for d in moving); y0 = min(d["box"][1] for d in moving)
            x1 = max(d["box"][0] + d["box"][2] for d in moving); y1 = max(d["box"][1] + d["box"][3] for d in moving)
            what = ", ".join(sorted({d["label"] for d in moving}))
            self.fire(cid, "motion", moving, dets, f"part of the image changed ({what}), alarm armed",
                      motion_box=[round(x0, 3), round(y0, 3), round(x1 - x0, 3), round(y1 - y0, 3)])

    def fire(self, cid, kind, hits, dets, measured="", motion_box=None):
        img = Image.fromarray(self.render(self.r_full, cid))
        clean = io.BytesIO()
        img.save(clean, "JPEG", quality=85)
        draw = ImageDraw.Draw(img)
        W, H = img.size
        for d in dets:
            x, y, w, h = d["box"]
            draw.rectangle([x * W, y * H, (x + w) * W, (y + h) * H], outline=(255, 214, 0), width=3)
            draw.text((x * W + 4, y * H + 2), f"{d['label']} {d['score']:.2f}", fill=(255, 214, 0))
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=85)
        dets_out = [{k: d[k] for k in ("label", "score", "box")} for d in dets]
        self.net.send(cid, {"type": "event", "kind": kind, "score": max([d["score"] for d in hits] or [0.8]),
                            "motion_box": motion_box,
                            "detections": dets_out, "jpeg": base64.b64encode(clean.getvalue()).decode(),
                            "jpeg_annotated": base64.b64encode(buf.getvalue()).decode(),
                            "note": f"on-device detector: {measured}"})
        self.say("detector", f"{cid}: {kind.replace('_', ' ')} detected")

    def say(self, kind, message):
        self.net.send("sim", {"type": "log", "kind": kind, "message": message})

    # staging -------------------------------------------------------------------------
    def stage(self, scenario, cid=None):
        cams = [c for c in self.site.data["cameras"] if c.get("stage_area") or c.get("zone_world")]
        cam = self.site.camera(cid) if cid else None
        cam = cam or random.choice(cams)
        x0, y0, x1, y1 = cam.get("stage_area") or cam["zone_world"]
        zx, zy = (x0 + x1) / 2, (y0 + y1) / 2
        entry = cam.get("entry")
        if not entry:
            room = self.site.room(cam["room"])
            cx, cy = room["x"] + room["w"] / 2, room["y"] + room["h"] / 2
            entry = (cx + (cx - zx) * 0.6, cy + (cy - zy) * 0.6)
        ex, ey = entry
        inner = (zx + random.uniform(-0.4, 0.4), zy + (0.25 if zy > ey else -0.25) * 0 + random.uniform(-0.2, 0.2))
        A = self.actors
        if scenario == "clear":
            for a in A.values():
                a.hide()
            for st in self.det.values():
                st.pop("prev", None)
                st["mov_t"] = 0.0
            return
        if scenario == "lights":
            # the lights dim for a moment: a real phone sees half the image change, with nobody there
            self.flash = (cam["id"], time.time())
            self.say("stage", f"light change at {cam['name']}")
            return
        if scenario in ("intruder", "staff"):
            a = A[scenario]
            a.hide()
            a.place(ex, ey)
            face = math.atan2((y0 if abs(zy - y0) < abs(zy - y1) else y1) - zy, 0.001)
            a.steps = [("goto", inner, 0.9), ("face", face), ("wait", 75), ("goto", (ex, ey), 1.0), ("hide",)]
        elif scenario == "bag":
            a = A["carrier"]
            a.hide()
            A["bag"].hide()
            a.place(ex, ey)
            a.carry = "bag"
            drop = (min(max(ex, x0 + 0.55), x1 - 0.55), min(max(ey, y0 + 0.55), y1 - 0.55))
            a.steps = [("goto", drop, 1.0), ("wait", 1.0), ("drop",), ("wait", 0.8), ("goto", (ex, ey), 1.2), ("hide",)]
        elif scenario == "visitor":
            a = A["visitor"]
            a.hide()
            # crosses the area and keeps walking
            edge_y = y1 + 0.7 if abs(ey - y1) < abs(ey - y0) else y0 - 0.7
            a.place(x0 - 1.0, edge_y)
            a.steps = [("goto", (x1 + 1.0, edge_y), 0.9), ("wait", 1), ("hide",)]
        self.say("stage", f"{scenario} staged at {cam['name']}")

    # loop ----------------------------------------------------------------------------
    def handle(self, ch, msg):
        t = msg.get("type")
        if ch == "sim":
            if t == "pose":
                if not self.physics:
                    self.pose = (msg["x"], msg["y"], msg["yaw"])
                self.cmd = tuple(msg.get("cmd") or (0, 0, 0))
                self.posture = msg.get("posture", "standing")
            elif t == "mode":
                was = self.physics
                self.physics = bool(msg.get("physics", True))
                if self.physics and not was:
                    self.reset_dog(*self.pose)
                print("dog:", "MuJoCo physics + trained policy" if self.physics else "kinematic, following the server")
            elif t == "teleport":
                self.pose = (msg["x"], msg["y"], msg.get("yaw", 0.0))
                if self.physics:
                    self.reset_dog(*self.pose)
            elif t == "stage":
                self.stage(msg.get("scenario"), msg.get("camera"))
            elif t == "view":
                self.view = msg.get("mode", "follow")
            elif t == "_connected":
                self.net.send("sim", {"type": "hello", "scenarios": SCENARIOS})
        elif t == "alarm":
            was = self.alarm_active()
            self.alarm = {"armed": bool(msg.get("armed")), "active_at": msg.get("active_at")}
            if was != self.alarm_active() or not self.alarm["armed"]:
                for st in self.det.values():
                    st.update(intr_t=0.0, intr_fired=False, intr_clear=0.0, bag_t=0.0, bag_fired=False, bag_clear=0.0,
                              pers_t=0.0, pers_fired=False, pers_clear=0.0)
        elif t == "live":
            self.live[ch] = bool(msg.get("on"))   # someone is watching this camera: send fast, large frames
        elif t == "capture":
            cam = "dogcam" if ch == "dog" else ch
            self.net.send(ch, {"type": "frame", "req": msg.get("req"), "jpeg": self.jpeg(self.render(self.r_full, cam), 85)})
        elif t == "_connected":
            self.net.send(ch, {"type": "status", "fps": 4, "armed": True, "model": "mujoco segmentation",
                               "detector": "simulated"})

    def run(self):
        self.net.start()
        if self.viewer_wanted:
            import mujoco.viewer as mjviewer  # an "import mujoco..." here would shadow the module in this function
            self.viewer = mjviewer.launch_passive(self.model, self.data, show_left_ui=False, show_right_ui=False)
            self.viewer.cam.lookat[:] = (7.0, 0.0, 0.0)
            self.viewer.cam.distance, self.viewer.cam.elevation, self.viewer.cam.azimuth = 14.0, -55.0, 90.0
            print("MuJoCo viewer open: drag with the mouse to look around, double-click a body and Ctrl+drag to push it.")
        print("Ronda MuJoCo simulator running. Ctrl+C to stop.")
        last = time.time()
        t_det = t_prev = t_view = t_act = t_live = 0.0
        while True:
            now = time.time()
            dt = min(0.1, now - last)
            last = now
            while True:
                try:
                    ch, msg = self.net.inbox.get_nowait()
                except queue.Empty:
                    break
                try:
                    self.handle(ch, msg)
                except Exception as e:
                    print("handle error", e)
            with (self.viewer.lock() if self.viewer else _nolock()):
                for a in self.actors.values():
                    a.update(dt, self)
                carrier, bag = self.actors["carrier"], self.actors["bag"]
                bag.carry_lock = carrier.carry == "bag" and carrier.visible
                if bag.carry_lock:  # held at the carrier's side, rolling on the floor
                    bag.place(carrier.x - 0.3 * math.sin(carrier.yaw), carrier.y + 0.3 * math.cos(carrier.yaw), carrier.yaw)
                for a in self.actors.values():
                    a.apply(self.data)
                if self.physics:
                    self.physics_step(dt)
                    x, y, yaw = self.pose
                    self.net.send("sim", {"type": "odom", "x": x, "y": y, "yaw": yaw, "z": float(self.data.qpos[2]),
                                          "vx": float(self.data.sensor("local_linvel").data[0])})
                else:
                    self.animate_dog(dt)
                mujoco.mj_forward(self.model, self.data)
            if self.viewer:
                if self.viewer.is_running():
                    self.viewer.sync()
                else:
                    self.viewer = None
                    print("MuJoCo viewer closed; the simulation keeps running for the console.")
            fl = getattr(self, "flash", None)
            if fl:
                lid = self.model.nlight - 1
                if not hasattr(self, "_light0"):
                    self._light0 = self.model.light_diffuse[lid].copy()
                if now - fl[1] < 0.4:
                    self.model.light_diffuse[lid] = self._light0 * 0.25
                elif fl[0]:
                    if self.alarm_active():
                        self.fire(fl[0], "motion", [], [], "a large part of the image changed brightness, alarm armed",
                                  motion_box=[0.02, 0.05, 0.96, 0.9])
                    self.flash = (None, fl[1])
                elif now - fl[1] > 1.2:
                    self.model.light_diffuse[lid] = self._light0
                    self.flash = None
            if now - t_det >= 0.25:
                for cid in self.cam_ids:
                    self.check_rules(cid, now - t_det if t_det else 0.25)
                t_det = now
            if now - t_live >= 1 / LIVE_FPS:
                for cid in self.cam_ids + ["dog"]:
                    if self.live.get(cid) and self.net.connected.get(cid):
                        cam = "dogcam" if cid == "dog" else cid
                        self.net.send(cid, {"type": "preview", "jpeg": self.jpeg(self.render(self.r_live, cam), 74)})
                t_live = now
            if now - t_view >= 0.12 and self.net.connected.get("sim-view") and self.live.get("sim-view", True):
                self.net.send("sim-view", {"type": "preview", "jpeg": self.jpeg(self.render(self.r_view, self.view_camera()), 70)})
                t_view = now
            if now - t_prev >= 1.0:
                for cid in self.cam_ids + ["dog"]:
                    if self.net.connected.get(cid) and not self.live.get(cid):
                        cam = "dogcam" if cid == "dog" else cid
                        self.net.send(cid, {"type": "preview", "jpeg": self.jpeg(self.render(self.r_small, cam), 65)})
                t_prev = now
            if now - t_act >= 0.5:
                self.net.send("sim", {"type": "actors", "actors": [
                    {"id": a.name, "kind": a.kind, "x": round(float(self.data.xpos[a.body][0]), 2),
                     "y": round(float(self.data.xpos[a.body][1]), 2), "yaw": round(a.yaw, 2)}
                    for a in self.actors.values() if a.visible]})
                t_act = now
            time.sleep(max(0.0, 1 / 30 - (time.time() - now)))


class _nolock:
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


# network: one websocket per camera, plus the simulator channel ------------------------------
TAKEN = 4409   # same as the server's: a real camera has this channel, try again later without pushing it out


class Net:
    def __init__(self, server, cams):
        base = server.rstrip("/").replace("https://", "wss://").replace("http://", "ws://")
        # ?sim=1: a real phone on the same camera has priority, see TAKEN
        self.urls = {"sim": base + "/ws/sim", **{c: f"{base}/ws/camera/{c}?sim=1" for c in cams}}
        self.inbox = queue.Queue()
        self.queues = {}
        self.connected = {}
        self.loop = None

    def start(self):
        threading.Thread(target=lambda: asyncio.run(self._main()), daemon=True).start()

    def send(self, ch, msg):
        q = self.queues.get(ch)
        if self.loop and q is not None and self.connected.get(ch):
            self.loop.call_soon_threadsafe(q.put_nowait, msg)

    async def _main(self):
        self.loop = asyncio.get_running_loop()
        await asyncio.gather(*(self._conn(ch, url) for ch, url in self.urls.items()))

    async def _conn(self, ch, url):
        while True:
            ws = None
            try:
                async with websockets.connect(url, max_size=16 * 1024 * 1024, ping_interval=20) as ws:
                    q = asyncio.Queue()
                    self.queues[ch] = q
                    self.connected[ch] = True
                    self.inbox.put((ch, {"type": "_connected"}))

                    async def pump():
                        while True:
                            m = await q.get()
                            await ws.send(json.dumps(m))
                    sender = asyncio.create_task(pump())
                    try:
                        async for raw in ws:
                            self.inbox.put((ch, json.loads(raw)))
                    finally:
                        sender.cancel()
            except Exception:
                pass
            self.connected[ch] = False
            await asyncio.sleep(5.0 if ws is not None and ws.close_code == TAKEN else 1.0)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", default=os.environ.get("RONDA_SERVER", "http://127.0.0.1:8000"))
    ap.add_argument("--no-cameras", action="store_true", help="no simulated fixed cameras: use real phones as Camera 1, 2, 3")
    ap.add_argument("--snapshot", help="render the views to this folder and exit (for checks)")
    ap.add_argument("--viewer", action="store_true", help="also open the native MuJoCo viewer (needs mjpython on macOS)")
    args = ap.parse_args()
    if args.no_cameras:
        os.environ["SIM_CAMERAS"] = "0"
    world = World(args.server, viewer=args.viewer)
    if args.snapshot:
        world.physics = False
        out = Path(args.snapshot)
        out.mkdir(parents=True, exist_ok=True)
        world.stage("intruder", "cam-1")
        a = world.actors["intruder"]
        a.place(6.4, -2.0, -1.57)
        a.steps = []
        world.actors["staff"].place(1.4, -2.2, 0.5)
        world.actors["bag"].place(12.2, 1.8, 0.3)
        world.pose = world.site.home_pose() if hasattr(world, "site") else (8.3, 1.6, 1.57)
        world.cmd = (0.4, 0, 0)
        for _ in range(8):
            world.animate_dog(1 / 30)
        for a in world.actors.values():
            a.apply(world.data)
        mujoco.mj_forward(world.model, world.data)
        for name in world.cam_ids + ["dogcam"]:
            Image.fromarray(world.render(world.r_full, name)).save(out / f"{name}.jpg")
        for v in ("follow", "map"):
            world.view = v
            Image.fromarray(world.render(world.r_view, world.view_camera())).save(out / f"view-{v}.jpg")
        print("dets cam-1", world.detect("cam-1"))
        sys.exit(0)
    world.run()
