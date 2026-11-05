"""The dog simulated in MuJoCo: physics and a trained walking policy run in sim/world.py.

Like the real Go1, this driver only sends velocity commands (vx, vy, wz) and reads back odometry.
"""
import time

from .base import Dog


class MujocoDog(Dog):
    kind = "mujoco"

    def __init__(self, **kw):
        super().__init__(**kw)
        self.x = self.y = self.yaw = 0.0
        self.last_rx = 0.0
        self.pending_teleport = None
        self.odom_source = "mujoco"
        self.yaw_tol = 0.25   # a learned gait does not turn by hundredths of a radian
        self.min_wz = 0.3

    def pose(self):
        return (self.x, self.y, self.yaw)

    def connected(self):
        return time.time() - self.last_rx < 1.0

    def battery(self):
        return 100 if self.connected() else None

    def zero_here(self):
        pass  # in the simulator the map frame is the world frame

    def teleport(self, x, y, yaw=0.0):
        self.pending_teleport = (x, y, yaw)
        self.x, self.y, self.yaw = x, y, yaw

    def update(self, x, y, yaw):
        self.x, self.y, self.yaw = x, y, yaw
        self.last_rx = time.time()

    def _run(self):
        while True:
            t0 = time.time()
            if self.posture == "rising" and t0 - getattr(self, "_rise_t", t0) > 1.5:
                self.posture = "standing"
            self.compute_cmd(self.pose())
            if not self.connected():
                self.cmd = (0.0, 0.0, 0.0)
            time.sleep(0.02)
