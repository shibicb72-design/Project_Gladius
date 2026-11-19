"""Alesia 500 civic buildings. Original procedural meshes, built with the W1 vertex pipeline."""

from pathlib import Path
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

from m2w1_world_kit import (
    box,
    bounds,
    fbox,
    fplate,
    fquad,
    lathe,
    prism,
    ring_run,
    wall_rects,
)
from m2cx2_export import export_family


def housing_shell(b, data, paint, near):
    """Keep the two barracks-sized doors, the window and the continuous ground floor."""
    opens = data.types["barracks"]["open"]
    for nm, sign, indices in (("-z", -1, (0, 2)), ("+z", 1, (1,))):
        gaps = []
        for i in indices:
            lo, hi = bounds(opens[i])
            gaps.append((lo[0], hi[0], lo[1], hi[1]))
        w = sign * 3
        b.set(paint, shade=0.45)
        wall_rects(b, nm, w, -4.5, 4.5, 0, 3.0, gaps)
        b.set("travertine_shade", shade=0.32)
        wall_rects(b, "+z" if sign < 0 else "-z", sign * 2.6, -4.1, 4.1, 0, 3.0, gaps)
        for i, (x0, x1, y0, y1) in enumerate(gaps):
            b.set("marble" if i == 0 else "timber", shade=0.42)
            if not near:
                fquad(b, nm, w, x0 - 0.13, x0, y0, y1, 0.05)
                fquad(b, nm, w, x1, x1 + 0.13, y0, y1, 0.05)
                fquad(b, nm, w, x0 - 0.13, x1 + 0.13, y1, y1 + 0.17, 0.05)
                continue
            fbox(b, nm, w, x0 - 0.13, x0, y0, y1, -0.4, 0.07)
            fbox(b, nm, w, x1, x1 + 0.13, y0, y1, -0.4, 0.07)
            fbox(b, nm, w, x0 - 0.13, x1 + 0.13, y1, y1 + 0.17, -0.4, 0.09)
            if y0 > 0:
                fbox(b, nm, w, x0 - 0.13, x1 + 0.13, y0 - 0.10, y0, -0.4, 0.12)
            elif near:
                b.set("lit_accent", shade=0.32)
                fquad(b, nm, w, x0 + 0.15, x1 - 0.15, y1 + 0.065, y1 + 0.11, 0.095)
    for n, w in (("-x", -4.5), ("+x", 4.5), ("+x", -4.1), ("-x", 4.1)):
        b.set(paint, shade=0.4)
        fquad(b, n, w, -2.6, 2.6, 0, 3)
    b.set("travertine_shade", shade=0.27)
    box(b, (-4.7, 3, -3.2), (4.7, 3.3, 3.2))


def windows(b, y, half_depth, paint, near):
    for n, w in (("-z", -half_depth), ("+z", half_depth)):
        for x in (-3.05, -1.03, 1.03, 3.05):
            b.set("timber", shade=0.2)
            fquad(b, n, w, x - 0.59, x + 0.59, y, y + 1.20, 0.009)
            b.set(paint, shade=0.42)
            fquad(b, n, w, x - 0.49, x + 0.49, y + 0.07, y + 1.11, 0.018)
            b.set("travertine_shade")
            fquad(b, n, w, x - 0.68, x + 0.68, y - 0.13, y, 0.045)
            if near:
                b.set("bronze", shade=0.38)
                fquad(b, n, w, x - 0.48, x + 0.48, y + 0.78, y + 0.84, 0.024)


def roof(b, y, half_width, half_depth, rise):
    b.set("roof_tile", shade=0.45)
    prism(b, "x", [(y, -half_depth), (y, half_depth), (y + rise, 0)], -half_width, half_width)
    b.set("travertine_shade", shade=0.55)
    ring_run(b, 4.5, 3.0, [(y - 0.14, 0), (y - 0.04, 0.07), (y, 0.07)])


def insula(b, data, near, floors):
    housing_shell(b, data, "travertine_shade", near)
    top = 5.55 if floors == 2 else 7.75
    b.set("travertine", "plaster", shade=0.54)
    box(b, (-4.5, 3.3, -3), (4.5, top, 3))
    for y in (3.7, 5.9) if floors == 3 else (3.7,):
        windows(b, y, 3, "legion_red" if floors == 2 else "timber", near)
        b.set("marble", shade=0.44)
        ring_run(b, 4.5, 3, [(y - 0.27, 0), (y - 0.18, 0.075), (y - 0.09, 0.075)])
    roof(b, top, 4.7, 3.2, 1.25)


def shop(b, data, near):
    housing_shell(b, data, "travertine", near)
    # The cloth projects over the display window. The two door aprons remain clear.
    stripes = 8 if near else 4
    for i in range(stripes):
        x0 = -0.45 + i * 4.72 / stripes
        x1 = x0 + 4.72 / stripes
        b.set("legion_red" if i % 2 == 0 else "canvas", "cloth", shade=0.51)
        b.poly([(x0, 3.03, -3.02), (x1, 3.03, -3.02), (x1, 2.58, -4.13), (x0, 2.58, -4.13)], (0, 1, 0))
        b.poly([(x0, 3.018, -3.02), (x1, 3.018, -3.02), (x1, 2.568, -4.13), (x0, 2.568, -4.13)], (0, -1, 0))
        fquad(b, "-z", -4.131, x0, x1, 2.44, 2.58)
    b.set("timber", shade=0.34)
    fbox(b, "-z", -4.10, -0.48, 4.30, 2.55, 2.61, 0, 0.025)
    roof(b, 3.3, 4.7, 3.2, 0.6)


def bath(b, data, near):
    housing_shell(b, data, "marble", near)
    b.set("travertine", shade=0.44)
    box(b, (-3, 3.3, -2.7), (3, 4.65, 2.7))
    b.set("bronze", shade=0.48)
    lathe(
        b,
        0,
        0,
        [(4.65, 2.72), (5.10, 2.72), (5.85, 2.38), (6.38, 1.62), (6.62, 0.67), (6.72, 0)],
        12 if near else 8,
    )
    for n, w in (("-z", -2.7), ("+z", 2.7)):
        b.set("dark", shade=0.35)
        for x in (-1.8, 0, 1.8) if near else (0,):
            fplate(
                b,
                n,
                w,
                [(x - 0.39, 3.54), (x + 0.39, 3.54), (x + 0.39, 4.14), (x, 4.48), (x - 0.39, 4.14)],
                0.009,
                0.035,
            )
    b.set("lit_accent", shade=0.4)
    lathe(b, 0, 0, [(5.08, 2.725), (5.14, 2.725)], 12 if near else 8)


def workshop(b, data, near):
    housing_shell(b, data, "travertine_shade", near)
    roof(b, 3.3, 4.7, 3.2, 1.1)
    for x in (-2.9, 2.9):
        b.set("travertine_shade", shade=0.31)
        box(b, (x - 0.44, 3.48, -0.49), (x + 0.44, 5.52, 0.49))
        b.set("dark", "steel", shade=0.35)
        box(b, (x - 0.50, 5.49, -0.55), (x + 0.50, 5.74, 0.55))
        b.set("bronze", shade=0.55)
        for z in (-0.504, 0.504):
            fquad(b, "-z" if z < 0 else "+z", z, x - 0.40, x + 0.40, 5.03, 5.17)


def temple(b, data, near):
    b.set("travertine_shade", shade=0.34)
    box(b, (-4.9, 0, -3.0), (4.9, 0.33, 3.0))
    b.set("travertine", shade=0.55)
    box(b, (-4.05, 0.33, -2.24), (4.05, 4.5, 2.7))
    for x in (-4.26, -1.42, 1.42, 4.26):
        b.set("marble", shade=0.5)
        lathe(
            b,
            x,
            -2.60,
            [(0.33, 0.4), (0.5, 0.4), (0.6, 0.28), (4.05, 0.23), (4.16, 0.39), (4.5, 0.39)],
            8 if near else 4,
        )
    b.set("legion_red", shade=0.57)
    box(b, (-4.95, 4.5, -3.08), (4.95, 4.83, 3.0))
    b.set("marble", shade=0.57)
    box(b, (-4.95, 4.83, -3.08), (4.95, 5.01, 3.0))
    b.set("roof_tile")
    prism(b, "z", [(-4.95, 5.01), (4.95, 5.01), (0, 6.9)], -3.08, 3.0)
    b.set("marble", shade=0.55)
    fplate(b, "-z", -3.08, [(-4.7, 5.05), (4.7, 5.05), (0, 6.79)], 0, 0.025)
    b.set("bronze", shade=0.43)
    fplate(b, "-z", -3.11, [(-1.85, 5.24), (1.85, 5.24), (0, 6.05)], 0, 0.025)
    b.set("lit_accent", shade=0.41)
    fquad(b, "-z", -3.11, -3.95, 3.95, 4.64, 4.71, 0.005)


if __name__ == "__main__":
    export_family(
        "town",
        {
            "insula_duplex": lambda b, d, n: insula(b, d, n, 2),
            "insula_triple": lambda b, d, n: insula(b, d, n, 3),
            "taberna_awning": shop,
            "thermae_rotunda": bath,
            "fabrica_stack": workshop,
            "templum_roofed": temple,
        },
    )
