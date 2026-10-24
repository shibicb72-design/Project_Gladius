# fold_prove_detect.py — menu/overlay detection + gate logic shared by fold prove harnesses.
# Pure functions (numpy/PIL only; OCR via pytesseract is optional) so they can be unit tested offline.
import numpy as np

SCHEMA_VERSION = 2
MENU_WORDS = ("sensitivity", "gyro:", "gyro", "invert x", "invert y", "resume", "settings", "paused")


def _frac(mask):
    return float(mask.mean()) if mask.size else 0.0


def chrome_masks(a):
    """Colour masks for the Sensitivity/pause menu chrome (dark bg, maroon buttons, gold text)."""
    r = a[:, :, 0].astype(np.int16)
    g = a[:, :, 1].astype(np.int16)
    b = a[:, :, 2].astype(np.int16)
    dark = (r < 40) & (g < 40) & (b < 45)
    maroon = (r > 100) & (r < 200) & (g < 50) & (b < 60) & (r - g > 70)
    gold = (r > 190) & (g > 150) & (g < 215) & (b < 90)
    return dark, maroon, gold


def ocr_text(a):
    """Best-effort OCR; returns lowercase text or '' when pytesseract/tesseract is unavailable."""
    try:
        import pytesseract
        from PIL import Image
        return pytesseract.image_to_string(Image.fromarray(a)).lower()
    except Exception:
        return ""


def detect_menu(a, use_ocr=True):
    """Return (is_menu, reasons). True for Sensitivity / pause / settings / lobby chrome.

    Pixel rules (resolution independent, all fractions of the frame):
      - back_button: maroon block in the top-left corner (the Back button)
      - button_rows: maroon full-width button rows near the top (Low/Medium/High, Gyro row)
      - dark_bg: near-black panel background dominating the frame
      - gold_text: gold label text plentiful
    A match HUD has none of the maroon rows; the blank world is mid-gray (77), not near-black.
    """
    h, w = a.shape[:2]
    dark, maroon, gold = chrome_masks(a)
    reasons = []
    back = _frac(maroon[: max(1, int(h * 0.12)), : max(1, int(w * 0.12))]) > 0.25
    rows = _frac(maroon[int(h * 0.10): int(h * 0.30), :]) > 0.10
    dark_bg = _frac(dark) > 0.35
    gold_text = _frac(gold) > 0.003
    if back:
        reasons.append("back_button")
    if rows:
        reasons.append("button_rows")
    if dark_bg:
        reasons.append("dark_bg")
    if gold_text:
        reasons.append("gold_text")
    maroon_any = _frac(maroon) > 0.02
    # Sensitivity is near-black + gold labels + maroon chrome; do NOT require gray77
    sens = dark_bg and gold_text and maroon_any
    pixel_menu = sens or (rows and (dark_bg or back)) or (back and dark_bg and gold_text)
    if use_ocr:
        txt = ocr_text(a)
        hits = [wd for wd in MENU_WORDS if wd in txt]
        if "sensitivity" in hits or "gyro:" in hits or len(hits) >= 2:
            reasons.append("ocr:" + ",".join(hits))
            pixel_menu = True
    return bool(pixel_menu), reasons


def classify_frame(a, use_ocr=True):
    is_menu, reasons = detect_menu(a, use_ocr=use_ocr)
    return {"menu": is_menu, "reasons": reasons}


def maroon_bands(a, min_row_frac=0.08, min_height=20):
    """Horizontal bands of maroon menu buttons, top to bottom: [(y0, y1, x0, x1), ...].
    Lets the harness tap real buttons (Host, Start) instead of spraying blind taps that can hit Sensitivity."""
    _, maroon, _ = chrome_masks(a)
    rows = maroon.mean(axis=1) > min_row_frac
    bands = []
    y = 0
    h = len(rows)
    while y < h:
        if not rows[y]:
            y += 1
            continue
        y0 = y
        while y < h and rows[y]:
            y += 1
        if y - y0 >= min_height:
            cols = np.where(maroon[y0:y].any(axis=0))[0]
            bands.append((y0, y, int(cols[0]), int(cols[-1])))
    return bands


def host_button_xy(a):
    """Centre of the first maroon band on the main menu (Host sits first, above Join/Sensitivity)."""
    bands = maroon_bands(a)
    if not bands:
        return None
    y0, y1, x0, x1 = bands[0]
    return (x0 + x1) // 2, (y0 + y1) // 2


def start_button_xy(a):
    """Lobby Start = middle third of the bottom maroon row (Class | Start | Back)."""
    bands = maroon_bands(a)
    if not bands:
        return None
    y0, y1, x0, x1 = bands[-1]
    return x0 + (x1 - x0) // 2, (y0 + y1) // 2


def back_button_xy(shape):
    """Approximate centre of the top-left Back button for a frame of the given (h, w, ...) shape."""
    h, w = shape[:2]
    return int(w * 0.05), int(h * 0.05)


def compute_gates(rest_is_match, frame_menu, metrics):
    """Combine pixel metrics with menu state. Any menu frame => everything FAIL, in_match=False.

    rest_is_match: rest frame looks like match HUD (and is not a menu).
    frame_menu: dict frame_name -> bool (True if that frame is a menu/overlay).
    metrics: dict with move_world, look_world, fire_game, visible_pass, camera_fail_magenta,
             gray77_hud_only, move_hud, look_hud, fire_hud (all bool).
    """
    menu_frames = sorted(k for k, v in frame_menu.items() if v)
    in_match = bool(rest_is_match) and not menu_frames
    looks_menu = bool(menu_frames)
    m = metrics

    def gate(ok):
        return "PASS" if (in_match and ok) else "FAIL"

    strict = {
        "move": gate(m["move_world"]),
        "look": gate(m["look_world"]),
        "fire": gate(m["fire_game"]),
        "visible_pawn": gate(m["visible_pass"] and not m["camera_fail_magenta"] and not m["gray77_hud_only"]),
    }
    if not in_match:
        why = "FAIL_menu" if looks_menu else "FAIL_no_match_hud"
        detail = {"move": why, "look": why, "fire": why, "visible_pawn": why}
    else:
        detail = {
            "visible_pawn": strict["visible_pawn"] if not m["gray77_hud_only"] else "FAIL_gray77_HUD",
            "move": "PASS" if m["move_world"] else ("HUD_PASS/world_FAIL" if m["move_hud"] else "FAIL"),
            "look": "PASS" if m["look_world"] else ("HUD_PASS/world_FAIL" if m["look_hud"] else "FAIL"),
            "fire": "PASS" if m["fire_game"] else ("HUD_PASS/gameplay_FAIL" if m["fire_hud"] else "FAIL"),
        }
    detail["in_match"] = in_match
    detail["looks_like_menu"] = looks_menu
    return {"in_match": in_match, "looks_like_menu": looks_menu, "menu_frames": menu_frames,
            "gates_strict": strict, "gates_detail": detail}
