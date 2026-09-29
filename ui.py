"""Settings page for solocam: http://127.0.0.1:8765 (local only).

Changes apply live (solocam reads `a.<name>` every frame) and are saved to settings.json,
which overrides the command line defaults on the next start. Uploaded backgrounds go to bg/.
While the page shows the preview it counts as a viewer, so the pipeline runs for it.
"""
import json
import os
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SETTINGS = os.path.join(HERE, "settings.json")
BG_DIR = os.path.join(HERE, "bg")
# name -> (type, min, max); bg is checked separately
LIVE = {"grow": (int, 1, 99), "feather": (int, 1, 99), "below": (float, 0, 3),
        "cut": (float, 0.2, 1), "hold": (float, 0, 10)}


def load(a):
    """Apply saved settings over the command line defaults."""
    try:
        with open(SETTINGS, encoding="utf-8") as f:
            saved = json.load(f)
    except (OSError, ValueError):
        return
    for k, v in saved.items():
        try:
            apply(a, k, v)
        except ValueError as e:
            print("settings.json:", e)


def apply(a, k, v):
    if k == "bg":
        v = str(v)
        if not (v == "blur" or re.fullmatch(r"#[0-9a-fA-F]{6}", v) or os.path.isfile(v)):
            raise ValueError(f"bad bg {v!r}")
    elif k in LIVE:
        t, lo, hi = LIVE[k]
        v = min(max(t(v), lo), hi)
    else:
        raise ValueError(f"unknown setting {k!r}")
    setattr(a, k, v)


def save(a):
    with open(SETTINGS, "w", encoding="utf-8") as f:
        json.dump({k: getattr(a, k) for k in ["bg", *LIVE]}, f, ensure_ascii=False, indent=1)


def start(a, state, port):
    lock = threading.Lock()

    class H(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, body, ctype="application/json", code=200):
            if isinstance(body, (dict, list)):
                body = json.dumps(body, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def body(self):
            return self.rfile.read(int(self.headers.get("Content-Length", 0)))

        def foreign(self):
            """Other web pages must not drive the camera: reject cross-site and rebound-DNS requests."""
            bad = (self.headers.get("Sec-Fetch-Site", "none") not in ("same-origin", "none")
                   or self.headers.get("Host") not in (f"127.0.0.1:{port}", f"localhost:{port}"))
            if bad:
                self.reply({"error": "forbidden"}, code=403)
            return bad

        def do_GET(self):
            if self.foreign():
                return
            path, _, query = self.path.partition("?")
            if path == "/":
                with open(os.path.join(HERE, "ui.html"), "rb") as f:
                    self.reply(f.read(), "text/html; charset=utf-8")
            elif path == "/state":
                self.reply({"settings": {k: getattr(a, k) for k in ["bg", *LIVE]},
                            "status": state.status, "fps": state.fps,
                            "locked": state.det is not None and state.det.target_id is not None,
                            "backgrounds": sorted(os.listdir(BG_DIR)) if os.path.isdir(BG_DIR) else []})
            elif path == "/bgfile":
                name = os.path.basename(query.removeprefix("n="))
                try:
                    with open(os.path.join(BG_DIR, name), "rb") as f:
                        self.reply(f.read(), "image/" + ("png" if name.endswith(".png") else "jpeg"))
                except OSError:
                    self.reply({"error": "no such file"}, code=404)
            elif path == "/preview.mjpg":
                self.mjpeg()
            else:
                self.reply({"error": "not found"}, code=404)

        def mjpeg(self):
            with lock:
                state.viewers += 1
            try:
                self.send_response(200)
                self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=f")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                last = None
                while True:
                    f = state.frame
                    if f is not None and f is not last:
                        last = f
                        ok, jpg = cv2.imencode(".jpg", np.ascontiguousarray(f[..., :3]), [cv2.IMWRITE_JPEG_QUALITY, 80])
                        self.wfile.write(b"--f\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n" % len(jpg)
                                         + jpg.tobytes() + b"\r\n")
                    time.sleep(1 / 15)
            except (ConnectionError, OSError):
                pass  # page closed
            finally:
                with lock:
                    state.viewers -= 1
                    if not state.viewers:
                        state.frame = None

        def do_POST(self):
            if self.foreign():
                return
            try:
                if self.path == "/settings":
                    for k, v in json.loads(self.body()).items():
                        apply(a, k, v)
                elif self.path == "/bg":
                    data = self.body()
                    img = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
                    if img is None:
                        raise ValueError("not an image")
                    os.makedirs(BG_DIR, exist_ok=True)
                    path = os.path.join(BG_DIR, time.strftime("%Y%m%d-%H%M%S") + ".jpg")
                    cv2.imwrite(path, img, [cv2.IMWRITE_JPEG_QUALITY, 95])
                    a.bg = path
                elif self.path == "/bgpick":
                    apply(a, "bg", os.path.join(BG_DIR, os.path.basename(json.loads(self.body())["name"])))
                elif self.path == "/bgdelete":
                    path = os.path.join(BG_DIR, os.path.basename(json.loads(self.body())["name"]))
                    if os.path.abspath(a.bg) == os.path.abspath(path):
                        raise ValueError("this background is in use")
                    os.remove(path)
                elif self.path == "/relock":
                    if state.det is not None:
                        state.det.relock = True
                else:
                    return self.reply({"error": "not found"}, code=404)
                save(a)
                self.reply({"ok": True})
            except (ValueError, KeyError, OSError) as e:
                self.reply({"error": str(e)}, code=400)

    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    print(f"settings page: http://127.0.0.1:{port}")
