#!/usr/bin/env python3
"""
Da eseguire SULLA NANO DELLA TESTA del Go1 (unitree@192.168.123.13).
Legge la camera stereo e la pubblica come stream MJPEG su http://192.168.123.13:8080

Uso:  python3 stream_nano.py [device] [--left]
      device = 0 o 1 (default 0)
      --left = invia solo l'immagine dell'obiettivo sinistro (piu' leggera)
"""
import sys, threading, time
import cv2
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

dev = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 0
only_left = "--left" in sys.argv

cap = cv2.VideoCapture(dev, cv2.CAP_V4L2)
cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1856)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 800)
if not cap.isOpened():
    print(f"ERRORE: impossibile aprire /dev/video{dev}. "
          "Hai fermato camerarosnode? (pkill -f camerarosnode)")
    sys.exit(1)

latest = None
lock = threading.Lock()

def grab():
    global latest
    while True:
        ok, frame = cap.read()
        if not ok:
            time.sleep(0.01)
            continue
        if only_left:
            frame = frame[:, : frame.shape[1] // 2]
            frame = cv2.resize(frame, (640, 552))
        else:
            frame = cv2.resize(frame, (928, 400))
        ok, jpg = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 70])
        if ok:
            with lock:
                latest = jpg.tobytes()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        last = None
        try:
            while True:
                with lock:
                    data = latest
                if data is None or data is last:
                    time.sleep(0.01)
                    continue
                last = data
                self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: "
                                 + str(len(data)).encode() + b"\r\n\r\n" + data + b"\r\n")
        except (BrokenPipeError, ConnectionResetError):
            pass

class Server(ThreadingMixIn, HTTPServer):
    daemon_threads = True

threading.Thread(target=grab, daemon=True).start()
print(f"Camera /dev/video{dev} attiva. Apri http://192.168.123.13:8080 (Ctrl+C per fermare)")
Server(("0.0.0.0", 8080), Handler).serve_forever()
