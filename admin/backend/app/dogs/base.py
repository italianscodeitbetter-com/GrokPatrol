"""Common robot dog interface and the go-to controller shared by the simulator and the Go1."""
import math
import threading
import time

from ..config import VMAX, WMAX, wrap


def clamp(v, m):
    return max(-m, min(m, v))


class Dog:
    kind = "base"

    def __init__(self, vmax=VMAX, wmax=WMAX, tol=0.25):
        self.lock = threading.Lock()
        self.vmax, self.wmax, self.tol = vmax, wmax, tol
        self.target = None            # (x, y, yaw or None)
        self._arrived = False
        self.armed = True             # False after an emergency stop
        self.manual = (0.0, 0.0, 0.0, 0.0)  # vx, vy, wz, valid_until
        self.posture = "standing"     # standing | down | rising
        self.cmd = (0.0, 0.0, 0.0)
        self._turning = False
        self.odom_source = "model"
        self.yaw_tol = 0.15
        self.min_wz = 0.0
        self.home_pose = (0.0, 0.0, 0.0)  # the home spot on the map, set by main

    # implemented by drivers
    def pose(self):
        raise NotImplementedError

    def connected(self) -> bool:
        return True

    def battery(self):
        return None

    def zero_here(self):
        """Declare the current pose as home (0, 0, 0)."""
        raise NotImplementedError

    # commands
    def go_to(self, x, y, yaw=None):
        with self.lock:
            self.target = (float(x), float(y), None if yaw is None else float(yaw))
            self._arrived = False
            self._turning = False
            self._at_xy = None    # time the position was reached; then only the final heading is corrected

    def arrived(self) -> bool:
        return self._arrived

    def stop(self):
        with self.lock:
            self.target = None
            self._arrived = False

    def estop(self):
        with self.lock:
            self.armed = False
            self.target = None
            self.manual = (0.0, 0.0, 0.0, 0.0)

    def reset_estop(self):
        with self.lock:
            self.armed = True

    def drive(self, vx, vy, wz):
        """Manual teleop. Each call is valid for 0.6 s (dead man)."""
        with self.lock:
            self.manual = (clamp(vx, self.vmax), clamp(vy, self.vmax * 0.6), clamp(wz, self.wmax), time.time() + 0.6)

    def manual_active(self) -> bool:
        return time.time() < self.manual[3]

    def lie_down(self):
        with self.lock:
            self.target = None
            self.posture = "down"

    def stand_up(self):
        with self.lock:
            self.posture = "rising"
            self._rise_t = time.time()

    def moving(self) -> bool:
        vx, vy, wz = self.cmd
        return abs(vx) + abs(vy) + abs(wz) > 1e-3

    def status(self) -> dict:
        x, y, yaw = self.pose()
        return {
            "kind": self.kind, "connected": self.connected(), "armed": self.armed,
            "x": round(x, 3), "y": round(y, 3), "yaw": round(yaw, 3),
            "target": self.target, "moving": self.moving(), "manual": self.manual_active(),
            "posture": self.posture, "battery": self.battery(), "odom": self.odom_source,
            "link": getattr(self, "link", "ok" if self.connected() else "no data"),
            "cmd": [round(c, 3) for c in self.cmd],
        }

    # controller
    def compute_cmd(self, pose):
        """Velocity command for this control step. Called by the driver loop."""
        with self.lock:
            if not self.armed or self.posture != "standing":
                self.cmd = (0.0, 0.0, 0.0)
                return self.cmd
            if self.manual_active():
                self.cmd = self.manual[:3]
                return self.cmd
            if self.target is None:
                self.cmd = (0.0, 0.0, 0.0)
                return self.cmd
            x, y, yaw = pose
            tx, ty, tyaw = self.target
            dx, dy = tx - x, ty - y
            d = math.hypot(dx, dy)
            at_xy = getattr(self, "_at_xy", None)
            if d < self.tol and at_xy is None:
                self._at_xy = at_xy = time.time()
            # once there, stay "there" unless pushed well away: turning in place drifts a few cm
            if at_xy is not None and d < self.tol * 2.5:
                if tyaw is not None and time.time() - at_xy < 6.0:
                    e = wrap(tyaw - yaw)
                    if abs(e) > self.yaw_tol:
                        wz = clamp(1.5 * e, self.wmax)
                        if abs(wz) < self.min_wz:
                            wz = self.min_wz if wz > 0 else -self.min_wz
                        self.cmd = (0.0, 0.0, wz)
                        return self.cmd
                self.target = None
                self._arrived = True
                self.cmd = (0.0, 0.0, 0.0)
                return self.cmd
            self._at_xy = None
            e = wrap(math.atan2(dy, dx) - yaw)
            # turn in place when badly misaligned, with hysteresis so it does not chatter
            if abs(e) > (0.35 if self._turning else 0.7):
                self._turning = True
                wz = clamp(1.8 * e, self.wmax)
                if abs(wz) < self.min_wz:
                    wz = self.min_wz if wz > 0 else -self.min_wz
                self.cmd = (0.0, 0.0, wz)
                return self.cmd
            self._turning = False
            v = min(self.vmax, 0.6 * d + 0.08) * max(0.0, math.cos(e))
            self.cmd = (v, 0.0, clamp(1.8 * e, self.wmax))
            return self.cmd

    def start(self):
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        raise NotImplementedError
