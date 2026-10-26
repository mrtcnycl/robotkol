import os
import sys
import time
import zlib
import struct
import threading
import tkinter as tk
import numpy as np

TOOLS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools")
SCRATCH_DIR = r"C:\Users\Mert\.gemini\antigravity\brain\cc411731-29cb-499e-a900-28c85e2af7db\scratch"
sys.path.insert(0, TOOLS_DIR)
sys.path.insert(0, SCRATCH_DIR)
import hil_verify_and_capture as hil

OUT_DIR = r"C:\Users\Mert\.gemini\antigravity\brain\cc411731-29cb-499e-a900-28c85e2af7db\scratch\sim_results"
os.makedirs(OUT_DIR, exist_ok=True)
LATEST_PNG = os.path.join(OUT_DIR, "live_latest.png")
LATEST_TMP = os.path.join(OUT_DIR, "live_latest_tmp.png")
TELEM_LOG  = os.path.join(OUT_DIR, "live_telemetry.txt")


def write_png_fast(path, rgb):
    h, w, _ = rgb.shape
    raw_rows = b"".join(b"\x00" + rgb[y].tobytes() for y in range(h))
    compressed = zlib.compress(raw_rows, 1)  # Level 1 = <4ms!
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


def upscale_80x60_to_320x240_smooth(img_80x60: np.ndarray) -> np.ndarray:
    """Fast 2x bilinear (80x60 -> 160x120) + 2x nearest (160x120 -> 320x240)."""
    a = img_80x60.astype(np.uint16)
    h, w = a.shape
    out160 = np.empty((h * 2, w * 2), dtype=np.uint16)
    a_r = np.pad(a[:, 1:], ((0, 0), (0, 1)), mode="edge")
    a_d = np.pad(a[1:, :], ((0, 1), (0, 0)), mode="edge")
    a_dr = np.pad(a[1:, 1:], ((0, 1), (0, 1)), mode="edge")

    out160[0::2, 0::2] = a
    out160[0::2, 1::2] = (a + a_r) >> 1
    out160[1::2, 0::2] = (a + a_d) >> 1
    out160[1::2, 1::2] = (a + a_r + a_d + a_dr) >> 2
    u8 = out160.astype(np.uint8)
    return np.repeat(np.repeat(u8, 2, axis=0), 2, axis=1)


class FPGALiveMonitorApp:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("Tang Nano 9K - Canlı OV7670 Kamera & Göz Bebeği Takip Monitörü (TURBO ~18 FPS)")
        self.root.configure(bg="#141820")
        self.root.resizable(False, False)

        self.root.geometry("+80+60")
        self.root.attributes("-topmost", True)
        self.root.lift()
        self.root.focus_force()

        self.info_var = tk.StringVar(value="COM7 Turbo Akış Başlatılıyor...")
        self.lbl_info = tk.Label(
            self.root,
            textvariable=self.info_var,
            font=("Consolas", 11, "bold"),
            fg="#00FF88",
            bg="#141820",
            padx=10,
            pady=6,
        )
        self.lbl_info.pack(fill=tk.X)

        self.canvas = tk.Canvas(self.root, width=640, height=480, bg="black", highlightthickness=0)
        self.canvas.pack(padx=8, pady=4)
        self.img_id = None
        self.tk_img = None

        self.lbl_hint = tk.Label(
            self.root,
            text="Sarı Çerçeve: Göz Hedef Alanı (ROI) | Kırmızı Maske: Algılanan Koyu İris | Yeşil Artı (+): Göz Bebeği Merkezi",
            font=("Segoe UI", 9),
            fg="#CCCCCC",
            bg="#141820",
            pady=4,
        )
        self.lbl_hint.pack(fill=tk.X)

        self.running = True
        self.lock = threading.Lock()
        self.latest_ppm = None
        self.latest_status = None
        self.latest_valid = False
        self.new_frame_ready = False

        self.worker = threading.Thread(target=self.serial_worker, daemon=True)
        self.worker.start()

        self.root.protocol("WM_DELETE_WINDOW", self.on_close)
        self.root.after(15, self.update_gui)

    def serial_worker(self):
        ser = None
        try:
            ser = hil.Win32Serial("COM7", 921600)
            ser.purge()
            ser.write(b"\x00")
            time.sleep(0.05)
            ser.purge()

            frame_cnt = 0
            last_save_t = 0.0
            fps_ema = 18.0
            t_prev = time.perf_counter()

            while self.running:
                ser.write(b"\xC6")  # 8 + 4800 = 4808 bytes Turbo 80x60 stream
                raw = ser.read_exact(4808, timeout_s=0.4)
                if len(raw) != 4808 or raw[0] != 0xAA or raw[1] != 0x55:
                    ser.purge()
                    time.sleep(0.02)
                    continue

                t_now = time.perf_counter()
                dt = max(1e-3, t_now - t_prev)
                t_prev = t_now
                fps_ema = 0.8 * fps_ema + 0.2 * (1.0 / dt)

                telem = hil.parse_telemetry(raw[:8])
                fb_80x60 = np.frombuffer(raw[8:], dtype=np.uint8).reshape((60, 80))
                gray_320x240 = upscale_80x60_to_320x240_smooth(fb_80x60)
                osd_320x240 = hil.render_fpga_osd_320x240(gray_320x240, telem)
                osd_640x480 = np.repeat(np.repeat(osd_320x240, 2, axis=0), 2, axis=1)

                ppm_bytes = b"P6\n640 480\n255\n" + osd_640x480.tobytes()
                frame_cnt += 1
                status_str = "KİLİTLENDİ (LOCK)" if telem["pupil_valid"] else "ARANIYOR..."
                line = (
                    f"[{status_str}]  Pupil: ({telem['pupil_x']:3d}, {telem['pupil_y']:3d})  |  "
                    f"Çekirdek: ({telem['core_x']:3d}, {telem['core_y']:3d})  |  "
                    f"Eşik: {telem['active_thresh']:3d}  |  Luma: {fb_80x60.mean():4.1f}  |  {fps_ema:4.1f} FPS"
                )

                with self.lock:
                    self.latest_ppm = ppm_bytes
                    self.latest_status = line
                    self.latest_valid = telem["pupil_valid"]
                    self.new_frame_ready = True

                if (t_now - last_save_t) >= 0.9:
                    last_save_t = t_now
                    write_png_fast(LATEST_TMP, osd_640x480)
                    os.replace(LATEST_TMP, LATEST_PNG)
                    with open(TELEM_LOG, "w", encoding="utf-8") as f:
                        f.write(f"frame={frame_cnt} {line}\n")
        except Exception as e:
            with self.lock:
                self.latest_status = f"Bağlantı hatası: {e}"
                self.new_frame_ready = True
        finally:
            if ser is not None:
                ser.close()

    def update_gui(self):
        if not self.running:
            return
        ppm = None
        status = None
        valid = False
        with self.lock:
            if self.new_frame_ready:
                ppm = self.latest_ppm
                status = self.latest_status
                valid = self.latest_valid
                self.new_frame_ready = False

        if status is not None:
            self.lbl_info.config(fg="#00FF66" if valid else "#FFCC00")
            self.info_var.set(status)

        if ppm is not None:
            self.tk_img = tk.PhotoImage(data=ppm, format="PPM")
            if self.img_id is None:
                self.img_id = self.canvas.create_image(0, 0, anchor=tk.NW, image=self.tk_img)
            else:
                self.canvas.itemconfig(self.img_id, image=self.tk_img)

        self.root.after(15, self.update_gui)

    def on_close(self):
        self.running = False
        self.root.after(100, self.root.destroy)


if __name__ == "__main__":
    root = tk.Tk()
    app = FPGALiveMonitorApp(root)
    root.mainloop()
