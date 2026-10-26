import os
import subprocess
import numpy as np

FFMPEG = r"C:\Users\Mert\AppData\Local\Microsoft\WinGet\Packages\yt-dlp.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-N-123285-g299383611d-win64-gpl\bin\ffmpeg.exe"
if not os.path.exists(FFMPEG):
    FFMPEG = "ffmpeg"

VID_DIR = r"c:\Users\Mert\Desktop\robotkol\test_videos"
OUT_DIR = r"C:\Users\Mert\.gemini\antigravity\brain\cc411731-29cb-499e-a900-28c85e2af7db\scratch\sim_results"
os.makedirs(OUT_DIR, exist_ok=True)

videos = sorted([os.path.join(VID_DIR, f) for f in os.listdir(VID_DIR) if f.endswith(".mp4")])

# Single-eye ROI: 140x80 centered at (160, 144) -> X: 90..230, Y: 104..184
ROI_X_MIN = 90
ROI_X_MAX = 230
ROI_Y_MIN = 104
ROI_Y_MAX = 184

# Buffer X range: 64..256 (192 pixels = 96 sub-columns, or 32..288 = 128 sub-columns)
BUF_X_MIN = 32
BUF_X_MAX = 288
BUF_Y_MIN = 64
BUF_Y_MAX = 224


def run_fpga_pupil_detector_frame(gray320x240, state):
    """
    Bit-exact hardware model of the 4-Row Circular BSRAM Concentric Disc-Surround Pupil Detector (v9):
    Uses ONLY 4 buffered sub-row offsets relative to current incoming sub-row `r_curr = sy + 13`:
      - Row `sy - 3` (r_curr - 16): c_tl(sx-3), c_up(sx), c_tr(sx+3)
      - Row `sy`     (r_curr - 13): L2(sx-14), L1(sx-11), c_lf(sx-4), c0(sx), c_rt(sx+4), R1(sx+11), R2(sx+14)
      - Row `sy + 3` (r_curr - 10): c_bl(sx-3), c_dn(sx), c_br(sx+3)
      - Row `sy + 10`(r_curr - 3) : B_out(sx) (+20px below center)
      - Row `sy + 13`(r_curr, 0)  : below_far(sx) (+26px below center, already in register!)
    """
    buf = gray320x240[BUF_Y_MIN:BUF_Y_MAX, BUF_X_MIN:BUF_X_MAX].astype(np.int32)

    # Glint-bridging horizontal filter (3-tap spike removal + 2-tap min)
    p_l = np.pad(buf[:, :-1], ((0, 0), (1, 0)), mode='edge')
    p_r = np.pad(buf[:, 1:], ((0, 0), (0, 1)), mode='edge')
    glint_b1 = np.minimum(buf, np.maximum(p_l, p_r))
    glint_b2 = np.minimum(glint_b1, np.pad(glint_b1[:, :-2], ((0, 0), (2, 0)), mode='edge'))

    # 2x2 subsampled buffer (1 cell = 2x2 pixels)
    sub = (
        glint_b2[0::2, 0::2] +
        glint_b2[0::2, 1::2] +
        glint_b2[1::2, 0::2] +
        glint_b2[1::2, 1::2]
    ) >> 2

    SX_MIN = (ROI_X_MIN - BUF_X_MIN) // 2
    SX_MAX = (ROI_X_MAX - BUF_X_MIN) // 2
    SY_MIN = (ROI_Y_MIN - BUF_Y_MIN) // 2
    SY_MAX = (ROI_Y_MAX - BUF_Y_MIN) // 2

    best_score = -9999
    best_sx = state['core_x']
    best_sy = state['core_y']
    best_c_val = 255

    for sy in range(SY_MIN, SY_MAX):
        for sx in range(SX_MIN, SX_MAX):
            # 1. 9-Point 16x12 Solid Inner Disc using ONLY 3 rows (sy-3, sy, sy+3):
            pts = [
                int(sub[sy, sx]),          # c0
                int(sub[sy - 3, sx]),      # c_up
                int(sub[sy + 3, sx]),      # c_dn
                int(sub[sy, sx - 4]),      # c_lf
                int(sub[sy, sx + 4]),      # c_rt
                int(sub[sy - 3, sx - 3]),  # c_tl
                int(sub[sy - 3, sx + 3]),  # c_tr
                int(sub[sy + 3, sx - 3]),  # c_bl
                int(sub[sy + 3, sx + 3]),  # c_br
            ]
            pts_sorted = sorted(pts)
            max1 = pts_sorted[8]  # Drop single brightest point (glint immunity!)
            max2 = pts_sorted[7]  # Second-brightest point (must be dark for solid disc!)
            c0 = pts[0]

            c_disc = (sum(pts) - max1) >> 3
            disc_spread = max2 - c0

            # 2. Horizontal Surround on row `sy` at +/- 22px (11 cells) and +/- 28px (14 cells)
            L_out = max(int(sub[sy, sx - 11]), int(sub[sy, sx - 14]))
            R_out = max(int(sub[sy, sx + 11]), int(sub[sy, sx + 14]))

            diff_L = L_out - c_disc
            diff_R = R_out - c_disc
            min_lr = min(diff_L, diff_R)
            max_lr = max(diff_L, diff_R)

            # 3. Lower Boundary on row `sy + 10` (+20px below center)
            B_out = int(sub[sy + 10, sx])
            diff_B = B_out - c_disc

            # 4. Eyebrow Rejection on current incoming row `sy + 13` (+26px below center)
            below_far = int(sub[sy + 13, sx])
            brow_penalty = max(0, (c_disc + 16) - below_far) * 4

            if (c_disc < 92) and (max2 < 108) and (disc_spread <= 40) and (min_lr >= 10) and (max_lr >= 20) and (diff_B >= 10):
                min_lr_cap = min(32, min_lr)
                max_lr_cap = min(48, max_lr)
                diff_B_cap = min(36, diff_B)

                px_full = BUF_X_MIN + sx * 2 + 1
                py_full = BUF_Y_MIN + sy * 2 + 1
                top_penalty = max(0, (118 - py_full) * 3)
                side_penalty = max(0, (98 - px_full)) + max(0, (px_full - 222))

                score = (
                    ((128 - c_disc) * 4) +
                    ((128 - max2) * 2) +
                    (min_lr_cap * 2) +
                    max_lr_cap +
                    diff_B_cap -
                    brow_penalty -
                    top_penalty -
                    side_penalty
                )
                if score > best_score:
                    best_score = score
                    best_sx = px_full
                    best_sy = py_full
                    best_c_val = c_disc

    # In single-pass streaming hardware, centroid is accumulated around prev_core_x/y during the scan,
    # while best_sx/best_sy is found by the 16-row BSRAM 2D Disc-Surround detector.
    prev_core_x = state['core_x']
    prev_core_y = state['core_y']
    thresh = state['active_thresh']

    sum_px = 0
    sum_py = 0
    sum_w = 0
    mask = np.zeros((240, 320), dtype=bool)

    for py in range(ROI_Y_MIN, ROI_Y_MAX):
        if abs(py - prev_core_y) <= 10:
            for px in range(ROI_X_MIN, ROI_X_MAX):
                if abs(px - prev_core_x) <= 13:
                    val = int(glint_b2[py - BUF_Y_MIN, px - BUF_X_MIN])
                    if val <= thresh:
                        w = min(16, (thresh - val) + 1)
                        sum_px += px * w
                        sum_py += py * w
                        sum_w += w
                        mask[py, px] = True

    valid_detect = (best_score >= 380)
    if valid_detect:
        state['core_x'] = best_sx
        state['core_y'] = best_sy
        state['active_thresh'] = min(120, max(20, best_c_val + 16))
        if (abs(best_sx - prev_core_x) <= 12) and (abs(best_sy - prev_core_y) <= 10) and (sum_w >= 20):
            qx = sum_px // sum_w
            qy = sum_py // sum_w
        else:
            qx = best_sx
            qy = best_sy
        state['pupil_x'] = (state['pupil_x'] + qx) >> 1
        state['pupil_y'] = (state['pupil_y'] + qy) >> 1
        state['pupil_valid'] = True
    else:
        state['pupil_valid'] = False

    return state['pupil_x'], state['pupil_y'], state['pupil_valid'], state['core_x'], state['core_y'], state['active_thresh'], mask


configs = [
    (0, "crop=440:330:0:135,scale=320:240", "vid1_right_eye"),
    (1, "crop=520:390:245:0,scale=320:240", "vid2_dual_eye"),
    (2, "crop=440:330:95:225,scale=320:240", "vid3_left_eye"),
    (3, "crop=680:510:180:15,scale=320:240", "vid4_closeup_eye"),
]

for v_idx, vf, name in configs:
    vpath = videos[v_idx]
    cmd = [
        FFMPEG, "-i", vpath,
        "-vf", f"fps=15,{vf}",
        "-f", "rawvideo", "-pix_fmt", "gray", "-"
    ]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    raw = np.frombuffer(p.stdout, dtype=np.uint8)
    num_frames = len(raw) // (320 * 240)
    frames = raw[:num_frames * 320 * 240].reshape((num_frames, 240, 320))

    state = {
        'core_x': 160,
        'core_y': 144,
        'pupil_x': 160,
        'pupil_y': 144,
        'active_thresh': 48,
        'pupil_valid': False
    }

    sample_indices = np.linspace(0, num_frames - 1, 20, dtype=int)
    montage_tiles = []
    valid_cnt = 0

    for f_i in range(num_frames):
        gray = frames[f_i]
        px, py, pval, cx, cy, th, mask = run_fpga_pupil_detector_frame(gray, state)
        if pval:
            valid_cnt += 1

        if f_i in sample_indices:
            rgb = np.stack([gray, gray, gray], axis=-1)
            rgb[mask, 0] = 200
            rgb[mask, 2] = np.minimum(255, rgb[mask, 2].astype(np.int32) + 40).astype(np.uint8)

            rgb[ROI_Y_MIN, ROI_X_MIN:ROI_X_MAX+1] = [0, 220, 255]
            rgb[ROI_Y_MAX, ROI_X_MIN:ROI_X_MAX+1] = [0, 220, 255]
            rgb[ROI_Y_MIN:ROI_Y_MAX+1, ROI_X_MIN] = [0, 220, 255]
            rgb[ROI_Y_MIN:ROI_Y_MAX+1, ROI_X_MAX] = [0, 220, 255]

            if pval:
                y0, y1 = max(0, py - 8), min(239, py + 8)
                x0, x1 = max(0, px - 8), min(319, px + 8)
                rgb[py-1:py+2, x0:x1+1] = [0, 255, 60]
                rgb[y0:y1+1, px-1:px+2] = [0, 255, 60]

            tile = rgb[80:200, 70:250]
            montage_tiles.append(tile)

    rows = []
    for r in range(4):
        rows.append(np.concatenate(montage_tiles[r*5:(r+1)*5], axis=1))
    grid = np.concatenate(rows, axis=0)

    out_png = os.path.join(OUT_DIR, f"{name}_tracking_v9.png")
    cmd_save = [
        FFMPEG, "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
        "-s", f"{grid.shape[1]}x{grid.shape[0]}", "-i", "-", out_png
    ]
    subprocess.run(cmd_save, input=grid.tobytes(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    print(f"{name}: {valid_cnt}/{num_frames} valid frames ({100.0*valid_cnt/num_frames:.1f}%) -> {out_png}")
