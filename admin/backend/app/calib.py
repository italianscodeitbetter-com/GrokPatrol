"""Camera calibration: a homography from the camera image to the floor, from pairs of points.

Each pair is a point on the floor in the image (u, v in 0..1 from the top left) and the same point on the
site map (x, y in meters). Four pairs define it, more pairs give an error estimate.
"""
import json
import time

import numpy as np


def _normalize(pts):
    pts = np.asarray(pts, float)
    c = pts.mean(axis=0)
    d = np.sqrt(((pts - c) ** 2).sum(axis=1)).mean() or 1.0
    s = np.sqrt(2) / d
    T = np.array([[s, 0, -s * c[0]], [0, s, -s * c[1]], [0, 0, 1]])
    return T


def homography(img_pts, floor_pts):
    """3x3 matrix mapping image (u, v) to floor (x, y). Normalized DLT."""
    img_pts, floor_pts = np.asarray(img_pts, float), np.asarray(floor_pts, float)
    Ti, Tf = _normalize(img_pts), _normalize(floor_pts)
    ih = (Ti @ np.column_stack([img_pts, np.ones(len(img_pts))]).T).T
    fh = (Tf @ np.column_stack([floor_pts, np.ones(len(floor_pts))]).T).T
    rows = []
    for (u, v, _), (x, y, _) in zip(ih, fh):
        rows.append([-u, -v, -1, 0, 0, 0, u * x, v * x, x])
        rows.append([0, 0, 0, -u, -v, -1, u * y, v * y, y])
    _, sv, vt = np.linalg.svd(np.asarray(rows))
    Hn = vt[-1].reshape(3, 3)
    H = np.linalg.inv(Tf) @ Hn @ Ti
    return H / H[2, 2], sv


def apply(H, u, v):
    p = np.asarray(H) @ np.array([u, v, 1.0])
    if abs(p[2]) < 1e-9:
        return None
    return float(p[0] / p[2]), float(p[1] / p[2])


def _area(pts):
    pts = np.asarray(pts, float)
    if len(pts) < 3:
        return 0.0
    from scipy.spatial import ConvexHull  # noqa: PLC0415
    try:
        return float(ConvexHull(pts).volume)
    except Exception:
        return 0.0


def solve(points):
    """points: [{u, v, x, y}]. Returns {ok, H, errors_m, rms_m, warnings}."""
    pts = [p for p in points if all(k in p for k in ("u", "v", "x", "y"))]
    if len(pts) < 4:
        return {"ok": False, "error": f"{len(pts)} pairs: at least 4 are needed", "n": len(pts)}
    img = [(p["u"], p["v"]) for p in pts]
    flo = [(p["x"], p["y"]) for p in pts]
    warnings = []
    if _area(img) < 0.03:
        warnings.append("the image points are close together or in a line: spread them over the floor you see")
    if _area(flo) < 1.0:
        warnings.append("the map points are close together or in a line")
    H, sv = homography(img, flo)
    if not np.all(np.isfinite(H)) or abs(np.linalg.det(H)) < 1e-12:
        return {"ok": False, "error": "these points do not define a floor plane: check the pairs", "n": len(pts)}
    errors = []
    for p in pts:
        q = apply(H, p["u"], p["v"])
        errors.append(round(float(np.hypot(q[0] - p["x"], q[1] - p["y"])), 3) if q else None)
    good = [e for e in errors if e is not None]
    rms = float(np.sqrt(np.mean(np.square(good)))) if good else None
    if len(pts) == 4:
        warnings.append("4 pairs fit exactly: add 2 or more to measure the accuracy")
    elif rms is not None and rms > 0.5:
        warnings.append("large error: one pair is probably wrong, check the one with the biggest error")
    return {"ok": True, "H": H.tolist(), "Hinv": np.linalg.inv(H).tolist(), "errors_m": errors,
            "rms_m": round(rms, 3) if rms is not None else None, "n": len(pts), "warnings": warnings}


class Calibrations:
    def __init__(self, path):
        self.path = path
        self.data = json.loads(path.read_text()) if path.exists() else {}

    def get(self, cid):
        return self.data.get(cid)

    def save(self, cid, points, aspect=None):
        r = solve(points)
        if not r["ok"]:
            return r
        self.data[cid] = {"H": r["H"], "Hinv": r["Hinv"], "points": points, "rms_m": r["rms_m"], "n": r["n"],
                          "aspect": aspect, "ts": time.time()}
        self.path.write_text(json.dumps(self.data, indent=1))
        return {**r, "saved": True}

    def delete(self, cid):
        self.data.pop(cid, None)
        self.path.write_text(json.dumps(self.data, indent=1))

    def to_floor(self, cid, u, v):
        c = self.data.get(cid)
        return apply(c["H"], u, v) if c else None
