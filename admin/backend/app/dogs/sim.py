"""Kinematic simulator with the same controller, speed caps and accelerations as the real dog."""
import math
import time

from .base import Dog
from ..config import wrap


class SimDog(Dog):
    kind = "sim"

    def __init__(self, **kw):
        super().__init__(**kw)
        self.x = self.y = self.yaw = 0.0
        self.v = [0.0, 0.0, 0.0]
        self.odom_source = "sim"

    def pose(self):
        return (self.x, self.y, self.yaw)

    def battery(self):
        return 100

    def zero_here(self):
        self.teleport(*self.home_pose)

    def teleport(self, x, y, yaw=0.0):
        self.x, self.y, self.yaw = x, y, yaw
        self.v = [0.0, 0.0, 0.0]

    def _run(self):
        dt = 1 / 30
        acc = (0.8, 0.8, 2.5)  # m/s2, m/s2, rad/s2
        while True:
            t0 = time.time()
            if self.posture == "rising" and t0 - getattr(self, "_rise_t", t0) > 1.5:
                self.posture = "standing"
            cmd = self.compute_cmd(self.pose())
            for i in range(3):
                dv = max(-acc[i] * dt, min(acc[i] * dt, cmd[i] - self.v[i]))
                self.v[i] += dv
            vx, vy, wz = self.v
            self.x += (vx * math.cos(self.yaw) - vy * math.sin(self.yaw)) * dt
            self.y += (vx * math.sin(self.yaw) + vy * math.cos(self.yaw)) * dt
            self.yaw = wrap(self.yaw + wz * dt)
            time.sleep(max(0.0, dt - (time.time() - t0)))
