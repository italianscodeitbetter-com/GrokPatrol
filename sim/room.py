"""The real room from the CAD model (scripts/import_step.py output) inside the MuJoCo scene.

Geom groups: 0 everything else, 1 full walls and pillars, 2 the Go1's own meshes, 3 invisible collision
boxes, 4 ceiling grid, 5 walls cut at 1.1 m for the views from above.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GROUP_STRUCTURE, GROUP_COLLISION, GROUP_CEILING, GROUP_LOW = 1, 3, 4, 5
# cameras on site and the dog see the full walls and the ceiling; views from above see walls cut at 1.1 m
CAMERA_GROUPS = (1, 1, 1, 0, 1, 0)
OVERVIEW_GROUPS = (1, 0, 1, 0, 0, 1)


def _fmt(*v):
    return " ".join(f"{x:.4f}" for x in v)


def _add(parent, tag, **kw):
    import xml.etree.ElementTree as ET
    return ET.SubElement(parent, tag, {k.rstrip("_"): str(v) for k, v in kw.items()})


def add_real_room(root, site):
    """Adds the room to the MJCF tree. Returns the bounds (x0, y0, x1, y1)."""
    model = site.data["model"]
    d = ROOT / model["dir"]
    plan = json.loads((d / "plan.json").read_text())
    boxes = json.loads((d / "boxes.json").read_text())
    asset = root.find("asset")
    w = root.find("worldbody")
    _add(asset, "mesh", name="room_structure", file=str(d / "structure.obj"), inertia="shell", smoothnormal="false")
    _add(asset, "mesh", name="room_ceiling", file=str(d / "upper.obj"), inertia="shell", smoothnormal="false")
    if (d / "lowwalls.obj").exists():
        _add(asset, "mesh", name="room_low", file=str(d / "lowwalls.obj"), inertia="shell")
    _add(asset, "material", name="room_wall", rgba="0.72 0.71 0.68 1", specular="0.1")
    # just under full alpha: transparent geoms cast no shadow, otherwise the roof would blacken the whole room
    _add(asset, "material", name="room_ceiling", rgba="0.52 0.53 0.54 0.999", emission="0.32")
    nv = dict(contype=0, conaffinity=0)
    _add(w, "geom", name="room_structure", type="mesh", mesh="room_structure", material="room_wall",
         group=GROUP_STRUCTURE, **nv)
    _add(w, "geom", name="room_ceiling", type="mesh", mesh="room_ceiling", material="room_ceiling",
         group=GROUP_CEILING, **nv)
    if (d / "lowwalls.obj").exists():
        _add(w, "geom", name="room_low", type="mesh", mesh="room_low", material="room_wall", group=GROUP_LOW, **nv)
    h = boxes.get("height", 2.6)
    for k, (x0, y0, x1, y1) in enumerate(boxes["boxes"]):
        # solid for the dog (feet and body), like the floor: contype 1, conaffinity 0
        _add(w, "geom", name=f"wall_{k}", type="box", pos=_fmt((x0 + x1) / 2, (y0 + y1) / 2, h / 2),
             size=_fmt((x1 - x0) / 2, (y1 - y0) / 2, h / 2), group=GROUP_COLLISION, rgba="1 0 0 0.3",
             contype=1, conaffinity=0, friction="0.6")
    bx0, by0, bx1, by1 = plan["bounds"]
    # the roof (not in the CAD model): cameras inside see a ceiling, not the sky
    _add(w, "geom", name="room_roof", type="box", pos=_fmt((bx0 + bx1) / 2, (by0 + by1) / 2, 5.56),
         size=_fmt((bx1 - bx0) / 2 + 4, (by1 - by0) / 2 + 4, 0.03), material="room_ceiling", group=GROUP_CEILING, **nv)
    # light: the scene's spotlight, the camera headlight and one directional light. Extra point lights
    # under the ceiling turned the whole render dark in this MuJoCo build, so there are none.
    # the sun comes in at an angle: the long soft shadows are what give the room its depth
    _add(w, "light", pos=_fmt((bx0 + bx1) / 2 - 5, (by0 + by1) / 2 - 3, 12), dir="0.35 0.22 -0.9", directional="true",
         diffuse="0.34 0.33 0.31", specular="0.2 0.2 0.2", castshadow="true")
    # even light from above: without it the floor goes dark at the low angle of the dog's camera
    _add(w, "light", pos=_fmt((bx0 + bx1) / 2, (by0 + by1) / 2, 11), dir="0 0 -1", directional="true",
         diffuse="0.40 0.40 0.40", specular="0 0 0", castshadow="false")
    for e in site.data.get("exhibits", []):
        add_exhibit(w, e)
    return (bx0, by0, bx1, by1)


def add_exhibit(w, e):
    import math
    yaw = e.get("yaw", 0.0) or 0.0
    q = _fmt(math.cos(yaw / 2), 0, 0, math.sin(yaw / 2))
    solid = dict(contype=1, conaffinity=0)
    body = _add(w, "body", name=f"exhibit_{e['type']}_{e['x']}_{e['y']}".replace(".", "_"),
                pos=_fmt(e["x"], e["y"], 0), quat=q)
    hw, hd = e["w"] / 2, e["d"] / 2
    if e["type"] == "case":
        _add(body, "geom", type="box", pos=_fmt(0, 0, 0.45), size=_fmt(hw, hd, 0.45), material="wood", **solid)
        _add(body, "geom", type="box", pos=_fmt(0, 0, 1.22), size=_fmt(hw, hd, 0.32), material="glass", **solid)
        _add(body, "geom", type="ellipsoid", pos=_fmt(-hw * 0.35, 0, 1.08), size=_fmt(0.1, 0.1, 0.17),
             material="gold", contype=0, conaffinity=0)
        _add(body, "geom", type="cylinder", pos=_fmt(hw * 0.4, 0, 0.98), size=_fmt(0.09, 0.07),
             material="gold", contype=0, conaffinity=0)
    elif e["type"] == "bench":
        _add(body, "geom", type="box", pos=_fmt(0, 0, 0.23), size=_fmt(hw, hd, 0.23), material="wood", **solid)
    elif e["type"] in ("table", "car", "stairs"):
        # tables with their chairs, the cars on display, the staircase: solid blocks of their footprint
        h = {"table": 0.38, "car": 0.55, "stairs": 0.6}[e["type"]]
        _add(body, "geom", type="box", pos=_fmt(0, 0, h), size=_fmt(hw, hd, h),
             material="wood" if e["type"] == "table" else "marble", **solid)
    else:
        _add(body, "geom", type="box", pos=_fmt(0, 0, 0.5), size=_fmt(hw, hd, 0.5), material="marble", **solid)
