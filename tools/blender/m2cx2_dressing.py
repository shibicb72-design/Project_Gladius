"""Alesia 500 foliage and civic dressing, authored as compound structure pieces."""

from pathlib import Path
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

from m2w1_world_kit import box, fplate, fquad, lathe, wheel
from m2cx2_export import export_family


def grove(b, data, near):
    # Group three trees in one shape owner. Smaller companion trees break the silhouette.
    for x, z, h, w in ((-2.15, 0.30, 4.9, 0.66), (0, -0.52, 6.3, 0.76), (2.2, 0.38, 4.2, 0.60)):
        b.set("timber", shade=0.30)
        lathe(b, x, z, [(0, 0.31), (0.34, 0.22), (1.46, 0.17)], 6 if near else 4)
        # Existing paint with matte plaster response and per-facet shade. Muted dry cypress.
        b.set("cloth", "plaster", shade=0.26, jitter=0.06)
        lathe(
            b,
            x,
            z,
            [(0.84, 0.24), (1.27, w * 0.88), (h * 0.54, w), (h * 0.78, w * 0.66), (h, 0.025)],
            7 if near else 4,
        )


def field_edge(b, data, near):
    b.set("rock", shade=0.31)
    box(b, (-3.45, 0, -0.55), (3.45, 0.30, 0.55))
    for i in range(5 if near else 3):
        n = 5 if near else 3
        x = -3.45 + i * 6.9 / n
        b.set("travertine_shade", shade=0.41, jitter=0.08)
        box(b, (x + 0.019, 0.28, -0.43), (x + 6.9 / n - 0.019, 1.27, 0.43), chamfer=0.036 if near else 0)
    b.set("travertine", shade=0.5)
    box(b, (-3.40, 1.27, -0.48), (3.40, 1.52, 0.48))


def stall(b, data, near):
    for x in (-1.5, 1.5):
        for z in (-1.42, 1.42):
            b.set("timber", shade=0.34)
            box(b, (x - 0.09, 0, z - 0.09), (x + 0.09, 2.69 - z * 0.14, z + 0.09))
    b.set("travertine_shade", shade=0.4)
    box(b, (-1.58, 0, 0.97), (1.58, 0.87, 1.53))
    b.set("timber", shade=0.44)
    box(b, (-1.62, 0.87, 0.93), (1.62, 1.0, 1.60))
    width = 3.58
    for i in range(6):
        x = -width * 0.5 + width * i / 6
        x1 = x + width / 6
        b.set("legion_red" if i % 2 == 0 else "canvas", "cloth", shade=0.52)
        pts = [(x, 2.95, -1.55), (x1, 2.95, -1.55), (x1, 2.50, 1.55), (x, 2.50, 1.55)]
        b.poly(pts, (0, 1, 0))
        b.poly([(a, y - 0.012, z) for a, y, z in pts], (0, -1, 0))
        fquad(b, "+z", 1.55, x, x1, 2.34, 2.50)
        fquad(b, "-z", -1.55, x, x1, 2.79, 2.95)
    if near:
        for x in (-0.92, -0.47, 0, 0.51, 0.99):
            b.set("roof_tile", shade=0.44)
            lathe(b, x, 1.28, [(1, 0.13), (1.10, 0.18), (1.18, 0.16), (1.26, 0.09)], 5, caps=(False, True))


def waystation(b, data, near):
    # A single body carries the basin, statue, flag staff and emissive brazier.
    b.set("travertine_shade", shade=0.39)
    lathe(
        b,
        0,
        0,
        [
            (0, 1.02),
            (0.21, 1.02),
            (0.24, 0.85),
            (0.82, 0.85),
            (0.86, 1),
            (0.99, 1),
            (0.99, 0.76),
            (0.71, 0.76),
        ],
        8 if near else 4,
    )
    b.set("dark", shade=0.33)
    lathe(b, 0, 0, [(0.71, 0.77)], 8 if near else 4, caps=(False, True))
    b.set("marble", shade=0.51)
    box(b, (-0.55, 0, -1.77), (0.55, 0.95, -0.75))
    b.set("bronze", shade=0.4)
    lathe(
        b,
        0,
        -1.26,
        [
            (0.95, 0.38),
            (1.13, 0.40),
            (1.33, 0.27),
            (1.62, 0.32),
            (1.93, 0.44),
            (2.28, 0.35),
            (2.41, 0.15),
            (2.53, 0.21),
            (2.8, 0.19),
            (2.88, 0.05),
        ],
        7 if near else 4,
    )
    b.set("timber", shade=0.34)
    box(b, (1.38, 0, -0.18), (1.59, 4.1, 0.08))
    b.set("legion_red", "cloth", shade=0.50)
    for n in ("-z", "+z"):
        fplate(b, n, 0, [(1.58, 3.92), (2.50, 3.92), (2.50, 2.73), (2.04, 2.48), (1.58, 2.73)], 0.023, 0.046)
    b.set("bronze", shade=0.56)
    lathe(b, 1.48, -0.04, [(3.98, 0.13), (4.16, 0.15), (4.32, 0)], 6 if near else 4)
    lathe(
        b,
        -1.62,
        0.45,
        [(0, 0.31), (0.15, 0.31), (0.31, 0.11), (0.91, 0.11), (1.15, 0.37), (1.29, 0.36)],
        7 if near else 4,
    )
    b.set("ember", shade=0.57)
    lathe(b, -1.62, 0.45, [(1.23, 0.285), (1.46, 0.13), (1.53, 0.015)], 7 if near else 4)


def cart(b, data, near):
    for sign in (-1, 1):
        wheel(b, sign, -0.21, 0.54, sign * 0.70, 0.54, 0.14)
        z = sign * 0.52
        b.set("timber", shade=0.42)
        box(b, (-1.15, 0.60, z - 0.073), (1.66, 0.76, z + 0.073))
        b.set("travertine_shade", shade=0.42)
        box(b, (1.42, 0, z - 0.068), (1.56, 0.61, z + 0.068))
    b.set("timber", shade=0.49)
    box(b, (-1.14, 0.76, -0.53), (0.93, 0.85, 0.53))
    for z in (-0.50, 0.50):
        box(b, (-1.14, 0.85, z - 0.06), (0.93, 1.21, z + 0.06))
    b.set("bronze", shade=0.43)
    box(b, (-1.21, 0.85, -0.53), (-1.12, 1.17, 0.53))


if __name__ == "__main__":
    export_family(
        "dressing",
        {
            "cypress_group": grove,
            "farm_boundary": field_edge,
            "forum_stall": stall,
            "waystation": waystation,
            "farm_cart": cart,
        },
    )
