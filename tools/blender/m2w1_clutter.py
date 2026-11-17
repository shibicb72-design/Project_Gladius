"""M2W1 item 5: the clutter family (low camp dressing and field scatter) as low-poly meshes, exported to one glb.

Run (Blender 5.3, background, from the repo root):
    blender.cmd -b --python tools/blender/m2w1_clutter.py -- [--out=<glb path>]

Same family as tools/blender/m2w1_world_kit.py (imported as a module: its Builder, primitives and vertex-data
convention): COLOR_0 = the paint AS sRGB, TEXCOORD_0 = metres on the face's main plane, TEXCOORD_1 = (surface id,
shade), flat normals, Godot frame. Extra paints the palette (data/art_astra.json, read-only) does not have come from
data/art_clutter.json "paints" (sRGB, with their surface). A blade of grass may carry a colour per corner (root dark,
tip light) for the foliage material (scripts/visual/world_clutter.gd turns those colours linear for that shader).
Every mesh stands on y = 0 (its ground) with its origin at its footprint centre; nothing rises over
data/art_clutter.json rules.max_height_m (checked here and by tests/test_m2w1_clutter.gd). One object per type,
named as the type. No .blend is saved; fixed seeds, stable vertex order: the same data gives the same file.
"""
import bpy
import math
import os
import random
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import m2w1_world_kit as kit  # noqa: E402

from m2w1_world_kit import add, sub, mul, dot, cross, norm, box, lathe, uv_axes, to_blender  # noqa: E402


class ClutterData(kit.Data):
    """The kit's data plus art_clutter.json's own paints (name -> [r, g, b, a] sRGB, surface)."""

    def __init__(self):
        astra = kit.load_json("data/art_astra.json")
        mats = kit.load_json("data/art_materials.json")
        self.colors = {k: v for k, v in astra["colors"].items() if not k.startswith("_")}
        self.order = mats["surface_order"]
        self.paint_surface = dict(mats["paint"])
        self.types = {}
        self.cfg = kit.load_json("data/art_clutter.json")
        for name, spec in self.cfg["paints"].items():
            if name.startswith("_"):
                continue
            self.colors[name] = spec["srgb"]
            self.paint_surface[name] = spec["surface"]


# ---------------------------------------------------------------- composition helpers

def rot_x(p, a):
    c, s = math.cos(a), math.sin(a)
    return (p[0], p[1] * c - p[2] * s, p[1] * s + p[2] * c)


def rot_y(p, a):
    c, s = math.cos(a), math.sin(a)
    return (p[0] * c + p[2] * s, p[1], -p[0] * s + p[2] * c)


def rot_z(p, a):
    c, s = math.cos(a), math.sin(a)
    return (p[0] * c - p[1] * s, p[0] * s + p[1] * c, p[2])


def place(b, fn, at=(0, 0, 0), rx=0.0, ry=0.0, rz=0.0, scale=(1, 1, 1)):
    """Builds `fn(sub_builder)` in its own frame, then scales, turns (x, then z, then y; degrees) and moves it into
    b. Per-corner colours (an optional 7th field) travel along."""
    t = kit.Builder(b.data, "sub%d" % len(b.tris))
    t.rng = b.rng
    fn(t)
    ax, az, ay = math.radians(rx), math.radians(rz), math.radians(ry)

    def tr(p):
        p = (p[0] * scale[0], p[1] * scale[1], p[2] * scale[2])
        p = rot_y(rot_z(rot_x(p, ax), az), ay)
        return add(p, at)
    for tri in t.tris:
        a, bb, c = tr(tri[0]), tr(tri[1]), tr(tri[2])
        if scale[0] * scale[1] * scale[2] < 0:
            bb, c = c, bb
        b.tris.append((a, bb, c) + tuple(tri[3:]))


def paint(b, name, shade=0.5, jitter=0.0, surface=None):
    b.set(name, surface, shade, jitter)


def cyl(b, x0, x1, r, segs, axis="x", c=(0.0, 0.0), caps=(True, True)):
    """A cylinder of `segs` facets along x or z from x0 to x1, centre (y, other) = c."""
    def fn(t):
        lathe(t, 0.0, 0.0, [(x0, r), (x1, r)], segs, phase=math.pi / segs, caps=caps)
    if axis == "x":
        place(b, fn, at=(0.0, c[0], c[1]), rz=-90.0)
    else:
        place(b, fn, at=(c[1], c[0], 0.0), rx=90.0)


def blade(b, root, tip, width, dark, light, lean_dir):
    """One grass blade: a single triangle, colour per corner (root dark, tip light)."""
    side = norm(cross(lean_dir, (0.0, 1.0, 0.0)))
    if side == (0.0, 0.0, 0.0):
        side = (1.0, 0.0, 0.0)
    a = add(root, mul(side, -width * 0.5))
    c = add(root, mul(side, width * 0.5))
    cd = b.data.paint(dark)[0]
    cl = b.data.paint(light)[0]
    b.set(dark, None, 0.5)
    if kit.length(cross(sub(c, a), sub(tip, a))) < 1e-10:
        return
    b.tris.append((a, c, tip, b.color, b.sid, b.shade, (cd, cd, cl)))


# ---------------------------------------------------------------- the clutter types (back = -z, front = +z)

def amphora(t, lean_deg, ry, at):
    def fn(u):
        paint(u, "terracotta", 0.5, 0.08)
        lathe(u, 0.0, 0.0, [(0.0, 0.05), (0.2, 0.135), (0.4, 0.11), (0.5, 0.05), (0.64, 0.055)], 5, caps=(True, True))
        paint(u, "terracotta", 0.35)
        box(u, (-0.12, 0.45, -0.015), (0.12, 0.56, 0.015), skip=("-y",))
    place(t, fn, at=at, rx=-lean_deg, ry=ry)


def build_stores(b):
    """Three amphorae leaning back in a low timber rack, a small crate at one end."""
    paint(b, "timber", 0.45)
    box(b, (-0.85, 0.0, -0.42), (0.55, 0.08, -0.32), skip=("-y",))          # ground beam (the feet rest on it)
    box(b, (-0.85, 0.30, -0.36), (0.55, 0.37, -0.29))                      # rail the necks lean on
    for x in (-0.8, -0.15, 0.5):
        box(b, (x - 0.035, 0.0, -0.37), (x + 0.035, 0.31, -0.30), skip=("-y", "+y"))
    for i, x in enumerate((-0.6, -0.15, 0.3)):
        amphora(b, 50.0 + 4.0 * (i - 1), 6.0 * (i - 1), (x, 0.0, 0.08))
    paint(b, "timber", 0.6, 0.05)
    box(b, (0.68, 0.0, -0.25), (1.08, 0.32, 0.12), skip=("-y",))
    paint(b, "bronze", 0.5)
    box(b, (0.66, 0.12, -0.27), (1.10, 0.16, 0.14), skip=("-y", "+y"))


def build_supply_crate(b):
    """A low supply crate with bronze straps, a folded red cloak over its lid and a sack against it."""
    paint(b, "timber", 0.55, 0.05)
    box(b, (-0.45, 0.0, -0.3), (0.45, 0.42, 0.3), chamfer=0.03)
    paint(b, "bronze", 0.5)
    for x in (-0.28, 0.28):
        box(b, (x - 0.04, -0.005, -0.315), (x + 0.04, 0.425, 0.315), skip=("-y",))
    paint(b, "legion_red", 0.5)
    box(b, (-0.3, 0.42, -0.24), (0.22, 0.47, 0.2), chamfer=0.012)              # the folded cloak
    box(b, (0.16, 0.30, -0.24), (0.26, 0.47, 0.2), chamfer=0.012)              # its fold hangs over the edge
    paint(b, "gold", 0.5)
    box(b, (-0.3, 0.465, -0.03), (0.22, 0.475, 0.01))
    paint(b, "canvas", 0.5, 0.06, surface="burlap")
    place(b, lambda u: lathe(u, 0.0, 0.0, [(0.0, 0.14), (0.08, 0.2), (0.28, 0.19), (0.38, 0.12), (0.44, 0.04)], 6, caps=(True, True)),
          at=(-0.66, 0.0, 0.12), rz=-12.0)


def scutum(u):
    paint(u, "legion_red", 0.5, 0.04)
    box(u, (-0.32, 0.0, -0.5), (0.32, 0.05, 0.5), skip=("-y",))
    paint(u, "bronze", 0.55)
    box(u, (-0.33, 0.0, -0.51), (0.33, 0.055, -0.47), skip=("-y",))
    box(u, (-0.33, 0.0, 0.47), (0.33, 0.055, 0.51), skip=("-y",))
    paint(u, "gold", 0.5)
    lathe(u, 0.0, 0.0, [(0.05, 0.11), (0.08, 0.07), (0.1, 0.0)], 5)


def build_arms(b):
    """Scuta stacked flat and a bundle of pila across two low trestles (0.4 m)."""
    place(b, scutum, at=(-0.95, 0.0, 0.0), ry=4.0)
    place(b, scutum, at=(-0.93, 0.055, 0.02), ry=-9.0)
    for x in (0.0, 1.1):
        paint(b, "timber", 0.4, 0.05)
        box(b, (x - 0.04, 0.0, -0.3), (x + 0.04, 0.34, -0.22), skip=("-y", "+y"))
        box(b, (x - 0.04, 0.0, 0.22), (x + 0.04, 0.34, 0.3), skip=("-y", "+y"))
        box(b, (x - 0.06, 0.34, -0.34), (x + 0.06, 0.4, 0.34))
    for i, z in enumerate((-0.16, 0.0, 0.16)):
        x0 = -0.35 + 0.08 * (i % 2)
        paint(b, "timber", 0.6, 0.06)
        box(b, (x0, 0.4, z - 0.018), (x0 + 1.35, 0.436, z + 0.018), skip=("-y",))
        paint(b, "plate_dark", 0.45)
        box(b, (x0 + 1.35, 0.405, z - 0.012), (x0 + 1.7, 0.43, z + 0.012), skip=("-y", "+x"))
        b.poly([(x0 + 1.7, 0.405, z - 0.012), (x0 + 1.7, 0.43, z - 0.012), (x0 + 1.82, 0.418, z)], (0, 0, -1))
        b.poly([(x0 + 1.7, 0.405, z + 0.012), (x0 + 1.82, 0.418, z), (x0 + 1.7, 0.43, z + 0.012)], (0, 0, 1))
        b.poly([(x0 + 1.7, 0.43, z - 0.012), (x0 + 1.7, 0.43, z + 0.012), (x0 + 1.82, 0.418, z)], (0, 1, 0))
        paint(b, "bronze", 0.5)
        box(b, (x0 + 1.3, 0.398, z - 0.024), (x0 + 1.36, 0.438, z + 0.024), skip=("-y",))


def build_trough(b):
    """A stone water trough and a bucket beside it."""
    paint(b, "travertine_shade", 0.5, 0.05)
    box(b, (-0.7, 0.0, -0.24), (0.7, 0.46, -0.16), chamfer=0.02, skip=("-y",))
    box(b, (-0.7, 0.0, 0.16), (0.7, 0.46, 0.24), chamfer=0.02, skip=("-y",))
    box(b, (-0.7, 0.0, -0.17), (-0.62, 0.46, 0.17), skip=("-y", "+z", "-z"))
    box(b, (0.62, 0.0, -0.17), (0.7, 0.46, 0.17), skip=("-y", "+z", "-z"))
    paint(b, "water", 0.5)
    b.poly([(-0.62, 0.38, -0.16), (0.62, 0.38, -0.16), (0.62, 0.38, 0.16), (-0.62, 0.38, 0.16)], (0, 1, 0))
    paint(b, "bronze", 0.5)
    box(b, (-0.71, 0.3, -0.25), (0.71, 0.34, 0.25), skip=("-y", "+y"))
    paint(b, "timber", 0.5, 0.05)
    lathe(b, 0.98, 0.1, [(0.0, 0.13), (0.3, 0.16), (0.3, 0.14), (0.05, 0.12)], 6, caps=(False, False))
    paint(b, "water", 0.5)
    b.poly(kit.ring_pts(0.98, 0.1, 0.05, 0.12, 6), (0, 1, 0))


def build_bench(b):
    """A low bench with a folded cloak and a cup on it."""
    paint(b, "timber", 0.55, 0.05)
    box(b, (-0.7, 0.36, -0.17), (0.7, 0.42, 0.17), chamfer=0.015)
    for x in (-0.55, 0.55):
        box(b, (x - 0.05, 0.0, -0.14), (x + 0.05, 0.36, 0.14))
    box(b, (-0.5, 0.12, -0.03), (0.5, 0.17, 0.03))
    paint(b, "legion_red", 0.45)
    box(b, (-0.5, 0.42, -0.14), (-0.1, 0.48, 0.13), chamfer=0.012)
    paint(b, "bronze", 0.55)
    lathe(b, 0.32, 0.0, [(0.42, 0.035), (0.43, 0.045), (0.52, 0.05)], 6, caps=(True, False))


def build_brazier_bowl(b):
    """A low bronze bowl on a tripod with glowing embers (no light)."""
    paint(b, "plate_dark", 0.45)
    for k in range(3):
        a = 2 * math.pi * k / 3
        place(b, lambda u: box(u, (-0.02, 0.0, -0.02), (0.02, 0.44, 0.02)),
              at=(0.2 * math.cos(a), 0.0, 0.2 * math.sin(a)), ry=-math.degrees(a), rz=14.0)
    paint(b, "bronze", 0.5)
    lathe(b, 0.0, 0.0, [(0.33, 0.05), (0.36, 0.17), (0.46, 0.26), (0.5, 0.28), (0.52, 0.27)], 8, caps=(True, False))
    paint(b, "plate_dark", 0.3)
    lathe(b, 0.0, 0.0, [(0.52, 0.27), (0.44, 0.22)], 8)
    paint(b, "ember", 0.5)
    lathe(b, 0.0, 0.0, [(0.44, 0.22), (0.5, 0.14), (0.52, 0.0)], 8)


def stone(u, rx, ry, rz, shade, segs=4):
    paint(u, "fieldstone", shade, 0.1)
    lathe(u, 0.0, 0.0, [(0.0, rx * 0.8), (ry * 0.5, rx), (ry, rx * 0.55)], segs, phase=0.4, caps=(False, True))


def build_campfire(b):
    """A ring of stones round charred logs and embers, a bronze pot on a low iron trivet."""
    for k in range(7):
        a = 2 * math.pi * k / 7 + 0.2
        place(b, lambda u, k=k: stone(u, 0.12, 0.13, 0.1, 0.35 + 0.05 * (k % 3)),
              at=(0.45 * math.cos(a), -0.02, 0.45 * math.sin(a)), ry=37.0 * k, scale=(1.0, 1.0, 0.75))
    paint(b, "dark", 0.25)
    for k, ang in enumerate((10.0, 70.0, 130.0)):
        place(b, lambda u: box(u, (-0.3, 0.0, -0.045), (0.3, 0.09, 0.045), skip=("-y",)), at=(0.0, 0.02 + 0.05 * k, 0.0), ry=ang)
    paint(b, "ember", 0.5)
    lathe(b, 0.0, 0.0, [(0.0, 0.3), (0.05, 0.22), (0.1, 0.0)], 6)
    paint(b, "plate_dark", 0.4)
    for k in range(3):
        a = 2 * math.pi * k / 3 + 0.5
        box(b, (0.3 * math.cos(a) - 0.015, 0.0, 0.3 * math.sin(a) - 0.015), (0.3 * math.cos(a) + 0.015, 0.3, 0.3 * math.sin(a) + 0.015), skip=("-y", "+y"))
    paint(b, "bronze", 0.45)
    lathe(b, 0.0, 0.0, [(0.26, 0.1), (0.3, 0.16), (0.44, 0.17), (0.47, 0.15)], 6, caps=(True, False))
    paint(b, "plate_dark", 0.2)
    b.poly(kit.ring_pts(0.0, 0.0, 0.46, 0.15, 6), (0, 1, 0))


def build_bedrolls(b):
    """Two bedrolls with leather straps, a low stool and a dolabra lying beside them."""
    for z, rot, col in ((-0.25, 3.0, "legion_red"), (0.2, -5.0, "cloth")):
        def roll(u, col=col):
            paint(u, col, 0.4, 0.05)
            cyl(u, -0.45, 0.45, 0.12, 6, c=(0.12, 0.0))
            paint(u, "leather", 0.5)
            for x in (-0.25, 0.25):
                cyl(u, x - 0.03, x + 0.03, 0.127, 6, c=(0.12, 0.0), caps=(False, False))
        place(b, roll, at=(-0.3, 0.0, z), ry=rot)
    paint(b, "timber", 0.5, 0.05)
    box(b, (0.45, 0.33, -0.2), (0.85, 0.38, 0.2))
    for x in (0.5, 0.8):
        for z in (-0.15, 0.15):
            box(b, (x - 0.025, 0.0, z - 0.025), (x + 0.025, 0.33, z + 0.025), skip=("-y", "+y"))
    def dolabra(u):
        paint(u, "timber", 0.6)
        box(u, (-0.4, 0.0, -0.02), (0.3, 0.04, 0.02), skip=("-y",))
        paint(u, "plate_dark", 0.5)
        box(u, (0.3, 0.0, -0.17), (0.4, 0.05, 0.03), skip=("-y",))
        box(u, (0.3, 0.0, 0.03), (0.38, 0.05, 0.12), skip=("-y", "-z"))
    place(b, dolabra, at=(0.25, 0.0, 0.5), ry=20.0)


def helmet(u):
    paint(u, "plate", 0.55)
    lathe(u, 0.0, 0.0, [(0.0, 0.12), (0.1, 0.115), (0.19, 0.0)], 6, caps=(False, False))
    paint(u, "visor", 0.5)
    box(u, (-0.07, 0.04, 0.1), (0.07, 0.08, 0.125), skip=("-z", "-y"))
    paint(u, "legion_red", 0.5)
    box(u, (-0.012, 0.15, -0.12), (0.012, 0.215, 0.11), skip=("-y",))


def build_helmet_rack(b):
    """A low peg board with three helmets hanging on its front."""
    paint(b, "timber", 0.5, 0.05)
    for x in (-0.6, 0.6):
        box(b, (x - 0.04, 0.0, -0.1), (x + 0.04, 0.55, -0.02), skip=("-y",))
        box(b, (x - 0.12, 0.0, -0.16), (x + 0.12, 0.05, 0.08), skip=("-y",))
    box(b, (-0.66, 0.38, -0.08), (0.66, 0.5, -0.03))
    for i, x in enumerate((-0.38, 0.0, 0.38)):
        paint(b, "plate_dark", 0.4)
        box(b, (x - 0.015, 0.4, -0.03), (x + 0.015, 0.43, 0.05), skip=("-z",))
        place(b, helmet, at=(x, 0.21, 0.06), rx=-12.0 + 6.0 * i, ry=8.0 * (i - 1))


def build_caltrops(b):
    """A low pile of iron caltrops on a sacking cloth, a few loose ones round it."""
    paint(b, "canvas", 0.4, 0.05, surface="burlap")
    b.poly([(-0.42, 0.012, -0.3), (0.42, 0.012, -0.34), (0.45, 0.012, 0.3), (-0.4, 0.012, 0.33)], (0, 1, 0))
    rng = random.Random(7)
    for k in range(13):
        if k < 9:
            x, z, y = rng.uniform(-0.25, 0.25), rng.uniform(-0.2, 0.2), 0.015 + 0.06 * (k // 4)
        else:
            a = rng.uniform(0, 2 * math.pi)
            x, z, y = 0.6 * math.cos(a), 0.45 * math.sin(a), 0.0
        s = 0.07
        p = [(x, y + s * 1.2, z), (x + s, y, z - s * 0.5), (x - s, y, z - s * 0.5), (x, y, z + s)]
        paint(b, "plate_dark", 0.35 + 0.1 * (k % 3))
        for i, j, m in ((0, 1, 2), (0, 2, 3), (0, 3, 1), (1, 3, 2)):
            c = mul(add(add(p[i], p[j]), p[m]), 1 / 3)
            centre = mul(add(add(add(p[0], p[1]), p[2]), p[3]), 0.25)
            b.poly([p[i], p[j], p[m]], sub(c, centre))


def build_ammo_case(b):
    """An open low case of energy cells (plate, glowing tips) and a coiled chain beside it."""
    paint(b, "plate_dark", 0.5, 0.04)
    b.poly([(-0.36, 0.06, -0.21), (0.36, 0.06, -0.21), (0.36, 0.06, 0.21), (-0.36, 0.06, 0.21)], (0, 1, 0))
    for (mn, mx) in (((-0.4, 0.0, -0.25), (0.4, 0.28, -0.21)), ((-0.4, 0.0, 0.21), (0.4, 0.28, 0.25)),
                     ((-0.4, 0.0, -0.21), (-0.36, 0.28, 0.21)), ((0.36, 0.0, -0.21), (0.4, 0.28, 0.21))):
        box(b, mn, mx, skip=("-y",))
    paint(b, "gold", 0.5)
    box(b, (-0.41, 0.2, -0.26), (0.41, 0.23, 0.26), skip=("-y", "+y"))
    for i in range(4):
        z = -0.13 + 0.087 * i
        paint(b, "plate", 0.45 + 0.05 * (i % 2))
        cyl(b, -0.3, 0.2, 0.035, 5, c=(0.1 + 0.07 * (i % 2), z), caps=(True, False))
        paint(b, "lit_accent", 0.5)
        cyl(b, 0.2, 0.28, 0.03, 5, c=(0.1 + 0.07 * (i % 2), z), caps=(False, True))
    paint(b, "plate_dark", 0.35)
    n = 7
    for k in range(n):
        a = 2 * math.pi * k / n
        cx, cz = 0.7 + 0.17 * math.cos(a), 0.05 + 0.17 * math.sin(a)
        place(b, lambda u: box(u, (-0.07, 0.0, -0.02), (0.07, 0.04, 0.02), skip=("-y",)), at=(cx, 0.0 if k % 2 else 0.02, cz), ry=-math.degrees(a) + 90.0)


def build_cippus(b):
    """A low marble boundary stone with a rounded head and a bronze number plate on its front."""
    paint(b, "marble", 0.5, 0.05)
    box(b, (-0.22, 0.0, -0.17), (0.22, 0.08, 0.17), skip=("-y",))
    box(b, (-0.17, 0.0, -0.12), (0.17, 0.44, 0.12), skip=("-y", "+y"))
    place(b, lambda u: kit.prism(u, "z", [(-0.17 + 0.34 * i / 6, 0.44 + 0.12 * math.sin(math.pi * i / 6)) for i in range(7)] + [(0.17, 0.43), (-0.17, 0.43)], -0.12, 0.12))
    paint(b, "bronze", 0.55)
    box(b, (-0.12, 0.18, 0.115), (0.12, 0.36, 0.135), skip=("-z",))
    paint(b, "gold", 0.5)
    for x in (-0.06, 0.0, 0.06):
        box(b, (x - 0.012, 0.22, 0.134), (x + 0.012, 0.32, 0.142), skip=("-z",))


def build_rubble(b):
    """A fallen ashlar block half sunk, with broken stone round it."""
    paint(b, "travertine", 0.45, 0.06, surface="ashlar")
    place(b, lambda u: box(u, (-0.45, -0.2, -0.3), (0.45, 0.25, 0.3), chamfer=0.05), at=(0.0, 0.0, 0.0), rz=9.0, ry=14.0)
    rng = random.Random(11)
    for k in range(6):
        a = 2 * math.pi * k / 6 + 0.4
        r = 0.65 + rng.uniform(-0.1, 0.15)
        place(b, lambda u, k=k: stone(u, 0.1 + 0.03 * (k % 3), 0.14 + 0.02 * (k % 2), 0.1, 0.5),
              at=(r * math.cos(a), -0.02, r * math.sin(a) * 0.8), ry=53.0 * k, scale=(1.0, 0.9, 0.8))
    paint(b, "marble", 0.5)
    place(b, lambda u: box(u, (-0.2, 0.0, -0.1), (0.2, 0.12, 0.1), chamfer=0.02), at=(-0.75, 0.0, -0.35), ry=-30.0)


def build_stakes_lying(b):
    """Spare sharpened stakes lying beside a low mound of dug earth."""
    paint(b, "earth_mound", 0.5, 0.05)
    place(b, lambda u: lathe(u, 0.0, 0.0, [(-0.05, 0.75), (0.12, 0.6), (0.24, 0.35), (0.3, 0.0)], 7, caps=(True, False)),
          at=(-0.6, 0.0, 0.0), scale=(1.0, 1.0, 0.7))
    for i, z in enumerate((-0.15, 0.05, 0.25)):
        def stake(u, i=i):
            paint(u, "timber", 0.45 + 0.06 * i, 0.04)
            box(u, (-0.9, 0.0, -0.045), (0.6, 0.09, 0.045))
            for (ya, za, yb, zb) in ((0.0, -0.045, 0.0, 0.045), (0.0, 0.045, 0.09, 0.045), (0.09, 0.045, 0.09, -0.045), (0.09, -0.045, 0.0, -0.045)):
                u.poly([(0.6, ya, za), (0.6, yb, zb), (0.85, 0.045, 0.0)], (1.0, (ya + yb) - 0.09, (za + zb)))
            paint(u, "bronze", 0.5)
            box(u, (-0.9, -0.002, -0.05), (-0.85, 0.092, 0.05))
        place(b, stake, at=(0.35, 0.09 * (i == 1) * 0.0, z), ry=6.0 * (i - 1))


# ---------------------------------------------------------------- scatter

def build_grass_clump(b):
    """A clump of grass blades (root dark, tip light) with a few poppies and broom flowers."""
    rng = random.Random(23)
    tufts = ((0.0, 0.0, 8, 1.0), (0.42, 0.18, 6, 0.8), (-0.3, 0.36, 5, 0.7), (-0.12, -0.42, 5, 0.75),
             (0.95, -0.3, 7, 0.9), (-0.85, -0.2, 6, 0.8), (0.3, 0.95, 6, 0.85), (0.5, -0.85, 5, 0.7))
    for (tx, tz, n, hs) in tufts:
        for k in range(n):
            a = 2 * math.pi * k / n + rng.uniform(-0.3, 0.3)
            r = rng.uniform(0.02, 0.1)
            root = (tx + r * math.cos(a), -0.02, tz + r * math.sin(a))
            lean = (math.cos(a), 0.0, math.sin(a))
            h = rng.uniform(0.26, 0.46) * hs
            tip = add(root, (lean[0] * rng.uniform(0.06, 0.16), h, lean[2] * rng.uniform(0.06, 0.16)))
            blade(b, root, tip, rng.uniform(0.04, 0.065), "grass_root", "grass_tip" if k % 3 else "grass_dry", lean)
    for k, col in enumerate(("poppy", "poppy", "broom", "poppy", "broom")):
        a = 1.3 * k + 0.4
        rr = 0.3 + 0.18 * k
        cx, cz, h = rr * math.cos(a), rr * math.sin(a), 0.3 + 0.03 * k
        blade(b, (cx - 0.005, -0.02, cz), (cx, h, cz + 0.01), 0.016, "grass_root", "grass_tip", (0, 0, 1))
        paint(b, col, 0.5)
        s = 0.04
        cd = b.data.paint(col)[0]
        b.tris.append(((cx - s, h, cz - s * 0.6), (cx + s, h + 0.01, cz - s * 0.6), (cx, h + 0.015, cz + s), b.color, b.sid, b.shade, (cd, cd, cd)))


def build_weeds(b):
    """A tuft of dry weeds (straw blades) with seed heads."""
    rng = random.Random(31)
    for (tx, tz, n) in ((0.0, 0.0, 7), (0.3, -0.22, 5), (-0.26, 0.2, 4)):
        for k in range(n):
            a = 2 * math.pi * k / n + rng.uniform(-0.4, 0.4)
            r = rng.uniform(0.02, 0.08)
            root = (tx + r * math.cos(a), -0.02, tz + r * math.sin(a))
            lean = (math.cos(a), 0.0, math.sin(a))
            tip = add(root, (lean[0] * 0.13, rng.uniform(0.14, 0.3), lean[2] * 0.13))
            blade(b, root, tip, 0.035, "straw_root", "straw", lean)
    for k in range(3):
        a = 2.0 * k + 1.0
        cx, cz, h = 0.06 * math.cos(a), 0.06 * math.sin(a), 0.34 + 0.03 * k
        blade(b, (cx, -0.02, cz), (cx + 0.02, h, cz), 0.01, "straw_root", "straw", (1, 0, 0))
        blade(b, (cx + 0.02, h - 0.07, cz - 0.02), (cx + 0.02, h + 0.02, cz + 0.02), 0.03, "straw", "straw", (0, 0, 1))


def build_scrub(b):
    """A low dry bush (broom / thyme): many stiff sprigs fanning out of one root, dark at the root, dusty olive at the
    tips, a few yellow broom flowers on top (foliage material: double-sided, it sways)."""
    rng = random.Random(5)
    n = 34
    for k in range(n):
        a = 2 * math.pi * k / n * 2.618 + rng.uniform(-0.2, 0.2)       # golden-angle spiral: no gaps, no rows
        up = 0.25 + 0.75 * ((k * 7) % n) / n                            # from lying out low to standing up
        r0 = rng.uniform(0.0, 0.12)
        root = (r0 * math.cos(a), -0.03, r0 * math.sin(a))
        reach = rng.uniform(0.32, 0.55)
        tip = add(root, (math.cos(a) * reach * (1.1 - up), 0.12 + 0.36 * up + rng.uniform(-0.04, 0.04), math.sin(a) * reach * (1.1 - up)))
        blade(b, root, tip, rng.uniform(0.07, 0.11), "scrub_dark", "scrub", (math.cos(a), 0.0, math.sin(a)))
    for k in range(4):
        a = 1.7 * k
        cx, cz, h = 0.18 * math.cos(a), 0.18 * math.sin(a), 0.44 + 0.02 * k
        paint(b, "broom", 0.5)
        cd = b.data.paint("broom")[0]
        b.tris.append(((cx - 0.04, h, cz - 0.03), (cx + 0.04, h + 0.01, cz - 0.03), (cx, h + 0.015, cz + 0.05), b.color, b.sid, b.shade, (cd, cd, cd)))


def build_stones(b):
    """A small cluster of field stones: one flat slab and a few rounded ones."""
    place(b, lambda u: stone(u, 0.26, 0.09, 0.2, 0.55, segs=5), at=(0.0, -0.03, 0.0), scale=(1.0, 1.0, 0.7), ry=20.0)
    for k, (x, z, r, h) in enumerate(((0.32, 0.1, 0.11, 0.1), (-0.28, 0.18, 0.09, 0.08), (0.1, -0.3, 0.13, 0.11))):
        place(b, lambda u, r=r, h=h, k=k: stone(u, r, h, r, 0.45 + 0.1 * (k % 3), segs=5), at=(x, -0.02, z), ry=71.0 * k, scale=(1.0, 1.0, 0.8))


BUILDERS = {
    "stores": build_stores, "supply_crate": build_supply_crate, "arms": build_arms, "trough": build_trough,
    "bench": build_bench, "brazier_bowl": build_brazier_bowl, "campfire": build_campfire, "bedrolls": build_bedrolls,
    "helmet_rack": build_helmet_rack, "caltrops": build_caltrops, "ammo_case": build_ammo_case, "cippus": build_cippus,
    "rubble": build_rubble, "stakes_lying": build_stakes_lying,
    "grass_clump": build_grass_clump, "weeds": build_weeds, "scrub": build_scrub, "stones": build_stones,
}


# ---------------------------------------------------------------- export (the kit's make_object, plus colour per corner)

def make_object(name, tris):
    verts = []
    faces = []
    for i, t in enumerate(tris):
        verts.extend([to_blender(t[0]), to_blender(t[1]), to_blender(t[2])])
        faces.append((3 * i, 3 * i + 1, 3 * i + 2))
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    uv0 = mesh.uv_layers.new(name="UVMap")
    uv1 = mesh.uv_layers.new(name="UV2")
    col = mesh.color_attributes.new(name="Color", type="FLOAT_COLOR", domain="CORNER")
    for poly in mesh.polygons:
        poly.use_smooth = False
    for i, t in enumerate(tris):
        a, b_, c = t[0], t[1], t[2]
        normal = norm(cross(sub(b_, a), sub(c, a)))
        u_axis, v_axis = uv_axes(normal)
        corners = t[6] if len(t) > 6 else (t[3], t[3], t[3])
        for k, p in enumerate((a, b_, c)):
            li = 3 * i + k
            uv0.data[li].uv = (dot(p, u_axis), 1.0 - dot(p, v_axis))
            uv1.data[li].uv = (float(t[4]), 1.0 - t[5])
            col.data[li].color = tuple(corners[k])
    mesh.color_attributes.active_color = col
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    data = ClutterData()
    out = os.path.join(kit.REPO, data.cfg["glb"].replace("res://", ""))
    for a in argv:
        if a.startswith("--out="):
            out = a[6:]
    bpy.ops.wm.read_factory_settings(use_empty=True)
    cap_h = float(data.cfg["rules"]["max_height_m"])
    report = []
    bad = 0
    for type_name, entry in data.cfg["types"].items():
        if type_name.startswith("_"):
            continue
        b = kit.Builder(data, "clutter/" + type_name)
        BUILDERS[type_name](b)
        tris = b.tris
        ys = [p[1] for t in tris for p in t[:3]]
        rs = [math.hypot(p[0], p[2]) for t in tris for p in t[:3]]
        flag = ""
        if max(ys) > cap_h or len(tris) > int(entry["max_tris"]) or len(tris) < 12:
            flag = " OVER"
            bad += 1
        make_object(type_name, tris)
        report.append("M2W1_CLUTTER %s triangles=%d top=%.3f bottom=%.3f radius=%.3f%s" % (type_name, len(tris), max(ys), min(ys), max(rs), flag))
    kit.export(out)
    for line in report:
        print(line)
    print("M2W1_CLUTTER wrote", out, "over=%d" % bad)


if __name__ == "__main__":
    main()
