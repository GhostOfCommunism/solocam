"""Windows 11 virtual camera for solocam, stdlib ctypes only.

MFCreateVirtualCamera registers a camera served by the media source DLL from
VL.Video.VirtualCamera (MIT, built from source, see vcam/). That DLL runs inside the
Frame Server and reads frames from shared memory, protocol v2 (src/shared/VCamProtocol.cs):
  - file %ProgramData%\\vvvv\\VirtualCamera\\vlvcam0.bin, 4096 B: format + writer heartbeat;
  - section Global\\vvvv-vcam0-v2-WxH, created by the DLL: seqlock ring of 3 BGRA slots.
Frames older than 2 s (heartbeat) make the camera serve black.

Who watches the camera comes from Windows itself: IMFSensorActivityMonitor reports every
process streaming from every camera, `active` is set while anyone streams from ours.
"""
import atexit
import ctypes
import os
import subprocess
import threading
import time
from ctypes import POINTER, byref, c_int32, c_int64, c_uint32, c_void_p, c_wchar_p, wintypes

CLSID = "{3522155e-17e0-4fd6-bf40-98a9dc8e53d1}"  # VCamProtocol.SourceClsid
DIR = os.path.join(os.environ.get("ProgramData", r"C:\ProgramData"), "vvvv", "VirtualCamera")
HEADER = 4096
SLOTS = 3

ole32, mfplat, kernel32 = ctypes.windll.ole32, ctypes.windll.mfplat, ctypes.windll.kernel32
mfsg = ctypes.windll.mfsensorgroup
kernel32.OpenFileMappingW.restype = wintypes.HANDLE
kernel32.MapViewOfFile.restype = c_void_p
kernel32.MapViewOfFile.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, ctypes.c_size_t]
kernel32.UnmapViewOfFile.argtypes = [c_void_p]
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]


def com(obj, idx, *argtypes):
    """Method `idx` of COM object `obj`'s vtable, bound to obj; raises OSError on a failed HRESULT."""
    vtbl = ctypes.cast(obj, POINTER(POINTER(c_void_p)))[0]
    fn = ctypes.WINFUNCTYPE(ctypes.HRESULT, c_void_p, *argtypes)(vtbl[idx])
    return lambda *args: fn(obj, *args)


def release(obj):
    vtbl = ctypes.cast(obj, POINTER(POINTER(c_void_p)))[0]
    ctypes.WINFUNCTYPE(wintypes.ULONG, c_void_p)(vtbl[2])(obj)


def net_ticks():  # .NET DateTime.UtcNow.Ticks: 100 ns since 0001-01-01
    return int(time.time() * 10_000_000) + 621_355_968_000_000_000


class Monitor:
    """IMFSensorActivityMonitor: calls on_change(bool) when anyone starts/stops streaming `name`."""

    PROTO = ctypes.WINFUNCTYPE(ctypes.HRESULT, c_void_p, c_void_p, POINTER(c_void_p))
    REF = ctypes.WINFUNCTYPE(wintypes.ULONG, c_void_p)
    REPORT = ctypes.WINFUNCTYPE(ctypes.HRESULT, c_void_p, c_void_p)

    def __init__(self, name, on_change):
        self.name, self.on_change, self.state = name, on_change, None
        # a hand-made COM object: QueryInterface answers any IID, lifetime is ours (refcount ignored)
        self._fns = [self.PROTO(self._qi), self.REF(lambda _: 1), self.REF(lambda _: 1), self.REPORT(self._report)]
        self._vtbl = (c_void_p * 4)(*[ctypes.cast(f, c_void_p) for f in self._fns])
        self._obj = ctypes.pointer(ctypes.pointer(self._vtbl))
        self.mon = c_void_p()
        mfsg.MFCreateSensorActivityMonitor.restype = ctypes.HRESULT
        mfsg.MFCreateSensorActivityMonitor(self._obj, byref(self.mon))
        com(self.mon, 3)()  # Start

    IIDS = {"00000000-0000-0000-c000-000000000046",  # IUnknown
            "de5072ee-dbe3-46dc-8a87-b6f631194751"}  # IMFSensorActivitiesReportCallback

    def _qi(self, this, riid, ppv):
        b = ctypes.string_at(riid, 16)  # GUID: Data1-3 little endian, Data4 as is
        iid = "%08x-%04x-%04x-%s-%s" % (int.from_bytes(b[0:4], "little"), int.from_bytes(b[4:6], "little"),
                                        int.from_bytes(b[6:8], "little"), b[8:10].hex(), b[10:].hex())
        if iid not in self.IIDS:  # e.g. IAgileObject/IMarshal: say no, else MF calls past our 4-slot vtable
            ppv[0] = None
            return -2147467262  # E_NOINTERFACE
        ppv[0] = this
        return 0

    def _report(self, this, report):
        if os.environ.get("VCAM_DEBUG"):
            print("report", time.strftime("%X"), flush=True)
        try:
            n = c_uint32()
            com(report, 3, POINTER(c_uint32))(byref(n))
            for i in range(n.value):
                ar = c_void_p()
                com(report, 4, c_uint32, POINTER(c_void_p))(i, byref(ar))
                buf, ln = ctypes.create_unicode_buffer(256), c_uint32()
                com(ar, 3, c_wchar_p, c_uint32, POINTER(c_uint32))(buf, 256, byref(ln))
                if os.environ.get("VCAM_DEBUG"):
                    sl, pc = ctypes.create_unicode_buffer(512), c_uint32()
                    com(ar, 4, c_wchar_p, c_uint32, POINTER(c_uint32))(sl, 512, byref(ln))
                    com(ar, 5, POINTER(c_uint32))(byref(pc))
                    print("  sensor", n.value, repr(buf.value), sl.value[:90], "procs", pc.value, flush=True)
                if buf.value.split(" (")[0] == self.name:  # Windows appends a localized "(Windows Virtual Camera)"
                    self._update(ar)
                release(ar)
        except OSError as e:
            print("sensor report:", e)
        return 0

    def _update(self, ar):
        pc, streaming = c_uint32(), False
        com(ar, 5, POINTER(c_uint32))(byref(pc))
        for j in range(pc.value):
            pa, pid, on = c_void_p(), c_uint32(), wintypes.BOOL()
            com(ar, 6, c_uint32, POINTER(c_void_p))(j, byref(pa))
            com(pa, 3, POINTER(c_uint32))(byref(pid))
            com(pa, 4, POINTER(wintypes.BOOL))(byref(on))
            release(pa)
            if os.environ.get("VCAM_DEBUG"):
                print("    pid", pid.value, "streaming", bool(on), flush=True)
            streaming |= bool(on) and pid.value != os.getpid()
        if streaming != self.state:
            self.state = streaming
            self.on_change(streaming)


class VirtualCamera:
    """send(rgb HxWx3 uint8 numpy or bytes of BGRA) into the camera; `active` = someone watches."""

    def __init__(self, w, h, fps, name="solocam"):
        self.w, self.h, self.slot_size = w, h, w * h * 4
        self.section_name = f"Global\\vvvv-vcam0-v2-{w}x{h}"
        self.view = self.handle = None
        self.active = threading.Event()

        ole32.CoInitializeEx(None, 0)  # MTA
        mfplat.MFStartup(0x00020070, 0)
        self._write_header(fps)

        self.cam = c_void_p()
        mfsg.MFCreateVirtualCamera.restype = ctypes.HRESULT
        mfsg.MFCreateVirtualCamera(0, 0, 0, c_wchar_p(name), c_wchar_p(CLSID), None, 0, byref(self.cam))
        com(self.cam, 36, c_void_p)(None)  # IMFVirtualCamera::Start (after 30 IMFAttributes + 3 own methods)
        atexit.register(self.close)
        self.monitor = Monitor(name, lambda on: (self.active.set if on else self.active.clear)())

    def _write_header(self, fps):
        path = os.path.join(DIR, "vlvcam0.bin")
        new = not os.path.exists(path)
        self._file = open(path, "r+b" if not new else "w+b")
        self._file.truncate(HEADER)
        if new:  # the Frame Server (Local Service) must read it
            subprocess.run(["icacls", path, "/grant", "*S-1-1-0:R"], capture_output=True)
        import mmap
        self.hdr = mmap.mmap(self._file.fileno(), HEADER)
        f = lambda off, v, t=c_int32: t.from_buffer(self.hdr, off).__setattr__("value", v)
        f(0, 0, c_uint32)
        for off, v in ((4, 2), (8, self.w), (12, self.h), (16, fps), (20, 1), (24, 1),
                       (28, self.w * 4), (32, SLOTS), (36, self.slot_size), (64 + 16 * 8, 4)):
            f(off, v)
        self._beat = c_int64.from_buffer(self.hdr, 40)
        self._beat.value = net_ticks()
        f(0, 0x4D435656, c_uint32)  # 'VVCM', written last
        # the DLL makes the frame section only for a live writer (heartbeat < 2 s old),
        # so beat while the process lives, not only while frames flow
        threading.Thread(target=self._heartbeat, daemon=True).start()

    def _heartbeat(self):
        while True:
            self._beat.value = net_ticks()
            time.sleep(0.5)

    def _attach(self):
        """Open the DLL's section and take it over as writer (VCamFrameSection.AttachAsWriter)."""
        self.handle = kernel32.OpenFileMappingW(0x6, False, self.section_name)  # FILE_MAP_READ|WRITE
        if not self.handle:
            if os.environ.get("VCAM_DEBUG"):
                print("no section", self.section_name, ctypes.GetLastError(), flush=True)
            return False
        self.view = kernel32.MapViewOfFile(self.handle, 0x6, 0, 0, HEADER + SLOTS * self.slot_size)
        if not self.view:
            self.detach()
            return False
        v = self.view
        magic, version = c_uint32.from_address(v), c_uint32.from_address(v + 4)
        self.latest, self.counter = c_int32.from_address(v + 8), c_int64.from_address(v + 16)
        gen = c_int64.from_address(v + 24)
        self.seqs = [c_int64.from_address(v + 32 + 8 * i) for i in range(SLOTS)]
        self.latest.value = -1
        for s in self.seqs:
            s.value += s.value & 1
        if magic.value == 0x53435656 and version.value == 2:
            gen.value += 1
        else:  # fresh zeroed section: build the header, magic last
            self.counter.value, version.value, gen.value = 0, 2, 1
            magic.value = 0x53435656
        self.next = 0
        return True

    def detach(self):
        if self.view:
            kernel32.UnmapViewOfFile(self.view)
        if self.handle:
            kernel32.CloseHandle(self.handle)
        self.view = self.handle = None

    def send(self, bgra):
        """One BGRA frame (bytes-like or C-contiguous numpy, h*w*4). Dropped until the DLL made its section."""
        if not self.view and not self._attach():
            return
        slot = self.next if self.next != self.latest.value else (self.next + 1) % SLOTS
        seq = self.seqs[slot]
        seq.value += 1  # odd: being written
        if hasattr(bgra, "flags"):
            assert bgra.flags.c_contiguous and bgra.nbytes == self.slot_size
        ctypes.memmove(self.view + HEADER + slot * self.slot_size,
                       bgra.ctypes.data if hasattr(bgra, "ctypes") else bgra, self.slot_size)
        seq.value += 1
        self.latest.value = slot
        self.counter.value += 1
        self.next = (slot + 1) % SLOTS

    def close(self):
        if self.cam:
            try:
                com(self.cam, 38)()  # Remove: the camera disappears from the device list
            except OSError:
                pass
            release(self.cam)
            self.cam = None
        self.detach()


if __name__ == "__main__":  # smoke test: moving bars while someone watches "solocam"
    import numpy as np
    cam = VirtualCamera(1280, 720, 30)
    print("camera up; open it in the Camera app / browser, Ctrl+C to quit")
    img = np.zeros((720, 1280, 4), np.uint8)
    img[..., 3] = 255
    i, was = 0, None
    while True:
        on = cam.active.is_set()
        if on != was:
            print("watched" if on else "idle", time.strftime("%X"), flush=True)
            was = on
        if not on:
            cam.detach()
            cam.active.wait(1)
            continue
        img[..., :3] = 40
        img[:, (i * 8) % 1280:(i * 8) % 1280 + 40, 1] = 255
        cam.send(img)
        i += 1
        time.sleep(1 / 30)
