"""Path planning on the room's occupancy grid (from scripts/import_step.py): A* with a safety margin."""
import heapq
import math

import numpy as np


class Planner:
    def __init__(self, grid_file, robot_radius=0.32, soft_margin=0.6, res=0.1, extra=()):
        d = np.load(grid_file)
        occ, origin, fine = d["occ"].copy(), d["origin"], float(d["res"])
        # furniture added in the site file (display cases, benches) is not in the CAD model
        ny0, nx0 = occ.shape
        gy, gx = np.mgrid[0:ny0, 0:nx0]
        wx, wy = origin[0] + (gx + 0.5) * fine, origin[1] + (gy + 0.5) * fine
        for cx, cy, w, dd, yaw in extra:
            c, sn = math.cos(-yaw), math.sin(-yaw)
            lx, ly = c * (wx - cx) - sn * (wy - cy), sn * (wx - cx) + c * (wy - cy)
            occ |= (np.abs(lx) <= w / 2) & (np.abs(ly) <= dd / 2)
        k = max(1, int(round(res / fine)))
        ny, nx = occ.shape[0] // k, occ.shape[1] // k
        occ = occ[:ny * k, :nx * k].reshape(ny, k, nx, k).any(axis=(1, 3))  # coarser, conservative
        self.res, self.origin = fine * k, origin
        self.hard = self._dilate(occ, robot_radius / self.res)
        soft = self._dilate(occ, soft_margin / self.res)
        self.cost = np.where(soft, 4.0, 1.0)
        self.ny, self.nx = occ.shape

    @staticmethod
    def _dilate(occ, r):
        r = int(math.ceil(r))
        out = occ.copy()
        for dj in range(-r, r + 1):
            for di in range(-r, r + 1):
                if dj * dj + di * di <= r * r:
                    out |= np.roll(np.roll(occ, dj, 0), di, 1)
        return out

    def cell(self, x, y):
        return int((y - self.origin[1]) / self.res), int((x - self.origin[0]) / self.res)

    def world(self, j, i):
        return (float(self.origin[0] + (i + 0.5) * self.res), float(self.origin[1] + (j + 0.5) * self.res))

    def free(self, j, i):
        return 0 <= j < self.ny and 0 <= i < self.nx and not self.hard[j, i]

    def nearest_free(self, j, i, max_r=15):
        if self.free(j, i):
            return j, i
        for r in range(1, max_r):
            best = None
            for dj in range(-r, r + 1):
                for di in (-r, r) if abs(dj) != r else range(-r, r + 1):
                    if self.free(j + dj, i + di):
                        d = dj * dj + di * di
                        if best is None or d < best[0]:
                            best = (d, j + dj, i + di)
            if best:
                return best[1], best[2]
        return None

    def line_free(self, a, b):
        (x0, y0), (x1, y1) = a, b
        n = max(2, int(math.hypot(x1 - x0, y1 - y0) / (self.res * 0.5)))
        for t in np.linspace(0, 1, n):
            j, i = self.cell(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t)
            if not self.free(j, i):
                return False
        return True

    def plan(self, start, goal):
        """List of (x, y) waypoints after the start, ending at the goal. None if there is no way."""
        if self.line_free(start, goal):
            return [tuple(goal)]
        s = self.nearest_free(*self.cell(*start))
        g = self.nearest_free(*self.cell(*goal))
        if not s or not g:
            return None
        steps = [(-1, 0, 1), (1, 0, 1), (0, -1, 1), (0, 1, 1), (-1, -1, 1.414), (-1, 1, 1.414), (1, -1, 1.414), (1, 1, 1.414)]
        h = lambda c: math.hypot(c[0] - g[0], c[1] - g[1])
        openq, came, cost = [(h(s), 0.0, s)], {s: None}, {s: 0.0}
        while openq:
            _, c, cur = heapq.heappop(openq)
            if cur == g:
                break
            if c > cost.get(cur, 1e18):
                continue
            for dj, di, w in steps:
                nxt = (cur[0] + dj, cur[1] + di)
                if not self.free(*nxt):
                    continue
                nc = c + w * self.cost[nxt]
                if nc < cost.get(nxt, 1e18):
                    cost[nxt], came[nxt] = nc, cur
                    heapq.heappush(openq, (nc + h(nxt), nc, nxt))
        if g not in came:
            return None
        cells, cur = [], g
        while cur is not None:
            cells.append(cur)
            cur = came[cur]
        pts = [self.world(*c) for c in reversed(cells)]
        # shortcut: keep only the turns needed to stay clear
        out, k = [], 0
        anchor = tuple(start)
        while k < len(pts) - 1:
            far = k + 1
            for m in range(len(pts) - 1, k, -1):
                if self.line_free(anchor, pts[m]):
                    far = m
                    break
            out.append(pts[far])
            anchor, k = pts[far], far
        out[-1] = tuple(goal)
        return out
