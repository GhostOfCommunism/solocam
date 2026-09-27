"""solocam - virtual webcam that keeps only you and drops everyone else in the frame.

Stock background removers (Meet, Telemost, NVIDIA Broadcast) segment the class "person",
so anyone behind you leaks through. Here YOLO-seg splits people into instances, ByteTrack
keeps their IDs and we lock onto one ID (the largest person at start, or after 'r').
Robust Video Matting gives the clean hair/edge alpha; it is multiplied by the (slightly
dilated, feathered) mask of the locked person minus everyone else's masks, and by a
cut line just below the shoulders (YOLO-pose), so other people, the chair and arms stay out.
Output goes to the OBS Virtual Camera (do not start OBS's own virtual camera meanwhile).

  python solocam.py                        # webcam "Full HD webcam" -> OBS Virtual Camera, plain dark bg
  python solocam.py --bg blur              # blurred real background instead
  python solocam.py --bg C:\\pics\\room.jpg  # replace background with a picture (or --bg green)
  python solocam.py --preview              # also show a window; keys (window focused): r = re-lock on largest, q/Esc or close button = quit
  python solocam.py --src clip.mp4 --out o.mp4 --no-vcam   # offline test on a file
"""
import argparse
import os
import subprocess
import sys
import threading
import time

import numpy as np
import torch
import torch.nn.functional as F
from ultralytics import YOLO

import glob
import shutil

if sys.stdout is None:  # pythonw (autostart task): keep a log instead of a console
    sys.stdout = sys.stderr = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "solocam.log"), "a", buffering=1)

FFMPEG = os.environ.get("SOLOCAM_FFMPEG") or shutil.which("ffmpeg") or next(iter(glob.glob(
    os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\WinGet\Packages\Gyan.FFmpeg_*\ffmpeg-*\bin\ffmpeg.exe"))), "ffmpeg")

ap = argparse.ArgumentParser()
ap.add_argument("--cam", default="Full HD webcam", help="DirectShow camera name")
ap.add_argument("--src", help="video file instead of the camera (looped)")
ap.add_argument("--size", default="1280x720")
ap.add_argument("--fps", type=int, default=30)
ap.add_argument("--bg", default="#232a33", help="#rrggbb solid colour | blur | path to an image (jpg/png)")
ap.add_argument("--model", default="yolo11s-seg.pt")
ap.add_argument("--imgsz", type=int, default=640, help="YOLO input size")
ap.add_argument("--grow", type=int, default=9, help="px the person mask is dilated before gating RVM alpha (small: chair/arm ghosts stay out)")
ap.add_argument("--cut", type=float, default=0.65, help="fallback cut line as a fraction of the frame height when shoulders are not seen; 1 = no cut at all")
ap.add_argument("--below", type=float, default=0.8, help="cut line below the shoulders, in nose-to-shoulder distances")
ap.add_argument("--pose", default="yolo11n-pose.pt", help="pose model that finds the shoulders")
ap.add_argument("--feather", type=int, default=21, help="px of soft falloff at the mask edge")
ap.add_argument("--hold", type=float, default=1.5, help="s to keep the last mask when the target is lost")
ap.add_argument("--preview", action="store_true")
ap.add_argument("--no-vcam", action="store_true")
ap.add_argument("--out", help="also write the result to this video file")
ap.add_argument("--frames", type=int, default=0, help="stop after N frames (tests)")
a = ap.parse_args()
W, H = map(int, a.size.split("x"))
dev = torch.device("cuda")


class Grabber:
    """ffmpeg -> raw RGB frames; a thread keeps only the latest one, so slow frames never pile up lag."""

    def __init__(self):
        if a.src:
            inp = ["-re", "-stream_loop", "-1", "-i", a.src]
        else:
            # camera's native mode (this one only offers 1920x1080@30 nv12/yuyv), scaled below
            inp = ["-f", "dshow", "-rtbufsize", "64M", "-i", f"video={a.cam}"]
        cmd = [FFMPEG, "-hide_banner", "-loglevel", "error", *inp,
               "-vf", f"scale={W}:{H}", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
        self.p = subprocess.Popen(cmd, stdout=subprocess.PIPE, bufsize=W * H * 3)
        self.frame, self.seq = None, 0
        self.cv = threading.Condition()
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        n = W * H * 3
        while True:
            buf = self.p.stdout.read(n)
            if len(buf) < n:
                break
            with self.cv:
                self.frame, self.seq = buf, self.seq + 1
                self.cv.notify()
        with self.cv:
            self.frame, self.seq = None, -1
            self.cv.notify()

    def get(self, last_seq):
        with self.cv:
            self.cv.wait_for(lambda: self.seq != last_seq)
            return self.frame, self.seq


def iou(b1, b2):
    x1, y1 = max(b1[0], b2[0]), max(b1[1], b2[1])
    x2, y2 = min(b1[2], b2[2]), min(b1[3], b2[3])
    inter = max(0, x2 - x1) * max(0, y2 - y1)
    area = lambda b: (b[2] - b[0]) * (b[3] - b[1])
    return inter / (area(b1) + area(b2) - inter + 1e-6)


def pick_target(boxes, ids, target_id, last_box):
    """Index of the locked person: same track ID, else best overlap with where they were, else largest."""
    if len(boxes) == 1:
        return 0  # alone in the frame: no ambiguity, never blur the only person over a lost track ID
    if target_id is not None and ids is not None:
        hit = np.nonzero(ids == target_id)[0]
        if len(hit):
            return int(hit[0])
    if last_box is not None:
        ov = [iou(b, last_box) for b in boxes]
        best = int(np.argmax(ov))
        if ov[best] > 0.3:
            return best
        return None  # someone else in another place: do not jump to them, wait for 'r' or hold expiry
    areas = (boxes[:, 2] - boxes[:, 0]) * (boxes[:, 3] - boxes[:, 1])
    return int(np.argmax(areas))


def make_bg():
    if a.bg == "green":
        a.bg = "#00ff00"
    if a.bg.startswith("#"):  # solid colour
        rgb = [int(a.bg[i:i + 2], 16) / 255 for i in (1, 3, 5)]
        return torch.tensor(rgb, device=dev).view(1, 3, 1, 1).expand(1, 3, H, W)
    if a.bg != "blur":
        import cv2
        img = cv2.cvtColor(cv2.imread(a.bg), cv2.COLOR_BGR2RGB)
        img = cv2.resize(img, (W, H), interpolation=cv2.INTER_AREA)
        return torch.from_numpy(img).to(dev).permute(2, 0, 1)[None].float() / 255
    return None


def blur(x):  # cheap strong blur on GPU: shrink 16x and scale back
    s = F.interpolate(x, scale_factor=1 / 16, mode="area")
    return F.interpolate(s, size=x.shape[-2:], mode="bilinear", align_corners=False)


class Detector:
    """Person detection + lock in its own thread and CUDA stream, so it overlaps with RVM.
    Publishes `gate`: the locked person's dilated mask minus everyone else, or None (show nobody).
    Its mask lags the frame by one detection (~30 ms); the dilation covers that."""

    def __init__(self):
        self.yolo = YOLO(a.model)
        self.pose = YOLO(a.pose) if a.cut < 1 else None  # shoulders -> cut line
        self.line = a.cut * H  # cut line in px, smoothed
        self.rows = torch.arange(H, device=dev).float().view(1, 1, H, 1)
        self.grow_k, self.feather_k = a.grow | 1, a.feather | 1
        self.stream = torch.cuda.Stream()
        self.rgb, self.gate, self.target_id, self.relock, self.box = None, None, None, False, None
        self.cv = threading.Condition()
        threading.Thread(target=self._run, daemon=True).start()

    def push(self, rgb):
        with self.cv:
            self.rgb = rgb
            self.cv.notify()

    def _up(self, m):
        m = m.float()[None, None]
        return m if m.shape[-2:] == (H, W) else F.interpolate(m, size=(H, W), mode="bilinear", align_corners=False)

    def shoulder_line(self, bgr, box):
        """Cut line in px: shoulders + a.below * (nose-to-shoulder); a.cut * H when the pose is not seen."""
        r = self.pose.predict(bgr, imgsz=a.imgsz, classes=[0], conf=0.35, verbose=False, device=0)[0]
        if r.keypoints is None or not len(r.boxes):
            return a.cut * H
        pb = r.boxes.xyxy.cpu().numpy()
        j = int(np.argmax([iou(b, box) for b in pb]))
        if iou(pb[j], box) < 0.5:
            return a.cut * H
        xy, c = r.keypoints.xy[j].cpu().numpy(), r.keypoints.conf[j].cpu().numpy()
        if min(c[0], c[5], c[6]) < 0.5:  # nose, left/right shoulder
            return a.cut * H
        sh = (xy[5, 1] + xy[6, 1]) / 2
        return float(sh + a.below * (sh - xy[0, 1]))

    def _run(self):
        target_id, last_box, last_seen = None, None, 0.0
        while True:
            with self.cv:
                self.cv.wait_for(lambda: self.rgb is not None)
                rgb, self.rgb = self.rgb, None
            if self.relock:
                target_id, last_box, self.relock = None, None, False
            with torch.inference_mode(), torch.cuda.stream(self.stream):
                bgr = np.ascontiguousarray(rgb[..., ::-1])
                r = self.yolo.track(bgr, persist=True, classes=[0], conf=0.35,
                                    imgsz=a.imgsz, retina_masks=True, verbose=False, device=0,
                                    tracker="bytetrack.yaml")[0]
                now, idx = time.time(), None
                if r.masks is not None and len(r.boxes):
                    boxes = r.boxes.xyxy.cpu().numpy()
                    ids = r.boxes.id.int().cpu().numpy() if r.boxes.id is not None else None
                    idx = pick_target(boxes, ids, target_id, last_box)
                if idx is not None:
                    target_id = int(ids[idx]) if ids is not None else target_id
                    last_box, last_seen = boxes[idx], now
                    m = self._up(r.masks.data[idx])
                    gate = F.max_pool2d(m, self.grow_k, 1, self.grow_k // 2)  # small dilation: hair only
                    for _ in range(2):  # soft edge, so the gate does not add its own hard outline
                        gate = F.avg_pool2d(gate, self.feather_k, 1, self.feather_k // 2, count_include_pad=False)
                    if self.pose is not None:
                        self.line += 0.3 * (self.shoulder_line(bgr, boxes[idx]) - self.line)
                        gate = gate * ((self.line + 30 - self.rows) / 60).clamp(0, 1)  # 1 above, 60 px fade
                    others = [k for k in range(len(boxes)) if k != idx]
                    if others:  # cut other people out of the rim too
                        gate = gate * (1 - self._up(r.masks.data[others].amax(0)) * (1 - m))
                    self.stream.synchronize()
                    self.gate, self.box = gate, boxes[idx]
                elif now - last_seen > a.hold:
                    target_id, last_box, self.gate, self.box = None, None, None, None  # target gone: show only background
            self.target_id = target_id


class Matter:
    """Robust Video Matting replayed as a CUDA graph: eager PyTorch on Windows is launch-bound
    (~14 ms per frame on this box), the graph runs the same net in ~6 ms."""

    def __init__(self):
        rvm = torch.hub.load("PeterL1n/RobustVideoMatting", "mobilenetv3", trust_repo=True, verbose=False)
        rvm = rvm.to(dev).eval()
        # its encoder builds mean/std tensors from lists every call, which graph capture forbids
        mean = torch.tensor([0.485, 0.456, 0.406], device=dev).view(1, 3, 1, 1)
        std = torch.tensor([0.229, 0.224, 0.225], device=dev).view(1, 3, 1, 1)
        sys.modules[type(rvm.backbone).__module__].normalize = lambda x, _m, _s: (x - mean) / std
        ratio = min(1.0, 512 / max(W, H))  # RVM guidance: ~512 px internal resolution
        with torch.inference_mode():
            self.src = torch.zeros(1, 3, H, W, device=dev)
            _, _, *self.rec = rvm(self.src, downsample_ratio=ratio)
            side = torch.cuda.Stream()
            side.wait_stream(torch.cuda.current_stream())
            with torch.cuda.stream(side):
                for _ in range(3):
                    rvm(self.src, *self.rec, downsample_ratio=ratio)
            torch.cuda.current_stream().wait_stream(side)
            self.graph = torch.cuda.CUDAGraph()
            with torch.cuda.graph(self.graph):
                self.out = rvm(self.src, *self.rec, downsample_ratio=ratio)

    def __call__(self, src):
        self.src.copy_(src)
        self.graph.replay()
        for r, o in zip(self.rec, self.out[2:]):  # recurrent state feeds the next frame
            r.copy_(o)
        return self.out[1]


def main():
    det = Detector()
    matte = Matter()
    bg_static = make_bg()

    cam = None
    if not a.no_vcam:
        import pyvirtualcam
        cam = pyvirtualcam.Camera(W, H, a.fps, backend="obs", fmt=pyvirtualcam.PixelFormat.RGB)
        print("virtual camera:", cam.device)
    writer = None
    if a.out:
        writer = subprocess.Popen([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo",
                                   "-pix_fmt", "rgb24", "-s", a.size, "-r", str(a.fps), "-i", "-",
                                   "-pix_fmt", "yuv420p", a.out], stdin=subprocess.PIPE)
    if a.preview:
        import cv2

    grab = Grabber()
    seq, n, t0 = 0, 0, time.time()
    while True:
        buf, seq = grab.get(seq)
        if buf is None:
            print("source ended")
            break
        rgb = np.frombuffer(buf, np.uint8).reshape(H, W, 3).copy()  # writable: torch warns otherwise
        det.push(rgb)
        with torch.inference_mode():
            src = torch.from_numpy(rgb).to(dev).permute(2, 0, 1)[None].float() / 255
            pha = matte(src)
            gate = det.gate
            alpha = pha * gate if gate is not None else torch.zeros_like(pha)
            bg = bg_static if bg_static is not None else blur(src)
            out = src * alpha + bg * (1 - alpha)
            frame = (out[0].permute(1, 2, 0) * 255).clamp(0, 255).byte().cpu().numpy()

        if cam:
            cam.send(frame)
        if writer:
            writer.stdin.write(frame.tobytes())
        if a.preview:
            view = np.ascontiguousarray(frame[..., ::-1])
            b = det.box
            if b is not None:  # preview only: who is locked
                cv2.rectangle(view, (int(b[0]), int(b[1])), (int(b[2]), int(b[3])), (0, 255, 0), 2)
                cv2.putText(view, f"id {det.target_id}", (int(b[0]), int(b[1]) - 6), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2)
            cv2.imshow("solocam", view)
            k = cv2.waitKey(1) & 0xFF
            if k in (ord("q"), 27) or cv2.getWindowProperty("solocam", cv2.WND_PROP_VISIBLE) < 1:
                break  # q / Esc with the window focused, or its close button
            if k == ord("r"):
                det.relock = True
        n += 1
        if n % 150 == 0:
            print(f"{n / (time.time() - t0):.1f} fps, target id {det.target_id}")
        if a.frames and n >= a.frames:
            break

    print(f"done: {n} frames, {n / (time.time() - t0):.1f} fps")
    if writer:
        writer.stdin.close()
        writer.wait()
    grab.p.kill()


if __name__ == "__main__":
    main()
