"""The Go1's head camera (Jetson Nano) in Ronda, through the dog's Raspberry Pi.

The Mac on the dog's wifi reaches the Pi (192.168.12.1) but not always the Nano (192.168.123.13): the
stream is read over an SSH channel through the Pi, so no route or network change is needed.
"""
import io
import threading
import time
from pathlib import Path

from .config import REPO, env

PI = env("GO1_PI_HOST", "192.168.12.1")
NANO = env("GO1_NANO_HOST", "192.168.123.13")
PI_USER, PI_PASS = env("GO1_PI_USER", "pi"), env("GO1_PI_PASS", "123")
NANO_USER, NANO_PASS = env("GO1_NANO_USER", "unitree"), env("GO1_NANO_PASS", "123")
KIT = REPO / "tools" / "nano"   # the Nano kit stays in the repo root


class DogCamera:
    def __init__(self, cams, log, cid="dog"):
        self.cams, self.log, self.cid = cams, log, cid
        self.state = "off"          # off | starting | streaming | error
        self.error = None
        self.fps = 0.0
        self._stop = threading.Event()
        self._thread = None
        self.loop = None

    def status(self):
        return {"state": self.state, "error": self.error, "fps": round(self.fps, 1)}

    def _ssh(self, host, user, pw, sock=None):
        import paramiko
        c = paramiko.SSHClient()
        c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        c.connect(host, username=user, password=pw, timeout=8, sock=sock, allow_agent=False, look_for_keys=False)
        return c

    def _nano(self):
        pi = self._ssh(PI, PI_USER, PI_PASS)
        ch = pi.get_transport().open_channel("direct-tcpip", (NANO, 22), ("127.0.0.1", 0))
        return pi, self._ssh(NANO, NANO_USER, NANO_PASS, sock=ch)

    def start(self, device=0, left=True):
        """Start the stream on the Nano (frees the camera from camerarosnode) and read it."""
        self.state, self.error = "starting", None
        try:
            pi, nano = self._nano()
            sftp = nano.open_sftp()
            for f in ("stream_nano.py", "avvia_camera_nano.sh"):
                sftp.put(str(KIT / f), f"/home/{NANO_USER}/{f}")
            sftp.close()
            _, o, _ = nano.exec_command("pgrep -f stream_nano.py >/dev/null && echo running || echo stopped", timeout=10)
            if o.read().decode().strip() != "running":
                nano.exec_command(f"nohup bash ~/avvia_camera_nano.sh {int(device)} {'--left' if left else ''} > ~/stream.log 2>&1 &", timeout=10)
                time.sleep(5)
            nano.close()
            pi.close()
        except Exception as e:
            self.state, self.error = "error", f"start: {e!r}"[:200]
            self.log.add("dogcam.error", f"Dog camera: {self.error}", level="error")
            return self.status()
        self.log.add("dogcam.start", "Dog camera: stream started on the head Jetson (front camera, left lens)")
        if not self._thread or not self._thread.is_alive():
            self._stop.clear()
            self._thread = threading.Thread(target=self._read, daemon=True)
            self._thread.start()
        return self.status()

    def stop(self):
        self._stop.set()
        try:
            pi, nano = self._nano()
            nano.exec_command("pkill -f stream_nano.py", timeout=10)
            nano.close()
            pi.close()
        except Exception as e:
            self.error = f"stop: {e!r}"[:200]
        self.state = "off"
        self.log.add("dogcam.stop", "Dog camera: stream stopped (Unitree's obstacle cameras come back at the next reboot)")
        return self.status()

    def _read(self):
        """Read the MJPEG stream through the Pi and hand each frame to the camera registry."""
        while not self._stop.is_set():
            pi = None
            try:
                pi = self._ssh(PI, PI_USER, PI_PASS)
                ch = pi.get_transport().open_channel("direct-tcpip", (NANO, 8080), ("127.0.0.1", 0))
                ch.settimeout(5)
                ch.sendall(b"GET / HTTP/1.0\r\nHost: nano\r\n\r\n")
                buf, n, t0 = b"", 0, time.time()
                self.state = "streaming"
                while not self._stop.is_set():
                    chunk = ch.recv(65536)
                    if not chunk:
                        raise ConnectionError("stream closed")
                    buf += chunk
                    while True:
                        a = buf.find(b"\xff\xd8")
                        b = buf.find(b"\xff\xd9", a + 2) if a >= 0 else -1
                        if a < 0 or b < 0:
                            break
                        jpeg, buf = buf[a:b + 2], buf[b + 2:]
                        self.cams.ingest(self.cid, jpeg)
                        n += 1
                    if len(buf) > 4_000_000:
                        buf = b""
                    if time.time() - t0 >= 2:
                        self.fps, n, t0 = n / (time.time() - t0), 0, time.time()
            except Exception as e:
                if not self._stop.is_set():
                    self.state, self.error = "error", f"stream: {e!r}"[:200]
                    time.sleep(3)
            finally:
                try:
                    pi and pi.close()
                except Exception:
                    pass
