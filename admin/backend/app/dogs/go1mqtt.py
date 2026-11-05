"""Unitree Go1 driven over MQTT, the channel the Unitree app uses (broker on the dog, 192.168.12.1:1883).

Works on Go1 units where the UDP SDK only answers after L1 + START. Topics (from the community, may change
with the firmware):
  controller/action   "standUp", "standDown", "walk", "recoverStand", "damping", ...
  controller/stick    4 float32 little-endian [lx, rx, ry, ly] in -1..1, sent about 20 times a second;
                      ly forward, lx right, rx turn right, ry head tilt. If the sticks stop, the dog stops.
  bms/state           the battery struct of the SDK (34 bytes): SOC is byte 3.
There is no odometry on this channel: the pose is integrated from the commands sent (dead reckoning).
"""
import math
import struct
import threading
import time

import paho.mqtt.client as mqtt

from .base import Dog, clamp
from ..config import env, env_float, wrap


class Go1MqttDog(Dog):
    kind = "go1"

    def __init__(self, **kw):
        super().__init__(tol=env_float("GO1_TOL", 0.35), **kw)
        self.host = env("GO1_MQTT_HOST", "192.168.12.1")
        self.vx_full = env_float("GO1_STICK_VX_FULL", 1.0)    # m/s at full stick (to confirm on the dog)
        self.vy_full = env_float("GO1_STICK_VY_FULL", 0.6)
        self.wz_full = env_float("GO1_STICK_WZ_FULL", 2.0)    # rad/s at full stick
        self.x = self.y = self.yaw = 0.0
        self.origin_set = False
        self.soc = None
        self.mode = None            # last action sent: standUp, walk, standDown
        self.link = "no data"
        self.odom_source = "commands"
        self.last_msg = 0.0
        self.min_wz = 0.25
        self.yaw_tol = 0.25
        try:
            self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="ronda")
        except AttributeError:
            self.client = mqtt.Client(client_id="ronda")
        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect
        self.client.on_message = self._on_message
        self.client.reconnect_delay_set(1, 5)
        self._connected = False

    # mqtt ---------------------------------------------------------------------------------
    def _on_connect(self, c, u, flags, rc, props=None):
        self._connected = True
        self.link = "mqtt"
        for t in ("bms/state", "robot/state", "controller/current_action", "usys/run"):
            c.subscribe(t)

    def _on_disconnect(self, c, u, *a):
        self._connected = False
        self.link = "no data"

    def _on_message(self, c, u, msg):
        self.last_msg = time.time()
        if msg.topic == "bms/state" and len(msg.payload) >= 4 and any(msg.payload):
            self.soc = msg.payload[3]

    def connected(self):
        return self._connected

    def battery(self):
        return self.soc

    def action(self, name):
        self.client.publish("controller/action", name, qos=1)
        self.mode = name

    def sticks(self, lx=0.0, rx=0.0, ry=0.0, ly=0.0):
        self.client.publish("controller/stick", struct.pack("<ffff", lx, rx, ry, ly), qos=0)

    # pose: integrated from the commands, placed on the home spot ---------------------------
    def pose(self):
        return (self.x, self.y, self.yaw)

    def zero_here(self):
        self.x, self.y, self.yaw = self.home_pose
        self.origin_set = True

    # posture --------------------------------------------------------------------------------
    def stand_up(self):
        with self.lock:
            self.posture = "rising"
            self._rise_t = time.time()
        self.action("standUp")

    def lie_down(self):
        with self.lock:
            self.target = None
            self.posture = "down"
        self.sticks()
        self.action("standDown")

    def start(self):
        try:
            self.client.connect_async(self.host, 1883, keepalive=20)
            self.client.loop_start()
        except Exception:
            pass
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        hz = 20
        dt = 1.0 / hz
        if not self.origin_set:
            self.zero_here()
        while True:
            t0 = time.time()
            if self.posture == "rising" and t0 - getattr(self, "_rise_t", t0) > 2.0:
                self.posture = "standing"
            vx, vy, wz = self.compute_cmd(self.pose())
            if not self._connected:
                vx = vy = wz = 0.0
                self.cmd = (0.0, 0.0, 0.0)
            moving = abs(vx) + abs(vy) + abs(wz) > 1e-3
            if moving and self.mode not in ("walk", "run", "climb"):
                self.action("walk")   # sticks move the dog only in a walking mode
            if self._connected:
                self.sticks(lx=clamp(-vy / self.vy_full, 1.0), rx=clamp(-wz / self.wz_full, 1.0), ly=clamp(vx / self.vx_full, 1.0))
            # dead reckoning from what was asked
            self.x += (vx * math.cos(self.yaw) - vy * math.sin(self.yaw)) * dt
            self.y += (vx * math.sin(self.yaw) + vy * math.cos(self.yaw)) * dt
            self.yaw = wrap(self.yaw + wz * dt)
            time.sleep(max(0.0, dt - (time.time() - t0)))
