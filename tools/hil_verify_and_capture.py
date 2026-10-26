import ctypes
from ctypes import wintypes
import time
import os
import subprocess
import zlib
import struct
import numpy as np

FFMPEG_EXE = r"C:\Users\Mert\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-8.1-full_build\bin\ffmpeg.exe"
OUT_DIR = r"C:\Users\Mert\.gemini\antigravity\brain\cc411731-29cb-499e-a900-28c85e2af7db\scratch\sim_results"
TRACKED_VID_DIR = r"c:\Users\Mert\Desktop\robotkol\test_videos\tracked_outputs"
os.makedirs(OUT_DIR, exist_ok=True)
os.makedirs(TRACKED_VID_DIR, exist_ok=True)

# =============================================================================
# 1. Win32 Native Serial Port (Zero External Dependencies)
# =============================================================================
GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
OPEN_EXISTING = 3
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value
PURGE_RXABORT = 0x0002
PURGE_RXCLEAR = 0x0008
PURGE_TXABORT = 0x0001
PURGE_TXCLEAR = 0x0004

class DCB(ctypes.Structure):
    _fields_ = [
        ("DCBlength", wintypes.DWORD),
        ("BaudRate", wintypes.DWORD),
        ("flags", wintypes.DWORD),
        ("wReserved", wintypes.WORD),
        ("XonLim", wintypes.WORD),
        ("XoffLim", wintypes.WORD),
        ("ByteSize", wintypes.BYTE),
        ("Parity", wintypes.BYTE),
        ("StopBits", wintypes.BYTE),
        ("XonChar", ctypes.c_char),
        ("XoffChar", ctypes.c_char),
        ("ErrorChar", ctypes.c_char),
        ("EofChar", ctypes.c_char),
        ("EvtChar", ctypes.c_char),
        ("wReserved1", wintypes.WORD),
    ]

class COMMTIMEOUTS(ctypes.Structure):
    _fields_ = [
        ("ReadIntervalTimeout", wintypes.DWORD),
        ("ReadTotalTimeoutMultiplier", wintypes.DWORD),
        ("ReadTotalTimeoutConstant", wintypes.DWORD),
        ("WriteTotalTimeoutMultiplier", wintypes.DWORD),
        ("WriteTotalTimeoutConstant", wintypes.DWORD),
    ]

class Win32Serial:
    def __init__(self, port="COM7", baud=921600):
        self.k32 = ctypes.windll.kernel32
        self.k32.CreateFileW.restype = wintypes.HANDLE
        self.handle = self.k32.CreateFileW(
            f"\\\\.\\{port}",
            GENERIC_READ | GENERIC_WRITE,
            0,
            None,
            OPEN_EXISTING,
            0,
            None
        )
        if self.handle == INVALID_HANDLE_VALUE or self.handle is None:
            err = self.k32.GetLastError()
            raise RuntimeError(f"Cannot open {port}, Win32 error={err}")

        self.k32.SetupComm(self.handle, 65536, 65536)

        dcb = DCB()
        dcb.DCBlength = ctypes.sizeof(DCB)
        if not self.k32.GetCommState(self.handle, ctypes.byref(dcb)):
            self.close()
            raise RuntimeError("GetCommState failed")

        dcb.BaudRate = baud
        dcb.ByteSize = 8
        dcb.Parity = 0   # NOPARITY
        dcb.StopBits = 0 # ONESTOPBIT
        dcb.flags = 0x00001011
        if not self.k32.SetCommState(self.handle, ctypes.byref(dcb)):
            self.close()
            raise RuntimeError("SetCommState failed")

        timeouts = COMMTIMEOUTS()
        timeouts.ReadIntervalTimeout = 10
        timeouts.ReadTotalTimeoutMultiplier = 0
        timeouts.ReadTotalTimeoutConstant = 50
        timeouts.WriteTotalTimeoutMultiplier = 0
        timeouts.WriteTotalTimeoutConstant = 3000
        self.k32.SetCommTimeouts(self.handle, ctypes.byref(timeouts))
        self.purge()

    def purge(self):
        self.k32.PurgeComm(
            self.handle,
            PURGE_RXABORT | PURGE_RXCLEAR | PURGE_TXABORT | PURGE_TXCLEAR
        )

    def write(self, data: bytes):
        written = wintypes.DWORD(0)
        buf = ctypes.create_string_buffer(data, len(data))
        ok = self.k32.WriteFile(
            self.handle,
            buf,
            len(data),
            ctypes.byref(written),
            None
        )
        if not ok or written.value != len(data):
            raise RuntimeError(f"Serial write failed: {written.value}/{len(data)}")

    def read_exact(self, n: int, timeout_s: float = 2.0) -> bytes:
        out = bytearray()
        t0 = time.perf_counter()
        buf = ctypes.create_string_buffer(8192)
        read_n = wintypes.DWORD(0)
        while len(out) < n:
            if (time.perf_counter() - t0) > timeout_s:
                break
            to_read = min(8192, n - len(out))
            ok = self.k32.ReadFile(
                self.handle,
                buf,
                to_read,
                ctypes.byref(read_n),
                None
            )
            if ok and read_n.value > 0:
                out.extend(buf.raw[:read_n.value])
        return bytes(out)

    def close(self):
        if self.handle and self.handle != INVALID_HANDLE_VALUE:
            self.k32.CloseHandle(self.handle)
            self.handle = None


def write_png(path, rgb):
    h, w, _ = rgb.shape
    raw_rows = b"".join(b"\x00" + rgb[y].tobytes() for y in range(h))
    compressed = zlib.compress(raw_rows, 6)
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", compressed)
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as f:
        f.write(png)


def parse_telemetry(pkt8: bytes):
    if len(pkt8) < 8 or pkt8[0] != 0xAA or pkt8[1] != 0x55:
        raise ValueError(f"Invalid telemetry header ({len(pkt8)} bytes): {pkt8.hex()}")
    st = pkt8[2]
    pupil_valid   = bool(st & 0x01)
    px_msb        = (st >> 1) & 0x01
    cx_msb        = (st >> 2) & 0x01
    glint_valid   = bool((st >> 4) & 0x01)
    stream_active = bool((st >> 5) & 0x01)
    cam_init_done = bool((st >> 6) & 0x01)
    hil_active    = bool((st >> 7) & 0x01)

    pupil_x       = (px_msb << 8) | pkt8[3]
    pupil_y       = pkt8[4]
    core_x        = (cx_msb << 8) | pkt8[5]
    core_y        = pkt8[6]
    active_thresh = pkt8[7]
    return {
        "pupil_valid": pupil_valid,
        "pupil_x": pupil_x,
        "pupil_y": pupil_y,
        "core_x": core_x,
        "core_y": core_y,
        "active_thresh": active_thresh,
        "glint_valid": glint_valid,
        "stream_active": stream_active,
        "cam_init_done": cam_init_done,
        "hil_active": hil_active,
    }


def render_fpga_osd_320x240(gray_320x240, t):
    """Bit-accurate match of osd_renderer.v on 320x240 coordinate grid."""
    rgb = np.stack([gray_320x240, gray_320x240, gray_320x240], axis=-1).copy()
    yy, xx = np.mgrid[0:240, 0:320]

    # Top status bar (y < 9 in 320x240 = v_cnt < 18 in 640x480)
    rgb[0:9, :, :] = [0, 70, 0]
    th_end = min(320, 40 + t["active_thresh"])
    rgb[0:9, 40:th_end] = [220, 180, 0]
    if t["pupil_valid"]:
        px = t["pupil_x"]
        rgb[0:9, max(0, px-2):min(320, px+3)] = [0, 255, 255]

    # ROI Border (X: 90..230, Y: 104..184)
    in_roi = (xx >= 90) & (xx <= 230) & (yy >= 104) & (yy <= 184)
    roi_border = in_roi & ((xx == 90) | (xx == 230) | (yy == 104) | (yy == 184))
    rgb[roi_border] = [180, 180, 40]

    # Local pupil mask inside +/-13x10 around (core_x, core_y)
    if t["pupil_valid"]:
        cx, cy = t["core_x"], t["core_y"]
        in_core_win = in_roi & (np.abs(xx - cx) <= 13) & (np.abs(yy - cy) <= 10)
        is_mask = in_core_win & (gray_320x240 <= t["active_thresh"])
        rgb[is_mask, 0] = np.minimum(255, (gray_320x240[is_mask].astype(np.int32) >> 1) + 180).astype(np.uint8)
        rgb[is_mask, 1] = (gray_320x240[is_mask] >> 2)
        rgb[is_mask, 2] = (gray_320x240[is_mask] >> 2)

        px, py = t["pupil_x"], t["pupil_y"]
        dx = np.abs(xx - px)
        dy = np.abs(yy - py)
        p_box = ((dx == 12) & (dy <= 10)) | ((dy == 10) & (dx <= 12))
        p_cross = ((dx <= 1) & (yy >= 104) & (yy <= 184)) | ((dy <= 1) & (xx >= 90) & (xx <= 230))
        p_center = (dx <= 2) & (dy <= 2)
        rgb[p_box | p_cross] = [0, 255, 60]
        rgb[p_center] = [255, 255, 255]
    return rgb


def capture_live_camera_frame(ser: Win32Serial):
    ser.purge()
    ser.write(b"\x00") # Ensure live camera mode
    time.sleep(0.15)   # Wait ~2-3 camera frames
    ser.purge()
    ser.write(b"\xC5")
    raw = ser.read_exact(8 + 19200, timeout_s=2.0)
    if len(raw) < 8 + 19200:
        raise RuntimeError(f"Short frame dump read: {len(raw)}/19208 bytes")
    telem = parse_telemetry(raw[:8])
    fb_160x120 = np.frombuffer(raw[8:8+19200], dtype=np.uint8).reshape((120, 160))
    gray_320x240 = np.repeat(np.repeat(fb_160x120, 2, axis=0), 2, axis=1)
    osd_320x240 = render_fpga_osd_320x240(gray_320x240, telem)
    osd_640x480 = np.repeat(np.repeat(osd_320x240, 2, axis=0), 2, axis=1)
    return telem, fb_160x120, osd_640x480


def send_hil_frame(ser: Win32Serial, frame_320x240: np.ndarray):
    """
    Sends 256x160 sub-frame (Y: 64..223, X: 287..32 descending, matching dvp_capture x_mirrored)
    prefixed with 0x5A, 0xA5 to the physical FPGA and returns the 8-byte hardware telemetry.
    """
    # Slice Y=64..223 (160 rows) and X=287..32 descending (256 cols)
    roi_slice = frame_320x240[64:224, 32:288][:, ::-1]
    payload = b"\x5A\xA5" + roi_slice.tobytes()
    ser.write(payload)
    resp = ser.read_exact(8, timeout_s=1.5)
    return parse_telemetry(resp)


if __name__ == "__main__":
    print("Opening COM7 at 921600 baud...")
    ser = Win32Serial("COM7", 921600)
    try:
        # 1. Test live telemetry ('T' = 0x54)
        ser.purge()
        ser.write(b"\x54")
        pkt = ser.read_exact(8, timeout_s=1.0)
        t_live = parse_telemetry(pkt)
        print("LIVE TELEMETRY ('T'):", t_live)

        # 2. Capture live OV7670 camera snapshot (0xC5)
        t_snap, fb_live, osd_live = capture_live_camera_frame(ser)
        live_path = os.path.join(OUT_DIR, "fpga_live_ov7670_snapshot.png")
        write_png(live_path, osd_live)
        print(
            f"LIVE CAMERA SNAPSHOT SAVED -> {live_path}\n"
            f"  cam_init_done={t_snap['cam_init_done']}, stream_active={t_snap['stream_active']}, "
            f"mean_luma={fb_live.mean():.1f}, min={fb_live.min()}, max={fb_live.max()}, "
            f"pupil=({t_snap['pupil_x']}, {t_snap['pupil_y']}) valid={t_snap['pupil_valid']}"
        )
    finally:
        ser.close()
