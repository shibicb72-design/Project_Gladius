"""Alesia 500 landmark grades. The shared W1 GLB is never exported by this script."""

from pathlib import Path
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

from m2w1_world_kit import (
    box,
    build_aqueduct_span,
    DIRS,
    fplate,
    fpt,
    fquad,
    lathe,
)
from m2cx2_export import export_family


def signal_eagle(b, data, near):
    b.set("travertine_shade", shade=0.33)
    box(b, (-0.86, 0, -0.86), (0.86, 0.22, 0.86))
    b.set("marble", shade=0.47)
    box(b, (-0.68, 0.22, -0.68), (0.68, 1.23, 0.68))
    b.set("bronze", shade=0.45)
    lathe(b, 0, 0, [(1.15, 0.49), (1.35, 0.38), (2.10, 0.27), (9.55, 0.22)], 8 if near else 4)
    for n, w in (("-z", -0.26), ("+z", 0.26), ("-x", -0.26), ("+x", 0.26)):
        b.set("legion_red", shade=0.54)
        fplate(b, n, w, [(-0.82, 5.45), (-0.82, 8.45), (0.82, 8.45), (0.82, 5.45), (0, 5.05)], 0, 0.035)
        b.set("bronze", shade=0.49)
        fquad(b, n, w, -0.84, 0.84, 8.43, 8.62, 0.06)
        b.set("lit_accent", shade=0.43)
        fquad(b, n, w, -0.06, 0.06, 5.75, 8.12, 0.045)
        b.set("bronze", shade=0.59)
        wings = [
            (-3.12, 11.54),
            (-2.60, 11.83),
            (-0.48, 10.63),
            (0, 10.87),
            (0.48, 10.63),
            (2.60, 11.83),
            (3.12, 11.54),
            (2.92, 10.98),
            (1.32, 9.96),
            (0.30, 9.74),
            (0, 9.24),
            (-0.30, 9.74),
            (-1.32, 9.96),
            (-2.92, 10.98),
        ]
        if near:
            fplate(b, n, 0, wings, 0.116, 0.232)
        else:
            b.poly([fpt(n, 0, x, y, 0.232) for x, y in wings], DIRS[n])
        b.set("gold", shade=0.63)
        fplate(
            b,
            n,
            0.0,
            [(-0.3, 10.79), (-0.17, 11.68), (0.31, 11.56), (0.57, 11.25), (0.14, 11.22), (0.23, 10.79)],
            0.235,
            0.27,
        )
        b.set("lit_accent", shade=0.48)
        fquad(b, n, 0.0, -0.33, 0.33, 10.13, 10.24, 0.275)


def tower(b, data, near):
    # Mounted exactly over the existing corner aerial, with a bronze collar and red signal fins.
    b.set("bronze", shade=0.42)
    lathe(b, 0, 0, [(0, 0.096), (7.85, 0.096), (8.08, 0.16), (8.32, 0.16)], 6)
    for n in ("-z", "+z", "-x", "+x"):
        b.set("legion_red", shade=0.49)
        fplate(b, n, 0, [(-0.67, 7.58), (-0.67, 8.48), (0.67, 8.48), (0.67, 7.58), (0, 7.31)], 0.014, 0.062)
    b.set("bronze", shade=0.58)
    lathe(
        b,
        0,
        0,
        [(8.39, 0.53), (8.52, 0.53), (8.70, 0.33), (9.13, 0.32), (9.32, 0.56), (9.43, 0.56), (9.72, 0.16)],
        6,
    )
    b.set("ember", shade=0.58)
    lathe(b, 0, 0, [(8.66, 0.34), (9.14, 0.34)], 6)


def aqueduct(b, data, near):
    build_aqueduct_span(b, data, 0 if near else 1)
    for n, w in (("-z", -1.4), ("+z", 1.4)):
        b.set("travertine_shade", shade=0.37)
        fquad(b, n, w, -4.97, 4.97, 4.66, 4.84, 0.093)
        b.set("bronze", shade=0.50)
        fquad(b, n, w, -4.97, 4.97, 4.83, 4.96, 0.101)
        b.set("lit_accent", shade=0.47)
        fquad(b, n, w, -1.12, 1.12, 4.72, 4.78, 0.103)
        for x in (-4.48, 4.48):
            b.set("marble", shade=0.5)
            fquad(b, n, w, x - 0.35, x + 0.35, 0.21, 3.47, 0.084)
            b.set("legion_red", shade=0.45)
            fquad(b, n, w, x - 0.37, x + 0.37, 3.50, 4.08, 0.089)


if __name__ == "__main__":
    export_family(
        "landmarks",
        {
            "arx_signal_eagle": signal_eagle,
            "specula_beacon": tower,
            "aqua_keystone": aqueduct,
        },
    )
