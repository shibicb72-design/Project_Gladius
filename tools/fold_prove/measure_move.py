# measure_move.py - offline numbers for the move world gate from an existing prove run's PNGs.
# Run: python tools/fold_prove/measure_move.py [build_dir]
import sys
from pathlib import Path
import numpy as np
from PIL import Image

BUILD = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "build"


def load(name):
    return np.array(Image.open(BUILD / name).convert("RGB"))


def pct(a, b, thr=12):
    d = np.abs(a.astype(np.int16) - b.astype(np.int16)).max(axis=-1)
    return 100.0 * float((d > thr).mean())


def center_world(a):
    h, w = a.shape[:2]
    return a[h // 4:3 * h // 4, w // 4:3 * w // 4]


def knob(a, y0, y1, x0, x1):
    """Centroid of near-white pixels (the stick knob) inside a box."""
    m = np.all(a[y0:y1, x0:x1] > 240, axis=-1)
    ys, xs = np.nonzero(m)
    if not len(xs):
        return None
    return round(float(xs.mean()) + x0), round(float(ys.mean()) + y0), int(m.sum())


rest = load("fold_prove_01_rest.png")
h, w = rest.shape[:2]
print("shape", rest.shape)
for n in ("fold_prove_02_move_held.png", "fold_prove_04_after_move.png",
          "fold_prove_05_look_held.png", "fold_prove_06_after_look.png"):
    if (BUILD / n).exists():
        print(n, "center_world_pct", round(pct(center_world(rest), center_world(load(n))), 2))
for n in ("fold_prove_01_rest.png", "fold_prove_02_move_held.png", "fold_prove_04_after_move.png"):
    if (BUILD / n).exists():
        print(n, "move_knob", knob(load(n), int(h * 0.55), h, 0, int(w * 0.35)))
