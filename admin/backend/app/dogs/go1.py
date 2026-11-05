"""Unitree Go1 driver over the high-level UDP protocol (free-dog-sdk, vendored in server/vendor/ucl).

Wifi: the laptop joins the dog's hotspot (Unitree_Go...), dog at 192.168.12.1.
Wired: ethernet to the dog, laptop on 192.168.123.x, dog at 192.168.123.161.
Pose: the dog's own odometry (HighState.position) and IMU yaw. If the firmware does not
report position, it falls back to integrating velocity with the IMU heading.
"""
import math
import sys
import time
from pathlib import Path

from .base import Dog
from ..config import GO1_LINK, env, env_float, wrap

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "vendor"))

from ucl.enums import GaitType, MotorModeHigh, SpeedLevel  # noqa: E402
from ucl.highCmd import highCmd  # noqa: E402
from ucl.highState import highState  # noqa: E402
from ucl.unitreeConnection import (HIGH_WIFI_DEFAULTS, HIGH_WIRED_DEFAULTS,  # noqa: E402
                                   unitreeConnection)


class Go1Dog(Dog):
    kind = "go1"

    def __init__(self, **kw):
        super().__init__(tol=env_float("GO1_TOL", 0.3), **kw)
        settings = HIGH_WIRED_DEFAULTS if GO1_LINK == "wired" else HIGH_WIFI_DEFAULTS
        if env("GO1_IP"):
            settings = (settings[0], env("GO1_IP"), settings[2], settings[3])
        self.conn = unitreeConnection(settings)
        self.conn.startRecv()
        self.hcmd = highCmd()
        self.hstate = highState()
        self.last_rx = 0.0
        self.raw = (0.0, 0.0, 0.0)       # odometry frame of the dog
        self.origin = None               # raw pose declared as home
        self.integ = [0.0, 0.0]          # integrated position (fallback)
        self.mode = env("GO1_ODOM", "auto")  # auto | state | integrate
        self.odom_source = "state" if self.mode != "integrate" else "integrate"
        self._moved_s = 0.0
        self._pos_at_move = None
        self.scale = env_float("GO1_ODOM_SCALE", 1.0)
        self.soc = None
        self.last_any = 0.0
        self.link = "no data"   # no data | standby (on, waiting for L1 + START or an SDK trigger) | ok

    def connected(self):
        return time.time() - self.last_rx < 1.0

    def battery(self):
        return self.soc

    def _raw_xy(self):
        if self.odom_source == "integrate":
            return self.integ[0], self.integ[1]
        return self.raw[0], self.raw[1]

    def pose(self):
        """Map pose: odometry relative to where 'Set home here' was pressed, placed on the home spot."""
        rx, ry = self._raw_xy()
        ryaw = self.raw[2]
        if self.origin is None:
            return (rx, ry, ryaw)
        ox, oy, oyaw = self.origin
        dx, dy = rx - ox, ry - oy
        c, s = math.cos(-oyaw), math.sin(-oyaw)
        lx, ly, lyaw = c * dx - s * dy, s * dx + c * dy, wrap(ryaw - oyaw)
        hx, hy, hyaw = self.home_pose
        ch, sh = math.cos(hyaw), math.sin(hyaw)
        return (hx + ch * lx - sh * ly, hy + sh * lx + ch * ly, wrap(hyaw + lyaw))

    def zero_here(self):
        rx, ry = self._raw_xy()
        self.origin = (rx, ry, self.raw[2])

    def _read(self, dt):
        packets = self.conn.getData()
        if not packets:
            if time.time() - self.last_any > 1.0:
                self.link = "no data"
            return
        self.last_any = time.time()
        if packets[-1][:2] != b"\xfe\xef":
            # the dog answers with an empty state until sport mode starts (remote: L1 + START)
            self.link = "standby"
            return
        try:
            self.hstate.parseData(packets[-1])
        except Exception:
            return
        self.link = "ok"
        self.last_rx = time.time()
        st = self.hstate
        yaw = st.imu.rpy[2]
        px, py = st.position[0], st.position[1]
        if not all(map(math.isfinite, (px, py, yaw))):
            return
        self.raw = (px, py, yaw)
        try:
            self.soc = int(st.bms.SOC)
        except Exception:
            pass
        if self.origin is None:
            self.zero_here()
            self.integ = [px, py]
        # fallback odometry: integrate the measured (or commanded) body velocity on the IMU heading
        vx, vy = st.velocity[0], st.velocity[1]
        if not (math.isfinite(vx) and math.isfinite(vy)) or (abs(vx) + abs(vy) < 1e-4 and self.moving()):
            vx, vy = self.cmd[0], self.cmd[1]
        self.integ[0] += (vx * math.cos(yaw) - vy * math.sin(yaw)) * dt * self.scale
        self.integ[1] += (vx * math.sin(yaw) + vy * math.cos(yaw)) * dt * self.scale
        # auto: if the dog walked for 2 s and the reported position did not change, switch to integration
        if self.mode == "auto" and self.odom_source == "state" and abs(self.cmd[0]) > 0.05:
            if self._pos_at_move is None:
                self._pos_at_move = (px, py)
            self._moved_s += dt
            if self._moved_s > 2.0:
                if math.hypot(px - self._pos_at_move[0], py - self._pos_at_move[1]) < 0.03:
                    # the integrated estimate shares the same frame and has tracked the real motion
                    self.odom_source = "integrate"
                self._moved_s, self._pos_at_move = 0.0, None

    def _run(self):
        hz = 100
        dt = 1.0 / hz
        h = self.hcmd
        h.levelFlag = 0xEE   # HIGHLEVEL, as InitCmdData sets it in unitree_legged_sdk
        h.gaitType = GaitType.TROT
        h.speedLevel = SpeedLevel.LOW_SPEED
        self.conn.send(h.buildCmd())  # tells the dog where to answer
        while True:
            t0 = time.time()
            self._read(dt)
            vx, vy, wz = self.compute_cmd(self.pose())
            if not self.connected():
                vx = vy = wz = 0.0
                self.cmd = (0.0, 0.0, 0.0)
            if not self.connected():
                h.mode, h.velocity, h.yawSpeed = MotorModeHigh.IDLE, [0.0, 0.0], 0.0
            elif self.posture == "down":
                h.mode, h.velocity, h.yawSpeed = MotorModeHigh.STAND_DOWN, [0.0, 0.0], 0.0
            elif self.posture == "rising":
                h.mode, h.velocity, h.yawSpeed = MotorModeHigh.STAND_UP, [0.0, 0.0], 0.0
                if t0 - getattr(self, "_rise_t", t0) > 2.0:
                    self.posture = "standing"
            elif self.armed and (self.target is not None or self.manual_active()):
                h.mode = MotorModeHigh.VEL_WALK
                h.gaitType = GaitType.TROT
                h.footRaiseHeight = 0.08
                h.velocity, h.yawSpeed = [float(vx), float(vy)], float(wz)
            else:
                h.mode, h.velocity, h.yawSpeed = MotorModeHigh.IDLE, [0.0, 0.0], 0.0
            try:
                self.conn.send(h.buildCmd())
            except OSError:
                pass  # network hiccup: the dog stops by itself without commands
            time.sleep(max(0.0, dt - (time.time() - t0)))
