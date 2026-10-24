# Offline checks for fold_prove_detect (run: python tools/fold_prove/test_fold_prove_detect.py)
import sys
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from fold_prove_detect import detect_menu, compute_gates


def sensitivity_frame(h=432, w=480):
    a = np.zeros((h, w, 3), np.uint8)
    a[:] = (16, 14, 20)
    a[2:int(h * .10), 2:int(w * .09)] = (130, 20, 20)           # Back
    for x0 in (5, 123, 241):                                    # Low/Medium/High
        a[int(h * .11):int(h * .19), x0:x0 + 112] = (130, 20, 20)
    a[int(h * .21):int(h * .27), 130:470] = (130, 20, 20)        # Gyro row
    a[int(h * .04):int(h * .06), 200:280] = (230, 190, 60)       # gold title
    return a


def match_frame(h=432, w=480):
    a = np.full((h, w, 3), 77, np.uint8)
    a[300:400, 20:120] = (240, 240, 240)  # stick knob
    return a


METRICS = dict(move_world=True, look_world=True, fire_game=True, visible_pass=True,
               camera_fail_magenta=False, gray77_hud_only=False, move_hud=True, look_hud=True, fire_hud=True)

assert detect_menu(sensitivity_frame(), use_ocr=False)[0]
assert not detect_menu(match_frame(), use_ocr=False)[0]
g = compute_gates(True, {"01_rest": True}, METRICS)
assert not g["in_match"] and g["looks_like_menu"]
assert set(g["gates_strict"].values()) == {"FAIL"}
g = compute_gates(True, {"01_rest": False, "c_final": True}, METRICS)
assert not g["in_match"] and set(g["gates_strict"].values()) == {"FAIL"}
g = compute_gates(True, {"01_rest": False}, METRICS)
assert g["in_match"] and set(g["gates_strict"].values()) == {"PASS"}
from fold_prove_detect import host_button_xy, start_button_xy
_a = np.full((1000, 600, 3), 77, dtype=np.uint8)
_a[100:200, 200:400] = (130, 20, 20)  # Host
_a[300:400, 200:400] = (130, 20, 20)  # Sensitivity
_a[900:960, 0:600] = (130, 20, 20)    # lobby bottom row
assert host_button_xy(_a) == (299, 150)
assert start_button_xy(_a) == (299, 930)
print("OK")
