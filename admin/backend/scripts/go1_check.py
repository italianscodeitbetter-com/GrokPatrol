"""Go1 connection check: reads the dog for a few seconds WITHOUT moving it. Run from admin/backend.

  .venv/bin/python scripts/go1_check.py              # wifi (laptop on the dog's hotspot)
  .venv/bin/python scripts/go1_check.py --wired      # ethernet (laptop on 192.168.123.x)
  .venv/bin/python scripts/go1_check.py --turn       # then a slow 2 s turn on the spot, after confirmation
"""
import argparse
import math
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app" / "vendor"))
from ucl.common import decode_sn, decode_version  # noqa: E402
from ucl.enums import GaitType, MotorModeHigh  # noqa: E402
from ucl.highCmd import highCmd  # noqa: E402
from ucl.highState import highState  # noqa: E402
from ucl.unitreeConnection import HIGH_WIFI_DEFAULTS, HIGH_WIRED_DEFAULTS, unitreeConnection  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--wired", action="store_true", help="ethernet instead of wifi")
ap.add_argument("--ip", help="dog address, if not the default")
ap.add_argument("--seconds", type=float, default=3.0)
ap.add_argument("--turn", action="store_true", help="slow turn on the spot for 2 s, after asking")
args = ap.parse_args()

settings = HIGH_WIRED_DEFAULTS if args.wired else HIGH_WIFI_DEFAULTS
if args.ip:
    settings = (settings[0], args.ip, settings[2], settings[3])
dog_ip, port = settings[1], settings[2]
conn = unitreeConnection(settings)
conn.startRecv()
cmd, st = highCmd(), highState()
cmd.levelFlag = 0xEE
cmd.gaitType = GaitType.TROT

print(f"\n  Talking to the Go1 at {dog_ip}:{port} ({'ethernet' if args.wired else 'wifi'}) for {args.seconds:.0f} s, no motion...")
got = bad = 0
t0 = time.time()
while time.time() - t0 < args.seconds:
    conn.send(cmd.buildCmd())  # mode IDLE, zero speed: the dog stays as it is
    for packet in conn.getData():
        try:
            st.parseData(packet)
            got += 1
        except Exception:
            bad += 1
    time.sleep(0.01)

if got and str(st.head) == "0x0":
    print("""
  The dog answers, but with an EMPTY state: it is on and waiting for sport mode.
  On the remote press L1 + START together (the dog stands up), then run this again.
""")
    sys.exit(2)
if not got:
    print(f"""
  NO DATA from the dog ({bad} unreadable packets).
  1. Is the laptop on the right network?  {'ethernet with IP 192.168.123.162, mask 255.255.255.0' if args.wired else "wifi 'Unitree_Go...' of this dog"}
  2. ping {dog_ip}   must answer
  3. macOS firewall: allow incoming connections for Python if asked
  4. Is the dog on and standing? Ask the museum staff.
""")
    sys.exit(1)

rate = got / args.seconds
yaw = math.degrees(st.imu.rpy[2])
print(f"""
  CONNECTED  ·  {rate:.0f} messages/s{f'  ·  {bad} unreadable' if bad else ''}
  Serial       {decode_sn(st.SN)}
  Firmware     {decode_version(st.version)}
  Battery      {st.bms.SOC} %
  Mode         {st.mode}  (0 idle/stand, 1 force stand, 2 walking, 5 lying, 6 standing up, 7 damping)
  Odometry     x {st.position[0]:.3f} m   y {st.position[1]:.3f} m
  Heading      {yaw:.1f} degrees
  Foot forces  {st.footForce}
""")

if args.turn:
    ok = input("  The dog will turn on the spot at 0.3 rad/s for 2 s. Is the area clear and staff ready? [y/N] ")
    if ok.strip().lower() not in ("y", "s", "yes", "si", "sì"):
        print("  Skipped.")
        sys.exit(0)
    yaw0 = st.imu.rpy[2]
    t0 = time.time()
    while time.time() - t0 < 3.0:
        moving = time.time() - t0 < 2.0
        cmd.mode = MotorModeHigh.VEL_WALK if moving else MotorModeHigh.IDLE
        cmd.velocity, cmd.yawSpeed, cmd.footRaiseHeight = [0.0, 0.0], 0.3 if moving else 0.0, 0.08
        conn.send(cmd.buildCmd())
        for packet in conn.getData():
            try:
                st.parseData(packet)
            except Exception:
                pass
        time.sleep(0.01)
    turned = math.degrees(math.atan2(math.sin(st.imu.rpy[2] - yaw0), math.cos(st.imu.rpy[2] - yaw0)))
    print(f"  Turned {turned:.0f} degrees (about 30 expected). Commands reach the dog: you can start Ronda.\n")
