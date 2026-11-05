"""Imports a CAD model of the real room (STEP) into Ronda.

  .venv/bin/python scripts/import_step.py <room.step> [--out sim/assets/site] [--cut 0.3]

Produces in --out:
  structure.obj   walls, pillars, partitions (visual mesh for MuJoCo, floor faces removed)
  upper.obj       everything above the ceiling height (hidden in the views from above)
  boxes.json      collision boxes for MuJoCo, from the floor plan
  grid.npz        occupancy grid at 5 cm for the dog's path planning
  plan.json       floor plan polygons and bounds for the console map
Units: meters (STEP files in millimeters are converted).
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np

try:
    import cascadio
    import trimesh
    from shapely.geometry import Polygon, box
    from shapely.ops import unary_union
except ImportError as e:
    sys.exit(f"missing package: {e.name}. Run: uv pip install --python .venv/bin/python trimesh cascadio shapely rtree scipy networkx")

ap = argparse.ArgumentParser()
ap.add_argument("step")
ap.add_argument("--out", default="sim/assets/site")
ap.add_argument("--cut", type=float, default=0.3, help="height of the floor plan cut, m")
ap.add_argument("--ceiling", type=float, default=2.85, help="faces entirely above this go to upper.obj")
ap.add_argument("--res", type=float, default=0.05, help="grid resolution, m")
args = ap.parse_args()
out = Path(args.out)
out.mkdir(parents=True, exist_ok=True)

glb = out / "_model.glb"
cascadio.step_to_glb(str(args.step), str(glb), tol_linear=2.0, tol_angular=0.5)
mesh = trimesh.load(glb, force="mesh")
mesh.merge_vertices()
lo, hi = mesh.bounds
print(f"model: {len(mesh.faces)} triangles, size {np.round(hi - lo, 2)} m, from {np.round(lo, 2)}")

# 1. visual meshes: drop the floor (MuJoCo draws its own), split what hangs above the ceiling line
tri = mesh.triangles
zmin, zmax = tri[:, :, 2].min(1), tri[:, :, 2].max(1)
normals = mesh.face_normals
floor = (zmax < 0.05) & (np.abs(normals[:, 2]) > 0.9)
upper = (zmin >= args.ceiling) & ~floor
structure = ~floor & ~upper
def oriented(part):
    """CAD exports often have faces turned the wrong way: orient every solid outwards, one body at a time."""
    part = part.copy()
    part.merge_vertices()
    bodies = part.split(only_watertight=False)
    for b in bodies:
        trimesh.repair.fix_normals(b, multibody=True)
    part = trimesh.util.concatenate(bodies) if bodies else part
    # MuJoCo lights per vertex: an 18 m wall made of two triangles shades as one big gradient
    return part.subdivide_to_size(max_edge=0.6, max_iter=12)


for name, mask in (("structure", structure), ("upper", upper)):
    part = oriented(mesh.submesh([np.nonzero(mask)[0]], append=True))
    part.export(out / f"{name}.obj", include_normals=False)
    print(f"{name}.obj: {mask.sum()} triangles, {len(part.split(only_watertight=False))} bodies")

# 2. floor plan: what the dog meets at --cut height
sec = mesh.section(plane_origin=[0, 0, args.cut], plane_normal=[0, 0, 1])
if sec is None:
    sys.exit("no geometry at the cut height")
p2, T = sec.to_2D()
polys = []
for poly in p2.polygons_closed:
    pts = trimesh.transform_points(np.column_stack([np.array(poly.exterior.coords), np.zeros(len(poly.exterior.coords))]), T)[:, :2]
    pg = Polygon(pts).buffer(0)
    if pg.area > 1e-4:
        polys.append(pg)
solid = unary_union(polys)
print(f"plan: {len(polys)} solid regions, {solid.area:.1f} m2 of walls and pillars")

# walls cut at 1.1 m, like a floor plan drawing: for the views from above and behind the dog
low = [trimesh.creation.extrude_polygon(g, 1.1) for g in (solid.geoms if hasattr(solid, "geoms") else [solid]) if g.area > 1e-3]
trimesh.util.concatenate(low).subdivide_to_size(max_edge=0.6, max_iter=12).export(out / "lowwalls.obj")
print(f"lowwalls.obj: {len(low)} extruded footprints")

# 3. occupancy grid
x0, y0 = np.floor(lo[0]) - 1.0, np.floor(lo[1]) - 1.0
x1, y1 = np.ceil(hi[0]) + 1.0, np.ceil(hi[1]) + 1.0
nx, ny = int(round((x1 - x0) / args.res)), int(round((y1 - y0) / args.res))
xs = x0 + (np.arange(nx) + 0.5) * args.res
ys = y0 + (np.arange(ny) + 0.5) * args.res
from shapely import contains_xy  # noqa: E402
gx, gy = np.meshgrid(xs, ys)
occ = contains_xy(solid, gx.ravel(), gy.ravel()).reshape(ny, nx)
np.savez_compressed(out / "grid.npz", occ=occ, origin=np.array([x0, y0]), res=np.array(args.res))
print(f"grid: {nx} x {ny} cells, {occ.mean() * 100:.1f}% occupied")

# 4. collision boxes: greedy rectangles over the occupied cells
used = np.zeros_like(occ)
boxes = []
for j in range(ny):
    i = 0
    while i < nx:
        if occ[j, i] and not used[j, i]:
            i2 = i
            while i2 + 1 < nx and occ[j, i2 + 1] and not used[j, i2 + 1]:
                i2 += 1
            j2 = j
            while j2 + 1 < ny and occ[j2 + 1, i:i2 + 1].all() and not used[j2 + 1, i:i2 + 1].any():
                j2 += 1
            used[j:j2 + 1, i:i2 + 1] = True
            bx0, by0 = x0 + i * args.res, y0 + j * args.res
            bx1, by1 = x0 + (i2 + 1) * args.res, y0 + (j2 + 1) * args.res
            boxes.append([round(bx0, 3), round(by0, 3), round(bx1, 3), round(by1, 3)])
            i = i2 + 1
        else:
            i += 1
(out / "boxes.json").write_text(json.dumps({"height": 2.6, "boxes": boxes}))
print(f"collision: {len(boxes)} boxes")

# 5. plan for the console map
def coords(pg):
    return [[round(float(x), 2), round(float(y), 2)] for x, y in pg.exterior.coords]

geoms = list(solid.geoms) if hasattr(solid, "geoms") else [solid]
plan = {"bounds": [round(float(lo[0]), 2), round(float(lo[1]), 2), round(float(hi[0]), 2), round(float(hi[1]), 2)],
        "solids": [coords(g.simplify(0.01)) for g in geoms if g.area > 1e-3], "cut": args.cut,
        "source": Path(args.step).name}
(out / "plan.json").write_text(json.dumps(plan))
glb.unlink()
print(f"done: {out}")
