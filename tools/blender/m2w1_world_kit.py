"""M2W1: the world-kit family (fortification pieces) as low-poly meshes with LODs, exported to one glb.

Run (Blender 5.3, background, from the repo root):
    blender.cmd -b --python tools/blender/m2w1_world_kit.py -- [--out=<glb path>] [--report]

Reads the repo's data itself, so dimensions and paints follow the data:
  data/art_astra.json "colors" (paint colours, sRGB), data/art_materials.json ("surface_order", "paint"),
  data/maps/alesia_structures.json "types" (the colliders each look is designed on),
  data/art_world_kit.json (which types, node names, the joint bend).
Writes assets/generated/world/m2w1_world_kit.glb with one object per type and LOD: "<type>" (near) and
"<type>_lod1" (far). Never saves a .blend. Pure python geometry (no modifiers, no randomness without a fixed
seed, stable vertex order), so the same data gives the same file.

Vertex data (what scripts/visual/world_kit_meshes.gd and the world shader expect):
  COLOR_0 = the paint colour AS sRGB, exactly the numbers of art_astra.json (a deliberate break with glTF,
  which says linear: Godot keeps vertex colours as 8 bits, and 8-bit linear loses the dark paints, e.g. visor
  0.04 came back 0.0; stored as sRGB every paint survives within half a step; the world shader converts
  sRGB to linear itself, as for the kit meshes), TEXCOORD_0 = metres on the face's main plane (the kit's rule, LowpolyKit._triangle),
  TEXCOORD_1 = (surface id, shade 0..1). Blender's exporter flips v (v_gltf = 1 - v_blender), so both maps are
  written pre-flipped. Flat normals: every triangle has its own three vertices. Coordinates are written in
  Godot's frame (x right, y up, z towards the viewer) and turned into Blender's z-up frame on output; the
  exporter's +Y up turns them back.
"""
import bpy
import json
import math
import os
import random
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))


def load_json(rel):
    with open(os.path.join(REPO, rel), "r", encoding="utf-8") as f:
        return json.load(f)


# ---------------------------------------------------------------- vectors (tuples, Godot frame)

def add(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def mul(a, s):
    return (a[0] * s, a[1] * s, a[2] * s)


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def length(a):
    return math.sqrt(dot(a, a))


def norm(a):
    n = length(a)
    return (a[0] / n, a[1] / n, a[2] / n) if n > 1e-12 else (0.0, 0.0, 0.0)


def newell(pts):
    n = [0.0, 0.0, 0.0]
    for i in range(len(pts)):
        a = pts[i]
        b = pts[(i + 1) % len(pts)]
        n[0] += (a[1] - b[1]) * (a[2] + b[2])
        n[1] += (a[2] - b[2]) * (a[0] + b[0])
        n[2] += (a[0] - b[0]) * (a[1] + b[1])
    return (n[0], n[1], n[2])


DIRS = {"+x": (1, 0, 0), "-x": (-1, 0, 0), "+y": (0, 1, 0), "-y": (0, -1, 0), "+z": (0, 0, 1), "-z": (0, 0, -1)}


# ---------------------------------------------------------------- data

class Data:
    def __init__(self):
        astra = load_json("data/art_astra.json")
        mats = load_json("data/art_materials.json")
        self.colors = {k: v for k, v in astra["colors"].items() if not k.startswith("_")}
        self.order = mats["surface_order"]
        self.paint_surface = mats["paint"]
        self.types = load_json("data/maps/alesia_structures.json")["types"]
        self.cfg = load_json("data/art_world_kit.json")

    def surface_id(self, name):
        return self.order.index(name)

    def paint(self, name, surface=None):
        rgba = self.colors[name]
        sid = self.surface_id(surface if surface else self.paint_surface.get(name, "plain"))
        return (float(rgba[0]), float(rgba[1]), float(rgba[2]), float(rgba[3])), sid

    def colliders(self, type_name):
        return self.types[type_name]["colliders"]


# ---------------------------------------------------------------- polygon helpers

def _area2(poly):
    a = 0.0
    for i in range(len(poly)):
        x0, y0 = poly[i]
        x1, y1 = poly[(i + 1) % len(poly)]
        a += x0 * y1 - x1 * y0
    return a * 0.5


def ear_clip(poly2):
    """Triangles (index triples) of a simple 2D polygon, any winding; deterministic."""
    n = len(poly2)
    if n < 3:
        return []
    idx = list(range(n))
    if _area2(poly2) < 0:
        idx.reverse()
    out = []
    guard = 0
    while len(idx) > 3 and guard < 10000:
        guard += 1
        found = False
        for k in range(len(idx)):
            i0, i1, i2 = idx[k - 1], idx[k], idx[(k + 1) % len(idx)]
            a, b, c = poly2[i0], poly2[i1], poly2[i2]
            cr = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
            if cr <= 1e-12:
                continue
            inside = False
            for j in idx:
                if j in (i0, i1, i2):
                    continue
                p = poly2[j]
                d1 = (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])
                d2 = (c[0] - b[0]) * (p[1] - b[1]) - (c[1] - b[1]) * (p[0] - b[0])
                d3 = (a[0] - c[0]) * (p[1] - c[1]) - (a[1] - c[1]) * (p[0] - c[0])
                if d1 >= -1e-12 and d2 >= -1e-12 and d3 >= -1e-12:
                    inside = True
                    break
            if inside:
                continue
            out.append((i0, i1, i2))
            idx.pop(k)
            found = True
            break
        if not found:
            break
    if len(idx) == 3:
        out.append((idx[0], idx[1], idx[2]))
    return out


def is_convex(pts, n):
    s = 0
    for i in range(len(pts)):
        a, b, c = pts[i - 1], pts[i], pts[(i + 1) % len(pts)]
        cr = dot(cross(sub(b, a), sub(c, b)), n)
        if abs(cr) < 1e-12:
            continue
        sg = 1 if cr > 0 else -1
        if s == 0:
            s = sg
        elif sg != s:
            return False
    return True


# ---------------------------------------------------------------- the mesh builder

class Builder:
    """Collects triangles (a, b, c, rgba_srgb, surface id, shade); (b - a) x (c - a) points out of the solid."""

    def __init__(self, data, seed_name):
        self.data = data
        self.tris = []
        self.rng = random.Random(zlib.crc32(seed_name.encode("utf-8")))
        self.color = (1, 1, 1, 1)
        self.sid = 0
        self.shade = 0.5

    def set(self, paint, surface=None, shade=None, jitter=0.0):
        self.color, self.sid = self.data.paint(paint, surface)
        if shade is None:
            shade = 0.5
        self.shade = min(1.0, max(0.0, shade + (self.rng.uniform(-jitter, jitter) if jitter > 0 else 0.0)))
        return self

    def tri(self, a, b, c):
        if length(cross(sub(b, a), sub(c, a))) < 1e-10:
            return
        self.tris.append((a, b, c, self.color, self.sid, self.shade))

    def poly(self, pts, hint):
        """A planar polygon; its winding is turned so its normal points along `hint`."""
        pts = [tuple(float(v) for v in p) for p in pts]
        n = newell(pts)
        if dot(n, hint) < 0:
            pts = pts[::-1]
            n = mul(n, -1)
        if len(pts) == 3:
            self.tri(pts[0], pts[1], pts[2])
            return
        if is_convex(pts, n):
            for i in range(1, len(pts) - 1):
                self.tri(pts[0], pts[i], pts[i + 1])
            return
        an = (abs(n[0]), abs(n[1]), abs(n[2]))
        if an[0] >= an[1] and an[0] >= an[2]:
            p2 = [(p[1], p[2]) for p in pts]
            flip = n[0] < 0
        elif an[1] >= an[2]:
            p2 = [(p[2], p[0]) for p in pts]
            flip = n[1] < 0
        else:
            p2 = [(p[0], p[1]) for p in pts]
            flip = n[2] < 0
        for i0, i1, i2 in ear_clip(p2):
            a, b, c = pts[i0], pts[i1], pts[i2]
            if dot(cross(sub(b, a), sub(c, a)), n) < 0:
                b, c = c, b
            self.tri(a, b, c)


def _skipped(normal, skip):
    nn = norm(normal)
    for s in skip:
        if dot(nn, DIRS[s]) > 0.5:
            return True
    return False


# ---------------------------------------------------------------- primitives

def box(b, mn, mx, chamfer=0.0, skip=()):
    """Axis-aligned box from min to max corner. chamfer > 0 cuts every edge at 45 degrees (the cut is what
    catches the light); faces looking along a `skip` direction ("-y", "+z" ...) are left out."""
    c = mul(add(mn, mx), 0.5)
    h = mul(sub(mx, mn), 0.5)
    k = min(chamfer, 0.45 * 2 * min(h))
    if k <= 1e-6:
        for axis in range(3):
            for s in (-1, 1):
                nrm = [0, 0, 0]
                nrm[axis] = s
                if _skipped(nrm, skip):
                    continue
                u, v = [a for a in range(3) if a != axis]
                pts = []
                for su, sv in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
                    p = [0, 0, 0]
                    p[axis] = c[axis] + s * h[axis]
                    p[u] = c[u] + su * h[u]
                    p[v] = c[v] + sv * h[v]
                    pts.append(tuple(p))
                b.poly(pts, tuple(nrm))
        return

    def P(axis, sx, sy, sz):
        s = (sx, sy, sz)
        p = [0.0, 0.0, 0.0]
        for a in range(3):
            p[a] = c[a] + s[a] * (h[a] if a == axis else h[a] - k)
        return tuple(p)

    signs = (-1, 1)
    # main faces
    for axis in range(3):
        for s in signs:
            nrm = [0, 0, 0]
            nrm[axis] = s
            if _skipped(nrm, skip):
                continue
            u, v = [a for a in range(3) if a != axis]
            pts = []
            for su, sv in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
                sg = [0, 0, 0]
                sg[axis] = s
                sg[u] = su
                sg[v] = sv
                pts.append(P(axis, *sg))
            b.poly(pts, tuple(nrm))
    # edge bevels: an edge runs along `run`, between the faces of axes a1, a2
    for run in range(3):
        a1, a2 = [a for a in range(3) if a != run]
        for s1 in signs:
            for s2 in signs:
                nrm = [0, 0, 0]
                nrm[a1] = s1
                nrm[a2] = s2
                if _skipped(nrm, skip):
                    continue
                pts = []
                for sr, which in ((-1, a1), (1, a1), (1, a2), (-1, a2)):
                    sg = [0, 0, 0]
                    sg[run] = sr
                    sg[a1] = s1
                    sg[a2] = s2
                    pts.append(P(which, *sg))
                b.poly(pts, tuple(nrm))
    # corner triangles
    for sx in signs:
        for sy in signs:
            for sz in signs:
                nrm = (sx, sy, sz)
                if _skipped(nrm, skip):
                    continue
                b.poly([P(0, sx, sy, sz), P(1, sx, sy, sz), P(2, sx, sy, sz)], nrm)


AXES = {"x": 0, "y": 1, "z": 2}


def _map(axis, t, u, v):
    """3D point of profile point (u, v) at position t along `axis`: x -> (t, u, v) = (x, y, z);
    z -> (u, v, t) = (x, y, z); y -> (u, t, v) = (x, y, z)."""
    if axis == "x":
        return (t, u, v)
    if axis == "z":
        return (u, v, t)
    return (u, t, v)


def _map_dir(axis, du, dv):
    return _map(axis, 0.0, du, dv)


def prism(b, axis, profile, a0, a1, skip=(), caps=(True, True)):
    """A closed profile (any winding) extruded along `axis` from a0 to a1, with end caps."""
    area = _area2(profile)
    sgn = 1.0 if area > 0 else -1.0
    n = len(profile)
    for i in range(n):
        p = profile[i]
        q = profile[(i + 1) % n]
        du, dv = q[0] - p[0], q[1] - p[1]
        out = _map_dir(axis, dv * sgn, -du * sgn)
        if _skipped(out, skip):
            continue
        b.poly([_map(axis, a0, *p), _map(axis, a0, *q), _map(axis, a1, *q), _map(axis, a1, *p)], out)
    ax = [0, 0, 0]
    ax[AXES[axis]] = 1
    for t, s, want in ((a0, -1, caps[0]), (a1, 1, caps[1])):
        nrm = mul(tuple(ax), s)
        if want and not _skipped(nrm, skip):
            b.poly([_map(axis, t, *p) for p in profile], nrm)


def strip(b, axis, points, a0, a1):
    """An open profile extruded along `axis`; walk the points with the solid on the LEFT (in (u, v))."""
    for i in range(len(points) - 1):
        p = points[i]
        q = points[i + 1]
        du, dv = q[0] - p[0], q[1] - p[1]
        out = _map_dir(axis, dv, -du)
        b.poly([_map(axis, a0, *p), _map(axis, a0, *q), _map(axis, a1, *q), _map(axis, a1, *p)], out)


FACE_FRAMES = {
    # normal: (axis index of the plane coordinate, u axis, v axis)
    "+z": (2, 0, 1), "-z": (2, 0, 1), "+x": (0, 2, 1), "-x": (0, 2, 1), "+y": (1, 0, 2), "-y": (1, 0, 2),
}


def _fp(normal, w, u, v):
    axis, ua, va = FACE_FRAMES[normal]
    p = [0.0, 0.0, 0.0]
    p[axis] = w
    p[ua] = u
    p[va] = v
    return tuple(p)


def face(b, normal, w, u0, u1, v0, v1, holes=(), paint=None):
    """A rectangle in the plane (normal axis) = w with normal `normal`, minus rectangular recesses.
    holes: list of dicts {u0, u1, v0, v1, depth, back (paint name), surface (optional), walls (paint, default
    the face's)}; holes must not overlap in u. The recess walls and back are built too."""
    n = DIRS[normal]
    face_paint = (b.color, b.sid, b.shade)
    hs = sorted(holes, key=lambda h: h["u0"])
    cur = u0

    def rect(a0, a1, c0, c1):
        if a1 - a0 > 1e-6 and c1 - c0 > 1e-6:
            b.poly([_fp(normal, w, a0, c0), _fp(normal, w, a1, c0), _fp(normal, w, a1, c1), _fp(normal, w, a0, c1)], n)

    for h in hs:
        rect(cur, h["u0"], v0, v1)
        rect(h["u0"], h["u1"], v0, h["v0"])
        rect(h["u0"], h["u1"], h["v1"], v1)
        cur = h["u1"]
    rect(cur, u1, v0, v1)
    sgn = 1 if normal[0] == "+" else -1
    for h in hs:
        back_w = w - sgn * h["depth"]
        # walls: four faces looking into the recess
        if "walls" in h:
            b.set(h["walls"], h.get("walls_surface"), h.get("walls_shade"))
        else:
            b.color, b.sid, b.shade = face_paint
        a0, a1, c0, c1 = h["u0"], h["u1"], h["v0"], h["v1"]
        axis, ua, va = FACE_FRAMES[normal]
        udir = [0, 0, 0]
        udir[ua] = 1
        vdir = [0, 0, 0]
        vdir[va] = 1
        b.poly([_fp(normal, w, a0, c0), _fp(normal, back_w, a0, c0), _fp(normal, back_w, a0, c1), _fp(normal, w, a0, c1)], tuple(udir))
        b.poly([_fp(normal, w, a1, c0), _fp(normal, back_w, a1, c0), _fp(normal, back_w, a1, c1), _fp(normal, w, a1, c1)], mul(tuple(udir), -1))
        b.poly([_fp(normal, w, a0, c0), _fp(normal, back_w, a0, c0), _fp(normal, back_w, a1, c0), _fp(normal, w, a1, c0)], tuple(vdir))
        b.poly([_fp(normal, w, a0, c1), _fp(normal, back_w, a0, c1), _fp(normal, back_w, a1, c1), _fp(normal, w, a1, c1)], mul(tuple(vdir), -1))
        b.set(h["back"], h.get("surface"), h.get("shade"), h.get("jitter", 0.0))
        b.poly([_fp(normal, back_w, a0, c0), _fp(normal, back_w, a1, c0), _fp(normal, back_w, a1, c1), _fp(normal, back_w, a0, c1)], n)
        b.color, b.sid, b.shade = face_paint


def arc_points(cx, cy, r, a0, a1, n):
    return [(cx + r * math.cos(a0 + (a1 - a0) * i / n), cy + r * math.sin(a0 + (a1 - a0) * i / n)) for i in range(n + 1)]


def blind_arch(b, z, sgn, x0, x1, y0, y1, ax0, ax1, spring, depth, segs, ring, paints):
    """A wall face in the plane z (normal sgn * z) over [x0, x1] x [y0, y1] with one blind arch bay: a
    recess of `depth` from y0 up to the springing and a half circle over [ax0, ax1]; voussoirs around it
    (ring = (width, proud, keystone width, keystone proud, gap)). paints: dict face / back / ring / key / impost."""
    n = (0, 0, sgn)
    r = (ax1 - ax0) * 0.5
    cx = (ax0 + ax1) * 0.5
    arc = arc_points(cx, spring, r, math.pi, 0.0, segs)
    b.set(*paints["face"])
    for a0, a1 in ((x0, ax0), (ax1, x1)):
        b.poly([(a0, y0, z), (a1, y0, z), (a1, y1, z), (a0, y1, z)], n)
    for i in range(segs):
        p, q = arc[i], arc[i + 1]
        b.poly([(p[0], p[1], z), (q[0], q[1], z), (q[0], y1, z), (p[0], y1, z)], n)
    zb = z - sgn * depth
    # jambs and intrados (the face colour), sill
    b.poly([(ax0, y0, z), (ax0, spring, z), (ax0, spring, zb), (ax0, y0, zb)], (1, 0, 0))
    b.poly([(ax1, y0, z), (ax1, spring, z), (ax1, spring, zb), (ax1, y0, zb)], (-1, 0, 0))
    for i in range(segs):
        p, q = arc[i], arc[i + 1]
        mid = ((p[0] + q[0]) * 0.5, (p[1] + q[1]) * 0.5)
        inward = (cx - mid[0], spring - mid[1], 0)
        b.poly([(p[0], p[1], z), (q[0], q[1], z), (q[0], q[1], zb), (p[0], p[1], zb)], inward)
    # back of the bay
    b.set(*paints["back"])
    back = [(ax0, y0, zb), (ax1, y0, zb)] + [(p[0], p[1], zb) for p in reversed(arc)]
    b.poly(back, n)
    # voussoirs
    width, proud, kw, kp, gap = ring
    count = segs
    for i in range(count):
        t0 = math.pi - math.pi * i / count
        t1 = math.pi - math.pi * (i + 1) / count
        key = (count % 2 == 1 and i == count // 2)
        w = kw if key else width
        pr = kp if key else proud
        g = gap / max(r, 0.1)
        ta, tb = t0 - g * 0.5, t1 + g * 0.5
        if i == 0:
            ta = t0
        if i == count - 1:
            tb = t1
        b.set(*(paints["key"] if key else paints["ring"]))
        zf = z + sgn * pr
        pi_a = (cx + r * math.cos(ta), spring + r * math.sin(ta))
        pi_b = (cx + r * math.cos(tb), spring + r * math.sin(tb))
        po_a = (cx + (r + w) * math.cos(ta), spring + (r + w) * math.sin(ta))
        po_b = (cx + (r + w) * math.cos(tb), spring + (r + w) * math.sin(tb))
        b.poly([(pi_a[0], pi_a[1], zf), (pi_b[0], pi_b[1], zf), (po_b[0], po_b[1], zf), (po_a[0], po_a[1], zf)], n)
        mo = ((po_a[0] + po_b[0]) * 0.5 - cx, (po_a[1] + po_b[1]) * 0.5 - spring, 0)
        b.poly([(po_a[0], po_a[1], z), (po_b[0], po_b[1], z), (po_b[0], po_b[1], zf), (po_a[0], po_a[1], zf)], mo)
        b.poly([(pi_a[0], pi_a[1], z), (pi_b[0], pi_b[1], z), (pi_b[0], pi_b[1], zf), (pi_a[0], pi_a[1], zf)], mul(mo, -1))
        sa = (math.sin(ta), -math.cos(ta), 0)  # side normals: towards decreasing / increasing angle
        b.poly([(pi_a[0], pi_a[1], z), (po_a[0], po_a[1], z), (po_a[0], po_a[1], zf), (pi_a[0], pi_a[1], zf)], sa)
        sb = (-math.sin(tb), math.cos(tb), 0)
        b.poly([(pi_b[0], pi_b[1], z), (po_b[0], po_b[1], z), (po_b[0], po_b[1], zf), (pi_b[0], pi_b[1], zf)], sb)


def steps(b, x_from, x_to, z0, z1, y_from, y_to, count, lift, paints, side_z=None, side_sgn=1, base_y=0.0, nosing=0.0, along="x"):
    """A straight flight rising from (x_from, y_from) to (x_to, y_to) across z0..z1 (along="x"), or along z
    with x0..x1 given as z0..z1 (along="z"). Each tread top lies `lift` above the ramp line at its lower edge.
    side_z: the plane of a visible side (stringer) face, side_sgn its normal sign."""
    run = (x_to - x_from) / count
    rise = (y_to - y_from) / count
    d = 1 if run > 0 else -1

    def P(t, y, w):
        return (t, y, w) if along == "x" else (w, y, t)

    def N(t, y, w):
        return (t, y, w) if along == "x" else (w, y, t)

    prev_top = base_y
    for i in range(count):
        t0 = x_from + run * i
        t1 = t0 + run
        top = min(y_from + rise * i + lift, y_to)
        top = max(top, base_y + 0.01)
        b.set(*paints["tread"], jitter=0.04)
        # tread
        tn = t0 + d * nosing if nosing > 0 else t0
        b.poly([P(tn, top, z0), P(t1, top, z0), P(t1, top, z1), P(tn, top, z1)], N(0, 1, 0))
        if nosing > 0:
            b.poly([P(t0, top - nosing, z0), P(tn, top, z0), P(tn, top, z1), P(t0, top - nosing, z1)], N(-d, 1, 0))
        # riser (from the previous tread up)
        b.set(*paints["riser"])
        rt = top - nosing if nosing > 0 else top
        if rt > prev_top + 1e-6:
            b.poly([P(t0, prev_top, z0), P(t0, rt, z0), P(t0, rt, z1), P(t0, prev_top, z1)], N(-d, 0, 0))
        sides = side_z if isinstance(side_z, list) else ([] if side_z is None else [(side_z, side_sgn, None, None)])
        for sw, ss, lo, hi in sides:
            if lo is not None and (max(t0, t1) <= lo or min(t0, t1) >= hi):
                continue
            b.set(*paints["side"])
            b.poly([P(t0, base_y, sw), P(t1, base_y, sw), P(t1, top, sw), P(t0, top, sw)], N(0, 0, ss))
        prev_top = top


def plate(b, pts2, w0, w1, normal_axis="z"):
    """A flat plate: the (u, v) polygon pts2 on a face with normal along +/- normal_axis, from plane w0 out to
    plane w1 (w1 - w0 gives the direction it stands out); the back face is left out. normal_axis "z": (u, v) =
    (x, y); "x": (u, v) = (z, y)."""
    sgn = 1 if w1 > w0 else -1
    if normal_axis == "z":
        prism(b, "z", pts2, w0, w1, skip=("-z" if sgn > 0 else "+z",))
    else:
        prism(b, "x", [(v, u) for (u, v) in pts2], w0, w1, skip=("-x" if sgn > 0 else "+x",))


def disc_pts(cu, cv, r, segs, phase=0.0):
    return [(cu + r * math.cos(phase + 2 * math.pi * i / segs), cv + r * math.sin(phase + 2 * math.pi * i / segs)) for i in range(segs)]


def parapet_run(b, axis, out_w, in_w, segs, y_low_out, y_low_in, crenel, ptop, near, holes_fn=None, ends=(True, True)):
    """One side of a parapet: segments (a, c, kind) along `axis` ("x": faces look along z; "z": faces look along
    x) with kind "post" / "merlon" (top ptop) or "crenel" (top crenel); outer face in the plane out_w (from
    y_low_out), inner face in the plane in_w (from y_low_in). Notch sides where a neighbour is lower; end faces
    when `ends` says. holes_fn(a, c, kind) -> holes for the outer face (near only)."""
    so = 1 if out_w > in_w else -1
    nrm_out = ("+" if so > 0 else "-") + ("z" if axis == "x" else "x")
    nrm_in = ("-" if so > 0 else "+") + ("z" if axis == "x" else "x")

    def pt(t, y, w):
        return (t, y, w) if axis == "x" else (w, y, t)

    top_of = lambda k: crenel if k == "crenel" else ptop
    for i, (a, c, k) in enumerate(segs):
        top = top_of(k)
        holes = holes_fn(a, c, k) if (near and holes_fn) else []
        face(b, nrm_out, out_w, a, c, y_low_out, top, holes)
        face(b, nrm_in, in_w, a, c, y_low_in, top)
        if k == "crenel" and not near:
            b.poly([pt(a, top, out_w), pt(c, top, out_w), pt(c, top, in_w), pt(a, top, in_w)], (0, 1, 0))
        for side, t, nb in ((-1, a, segs[i - 1] if i > 0 else None), (1, c, segs[i + 1] if i < len(segs) - 1 else None)):
            lo = None
            if nb is not None and top_of(nb[2]) < top - 1e-6:
                lo = top_of(nb[2])
            elif nb is None and ends[0 if side < 0 else 1]:
                lo = min(y_low_in, y_low_out)
            if lo is not None:
                n = (side, 0, 0) if axis == "x" else (0, 0, side)
                b.poly([pt(t, lo, out_w), pt(t, top, out_w), pt(t, top, in_w), pt(t, lo, in_w)], n)


def copings(b, axis, out_w, in_w, segs, crenel, ptop, near, overhang=0.05, cap_h=0.12, sill=True, along=True):
    """Marble copings on the posts and merlons of a parapet run (overhanging outwards, and along the run when
    `along`) and sills in the crenels."""
    so = 1 if out_w > in_w else -1
    lo_w, hi_w = (in_w, out_w + overhang) if so > 0 else (out_w - overhang, in_w)
    for (a, c, k) in segs:
        if k == "crenel":
            if near and sill:
                mn = (a, crenel - 0.05, lo_w) if axis == "x" else (lo_w, crenel - 0.05, a)
                mx = (c, crenel + 0.03, hi_w) if axis == "x" else (hi_w, crenel + 0.03, c)
                box(b, mn, mx, chamfer=0.02, skip=("-y",))
            continue
        e = overhang if along else 0.0
        mn = (a - e, ptop - 0.02, lo_w) if axis == "x" else (lo_w, ptop - 0.02, a - e)
        mx = (c + e, ptop + cap_h - 0.02, hi_w) if axis == "x" else (hi_w, ptop + cap_h - 0.02, c + e)
        box(b, mn, mx, chamfer=0.03 if near else 0.0, skip=("-y",))


# ---------------------------------------------------------------- post: joint bend, attributes

def joint_bend(tris, joint):
    """Pieces of one wall side overlap by 0.5 to 1.4 m (centres 6.6 to 7.5 m apart): so their faces never lie
    in one plane there, every piece is skewed a little: a point moves by offset * (x / half_length) * f, with
    f = min(y / y_knee, 1) upwards (the ground stays) and clamp(z / z_knee, -1, 1) sideways. The +x end
    swells and the -x end shrinks, so in an overlap the left piece's faces lie 1.3 offset or more outside the
    right piece's. Linear in x, so a flat face stays flat (no splits, no cracks)."""
    if not joint:
        return tris
    e, half = float(joint["offset_m"]), float(joint["half_length_m"])
    yk, zk = float(joint["y_knee_m"]), float(joint["z_knee_m"])

    def bend(p):
        r = max(-1.0, min(p[0] / half, 1.0))
        dy = e * r * max(0.0, min(p[1] / yk, 1.0))
        dz = e * r * max(-1.0, min(p[2] / zk, 1.0))
        return (p[0], p[1] + dy, p[2] + dz)

    out = []
    for t in tris:
        q = [bend(t[0]), bend(t[1]), bend(t[2])]
        if length(cross(sub(q[1], q[0]), sub(q[2], q[0]))) > 1e-10:
            out.append((q[0], q[1], q[2]) + tuple(t[3:]))
    return out


def uv_axes(normal):
    """The kit's rule (LowpolyKit._triangle): u / v axes of a face from its normal."""
    ax, ay, az = abs(normal[0]), abs(normal[1]), abs(normal[2])
    u_axis = (1.0, 0.0, 0.0)
    v_axis = (0.0, -1.0, 0.0)
    if ay >= ax and ay >= az:
        v_axis = (0.0, 0.0, 1.0)
        if ay < 0.985:
            hv = norm((normal[0], 0.0, normal[2]))
            s = 1.0 if normal[1] >= 0.0 else -1.0
            v_axis = (hv[0] * s, 0.0, hv[2] * s)
            u_axis = (v_axis[2], 0.0, -v_axis[0])
    elif ax >= az:
        u_axis = (0.0, 0.0, 1.0)
    return u_axis, v_axis


# ---------------------------------------------------------------- a quick fit check (the report line)
# An approximation of tests/test_m2w1_world_kit.gd for iterating in Blender alone (the test is the authority):
# boxes exact; a wedge by its largest face-plane distance (exact over a face, low near its edges); open volumes and
# walk surfaces as the test reads them. Only rotations about y are handled (all the kit uses).

def _yaw_of(entry):
    return math.radians(float(entry.get("rot", [0, 0, 0])[1]))


def _to_local(entry, p):
    at = entry["at"]
    d = (p[0] - at[0], p[1] - at[1], p[2] - at[2])
    t = _yaw_of(entry)
    c, s = math.cos(t), math.sin(t)
    # inverse of x' = x c + z s, z' = -x s + z c
    return (d[0] * c - d[2] * s, d[1], d[0] * s + d[2] * c)


def _solid_distance(entry, p):
    q = _to_local(entry, p)
    h = [entry["size"][i] * 0.5 for i in range(3)]
    if entry.get("shape", "box") != "wedge":
        d = [max(abs(q[i]) - h[i], 0.0) for i in range(3)]
        return length(d)
    ridge = float(entry.get("ridge", 1.0))
    zr = -h[2] + 2 * h[2] * ridge
    worst = max(abs(q[0]) - h[0], -h[1] - q[1])
    # sloped faces (in y-z): from (z=-h2, y=-h1) to (zr, h1) and from (zr, h1) to (h2, -h1)
    for (z0, y0, z1, y1) in ((-h[2], -h[1], zr, h[1]), (zr, h[1], h[2], -h[1])):
        dz, dy = z1 - z0, y1 - y0
        n = (-dy, dz)   # outward (z, y) for this walk order (from -z to +z over the top)
        ln = math.hypot(n[0], n[1])
        if ln < 1e-9:
            continue
        sd = ((q[2] - z0) * n[0] + (q[1] - y0) * n[1]) / ln
        worst = max(worst, sd)
    return max(worst, 0.0)


def fit_check(data, type_name, tris):
    t = data.types[type_name]
    cols = t["colliders"]
    seen = set()
    worst, at = 0.0, None
    deep, deep_at = 0.0, None
    walk_w, walk_at = 0.0, None
    cfg = data.cfg
    clear, head, edge = cfg["walk_clear_m"], cfg["walk_head_m"], cfg["walk_edge_m"]
    for tr in tris:
        for v in tr[:3]:
            key = (round(v[0], 5), round(v[1], 5), round(v[2], 5))
            if key in seen:
                continue
            seen.add(key)
            best = min(_solid_distance(c, v) for c in cols)
            if best > worst:
                worst, at = best, v
            for o in t.get("open", []):
                q = [abs(v[i] - o["at"][i]) for i in range(3)]
                h = [o["size"][i] * 0.5 for i in range(3)]
                if q[0] < h[0] and q[1] < h[1] and q[2] < h[2]:
                    dpt = min(h[0] - q[0], h[1] - q[1], h[2] - q[2])
                    if dpt > deep:
                        deep, deep_at = dpt, v
            for wk in t.get("walk", []):
                q = _to_local(wk, v)
                sx, sz = wk["size"]
                if abs(q[0]) >= sx * 0.5 - edge or abs(q[2]) >= sz * 0.5 - edge:
                    continue
                above = q[1] - float(wk.get("rise", 0.0)) * q[2] / sz
                if clear < above <= head and above > walk_w:
                    walk_w, walk_at = above, v
    fmt = lambda p: "(%.3f,%.3f,%.3f)" % p if p else "-"
    flag = "" if worst <= cfg["fit_tolerance_m"] + 1e-5 and deep <= cfg["fit_tolerance_m"] + 1e-5 and walk_w == 0.0 else " FIT_FAIL"
    return "over=%.3f@%s open=%.3f@%s walk=%.3f@%s%s" % (worst, fmt(at), deep, fmt(deep_at), walk_w, fmt(walk_at), flag)


# ---------------------------------------------------------------- export

def to_blender(p):
    return (p[0], -p[2], p[1])


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
    # Every loop i is vertex i (from_pydata keeps the order); attributes per loop.
    for i, t in enumerate(tris):
        a, b_, c = t[0], t[1], t[2]
        normal = norm(cross(sub(b_, a), sub(c, a)))
        u_axis, v_axis = uv_axes(normal)
        rgba, sid, shade = t[3], t[4], t[5]
        lin = (rgba[0], rgba[1], rgba[2], rgba[3])  # sRGB on purpose (see the module note)
        for k, p in enumerate((a, b_, c)):
            li = 3 * i + k
            uv0.data[li].uv = (dot(p, u_axis), 1.0 - dot(p, v_axis))
            uv1.data[li].uv = (float(sid), 1.0 - shade)
            col.data[li].color = lin
    mesh.color_attributes.active_color = col
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def export(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=path, export_format="GLB", use_selection=False, export_apply=False,
        export_texcoords=True, export_normals=True, export_tangents=False,
        export_materials="NONE", export_vertex_color="ACTIVE", export_all_vertex_colors=False,
        export_active_vertex_color_when_no_material=True, export_attributes=False,
        export_yup=True, export_extras=False, export_animations=False, export_cameras=False,
        export_lights=False, export_draco_mesh_compression_enable=False)


# ---------------------------------------------------------------- the types
# Every look is designed ON its colliders (data/maps/alesia_structures.json): dimensions come from the
# collider boxes; the numbers below are art offsets (how far a moulding stands out, a course height ...), all
# kept inside data/art_world_kit.json fit_tolerance_m of the colliders (tests/test_m2w1_world_kit.gd).

def bounds(entry):
    at, size = entry["at"], entry["size"]
    mn = tuple(at[i] - size[i] * 0.5 for i in range(3))
    mx = tuple(at[i] + size[i] * 0.5 for i in range(3))
    return mn, mx


class WallDims:
    """The wall section from its two colliders: the body box and the parapet box on the outer (-z) side."""

    def __init__(self, data):
        cols = data.colliders("wall_walk")
        (x0, _, zo), (x1, wy, zi) = bounds(cols[0])
        (_, _, pz0), (_, ptop, pin) = bounds(cols[1])
        self.x0, self.x1, self.zo, self.zi, self.wy = x0, x1, zo, zi, wy
        self.pin, self.ptop = pin, ptop
        # M2W1 item 2: the crenel floors 0.14 below the collider top and the merlon copings 0.12 above it (a
        # 0.26 m step; 0.12 because the joint bend lifts the +x end 0.015 and the coping overhangs 0.04: its
        # corner stays inside the fit tolerance).
        self.crenel = ptop - 0.14
        self.merlon_top = ptop + 0.12
        # Merlon rhythm: both ends of a piece are merlons end_m wide; pieces overlap 0.5 to 1.4 m, so with end_m
        # >= 1.4 the two end merlons always join into one wider merlon at a joint and no crenel there is ever cut
        # short. Between them crenels of crenel_m and merlons of merlon_m, evenly: 4 c + 3 m = length - 2 end.
        end_m, n_cr = 1.4, 4
        merlon_m = 0.8
        crenel_m = ((x1 - x0) - 2 * end_m - (n_cr - 1) * merlon_m) / n_cr
        edges = [(x0, x0 + end_m)]
        cur = x0 + end_m
        for i in range(n_cr - 1):
            a = cur + crenel_m
            edges.append((a, a + merlon_m))
            cur = a + merlon_m
        edges.append((x1 - end_m, x1))
        self.merlon_edges = edges
        self.string = (2.5, 2.75)          # marble string course (y); the ashlar courses below are 0.5 m (the texture's rows)
        self.cornice_y = 2.70              # inner cornice bottom


# paints: (paint name, surface override or None)
P_BASE = ("rock", "ashlar")
P_WALL = ("travertine", None)
P_SHADE = ("travertine_shade", None)
P_MARBLE = ("marble", None)
P_BRONZE = ("bronze", None)
P_GLOW = ("lit_accent", None)
P_RED = ("legion_red", "plaster")
P_GOLD = ("gold", None)
P_SLIT = ("visor", "plain")
P_WALK = ("travertine_shade", "paving")
P_DARKSTONE = ("dark", "rock")
P_TIMBER = ("timber", None)
P_LEATHER = ("leather", None)
P_CANVAS = ("canvas", None)
P_ROOF = ("roof_tile", None)
P_PLATE = ("plate_dark", None)


def paint(b, p, shade=None, jitter=0.0):
    b.set(p[0], p[1], shade, jitter)


def wall_section(b, w, level, inner="arcade"):
    """The wall body: outer face (plinth, courses, string course, centre pilaster, spouts), parapet with
    merlons and bronze-shuttered crenels, the walkway, the inner face (inner = "arcade": cornice and one blind
    arch; "flat": a plain face, for the stair piece) and the end caps."""
    X0, X1, ZO, ZI, WY, PIN = w.x0, w.x1, w.zo, w.zi, w.wy, w.pin
    s0, s1 = w.string
    near = level == 0
    # segments of the parapet: (x_a, x_b, is_merlon)
    segs = []
    cur = X0
    for a, c in w.merlon_edges:
        if a > cur + 1e-6:
            segs.append((cur, a, False))
        segs.append((a, c, True))
        cur = c
    if cur < X1 - 1e-6:
        segs.append((cur, X1, False))
    top_of = lambda m: w.ptop if m else w.crenel
    OF = ZO - 0.02  # parapet outer face

    if near:
        # outer plinth (dark base course with a weathered top)
        paint(b, P_BASE, 0.5)
        prism(b, "x", [(0.0, ZO), (0.0, ZO - 0.12), (0.42, ZO - 0.12), (0.5, ZO - 0.03), (0.5, ZO)], X0, X1,
              skip=("-y", "+z"), caps=(False, False))
        # ashlar courses: each a band with chamfered (V-groove) edges, on the texture's 0.5 m rows
        rows = []
        y = 0.5
        while y < s0 - 1e-6:
            rows.append((y, min(y + 0.5, s0)))
            y += 0.5
        for i, (ya, yb) in enumerate(rows):
            paint(b, P_WALL, 0.5, 0.07)
            pts = []
            pts.append((ya, ZO - 0.03) if i == 0 else (ya, ZO))
            if i > 0:
                pts.append((ya + 0.03, ZO - 0.03))
            pts.append((yb - 0.03, ZO - 0.03))
            pts.append((yb, ZO))
            strip(b, "x", pts, X0, X1)
        # string course (marble) under the walk level
        paint(b, P_MARBLE, 0.5)
        prism(b, "x", [(s0, ZO), (s0 + 0.06, ZO - 0.10), (s0 + 0.14, ZO - 0.12), (s1, ZO - 0.12), (s1, ZO)], X0, X1,
              skip=("+z",), caps=(False, False))
        # centre pilaster with base and capital, under the centre merlon
        paint(b, P_WALL, 0.56)
        box(b, (-0.45, 0.6, ZO - 0.10), (0.45, s0 - 0.16, ZO), chamfer=0.03, skip=("-y", "+y", "+z"))
        paint(b, P_MARBLE, 0.46)
        box(b, (-0.52, 0.44, ZO - 0.13), (0.52, 0.6, ZO), chamfer=0.025, skip=("-y", "+z"))
        box(b, (-0.53, s0 - 0.16, ZO - 0.13), (0.53, s0, ZO), chamfer=0.025, skip=("+z", "+y"))
        paint(b, P_BRONZE, 0.5)
        box(b, (-0.16, 1.45, ZO - 0.13), (0.16, 1.77, ZO - 0.09), chamfer=0.02, skip=("+z",))
        # bronze spouts under the string course, below the in-piece crenels
        for (a, c, m) in segs:
            if not m and a > X0 + 1e-6 and c < X1 - 1e-6:
                cx = (a + c) * 0.5
                box(b, (cx - 0.07, s0 - 0.12, ZO - 0.135), (cx + 0.07, s0 - 0.03, ZO), chamfer=0.015, skip=("+z",))
    else:
        paint(b, P_WALL, 0.5)
        b.poly([(X0, 0, ZO - 0.05), (X1, 0, ZO - 0.05), (X1, s0, ZO - 0.05), (X0, s0, ZO - 0.05)], (0, 0, -1))
        paint(b, P_MARBLE, 0.5)
        box(b, (X0, s0, ZO - 0.12), (X1, s1, ZO), skip=("+z", "-x", "+x"))
        # parapet: one face each side, the crenel-level top, three merlon blocks with their coping
        paint(b, P_WALL, 0.5)
        b.poly([(X0, s1, OF), (X1, s1, OF), (X1, w.crenel, OF), (X0, w.crenel, OF)], (0, 0, -1))
        b.poly([(X0, WY, PIN), (X1, WY, PIN), (X1, w.crenel, PIN), (X0, w.crenel, PIN)], (0, 0, 1))
        b.poly([(X0, w.crenel, OF), (X1, w.crenel, OF), (X1, w.crenel, PIN), (X0, w.crenel, PIN)], (0, 1, 0))
        paint(b, P_MARBLE, 0.5)
        for (a, c, m) in segs:
            if m:
                box(b, (a, w.crenel, ZO - 0.04), (c, w.merlon_top, PIN), skip=("-y",))

    # parapet
    for i, (a, c, m) in enumerate(segs if near else []):
        top = top_of(m)
        holes = []
        if near:
            cx = (a + c) * 0.5
            if m:
                holes.append({"u0": cx - 0.06, "u1": cx + 0.06, "v0": 3.2, "v1": 3.85, "depth": 0.12,
                              "back": P_SLIT[0], "surface": P_SLIT[1]})
            elif a > X0 + 1e-6 and c < X1 - 1e-6:
                # the crenel's recessed face: dark stone (bronze read rust-orange at dusk)
                holes.append({"u0": a + 0.1, "u1": c - 0.1, "v0": 3.28, "v1": w.crenel - 0.12, "depth": 0.07,
                              "back": P_DARKSTONE[0], "surface": P_DARKSTONE[1], "shade": 0.42})
        paint(b, P_WALL, 0.5, 0.05 if near else 0.0)
        if near:
            face(b, "-z", OF, a, c, s1, top, holes)
        elif m:
            b.poly([(a, w.crenel, OF), (c, w.crenel, OF), (c, top, OF), (a, top, OF)], (0, 0, -1))
        paint(b, P_WALL, 0.5)
        b.poly([(a, WY, PIN), (c, WY, PIN), (c, top, PIN), (a, top, PIN)], (0, 0, 1))
        if not m and not near:
            b.poly([(a, top, OF), (c, top, OF), (c, top, PIN), (a, top, PIN)], (0, 1, 0))
        # notch sides: where the neighbour segment is lower
        for side, x, nb in ((-1, a, segs[i - 1] if i > 0 else None), (1, c, segs[i + 1] if i < len(segs) - 1 else None)):
            if nb is not None and top_of(nb[2]) < top - 1e-6:
                lo = top_of(nb[2])
                b.poly([(x, lo, OF), (x, top, OF), (x, top, PIN), (x, lo, PIN)], (side, 0, 0))
    if near:
        paint(b, P_MARBLE, 0.5, 0.05)
        for (a, c, m) in segs:
            if m:
                # copings overhang 0.04 outwards and 0.03 along (none at the piece's ends: the joint merlon)
                ea = 0.0 if a <= X0 + 1e-6 else 0.03
                ec = 0.0 if c >= X1 - 1e-6 else 0.03
                box(b, (a - ea, w.ptop - 0.02, ZO - 0.04), (c + ec, w.merlon_top, PIN), chamfer=0.03, skip=("-y",))
            else:
                box(b, (a, w.crenel - 0.05, ZO - 0.07), (c, w.crenel + 0.03, PIN), chamfer=0.02, skip=("-y", "-x", "+x"))

    # walkway: slabs with chamfered joints across the walk
    paint(b, P_WALK, 0.5)
    wz1 = ZI + (0.11 if inner == "arcade" else 0.0)
    if near:
        n = 8
        for k in range(n):
            xa = X0 + (X1 - X0) * k / n
            xb = X0 + (X1 - X0) * (k + 1) / n
            paint(b, P_WALK, 0.5, 0.06)
            g = 0.02
            b.poly([(xa + g, WY, PIN), (xb - g, WY, PIN), (xb - g, WY, wz1), (xa + g, WY, wz1)], (0, 1, 0))
            b.poly([(xa, WY - g, PIN), (xa + g, WY, PIN), (xa + g, WY, wz1), (xa, WY - g, wz1)], (-1, 1, 0))
            b.poly([(xb - g, WY, PIN), (xb, WY - g, PIN), (xb, WY - g, wz1), (xb - g, WY, wz1)], (1, 1, 0))
    else:
        b.poly([(X0, WY, PIN), (X1, WY, PIN), (X1, WY, wz1), (X0, WY, wz1)], (0, 1, 0))

    # inner face
    IF = ZI + 0.02
    if inner == "arcade":
        if near:
            # M2W1 item 2: the proud plinth stops 1.4 m (the largest overlap) short of both ends, so it never runs
            # across a neighbouring stair's first steps; over the ends a flush base band.
            pe = 1.4
            paint(b, P_BASE, 0.5)
            prism(b, "x", [(0.0, ZI), (0.0, ZI + 0.10), (0.42, ZI + 0.10), (0.5, IF), (0.5, ZI)], X0 + pe, X1 - pe,
                  skip=("-y", "-z"), caps=(True, True))
            paint(b, P_BASE, 0.46)
            for (xa, xb) in ((X0, X0 + pe), (X1 - pe, X1)):
                b.poly([(xa, 0.0, ZI + 0.004), (xb, 0.0, ZI + 0.004), (xb, 0.5, ZI + 0.004), (xa, 0.5, ZI + 0.004)], (0, 0, 1))
                b.poly([(xa, 0.5, ZI + 0.004), (xb, 0.5, ZI + 0.004), (xb, 0.5, IF), (xa, 0.5, IF)], (0, -1, 0))
            paint(b, P_MARBLE, 0.5)
            strip(b, "x", [(WY, wz1), (WY - 0.07, wz1), (w.cornice_y + 0.10, ZI + 0.08), (w.cornice_y, IF)], X0, X1)
            paint(b, P_GLOW, 0.5)
            box(b, (X0, w.cornice_y - 0.07, IF - 0.01), (X1, w.cornice_y - 0.04, IF + 0.025), skip=("-z", "-x", "+x"))
            blind_arch(b, IF, 1, X0, X1, 0.5, w.cornice_y - 0.07, -1.5, 1.5, 0.88, 0.2, 9,
                       (0.18, 0.03, 0.2, 0.05, 0.012),
                       {"face": ("travertine", None, 0.5), "back": ("travertine_shade", None, 0.42),
                        "ring": ("travertine", None, 0.58), "key": ("marble", None, 0.5)})
            paint(b, P_WALL, 0.5)
            b.poly([(X0, w.cornice_y - 0.07, IF), (X1, w.cornice_y - 0.07, IF), (X1, w.cornice_y, IF), (X0, w.cornice_y, IF)], (0, 0, 1))
            paint(b, P_MARBLE, 0.5)
            for sx in (-1, 1):
                ax = sx * 1.5
                box(b, (min(ax, ax + sx * 0.16) - (0.0 if sx > 0 else 0.0), 0.8, IF - 0.01),
                    (max(ax, ax + sx * 0.16), 0.88, IF + 0.04), chamfer=0.015, skip=("-z",))
        else:
            paint(b, P_WALL, 0.5)
            b.poly([(X0, 0, IF), (X1, 0, IF), (X1, WY, IF), (X0, WY, IF)], (0, 0, 1))
            paint(b, P_SHADE, 0.42)
            arc = arc_points(0.0, 0.88, 1.5, math.pi, 0.0, 4)
            b.poly([(-1.5, 0.5, IF + 0.006), (1.5, 0.5, IF + 0.006)] + [(p[0], p[1], IF + 0.006) for p in reversed(arc)], (0, 0, 1))
            paint(b, P_MARBLE, 0.5)
            b.poly([(X0, WY - 0.3, IF + 0.09), (X1, WY - 0.3, IF + 0.09), (X1, WY, IF + 0.09), (X0, WY, IF + 0.09)], (0, 0, 1))
            b.poly([(X0, WY - 0.3, IF), (X1, WY - 0.3, IF), (X1, WY - 0.3, IF + 0.09), (X0, WY - 0.3, IF + 0.09)], (0, -1, 0))
    else:
        paint(b, P_WALL, 0.5)
        b.poly([(X0, 0, ZI), (X1, 0, ZI), (X1, WY, ZI), (X0, WY, ZI)], (0, 0, 1))

    # end caps: the section's outline at x = X0 and X1
    out_profile = [(0.0, ZO - 0.12), (0.42, ZO - 0.12), (0.5, ZO - 0.03), (s0, ZO - 0.03), (s0, ZO),
                   (s0 + 0.06, ZO - 0.10), (s0 + 0.14, ZO - 0.12), (s1, ZO - 0.12), (s1, OF)]
    if not near:
        out_profile = [(0.0, ZO - 0.05), (s0, ZO - 0.05), (s0, ZO - 0.12), (s1, ZO - 0.12), (s1, OF)]
    if near:
        out_profile += [(w.crenel - 0.05, OF), (w.crenel - 0.05, ZO - 0.07), (w.crenel + 0.03, ZO - 0.07), (w.crenel + 0.03, PIN)]
    else:
        out_profile += [(w.crenel, OF), (w.crenel, PIN)]
    out_profile += [(WY, PIN), (WY, wz1)]
    if inner == "arcade":
        if near:
            out_profile += [(WY - 0.07, wz1), (w.cornice_y + 0.10, ZI + 0.08), (w.cornice_y, IF), (0.5, IF), (0.5, ZI + 0.004), (0.0, ZI + 0.004)]
        else:
            out_profile += [(WY, IF + 0.09), (WY - 0.3, IF + 0.09), (WY - 0.3, IF), (0.0, IF)]
    else:
        out_profile += [(0.0, ZI)]
    paint(b, P_SHADE, 0.5)
    for x, s in ((X0, -1), (X1, 1)):
        b.poly([(x, y, z) for (y, z) in out_profile], (s, 0, 0))


def build_wall_walk(b, data, level):
    wall_section(b, WallDims(data), level, "arcade")


def wedge_ramp(entry):
    """A ridge-1 wedge collider as (x range, z range, y bottom, y top, rising axis "x"/"z", sign): the ramp
    rises towards local +Z before rot (only 90 degree turns about y are used by the kit)."""
    (mnx, mny, mnz), (mxx, mxy, mxz) = bounds(entry)
    yaw = round(float(entry.get("rot", [0, 0, 0])[1])) % 360
    sx, sz = entry["size"][0], entry["size"][2]
    cx, cz = entry["at"][0], entry["at"][2]
    if yaw in (90, 270):
        sx, sz = sz, sx
    xr = (cx - sx * 0.5, cx + sx * 0.5)
    zr = (cz - sz * 0.5, cz + sz * 0.5)
    # local +z turned by yaw: 0 -> +z, 90 -> +x, 180 -> -z, 270 -> -x
    rise = {0: ("z", 1), 90: ("x", 1), 180: ("z", -1), 270: ("x", -1)}[yaw]
    return xr, zr, mny, mxy, rise


def build_wall_stair(b, data, level):
    w = WallDims(data)
    wall_section(b, w, level, "flat")
    cols = data.colliders("wall_stair")
    ramp = [c for c in cols if c.get("shape") == "wedge"][0]
    landing = [c for c in cols if c.get("shape", "box") == "box" and bounds(c)[0][2] >= w.zi - 1e-6][0]
    xr, zr, yb, yt, (axis, sg) = wedge_ramp(ramp)
    (lx0, _, lz0), (lx1, ly1, lz1) = bounds(landing)
    near = level == 0
    paints = {"tread": ("travertine", None), "riser": ("travertine_shade", None), "side": ("travertine_shade", None)}
    if near:
        steps(b, xr[0], xr[1], zr[0], zr[1], yb, yt, 20, 0.03, paints, side_z=zr[1], side_sgn=1, nosing=0.025)
        # the last riser up to the landing
        paint(b, P_SHADE, 0.5)
        last = yb + (yt - yb) * 19 / 20 + 0.03
        b.poly([(xr[1], last, zr[0]), (xr[1], yt, zr[0]), (xr[1], yt, zr[1]), (xr[1], last, zr[1])], (-1, 0, 0))
        # stringer coping on the open side: a marble band along the flight's side, just below the treads
        paint(b, P_MARBLE, 0.5)
        run = xr[1] - xr[0]
        k = (yt - yb) / run
        zs = zr[1] + 0.06
        xa_top = xr[0] + 0.13 / k
        xa_bot = xr[0] + 0.29 / k
        top_end, bot_end = yt - 0.13, yt - 0.29
        b.poly([(xa_top, yb, zs), (xa_bot, yb, zs), (xr[1], bot_end, zs), (xr[1], top_end, zs)], (0, 0, 1))
        b.poly([(xa_top, yb, zr[1]), (xr[1], top_end, zr[1]), (xr[1], top_end, zs), (xa_top, yb, zs)], (-k, 1, 0))
        b.poly([(xa_bot, yb, zr[1]), (xr[1], bot_end, zr[1]), (xr[1], bot_end, zs), (xa_bot, yb, zs)], (k, -1, 0))
    else:
        paint(b, P_WALL, 0.5)
        n = 5
        prev = 0.0
        for kk in range(n):
            t0 = xr[0] + (xr[1] - xr[0]) * kk / n
            t1 = xr[0] + (xr[1] - xr[0]) * (kk + 1) / n
            top = yb + (yt - yb) * kk / n + 0.03
            b.poly([(t0, top, zr[0]), (t1, top, zr[0]), (t1, top, zr[1]), (t0, top, zr[1])], (0, 1, 0))
            b.poly([(t0, prev, zr[0]), (t0, top, zr[0]), (t0, top, zr[1]), (t0, prev, zr[1])], (-1, 0, 0))
            b.poly([(t0, 0, zr[1]), (t1, 0, zr[1]), (t1, top, zr[1]), (t0, top, zr[1])], (0, 0, 1))
            prev = top
        b.poly([(xr[1], prev, zr[0]), (xr[1], yt, zr[0]), (xr[1], yt, zr[1]), (xr[1], prev, zr[1])], (-1, 0, 0))
    # landing block: plinth, ashlar face, a marble coping band, the paving on top
    if near:
        po = 0.08  # plinth / coping overhang (both faces: the corner stays inside the fit tolerance)
        paint(b, P_BASE, 0.5)
        prism(b, "x", [(0.0, lz1), (0.0, lz1 + po), (0.42, lz1 + po), (0.5, lz1 + 0.03), (0.5, lz1)], lx0, lx1 + po,
              skip=("-y", "-z"), caps=(True, False))
        prism(b, "z", [(lx1, 0.0), (lx1 + po, 0.0), (lx1 + po, 0.42), (lx1 + 0.03, 0.5), (lx1, 0.5)], lz0, lz1,
              skip=("-y", "-x"), caps=(False, False))
        for kk, (ya, yb2) in enumerate(((0.5, 1.0), (1.0, 1.5), (1.5, 2.0), (2.0, 2.5), (2.5, 2.72))):
            paint(b, P_WALL, 0.5, 0.07)
            b.poly([(lx0, ya, lz1 + 0.03), (lx1 + 0.03, ya, lz1 + 0.03), (lx1 + 0.03, yb2, lz1 + 0.03), (lx0, yb2, lz1 + 0.03)], (0, 0, 1))
            b.poly([(lx1 + 0.03, ya, lz0), (lx1 + 0.03, ya, lz1 + 0.03), (lx1 + 0.03, yb2, lz1 + 0.03), (lx1 + 0.03, yb2, lz0)], (1, 0, 0))
        co = 0.07
        paint(b, P_MARBLE, 0.5)
        box(b, (lx0, 2.72, lz0), (lx1 + co, ly1 - 0.02, lz1 + co), chamfer=0.025, skip=("-x", "-z", "+y"))
        paint(b, P_WALK, 0.5, 0.06)
        b.poly([(lx0, ly1, lz0), (lx1, ly1, lz0), (lx1, ly1, lz1), (lx0, ly1, lz1)], (0, 1, 0))
        paint(b, P_MARBLE, 0.5)
        b.poly([(lx0, ly1 - 0.02, lz1), (lx1, ly1 - 0.02, lz1), (lx1 + co, ly1 - 0.02, lz1 + co), (lx0, ly1 - 0.02, lz1 + co)], (0, 1, 0))
        b.poly([(lx1, ly1 - 0.02, lz0), (lx1 + co, ly1 - 0.02, lz0), (lx1 + co, ly1 - 0.02, lz1 + co), (lx1, ly1 - 0.02, lz1)], (0, 1, 0))
        b.poly([(lx1, ly1 - 0.02, lz1), (lx1, ly1, lz1), (lx0, ly1, lz1), (lx0, ly1 - 0.02, lz1)], (0, 0, 1))
        b.poly([(lx1, ly1 - 0.02, lz0), (lx1, ly1, lz0), (lx1, ly1, lz1), (lx1, ly1 - 0.02, lz1)], (1, 0, 0))
    else:
        paint(b, P_WALL, 0.5)
        box(b, (lx0, 0.0, lz0), (lx1, ly1, lz1), skip=("-y", "-x", "-z"))


LETTER_ROWS = 2


def build_gate(b, data, level):
    """A gatehouse front on each face (outer -z grander): two pylons (plinth, rusticated courses, a red shield
    panel with a bronze boss, a cap moulding), a marble portal frame with corner brackets, a flat arch of
    voussoirs with a keystone over the lintel, the attic with a red tablet of gold letter bars and two bronze
    eagle roundels, a cornice, merlons; the jambs carry the pocket slots the leaves slide into."""
    cols = data.colliders("gate")
    (lx0, _, zo), (lx1, py1, zi) = bounds(cols[0])[0], bounds(cols[1])[1]
    (_, ay0, _), (_, ay1, _) = bounds(cols[2])
    X0, X1 = bounds(cols[0])[0][0], bounds(cols[1])[1][0]
    ox0, ox1 = bounds(cols[0])[1][0], bounds(cols[1])[0][0]   # the opening's sides
    near = level == 0
    crenel = ay1 - 0.15
    cor0, cor1 = ay1 - 0.45, crenel                              # cornice band
    merlon_cs = [-3.2, -1.6, 0.0, 1.6, 3.2]
    mh = 0.45
    segs = []
    cur = X0
    for c in merlon_cs:
        segs.append((cur, c - mh, "crenel"))
        segs.append((c - mh, c + mh, "merlon"))
        cur = c + mh
    segs.append((cur, X1, "crenel"))
    lint0, lint1 = py1, py1 + 0.35                               # lintel band of the portal frame
    vou1 = lint1 + 0.5                                           # top of the flat arch
    tab0, tab1 = vou1 + 0.08, cor0 - 0.08                         # the tablet
    slot = 0.16                                                   # pocket slot half width (leaf 0.25 thick)

    for s in (-1, 1):
        outer = s < 0
        Z = zo if outer else zi
        F = Z + s * 0.02         # face plane, a little proud of the collider
        nz = (0, 0, s)
        nzs = "+z" if s > 0 else "-z"
        back = "+z" if s < 0 else "-z"   # the direction into the gate from this face
        if near:
            for (px0, px1) in ((X0, ox0), (ox1, X1)):
                paint(b, P_BASE, 0.5)
                prism(b, "x", [(0.0, Z), (0.0, Z + s * 0.12), (0.5, Z + s * 0.12), (0.6, Z + s * 0.04), (0.6, Z)], px0, px1,
                      skip=("-y", back), caps=(px0 > X0 + 1e-6, px1 < X1 - 1e-6))
                cy0 = py1 - 0.5
                rows = [(0.6, 1.0)] + [(v * 0.5, v * 0.5 + 0.5) for v in range(2, int(round(cy0 * 2)))]
                for i, (ya, yb) in enumerate(rows):
                    paint(b, P_WALL, 0.5, 0.08)
                    pts = [(ya, Z + s * 0.04)] if i == 0 else [(ya, Z), (ya + 0.03, Z + s * 0.04)]
                    pts += [(yb - 0.03, Z + s * 0.04), (yb, Z)]
                    if s > 0:
                        pts = [(p[0], p[1]) for p in reversed(pts)]
                    strip(b, "x", pts, px0, px1)
                # cap moulding of the pylon (under the lintel line), returns into the opening skipped
                paint(b, P_MARBLE, 0.5)
                prism(b, "x", [(cy0, Z), (cy0 + 0.1, Z + s * 0.11), (py1, Z + s * 0.12), (py1, Z)], px0, px1,
                      skip=(back,), caps=(px0 > X0 + 1e-6, px1 < X1 - 1e-6))
                # shield panel: recessed, red on the outer face, with a bronze boss
                cx = (px0 + px1) * 0.5
                paint(b, P_WALL, 0.5)
                if outer:
                    paint(b, P_MARBLE, 0.5)
                    for (u0, u1, v0, v1) in ((cx - 0.55, cx + 0.55, 1.45, 1.55), (cx - 0.55, cx + 0.55, 3.35, 3.45),
                                             (cx - 0.55, cx - 0.45, 1.55, 3.35), (cx + 0.45, cx + 0.55, 1.55, 3.35)):
                        box(b, (u0, v0, min(Z, Z + s * 0.08)), (u1, v1, max(Z, Z + s * 0.08)), skip=(back,))
                    paint(b, P_RED, 0.5)
                    b.poly([(cx - 0.45, 1.55, Z + s * 0.045), (cx + 0.45, 1.55, Z + s * 0.045), (cx + 0.45, 3.35, Z + s * 0.045), (cx - 0.45, 3.35, Z + s * 0.045)], nz)
                    paint(b, P_BRONZE, 0.5)
                    plate(b, disc_pts(cx, 2.45, 0.24, 10), Z + s * 0.045, Z + s * 0.11)
                    paint(b, P_GOLD, 0.5)
                    plate(b, disc_pts(cx, 2.45, 0.09, 6), Z + s * 0.11, Z + s * 0.13)
                    # bronze bands across the shield
                    paint(b, P_BRONZE, 0.45)
                    for vy in (1.85, 3.05):
                        box(b, (cx - 0.45, vy - 0.035, min(Z + s * 0.045, Z + s * 0.075)), (cx + 0.45, vy + 0.035, max(Z + s * 0.045, Z + s * 0.075)), skip=(back,))
                else:
                    # M2W1 item 2: the inner face gets the same pylon panel, simpler: a marble frame round a
                    # sunk travertine field and one bronze roundel with a gold boss
                    paint(b, P_MARBLE, 0.47)
                    for (u0, u1, v0, v1) in ((cx - 0.55, cx + 0.55, 1.45, 1.55), (cx - 0.55, cx + 0.55, 3.35, 3.45),
                                             (cx - 0.55, cx - 0.45, 1.55, 3.35), (cx + 0.45, cx + 0.55, 1.55, 3.35)):
                        box(b, (u0, v0, min(Z, Z + s * 0.08)), (u1, v1, max(Z, Z + s * 0.08)), skip=(back,))
                    paint(b, P_SHADE, 0.44)
                    b.poly([(cx - 0.45, 1.55, Z + s * 0.045), (cx + 0.45, 1.55, Z + s * 0.045), (cx + 0.45, 3.35, Z + s * 0.045), (cx - 0.45, 3.35, Z + s * 0.045)], nz)
                    paint(b, P_BRONZE, 0.5)
                    plate(b, disc_pts(cx, 2.45, 0.27, 10), Z + s * 0.045, Z + s * 0.1)
                    paint(b, P_GOLD, 0.5)
                    plate(b, disc_pts(cx, 2.45, 0.1, 6), Z + s * 0.1, Z + s * 0.125)
            # portal frame: two jamb bands and the lintel band (marble), corner brackets in the opening
            paint(b, P_MARBLE, 0.5)
            fw = 0.32
            for (u0, u1) in ((ox0 - fw, ox0), (ox1, ox1 + fw)):
                box(b, (u0, 0.6, min(Z, Z + s * 0.08)), (u1, lint0, max(Z, Z + s * 0.08)), chamfer=0.025, skip=(back, "-y", "+y"))
            box(b, (ox0 - fw - 0.04, lint0, min(Z, Z + s * 0.09)), (ox1 + fw + 0.04, lint1, max(Z, Z + s * 0.09)), chamfer=0.025, skip=(back,))
            # (0.07 into the opening: tests/test_world_kit.gd casts rays 0.08 inside the open volume's skin)
            for (u0, u1) in ((ox0, ox0 + 0.07), (ox1 - 0.07, ox1)):
                z_a, z_b = Z - s * 0.4, Z + s * 0.05
                box(b, (u0, py1 - 0.32, min(z_a, z_b)), (u1, py1, max(z_a, z_b)), chamfer=0.02, skip=(back,))
            # flat arch: voussoirs splaying from a point under the opening, keystone proud and taller
            n = 9
            apex = lint1 - 2.6
            k = (vou1 - apex) / (lint1 - apex)
            half = ox1 + fw
            for i in range(n):
                xa = -half + 2 * half * i / n
                xb = -half + 2 * half * (i + 1) / n
                g = 0.012
                key = i == n // 2
                top = vou1 + (0.12 if key else 0.0)
                kk = (top - apex) / (lint1 - apex)
                pts = [(xa + g, lint1), (xb - g, lint1), ((xb - g) * kk, top), ((xa + g) * kk, top)]
                if key:
                    paint(b, P_MARBLE, 0.5)
                else:
                    paint(b, P_MARBLE, 0.5 if outer else 0.42, 0.06)
                plate(b, pts, Z, Z + s * (0.09 if key else 0.05))
            # attic face: from the lintel band to the cornice, with the tablet (outer) or a plain panel (inner)
            paint(b, P_WALL, 0.5, 0.04)
            holes = [{"u0": -1.75, "u1": 1.75, "v0": tab0, "v1": tab1, "depth": 0.07,
                      "back": P_RED[0] if outer else P_SHADE[0], "surface": P_RED[1] if outer else None, "shade": 0.48}]
            face(b, nzs, F, X0, X1, py1, cor0, holes)
            if outer:
                # gold letter bars on the tablet, two rows, seeded widths
                paint(b, P_GOLD, 0.5)
                rh = (tab1 - tab0) / (LETTER_ROWS * 2 + 1)
                for row in range(LETTER_ROWS):
                    vy0 = tab1 - rh * (1 + 2 * row) - rh * 0.9
                    vy1 = vy0 + rh * 0.9
                    xcur = -1.5
                    while True:
                        wdt = b.rng.choice((0.09, 0.12, 0.16, 0.2))
                        if xcur + wdt > 1.5:
                            break
                        box(b, (xcur, vy0, min(Z + s * -0.05, Z + s * -0.02)), (xcur + wdt, vy1, max(Z + s * -0.05, Z + s * -0.02)), skip=(back,))
                        xcur += wdt + b.rng.choice((0.05, 0.05, 0.12))
                # bronze eagle roundels on the attic over the pylons
                for cx in (X0 + 0.8, X1 - 0.8):
                    cy = (lint1 + cor0) * 0.5 + 0.05
                    paint(b, P_BRONZE, 0.5)
                    plate(b, disc_pts(cx, cy, 0.36, 12), F, F + s * 0.05)
                    paint(b, P_GOLD, 0.5)
                    plate(b, disc_pts(cx, cy, 0.2, 8, math.pi / 8), F + s * 0.05, F + s * 0.09)
                    paint(b, P_BRONZE, 0.55)
                    for sx in (-1, 1):
                        wing = [(cx + sx * 0.3, cy - 0.06), (cx + sx * 0.72, cy + 0.16), (cx + sx * 0.66, cy + 0.26), (cx + sx * 0.3, cy + 0.1)]
                        plate(b, wing, F, F + s * 0.06)
            # energy strip under the lintel (in the opening, near this face; away from the leaves)
            paint(b, P_GLOW, 0.5)
            z_a, z_b = Z - s * 0.75, Z - s * 0.6
            box(b, (ox0, py1 - 0.03, min(z_a, z_b)), (ox1, py1, max(z_a, z_b)), skip=("+y",))
            # cornice
            paint(b, P_MARBLE, 0.5)
            prism(b, "x", [(cor0, Z), (cor0 + 0.1, Z + s * 0.1), (cor1 - 0.06, Z + s * 0.12), (cor1, Z + s * 0.12), (cor1, Z)], X0, X1,
                  skip=(back,), caps=(True, True))
        else:
            paint(b, P_WALL, 0.5)
            for (px0, px1) in ((X0, ox0), (ox1, X1)):
                b.poly([(px0, 0, F), (px1, 0, F), (px1, py1, F), (px0, py1, F)], nz)
                paint(b, P_BASE, 0.5)
                box(b, (px0, 0.0, min(Z, Z + s * 0.1)), (px1, 0.6, max(Z, Z + s * 0.1)), skip=(back, "-y", "-x", "+x"))
                paint(b, P_WALL, 0.5)
                if outer:
                    paint(b, P_RED, 0.5)
                    cx = (px0 + px1) * 0.5
                    b.poly([(cx - 0.45, 1.55, F + s * 0.01), (cx + 0.45, 1.55, F + s * 0.01), (cx + 0.45, 3.35, F + s * 0.01), (cx - 0.45, 3.35, F + s * 0.01)], nz)
                    paint(b, P_WALL, 0.5)
            paint(b, P_MARBLE, 0.5)
            box(b, (ox0 - 0.36, lint0, min(Z, Z + s * 0.09)), (ox1 + 0.36, vou1, max(Z, Z + s * 0.09)), skip=(back, "-x", "+x"))
            paint(b, P_WALL, 0.5)
            b.poly([(X0, lint0, F), (X1, lint0, F), (X1, cor0, F), (X0, cor0, F)], nz)
            if outer:
                paint(b, P_RED, 0.5)
                b.poly([(-1.75, tab0, F + s * 0.01), (1.75, tab0, F + s * 0.01), (1.75, tab1, F + s * 0.01), (-1.75, tab1, F + s * 0.01)], nz)
                paint(b, P_BRONZE, 0.5)
                for cx in (X0 + 0.8, X1 - 0.8):
                    b.poly([(p[0], p[1], F + s * 0.01) for p in disc_pts(cx, (lint1 + cor0) * 0.5 + 0.05, 0.36, 6)], nz)
            paint(b, P_MARBLE, 0.5)
            box(b, (X0, cor0, min(Z, Z + s * 0.12)), (X1, cor1, max(Z, Z + s * 0.12)), skip=(back, "+y"))
    # jambs (the opening's sides) with the pocket slots, the soffit with a bronze coffer
    paint(b, P_WALL, 0.5, 0.05 if near else 0.0)
    for side, xw in ((1, ox0), (-1, ox1)):
        nrm = "+x" if side > 0 else "-x"
        holes = [{"u0": -slot, "u1": slot, "v0": 0.0, "v1": py1 - 0.001, "depth": 0.12, "back": P_SLIT[0], "surface": P_SLIT[1]}] if near else []
        face(b, nrm, xw, zo, zi, 0.0, py1, holes)
        if not near:
            paint(b, P_SLIT, 0.5)
            b.poly([(xw + side * 0.005, 0.0, -slot), (xw + side * 0.005, 0.0, slot), (xw + side * 0.005, py1, slot), (xw + side * 0.005, py1, -slot)], (side, 0, 0))
            paint(b, P_WALL, 0.5)
    paint(b, P_WALL, 0.48)
    holes = [{"u0": ox0 + 0.35, "u1": ox1 - 0.35, "v0": -0.75, "v1": -0.3, "depth": 0.1, "back": P_BRONZE[0], "shade": 0.4},
             ] if near else []
    if near:
        # two coffers either side of the leaves' line (face() wants holes apart in u: split the soffit in z)
        face(b, "-y", py1, ox0, ox1, zo, -slot - 0.1, [{"u0": ox0 + 0.35, "u1": ox1 - 0.35, "v0": zo + 0.3, "v1": -slot - 0.35, "depth": 0.1, "back": P_BRONZE[0], "shade": 0.4}])
        face(b, "-y", py1, ox0, ox1, -slot - 0.1, slot + 0.1)
        face(b, "-y", py1, ox0, ox1, slot + 0.1, zi, [{"u0": ox0 + 0.35, "u1": ox1 - 0.35, "v0": slot + 0.35, "v1": zi - 0.3, "depth": 0.1, "back": P_BRONZE[0], "shade": 0.4}])
    else:
        face(b, "-y", py1, ox0, ox1, zo, zi)
    # guard stones at the opening's corners (near both faces, clear of the leaves)
    if near:
        paint(b, P_BASE, 0.55)
        for gx in (ox0 - 0.05, ox1 - 0.07):
            for gz in (zo + 0.08, zi - 0.38):
                box(b, (gx, 0.0, gz), (gx + 0.12, 0.62, gz + 0.3), chamfer=0.03, skip=("-y",))
    # the ends (x = X0 / X1: above the walls beside the gate) and the top
    paint(b, P_WALL, 0.5)
    for x, sx in ((X0, -1), (X1, 1)):
        b.poly([(x, 0.0, zo), (x, 0.0, zi), (x, crenel, zi), (x, crenel, zo)], (sx, 0, 0))
    if near:
        parapet_run(b, "x", zo - 0.02, zi + 0.02, segs, cor1, cor1, crenel, ay1, near)
        paint(b, P_MARBLE, 0.5, 0.05)
        copings(b, "x", zo - 0.02, zi + 0.02, segs, crenel, ay1, near, overhang=0.04, cap_h=0.12)
        paint(b, P_WALL, 0.5)
        b.poly([(X0, crenel, zo), (X1, crenel, zo), (X1, crenel, zi), (X0, crenel, zi)], (0, 1, 0))
    else:
        b.poly([(X0, crenel, zo), (X1, crenel, zo), (X1, crenel, zi), (X0, crenel, zi)], (0, 1, 0))
        paint(b, P_MARBLE, 0.5)
        for (a, c, kd) in segs:
            if kd == "merlon":
                box(b, (a, crenel, zo - 0.02), (c, ay1 + 0.1, zi + 0.02), skip=("-y",))


def build_watchtower(b, data, level):
    """A square tower with a ramp: plinth, rusticated courses, quoins at the corners, arrow loops, a marble belt
    course under the deck, a crenellated parapet with corner posts and coping, the beacon mast with a bronze
    housing round an energy core; the ramp as steps with side kerbs; the landing dressed like the tower."""
    cols = data.colliders("watchtower")
    (bx0, _, bz0), (bx1, deck, bz1) = bounds(cols[0])
    ptop = bounds(cols[1])[1][1]
    pin = bounds(cols[1])[1][2]           # inner face of the -z parapet (-1.9)
    pinx = bounds(cols[3])[1][0]          # inner face of the -x parapet (-1.9)
    e_z0, e_z1 = bounds(cols[4])[0][2], bounds(cols[4])[1][2]   # +x parapet z range (-1.9 .. 0.2)
    s_x1 = bounds(cols[2])[1][0]          # +z parapet ends at x 1.9
    ramp = [c for c in cols if c.get("shape") == "wedge"][0]
    xr, zr, ry0, ry1, (raxis, rsg) = wedge_ramp(ramp)
    (lx0, _, lz0), (lx1, ly1, lz1) = bounds(cols[6])
    (mx0, my0, mz0), (mx1, my1, mz1) = bounds(cols[7])
    near = level == 0
    crenel = ptop - 0.15
    belt0, belt1 = 3.5, deck - 0.12
    po = 0.1

    # body faces: N (-z), S (+z), W (-x); E (+x) hidden by the ramp and landing but for the top
    if near:
        for (fn, axis, w, sgn, a0, a1) in (("N", "x", bz0, -1, bx0, bx1), ("S", "x", bz1, 1, bx0, lx1), ("W", "z", bx0, -1, bz0, bz1),
                                           ("LE", "z", lx1, 1, lz0, lz1)):
            back = ("+" if sgn < 0 else "-") + ("z" if axis == "x" else "x")
            paint(b, P_BASE, 0.5)
            if axis == "x":
                prism(b, "x", [(0.0, w), (0.0, w + sgn * po), (0.42, w + sgn * po), (0.5, w + sgn * 0.03), (0.5, w)], a0 - (po if fn != "S" else po), a1 + po,
                      skip=("-y", back), caps=(False, False))
            else:
                prism(b, "z", [(w, 0.0), (w + sgn * po, 0.0), (w + sgn * po, 0.42), (w + sgn * 0.03, 0.5), (w, 0.5)], a0, a1,
                      skip=("-y", back), caps=(False, False))
            rows = [(0.5 + 0.5 * i, 1.0 + 0.5 * i) for i in range(6)]
            for i, (ya, yb) in enumerate(rows):
                paint(b, P_WALL, 0.5, 0.08)
                pts = [(ya, w + sgn * 0.03)] if i == 0 else [(ya, w), (ya + 0.03, w + sgn * 0.03)]
                pts += [(yb - 0.03, w + sgn * 0.03), (yb, w)]
                # solid on the left: walk up for a face looking -v, down for +v (x prisms: v = z; z prisms: (u, v) = (x, y))
                if axis == "x":
                    if sgn > 0:
                        pts = list(reversed(pts))
                    strip(b, "x", pts, a0, a1)
                else:
                    pts2 = [(p[1], p[0]) for p in pts]   # (x, y)
                    if sgn < 0:
                        pts2 = list(reversed(pts2))
                    strip(b, "z", pts2, a0, a1)
            paint(b, P_MARBLE, 0.5)
            if axis == "x":
                # the N belt stops at the ramp's side (nothing may hang over the ramp's walk)
                prism(b, "x", [(belt0, w), (belt0 + 0.08, w + sgn * po), (belt1, w + sgn * po), (belt1, w)], a0 - po, a1 + (0.0 if fn == "N" else po), skip=(back,), caps=(True, True))
            else:
                prism(b, "z", [(w, belt0), (w + sgn * po, belt0 + 0.08), (w + sgn * po, belt1), (w, belt1)], a0, a1, skip=(back,), caps=(False, False))
            # the band between the belt course and the deck edge
            paint(b, P_WALL, 0.5)
            if axis == "x":
                b.poly([(a0, belt1, w + sgn * 0.02), (a1, belt1, w + sgn * 0.02), (a1, deck, w + sgn * 0.02), (a0, deck, w + sgn * 0.02)], (0, 0, sgn))
            else:
                b.poly([(w + sgn * 0.02, belt1, a0), (w + sgn * 0.02, belt1, a1), (w + sgn * 0.02, deck, a1), (w + sgn * 0.02, deck, a0)], (sgn, 0, 0))
        # E face of the tower above the ramp
        paint(b, P_WALL, 0.5)
        b.poly([(bx1, 0.0, bz0), (bx1, 0.0, bz1), (bx1, deck, bz1), (bx1, deck, bz0)], (1, 0, 0))
        # quoins: alternating long and short blocks at the free corners, proud of the courses
        for (cx, cz, sx, sz) in ((bx0, bz0, -1, -1), (bx0, bz1, -1, 1), (bx1, bz0, 1, -1), (lx1, lz1, 1, 1)):
            for i in range(6):
                ya, yb = 0.5 + 0.5 * i, 1.0 + 0.5 * i
                la, lb = (0.7, 0.4) if i % 2 == 0 else (0.4, 0.7)
                # M2W1 item 2: 0.085 proud of the collider (0.055 over the courses) with a chamfer, in the darker
                # travertine so the corner reads from across the field
                paint(b, P_SHADE, 0.56, 0.05)
                qp = 0.085
                x_in, z_in = cx - sx * la, cz - sz * lb
                mn = (min(cx + sx * qp, x_in), ya + 0.012, min(cz + sz * qp, z_in))
                mx = (max(cx + sx * qp, x_in), yb - 0.012, max(cz + sz * qp, z_in))
                skip = ("-y",)
                if (cx, cz) == (bx1, bz0):
                    # beside the ramp: flush on the ramp's side
                    mx = (cx, mx[1], mx[2])
                    skip = ("-y", "+x")
                box(b, mn, mx, chamfer=0.02, skip=skip)
        # arrow loops on N, W and S: a marble frame with a dark slit
        for (axis, w, sgn, cu) in (("x", bz0, -1, 0.0), ("z", bx0, -1, 0.0), ("x", bz1, 1, -0.8)):
            paint(b, P_MARBLE, 0.5)
            if axis == "x":
                box(b, (cu - 0.22, 1.45, min(w, w + sgn * 0.07)), (cu + 0.22, 2.75, max(w, w + sgn * 0.07)), chamfer=0.02, skip=(("+z" if sgn < 0 else "-z"),))
                paint(b, P_SLIT, 0.5)
                b.poly([(cu - 0.06, 1.6, w + sgn * 0.075), (cu + 0.06, 1.6, w + sgn * 0.075), (cu + 0.06, 2.6, w + sgn * 0.075), (cu - 0.06, 2.6, w + sgn * 0.075)], (0, 0, sgn))
            else:
                box(b, (min(w, w + sgn * 0.07), 1.45, cu - 0.22), (max(w, w + sgn * 0.07), 2.75, cu + 0.22), chamfer=0.02, skip=(("+x" if sgn < 0 else "-x"),))
                paint(b, P_SLIT, 0.5)
                b.poly([(w + sgn * 0.075, 1.6, cu - 0.06), (w + sgn * 0.075, 1.6, cu + 0.06), (w + sgn * 0.075, 2.6, cu + 0.06), (w + sgn * 0.075, 2.6, cu - 0.06)], (sgn, 0, 0))
    else:
        paint(b, P_WALL, 0.5)
        b.poly([(bx0, 0, bz0 - 0.03), (bx1, 0, bz0 - 0.03), (bx1, deck, bz0 - 0.03), (bx0, deck, bz0 - 0.03)], (0, 0, -1))
        b.poly([(bx0, 0, bz1 + 0.03), (lx1, 0, bz1 + 0.03), (lx1, deck, bz1 + 0.03), (bx0, deck, bz1 + 0.03)], (0, 0, 1))
        b.poly([(bx0 - 0.03, 0, bz0), (bx0 - 0.03, 0, bz1), (bx0 - 0.03, deck, bz1), (bx0 - 0.03, deck, bz0)], (-1, 0, 0))
        b.poly([(lx1 + 0.03, 0, lz0), (lx1 + 0.03, 0, lz1), (lx1 + 0.03, deck, lz1), (lx1 + 0.03, deck, lz0)], (1, 0, 0))
        b.poly([(bx1, 2.6, bz0), (bx1, 2.6, lz0), (bx1, deck, lz0), (bx1, deck, bz0)], (1, 0, 0))
        paint(b, P_MARBLE, 0.5)
        b.poly([(bx0 - po, belt0, bz0 - po), (bx1, belt0, bz0 - po), (bx1, belt1, bz0 - po), (bx0 - po, belt1, bz0 - po)], (0, 0, -1))
        b.poly([(bx0 - po, belt0, bz1 + po), (lx1 + po, belt0, bz1 + po), (lx1 + po, belt1, bz1 + po), (bx0 - po, belt1, bz1 + po)], (0, 0, 1))
        b.poly([(bx0 - po, belt0, bz0 - po), (bx0 - po, belt0, bz1 + po), (bx0 - po, belt1, bz1 + po), (bx0 - po, belt1, bz0 - po)], (-1, 0, 0))
        b.poly([(lx1 + po, belt0, lz0), (lx1 + po, belt0, bz1 + po), (lx1 + po, belt1, bz1 + po), (lx1 + po, belt1, lz0)], (1, 0, 0))
    # deck and landing tops
    paint(b, P_WALK, 0.5, 0.05 if near else 0.0)
    if near:
        n = 4
        for i in range(n):
            za = pin + (-pin - pin) * i / n
            zb = pin + (-pin - pin) * (i + 1) / n
            g = 0.02
            b.poly([(pinx, deck, za + g), (-pinx, deck, za + g), (-pinx, deck, zb - g), (pinx, deck, zb - g)], (0, 1, 0))
            b.poly([(pinx, deck - g, za), (-pinx, deck - g, za), (-pinx, deck, za + g), (pinx, deck, za + g)], (0, 1, -1))
            b.poly([(pinx, deck, zb - g), (-pinx, deck, zb - g), (-pinx, deck - g, zb), (pinx, deck - g, zb)], (0, 1, 1))
        b.poly([(-pinx, deck, e_z1), (lx1, deck, lz0), (lx1, deck, lz1), (-pinx, deck, lz1)], (0, 1, 0))
    else:
        b.poly([(pinx, deck, pin), (-pinx, deck, pin), (-pinx, deck, -pin), (pinx, deck, -pin)], (0, 1, 0))
        b.poly([(-pinx, deck, e_z1), (lx1, deck, lz0), (lx1, deck, lz1), (-pinx, deck, lz1)], (0, 1, 0))
    # parapets: corner posts, a merlon in the middle of each side, crenels between
    paint(b, P_WALL, 0.5, 0.04 if near else 0.0)
    runs = [
        ("x", bz0 - 0.02, pin, [(bx0, bx0 + 0.6, "post"), (bx0 + 0.6, -0.5, "crenel"), (-0.5, 0.5, "merlon"), (0.5, bx1 - 0.6, "crenel"), (bx1 - 0.6, bx1, "post")], (True, True)),
        ("x", bz1 + 0.02, -pin, [(bx0, bx0 + 0.6, "post"), (bx0 + 0.6, -0.5, "crenel"), (-0.5, 0.5, "merlon"), (0.5, s_x1 - 0.5, "crenel"), (s_x1 - 0.5, s_x1, "post")], (True, True)),
        ("z", bx0 - 0.02, pinx, [(pin, pin + 0.3, "post"), (pin + 0.3, -0.5, "crenel"), (-0.5, 0.5, "merlon"), (0.5, -pin - 0.3, "crenel"), (-pin - 0.3, -pin, "post")], (False, False)),
        # the +x side stands over the ramp: flush with the collider, no overhang (nothing over the ramp's walk)
        ("z", bx1, -pinx, [(e_z0, e_z0 + 0.3, "post"), (e_z0 + 0.3, e_z1 - 0.5, "crenel"), (e_z1 - 0.5, e_z1, "post")], (False, True)),
    ]
    for axis, out_w, in_w, segs, ends in runs:
        paint(b, P_WALL, 0.5, 0.04 if near else 0.0)
        if near:
            parapet_run(b, axis, out_w, in_w, segs, deck, deck, crenel, ptop, near, ends=ends)
            paint(b, P_MARBLE, 0.5, 0.05)
            copings(b, axis, out_w, in_w, segs, crenel, ptop, near, overhang=0.0 if out_w == bx1 else 0.05, cap_h=0.13, along=False)
        else:
            so = 1 if out_w > in_w else -1
            a0, a1 = segs[0][0], segs[-1][1]
            if axis == "x":
                b.poly([(a0, deck, out_w), (a1, deck, out_w), (a1, crenel, out_w), (a0, crenel, out_w)], (0, 0, so))
                b.poly([(a0, deck, in_w), (a1, deck, in_w), (a1, crenel, in_w), (a0, crenel, in_w)], (0, 0, -so))
                b.poly([(a0, crenel, out_w), (a1, crenel, out_w), (a1, crenel, in_w), (a0, crenel, in_w)], (0, 1, 0))
            else:
                b.poly([(out_w, deck, a0), (out_w, deck, a1), (out_w, crenel, a1), (out_w, crenel, a0)], (so, 0, 0))
                b.poly([(in_w, deck, a0), (in_w, deck, a1), (in_w, crenel, a1), (in_w, crenel, a0)], (-so, 0, 0))
                b.poly([(out_w, crenel, a0), (out_w, crenel, a1), (in_w, crenel, a1), (in_w, crenel, a0)], (0, 1, 0))
            paint(b, P_MARBLE, 0.5)
            for (a, c, kd) in segs:
                # far: the corner posts of the z runs are left to the x runs' posts beside them
                if kd != "crenel" and not (axis == "z" and kd == "post" and (out_w < 0 or abs(a - e_z0) < 1e-6)):
                    lo_w, hi_w = min(out_w, in_w), max(out_w, in_w)
                    mn = (a, crenel, lo_w) if axis == "x" else (lo_w, crenel, a)
                    mx = (c, ptop + 0.1, hi_w) if axis == "x" else (hi_w, ptop + 0.1, c)
                    box(b, mn, mx, skip=("-y",))
    # beacon mast with a bronze housing round an energy core
    mcx, mcz = (mx0 + mx1) * 0.5, (mz0 + mz1) * 0.5
    mh = (mx1 - mx0) * 0.5
    hw = mh + 0.095
    top = my1 + 0.05
    paint(b, ("plate_dark", None), 0.5)
    box(b, (mx0 + 0.02, ptop + 0.1, mz0 + 0.02), (mx1 - 0.02, my1 - 0.75, mz1 - 0.02), chamfer=0.02 if near else 0.0, skip=("-y",))
    if near:
        paint(b, P_BRONZE, 0.5)
        box(b, (mcx - hw, my1 - 0.8, mcz - hw), (mcx + hw, my1 - 0.72, mcz + hw), chamfer=0.015)
        box(b, (mcx - hw, top - 0.06, mcz - hw), (mcx + hw, top, mcz + hw), chamfer=0.015)
        for sx in (-1, 1):
            for sz in (-1, 1):
                box(b, (mcx + sx * hw - (0.05 if sx > 0 else 0.0), my1 - 0.72, mcz + sz * hw - (0.05 if sz > 0 else 0.0)),
                    (mcx + sx * hw + (0.05 if sx < 0 else 0.0), top - 0.06, mcz + sz * hw + (0.05 if sz < 0 else 0.0)), skip=("-y", "+y"))
        paint(b, P_GLOW, 0.5)
        box(b, (mcx - mh - 0.03, my1 - 0.7, mcz - mh - 0.03), (mcx + mh + 0.03, top - 0.08, mcz + mh + 0.03), skip=("-y", "+y"))
        # a narrow legion-red pennant on the mast
        paint(b, P_RED, 0.5)
        b.poly([(mx1, my1 - 1.6, mcz - 0.01), (mx1 + 0.12, my1 - 1.55, mcz - 0.01), (mx1 + 0.12, my1 - 0.95, mcz - 0.01), (mx1, my1 - 0.9, mcz - 0.01)], (0, 0, -1))
        b.poly([(mx1, my1 - 1.6, mcz + 0.01), (mx1 + 0.12, my1 - 1.55, mcz + 0.01), (mx1 + 0.12, my1 - 0.95, mcz + 0.01), (mx1, my1 - 0.9, mcz + 0.01)], (0, 0, 1))
    else:
        paint(b, P_BRONZE, 0.5)
        box(b, (mcx - hw, my1 - 0.8, mcz - hw), (mcx + hw, top, mcz + hw), skip=("-y",))
        paint(b, P_GLOW, 0.5)
        box(b, (mcx - hw - 0.005, my1 - 0.7, mcz - 0.06), (mcx + hw + 0.005, top - 0.1, mcz + 0.06), skip=("-y", "+y"))
    # the ramp: steps rising along z, kerbs on both sides
    paints = {"tread": ("travertine", None), "riser": ("travertine_shade", None), "side": ("travertine_shade", None)}
    if near:
        count = 24
        steps(b, zr[0], zr[1], xr[0], xr[1], ry0, ry1, count, 0.03, paints,
              side_z=[(xr[1], 1, None, None), (xr[0], -1, zr[0], bz0)], nosing=0.025, along="z")
        last = ry0 + (ry1 - ry0) * (count - 1) / count + 0.03
        paint(b, P_SHADE, 0.5)
        b.poly([(xr[0], last, zr[1]), (xr[0], ry1, zr[1]), (xr[1], ry1, zr[1]), (xr[1], last, zr[1])], (0, 0, -1))
        k = (ry1 - ry0) / (zr[1] - zr[0])
        paint(b, P_MARBLE, 0.5)
        for (xa, xb, z_end) in ((xr[1], xr[1] + 0.08, zr[1]), (xr[0] - 0.08, xr[0], bz0)):
            y_end = ry0 + k * (z_end - zr[0])
            outer = xb if xa == xr[1] else xa
            sgn = 1 if xa == xr[1] else -1
            inner = xa if sgn > 0 else xb
            # top (sloped), the outer side and the side that faces the treads; it starts at the ground
            b.poly([(xa, ry0 + 0.08, zr[0]), (xb, ry0 + 0.08, zr[0]), (xb, y_end + 0.08, z_end), (xa, y_end + 0.08, z_end)], (0, 1, -k))
            b.poly([(outer, 0.0, zr[0]), (outer, ry0 + 0.08, zr[0]), (outer, y_end + 0.08, z_end), (outer, y_end - 0.3, z_end)], (sgn, 0, 0))
            b.poly([(inner, ry0 + 0.03, zr[0]), (inner, ry0 + 0.08, zr[0]), (inner, y_end + 0.08, z_end), (inner, y_end - 0.02, z_end)], (-sgn, 0, 0))
            b.poly([(xa, 0.0, zr[0]), (xb, 0.0, zr[0]), (xb, ry0 + 0.08, zr[0]), (xa, ry0 + 0.08, zr[0])], (0, 0, -1))
    else:
        paint(b, P_WALL, 0.5)
        n = 4
        prev = 0.0
        for kk in range(n):
            t0 = zr[0] + (zr[1] - zr[0]) * kk / n
            t1 = zr[0] + (zr[1] - zr[0]) * (kk + 1) / n
            top = ry0 + (ry1 - ry0) * kk / n + 0.03
            b.poly([(xr[0], top, t0), (xr[1], top, t0), (xr[1], top, t1), (xr[0], top, t1)], (0, 1, 0))
            b.poly([(xr[0], prev, t0), (xr[1], prev, t0), (xr[1], top, t0), (xr[0], top, t0)], (0, 0, -1))
            b.poly([(xr[1], 0, t0), (xr[1], 0, t1), (xr[1], top, t1), (xr[1], top, t0)], (1, 0, 0))
            if t0 < bz0:
                b.poly([(xr[0], 0, t0), (xr[0], 0, min(t1, bz0)), (xr[0], top, min(t1, bz0)), (xr[0], top, t0)], (-1, 0, 0))
            prev = top
        b.poly([(xr[0], prev, zr[1]), (xr[1], prev, zr[1]), (xr[1], ry1, zr[1]), (xr[0], ry1, zr[1])], (0, 0, -1))


# ---------------------------------------------------------------- item 2: helpers

def slab(b, pts, off, back=True, sides=True):
    """A planar polygon (3D points, any winding, may be concave) pushed out by the vector `off`: the front at
    pts + off (facing along off), the back at pts (when `back`), the rim between them (when `sides`)."""
    pts = [tuple(float(v) for v in p) for p in pts]
    n = norm(newell(pts))
    if dot(n, off) < 0:
        pts = pts[::-1]
        n = mul(n, -1)
    b.poly([add(p, off) for p in pts], off)
    if back:
        b.poly(pts, mul(off, -1))
    if sides:
        for i in range(len(pts)):
            p, q = pts[i], pts[(i + 1) % len(pts)]
            b.poly([p, q, add(q, off), add(p, off)], cross(sub(q, p), n))


def ring_pts(cx, cz, y, r, segs, phase=0.0, star=None):
    n = segs * 2 if star else segs
    out = []
    for i in range(n):
        a = phase + 2 * math.pi * i / n
        rr = r * (star if (star and i % 2 == 1) else 1.0)
        out.append((cx + rr * math.cos(a), y, cz + rr * math.sin(a)))
    return out


def lathe(b, cx, cz, rings, segs, phase=0.0, star=None, caps=(False, False)):
    """A turned shape round the vertical axis through (cx, cz): rings [(y, r)] from the bottom up (the same y
    twice makes a flat step), flat facets; star = every other vertex pulled in to this fraction (flutes)."""
    pr = [ring_pts(cx, cz, y, r, segs, phase, star) for (y, r) in rings]
    n = len(pr[0])
    for k in range(len(rings) - 1):
        (y0, r0), (y1, r1) = rings[k], rings[k + 1]
        dr, dy = r1 - r0, y1 - y0
        if abs(dr) < 1e-9 and abs(dy) < 1e-9:
            continue
        A, B = pr[k], pr[k + 1]
        for i in range(n):
            j = (i + 1) % n
            a = phase + 2 * math.pi * (i + 0.5) / n
            b.poly([A[i], A[j], B[j], B[i]], (math.cos(a) * dy, -dr, math.sin(a) * dy))
    if caps[0]:
        b.poly(pr[0], (0, -1, 0))
    if caps[1]:
        b.poly(pr[-1], (0, 1, 0))


def fpt(normal, w, u, v, d=0.0):
    """A point on the face (normal, plane w) at (u, v), d out of the face (FACE_FRAMES: +-z: u = x; +-x: u = z;
    +-y: u = x, v = z)."""
    sg = 1 if normal[0] == "+" else -1
    return _fp(normal, w + sg * d, u, v)


def fquad(b, normal, w, u0, u1, v0, v1, d=0.0):
    if u1 - u0 > 1e-6 and v1 - v0 > 1e-6:
        b.poly([fpt(normal, w, u0, v0, d), fpt(normal, w, u1, v0, d), fpt(normal, w, u1, v1, d), fpt(normal, w, u0, v1, d)], DIRS[normal])


def fbox(b, normal, w, u0, u1, v0, v1, d0, d1, chamfer=0.0, skip=()):
    """A box standing on a face: u0..u1, v0..v1, from d0 to d1 out of the face; its back is left out."""
    p0 = fpt(normal, w, u0, v0, d0)
    p1 = fpt(normal, w, u1, v1, d1)
    mn = tuple(min(p0[i], p1[i]) for i in range(3))
    mx = tuple(max(p0[i], p1[i]) for i in range(3))
    back = ("-" if normal[0] == "+" else "+") + normal[1]
    box(b, mn, mx, chamfer=chamfer, skip=tuple(skip) + (back,))


def fplate(b, normal, w, pts_uv, d0, d1):
    """A flat relief: the (u, v) polygon from d0 out to d1 (no back)."""
    slab(b, [fpt(normal, w, u, v, d0) for (u, v) in pts_uv], mul(DIRS[normal], d1 - d0), back=False)


def wall_rects(b, normal, w, u0, u1, v0, v1, openings, d=0.0):
    """The face rectangle minus through openings (u0, u1, v0, v1; apart in u) as plain rectangles."""
    cur = u0
    for (a0, a1, c0, c1) in sorted(openings):
        a0c, a1c = max(a0, u0), min(a1, u1)
        if a1c <= a0c + 1e-6:
            continue
        fquad(b, normal, w, cur, a0c, v0, v1, d)
        fquad(b, normal, w, a0c, a1c, v0, max(v0, min(c0, v1)), d)
        fquad(b, normal, w, a0c, a1c, min(v1, max(c1, v0)), v1, d)
        cur = a1c
    fquad(b, normal, w, cur, u1, v0, v1, d)


def band_run(b, normal, w, u0, u1, profile, ends=(0, 0), skip_last=False):
    """A moulding run along a face from u0 to u1: profile [(v, d)] walked from the face (d = 0) at the bottom,
    out and up, back to the face. ends: +1 = an outer corner (mitred: the run reaches d further), -1 = an inner
    corner (stops d short), 0 = a flat end cap. skip_last: the last segment (the top, often hidden) left out."""
    def U(e, d):
        return u0 - ends[0] * d if e == 0 else u1 + ends[1] * d
    nf = DIRS[normal]
    _, ua, _ = FACE_FRAMES[normal]
    udir = [0.0, 0.0, 0.0]
    udir[ua] = 1.0
    segs = len(profile) - 1 - (1 if skip_last else 0)
    for i in range(segs):
        (va, da), (vb, db) = profile[i], profile[i + 1]
        hint = add(mul((0, 1, 0), -(db - da)), mul(nf, vb - va))
        b.poly([fpt(normal, w, U(0, da), va, da), fpt(normal, w, U(1, da), va, da),
                fpt(normal, w, U(1, db), vb, db), fpt(normal, w, U(0, db), vb, db)], hint)
    for e, sg in ((0, -1), (1, 1)):
        if ends[e] == 0:
            b.poly([fpt(normal, w, U(e, d), v, d) for (v, d) in profile], mul(tuple(udir), sg))


def ring_run(b, hx, hz, profile, outer=True, skip_last=False, gaps=None):
    """band_run on the four faces of a rectangle (faces at x = +-hx, z = +-hz), mitred at the corners (outer
    corners when `outer`, else the inside of a room); gaps {face: [(u0, u1)]} leave openings (flat caps)."""
    gaps = gaps or {}
    s = 1 if outer else -1
    faces = [("-z" if outer else "+z", -hz, -hx, hx), ("+z" if outer else "-z", hz, -hx, hx),
             ("-x" if outer else "+x", -hx, -hz, hz), ("+x" if outer else "-x", hx, -hz, hz)]
    for (nm, w, a, c) in faces:
        cuts = sorted(gaps.get(nm, []))
        runs = []
        cur, e0 = a, s
        for (g0, g1) in cuts:
            runs.append((cur, g0, e0, 0))
            cur, e0 = g1, 0
        runs.append((cur, c, e0, s))
        for (r0, r1, ea, eb) in runs:
            if r1 - r0 > 1e-6:
                band_run(b, nm, w, r0, r1, profile, (ea, eb), skip_last)


# ---------------------------------------------------------------- item 2: the citadel order

def column_at(b, cx, cz, near):
    """A Roman Tuscan-Doric column on its collider (1 x 4.5 x 1): a square plinth, an attic base (torus and
    cove), a fluted shaft with entasis (10 flutes), an astragal, the echinus and a chamfered abacus."""
    if near:
        paint(b, P_MARBLE, 0.47, 0.03)
        box(b, (cx - 0.56, 0.0, cz - 0.56), (cx + 0.56, 0.2, cz + 0.56), chamfer=0.03, skip=("-y",))
        paint(b, P_MARBLE, 0.53)
        lathe(b, cx, cz, [(0.2, 0.5), (0.3, 0.52), (0.42, 0.45)], 10, caps=(False, True))
        paint(b, P_MARBLE, 0.5, 0.02)
        lathe(b, cx, cz, [(0.42, 0.41), (1.6, 0.415), (3.9, 0.35)], 10, star=0.86)
        paint(b, P_MARBLE, 0.56)
        lathe(b, cx, cz, [(3.9, 0.35), (3.9, 0.385), (3.97, 0.385)], 10)
        paint(b, P_MARBLE, 0.52)
        lathe(b, cx, cz, [(3.97, 0.385), (4.12, 0.47), (4.24, 0.53)], 10)
        paint(b, P_MARBLE, 0.5, 0.03)
        # (0.57: under the 0.08 skin of the bays' open volumes, tests/test_world_kit.gd)
        box(b, (cx - 0.57, 4.24, cz - 0.57), (cx + 0.57, 4.5, cz + 0.57), chamfer=0.025, skip=("+y",))
    else:
        paint(b, P_MARBLE, 0.48)
        box(b, (cx - 0.55, 0.0, cz - 0.55), (cx + 0.55, 0.42, cz + 0.55), skip=("-y",))
        paint(b, P_MARBLE, 0.5)
        lathe(b, cx, cz, [(0.42, 0.42), (4.0, 0.36)], 6)
        box(b, (cx - 0.56, 4.0, cz - 0.56), (cx + 0.56, 4.5, cz + 0.56), skip=("+y",))


def build_column(b, data, level):
    near = level == 0
    column_at(b, 0.0, 0.0, near)
    if near:
        # the top of the lone column (seen from the walls)
        paint(b, P_MARBLE, 0.5)
        b.poly([(-0.555, 4.5, -0.555), (0.555, 4.5, -0.555), (0.555, 4.5, 0.555), (-0.555, 4.5, 0.555)], (0, 1, 0))
    else:
        b.poly([(-0.56, 4.5, -0.56), (0.56, 4.5, -0.56), (0.56, 4.5, 0.56), (-0.56, 4.5, 0.56)], (0, 1, 0))


TRIGLYPH_X = (-4.5, -3.0, -1.5, 0.0, 1.5, 3.0, 4.5)


def entablature(b, near, X=5.0):
    """On the 10 x 0.9 x 1.2 collider (y 4.5 .. 5.4): an architrave of two fasciae and a taenia, a recessed
    frieze with bronze triglyphs over every column and every bay, a thin energy line at its foot, a cornice."""
    if near:
        paint(b, P_MARBLE, 0.5, 0.03)
        prof = [(4.5, -0.58), (4.5, 0.58), (4.68, 0.58), (4.68, 0.62), (4.86, 0.62), (4.86, 0.65), (4.92, 0.65),
                (4.92, -0.65), (4.86, -0.65), (4.86, -0.62), (4.68, -0.62), (4.68, -0.58)]
        prism(b, "x", prof, -X, X, skip=("+y",))
        paint(b, P_WALL, 0.5, 0.03)
        box(b, (-X, 4.92, -0.56), (X, 5.15, 0.56), skip=("-y", "+y"))
        paint(b, P_GLOW, 0.5)
        for s in (-1, 1):
            z0, z1 = sorted((s * 0.56, s * 0.575))
            box(b, (-X, 4.92, z0), (X, 4.945, z1), skip=("-y", "-z" if s > 0 else "+z"))
        for s in (-1, 1):
            nm = "+z" if s > 0 else "-z"
            for x in TRIGLYPH_X:
                paint(b, P_BRONZE, 0.5)
                fbox(b, nm, s * 0.56, x - 0.17, x + 0.17, 4.95, 5.15, 0.0, 0.04, skip=("+y",))
                paint(b, P_PLATE, 0.4)
                for gx in (x - 0.06, x + 0.06):
                    fquad(b, nm, s * 0.56, gx - 0.025, gx + 0.025, 4.98, 5.15, 0.041)
        paint(b, P_MARBLE, 0.52, 0.03)
        cprof = [(5.15, -0.6), (5.15, 0.6), (5.22, 0.66), (5.3, 0.7), (5.4, 0.7), (5.4, -0.7), (5.3, -0.7), (5.22, -0.66)]
        prism(b, "x", cprof, -X - 0.06, X + 0.06)
    else:
        paint(b, P_MARBLE, 0.5)
        box(b, (-X, 4.5, -0.62), (X, 5.4, 0.62))
        paint(b, P_GLOW, 0.5)
        for s in (-1, 1):
            b.poly([(-X, 4.92, s * 0.625), (X, 4.92, s * 0.625), (X, 4.95, s * 0.625), (-X, 4.95, s * 0.625)], (0, 0, s))


def build_colonnade(b, data, level):
    near = level == 0
    for cx in (-4.5, -1.5, 1.5, 4.5):
        column_at(b, cx, 0.0, near)
    entablature(b, near)


def pediment_y(x):
    return 5.4 + 1.6 * (1.0 - abs(x) / 5.0)


def build_pediment_front(b, data, level):
    """The colonnade with a gable on its wedge collider (y 5.4 .. 7.0): a raking cornice with a tiled top, the
    tympanum recessed between the cornices, a bronze winged wreath with a gold ring and an energy core on it."""
    near = level == 0
    for cx in (-4.5, -1.5, 1.5, 4.5):
        column_at(b, cx, 0.0, near)
    entablature(b, near)
    ex = 5.06
    up, down = 0.10, 0.20
    prof = [(-ex, pediment_y(ex) + up), (0.0, 7.0 + up), (ex, pediment_y(ex) + up), (ex, pediment_y(ex) - down),
            (0.0, 7.0 - down), (-ex, pediment_y(ex) - down)]
    zr = 0.68
    if near:
        paint(b, P_MARBLE, 0.52, 0.03)
        prism(b, "z", prof, -zr, zr, skip=("+y",))
        paint(b, P_ROOF, 0.5, 0.04)
        for sx in (-1, 1):
            b.poly([(sx * ex, pediment_y(ex) + up, -zr), (0.0, 7.0 + up, -zr), (0.0, 7.0 + up, zr), (sx * ex, pediment_y(ex) + up, zr)], (sx * 0.32, 1, 0))
        # tympanum: recessed 0.06 behind the collider face, framed by the cornices
        xb = 5.0 * (1.0 - down / 1.6)
        for s in (-1, 1):
            nm = "+z" if s > 0 else "-z"
            zt = s * 0.54
            paint(b, P_SHADE, 0.47, 0.03)
            b.poly([(-xb, 5.4, zt), (xb, 5.4, zt), (0.0, 7.0 - down, zt)], (0, 0, s))
            # the winged wreath (shallow relief, inside the collider)
            cx, cy, r0, r1 = 0.0, 5.92, 0.22, 0.31
            paint(b, P_GOLD, 0.5)
            n = 8
            for i in range(n):
                a0 = 2 * math.pi * i / n + math.pi / 8
                a1 = 2 * math.pi * (i + 1) / n + math.pi / 8 - 0.06
                pts = [(cx + r0 * math.cos(a0), cy + r0 * math.sin(a0)), (cx + r1 * math.cos(a0), cy + r1 * math.sin(a0)),
                       (cx + r1 * math.cos(a1), cy + r1 * math.sin(a1)), (cx + r0 * math.cos(a1), cy + r0 * math.sin(a1))]
                fplate(b, nm, zt, pts, 0.0, 0.05)
            paint(b, P_GLOW, 0.5)
            fplate(b, nm, zt, disc_pts(cx, cy, 0.09, 6, math.pi / 6), 0.0, 0.03)
            paint(b, P_BRONZE, 0.52)
            for sx in (-1, 1):
                wing = [(0.28, 5.84), (0.62, 5.76), (0.78, 5.86), (0.98, 5.8), (1.14, 5.92), (1.34, 5.9), (1.62, 6.12),
                        (1.0, 6.1), (0.29, 6.04)]
                fplate(b, nm, zt, [(sx * u, v) for (u, v) in wing], 0.0, 0.055)
            # the eagle's head and crest over the wreath
            fplate(b, nm, zt, [(-0.07, 6.22), (0.07, 6.22), (0.09, 6.36), (0.0, 6.44), (-0.09, 6.36)], 0.0, 0.05)
    else:
        paint(b, P_MARBLE, 0.5)
        prism(b, "z", prof, -zr, zr, skip=("+y", "-y"))
        paint(b, P_ROOF, 0.5)
        for sx in (-1, 1):
            b.poly([(sx * ex, pediment_y(ex) + up, -zr), (0.0, 7.0 + up, -zr), (0.0, 7.0 + up, zr), (sx * ex, pediment_y(ex) + up, zr)], (sx * 0.32, 1, 0))
        paint(b, P_SHADE, 0.47)
        xb = 5.0 * (1.0 - down / 1.6)
        for s in (-1, 1):
            b.poly([(-xb, 5.4, s * 0.58), (xb, 5.4, s * 0.58), (0.0, 7.0 - down, s * 0.58)], (0, 0, s))
        paint(b, P_BRONZE, 0.5)
        for s in (-1, 1):
            b.poly([(-1.5, 5.8, s * 0.6), (1.5, 5.8, s * 0.6), (1.5, 6.1, s * 0.6), (-1.5, 6.1, s * 0.6)], (0, 0, s))


# ---------------------------------------------------------------- item 2: the forum blocks

def build_terrace_block(b, data, level):
    """A 4 x 1.2 x 4 step block: a base course, ashlar sides, a marble nosing course round the top and paving."""
    near = level == 0
    if near:
        paint(b, P_BASE, 0.5)
        box(b, (-2.08, 0.0, -2.08), (2.08, 0.3, 2.08), chamfer=0.03, skip=("-y",))
        paint(b, P_WALL, 0.5, 0.05)
        box(b, (-2.0, 0.3, -2.0), (2.0, 1.04, 2.0), skip=("-y", "+y"))
        paint(b, P_GLOW, 0.5)
        box(b, (-2.012, 0.98, -2.012), (2.012, 1.0, 2.012), skip=("-y", "+y"))
        paint(b, P_MARBLE, 0.5, 0.03)
        box(b, (-2.07, 1.0, -2.07), (2.07, 1.2, 2.07), chamfer=0.025, skip=("-y", "+y"))
        for (x0, x1, z0, z1) in ((-2.07, 2.07, -2.07, -2.0), (-2.07, 2.07, 2.0, 2.07), (-2.07, -2.0, -2.0, 2.0), (2.0, 2.07, -2.0, 2.0)):
            b.poly([(x0, 1.2, z0), (x1, 1.2, z0), (x1, 1.2, z1), (x0, 1.2, z1)], (0, 1, 0))
        n = 4
        g = 0.02
        for k in range(n):
            za = -2.0 + 4.0 * k / n
            zb = -2.0 + 4.0 * (k + 1) / n
            paint(b, P_WALK, 0.5, 0.06)
            ga = g if k > 0 else 0.0
            gb = g if k < n - 1 else 0.0
            b.poly([(-2.0, 1.2, za + ga), (2.0, 1.2, za + ga), (2.0, 1.2, zb - gb), (-2.0, 1.2, zb - gb)], (0, 1, 0))
            if ga:
                b.poly([(-2.0, 1.2 - g, za), (2.0, 1.2 - g, za), (2.0, 1.2, za + ga), (-2.0, 1.2, za + ga)], (0, 1, -1))
            if gb:
                b.poly([(-2.0, 1.2, zb - gb), (2.0, 1.2, zb - gb), (2.0, 1.2 - g, zb), (-2.0, 1.2 - g, zb)], (0, 1, 1))
    else:
        paint(b, P_WALL, 0.5)
        box(b, (-2.0, 0.0, -2.0), (2.0, 1.2, 2.0), skip=("-y", "+y"))
        paint(b, P_WALK, 0.5)
        b.poly([(-2.0, 1.2, -2.0), (2.0, 1.2, -2.0), (2.0, 1.2, 2.0), (-2.0, 1.2, 2.0)], (0, 1, 0))
        paint(b, P_MARBLE, 0.5)
        for (nx, nz) in ((0, -1), (0, 1), (-1, 0), (1, 0)):
            w = 2.04
            if nz:
                b.poly([(-w, 1.0, nz * w), (w, 1.0, nz * w), (w, 1.2, nz * w), (-w, 1.2, nz * w)], (0, 0, nz))
            else:
                b.poly([(nx * w, 1.0, -w), (nx * w, 1.0, w), (nx * w, 1.2, w), (nx * w, 1.2, -w)], (nx, 0, 0))


def build_ramp_block(b, data, level):
    """The 3 x 1.2 x 4 ramp wedge (rising to +z): three paving slabs on the slope, marble kerbs on the side
    edges, a base course on the sides and a marble nosing at the top. No far mesh (60 triangles)."""
    xr, zr, y0, y1, _ = wedge_ramp(data.colliders("ramp_block")[0])
    hx = xr[1]
    k = (y1 - y0) / (zr[1] - zr[0])
    Y = lambda z: y0 + k * (z - zr[0])
    nz, ny = -k, 1.0
    n = 3
    g = 0.025
    for i in range(n):
        za = zr[0] + (zr[1] - zr[0]) * i / n
        zb = zr[0] + (zr[1] - zr[0]) * (i + 1) / n
        paint(b, P_WALK, 0.5, 0.06)
        ga = g if i > 0 else 0.0
        b.poly([(-hx, Y(za + ga), za + ga), (hx, Y(za + ga), za + ga), (hx, Y(zb), zb), (-hx, Y(zb), zb)], (0, ny, nz))
        if ga:
            b.poly([(-hx, Y(za) - g, za), (hx, Y(za) - g, za), (hx, Y(za + ga), za + ga), (-hx, Y(za + ga), za + ga)], (0, 1, -1))
    paint(b, P_WALL, 0.5)
    for s in (-1, 1):
        b.poly([(s * hx, 0.0, zr[0]), (s * hx, 0.0, zr[1]), (s * hx, y1, zr[1])], (s, 0, 0))
    b.poly([(-hx, 0.0, zr[1]), (hx, 0.0, zr[1]), (hx, y1, zr[1]), (-hx, y1, zr[1])], (0, 0, 1))
    paint(b, P_BASE, 0.5)
    for s in (-1, 1):
        b.poly([(s * (hx + 0.05), 0.0, zr[0] + 0.75), (s * (hx + 0.05), 0.0, zr[1]), (s * (hx + 0.05), 0.2, zr[1]), (s * (hx + 0.05), 0.2, zr[0] + 1.25)], (s, 0, 0))
        b.poly([(s * hx, 0.2, zr[0] + 1.25), (s * hx, 0.2, zr[1]), (s * (hx + 0.05), 0.2, zr[1]), (s * (hx + 0.05), 0.2, zr[0] + 1.25)], (0, 1, 0))
        b.poly([(s * hx, 0.0, zr[0] + 0.75), (s * hx, 0.2, zr[0] + 1.25), (s * (hx + 0.05), 0.2, zr[0] + 1.25), (s * (hx + 0.05), 0.0, zr[0] + 0.75)], (0, 0.5, -0.8))
    paint(b, P_MARBLE, 0.5)
    for s in (-1, 1):
        xa, xb = (hx - 0.02, hx + 0.06) if s > 0 else (-hx - 0.06, -hx + 0.02)
        xo = xb if s > 0 else xa
        b.poly([(xa, Y(zr[0]) + 0.04, zr[0]), (xb, Y(zr[0]) + 0.04, zr[0]), (xb, Y(zr[1]) + 0.04, zr[1]), (xa, Y(zr[1]) + 0.04, zr[1])], (0, ny, nz))
        b.poly([(xo, Y(zr[0]) - 0.1, zr[0]), (xo, Y(zr[1]) - 0.1, zr[1]), (xo, Y(zr[1]) + 0.04, zr[1]), (xo, Y(zr[0]) + 0.04, zr[0])], (s, 0, 0))
    b.poly([(-hx - 0.06, y1 - 0.1, zr[1] + 0.06), (hx + 0.06, y1 - 0.1, zr[1] + 0.06), (hx + 0.06, y1 + 0.0, zr[1] + 0.06), (-hx - 0.06, y1 + 0.0, zr[1] + 0.06)], (0, 0, 1))
    b.poly([(-hx - 0.06, y1, zr[1]), (hx + 0.06, y1, zr[1]), (hx + 0.06, y1, zr[1] + 0.06), (-hx - 0.06, y1, zr[1] + 0.06)], (0, 1, 0))


# ---------------------------------------------------------------- item 2: the eagle standard

def build_eagle_standard(b, data, level):
    """The aquila on its plinth (1.6 box to y 1.2) and pole (0.3 box to y 6.8): everything over the plinth stays
    within 0.15 m of the 0.3 m pole box, so the vexillum, the wreath and the eagle (wings raised in a V) are
    narrow; a stepped marble plinth with red panels and an energy line under its cornice."""
    near = level == 0
    if near:
        paint(b, P_MARBLE, 0.42, 0.03)
        box(b, (-0.9, 0.0, -0.9), (0.9, 0.22, 0.9), chamfer=0.03, skip=("-y",))
        for nm, w in (("-z", -0.8), ("+z", 0.8)):
            paint(b, P_MARBLE, 0.5, 0.03)
            face(b, nm, w, -0.8, 0.8, 0.22, 0.95, [{"u0": -0.55, "u1": 0.55, "v0": 0.34, "v1": 0.83, "depth": 0.04,
                                                    "back": P_RED[0], "surface": P_RED[1], "walls": "marble"}])
        for nm, w in (("-x", -0.8), ("+x", 0.8)):
            paint(b, P_MARBLE, 0.5, 0.03)
            fquad(b, nm, w, -0.8, 0.8, 0.22, 0.95)
            paint(b, P_RED, 0.5)
            fquad(b, nm, w, -0.55, 0.55, 0.34, 0.83, 0.006)
        paint(b, P_GLOW, 0.5)
        box(b, (-0.815, 0.95, -0.815), (0.815, 0.98, 0.815), skip=("-y", "+y"))
        paint(b, P_MARBLE, 0.55, 0.03)
        box(b, (-0.9, 0.98, -0.9), (0.9, 1.2, 0.9), chamfer=0.03, skip=("-y",))
        paint(b, P_MARBLE, 0.48)
        box(b, (-0.36, 1.2, -0.36), (0.36, 1.32, 0.36), chamfer=0.02, skip=("-y",))
        paint(b, P_BRONZE, 0.5)
        lathe(b, 0.0, 0.0, [(1.32, 0.065), (6.3, 0.065)], 8)
        paint(b, P_BRONZE, 0.6)
        for y in (2.4, 3.7):
            lathe(b, 0.0, 0.0, [(y, 0.088), (y + 0.07, 0.088), (y + 0.09, 0.065)], 6)
        # crossbar with gold knobs, the red vexillum with a gold fringe bar and gold letter bars
        paint(b, P_BRONZE, 0.55)
        box(b, (-0.25, 5.56, -0.035), (0.25, 5.63, 0.035), skip=("-x", "+x"))
        paint(b, P_GOLD, 0.5)
        for s in (-1, 1):
            box(b, (min(s * 0.25, s * 0.29), 5.55, -0.04), (max(s * 0.25, s * 0.29), 5.64, 0.04), skip=(("-x" if s > 0 else "+x"),))
        paint(b, P_RED, 0.5)
        slab(b, [(-0.24, 4.74, -0.11), (0.24, 4.74, -0.11), (0.24, 5.56, -0.11), (-0.24, 5.56, -0.11)], (0, 0, 0.022))
        paint(b, P_GOLD, 0.5)
        box(b, (-0.25, 4.69, -0.115), (0.25, 4.75, -0.083))
        for (x0, x1, yy0, yy1) in ((-0.16, 0.16, 5.38, 5.43), (-0.16, -0.12, 5.0, 5.3), (-0.04, 0.0, 5.0, 5.3), (0.08, 0.16, 5.12, 5.17), (0.12, 0.16, 5.0, 5.3)):
            b.poly([(x0, yy0, -0.1115), (x1, yy0, -0.1115), (x1, yy1, -0.1115), (x0, yy1, -0.1115)], (0, 0, -1))
        # the wreath (gold ring, x-y plane) with an energy core
        cy, r0, r1 = 5.96, 0.17, 0.25
        n = 6
        paint(b, P_GOLD, 0.5)
        for i in range(n):
            # leaves: each a quad tilted out of the plane, front and back (a wreath reads by its broken outline)
            a0 = 2 * math.pi * i / n + math.pi / 6
            a1 = 2 * math.pi * (i + 1) / n + math.pi / 6 - 0.12
            for zf in (-0.03, 0.03):
                pts = [(r0 * math.cos(a0), cy + r0 * math.sin(a0), zf), (r1 * math.cos(a0), cy + r1 * math.sin(a0), zf),
                       (r1 * math.cos(a1), cy + r1 * math.sin(a1), zf * 0.3), (r0 * math.cos(a1), cy + r0 * math.sin(a1), zf * 0.3)]
                b.poly(pts, (0, 0, 1 if zf > 0 else -1))
        paint(b, P_GLOW, 0.5)
        slab(b, [(0.0, cy - 0.08, -0.02), (0.08, cy, -0.02), (0.0, cy + 0.08, -0.02), (-0.08, cy, -0.02)], (0, 0, 0.04))
        paint(b, P_BRONZE, 0.5)
        lathe(b, 0.0, 0.0, [(6.21, 0.05), (6.3, 0.05)], 6, caps=(False, True))
        # the eagle: perch, body (breast to -z), head and gold beak, wings raised and swept back
        paint(b, P_GOLD, 0.45)
        box(b, (-0.08, 6.3, -0.06), (0.08, 6.36, 0.08), skip=("-y",))
        body = [(0.12, 6.36), (-0.05, 6.36), (-0.11, 6.48), (-0.09, 6.62), (0.0, 6.66), (0.08, 6.56), (0.16, 6.42)]
        paint(b, P_GOLD, 0.52)
        slab(b, [(-0.065, y, z) for (z, y) in body], (0.13, 0, 0))
        paint(b, P_GOLD, 0.58)
        box(b, (-0.05, 6.62, -0.14), (0.05, 6.74, -0.03), chamfer=0.015)
        paint(b, P_BRONZE, 0.4)
        slab(b, [(-0.02, 6.64, -0.14), (-0.02, 6.7, -0.14), (-0.02, 6.64, -0.2)], (0.04, 0, 0))
        paint(b, P_GOLD, 0.5)
        L = 0.42
        for sx in (-1, 1):
            sh = (sx * 0.05, 6.5, 0.0)
            dvec = mul(norm((sx * 0.2, 0.36, 0.0)), 1.0)
            wing = [(0.0, -0.06), (0.22, -0.1), (L, -0.05), (0.4, 0.0), (0.33, 0.02), (0.36, 0.07), (0.27, 0.08),
                    (0.29, 0.13), (0.18, 0.13), (0.18, 0.17), (0.06, 0.12), (0.0, 0.08)]
            pts = [add(add(sh, mul(dvec, s_)), (0.0, 0.0, t)) for (s_, t) in wing]
            thick = mul(norm(cross(dvec, (0, 0, 1))), 0.035 * sx)
            slab(b, pts, thick)
    else:
        paint(b, P_MARBLE, 0.5)
        box(b, (-0.85, 0.0, -0.85), (0.85, 1.2, 0.85), skip=("-y",))
        paint(b, P_BRONZE, 0.5)
        box(b, (-0.07, 1.2, -0.07), (0.07, 6.3, 0.07), skip=("-y", "+y"))
        box(b, (-0.27, 5.56, -0.035), (0.27, 5.63, 0.035), skip=("-x", "+x"))
        paint(b, P_RED, 0.5)
        for s in (-1, 1):
            b.poly([(-0.24, 4.7, -0.1), (0.24, 4.7, -0.1), (0.24, 5.56, -0.1), (-0.24, 5.56, -0.1)], (0, 0, s))
        paint(b, P_GOLD, 0.5)
        box(b, (-0.08, 6.3, -0.12), (0.08, 6.66, 0.14), skip=("-y",))
        for sx in (-1, 1):
            p = [(sx * 0.06, 6.5, -0.06), (sx * 0.26, 6.86, -0.08), (sx * 0.2, 6.78, 0.16), (sx * 0.06, 6.55, 0.1)]
            b.poly(p, (0, 0, -1))
            b.poly(p, (0, 0, 1))


# ---------------------------------------------------------------- item 2: the camp

def build_tent(b, data, level):
    """A legion leather tent (papilio) on its wedge collider (3.6 long, ridge at y 2.4 over z 0, eaves at z +-2):
    low sod walls, the pitched roof a few centimetres over the collider's slopes in three panels with leather
    seams, a leather eave band and barge boards, a ridge pole with bronze finials, closed door flaps with bronze
    toggles on the +x gable, a red and gold unit pennon on the -x gable, guy ropes to bronze pegs."""
    near = level == 0
    hx = 1.8
    zw, yw = 1.93, 0.28        # sod wall
    ze, ye = 1.96, 0.24        # eave
    ya = 2.44                  # apex of the roof sheet
    rx = 1.83                  # roof overhang over the gables
    roof_n = lambda s: (0.0, ze, s * (ya - ye))   # outward normal hint of the +-z slope
    def R(x, t, s):            # point on the s side's roof at x, t = 0 eave .. 1 apex, lifted by `lift`
        return (x, ye + (ya - ye) * t, s * ze * (1.0 - t))
    # sod walls
    paint(b, P_LEATHER, 0.5, 0.03)
    for s in (-1, 1):
        b.poly([(-hx, 0.0, s * zw), (hx, 0.0, s * zw), (hx, yw, s * zw), (-hx, yw, s * zw)], (0, 0, s))
    # gables
    paint(b, P_CANVAS, 0.46)
    for sx in (-1, 1):
        b.poly([(sx * hx, 0.0, -zw), (sx * hx, 0.0, zw), (sx * hx, yw, zw), (sx * hx, ya - 0.04, 0.0), (sx * hx, yw, -zw)], (sx, 0, 0))
    if not near:
        paint(b, P_CANVAS, 0.5)
        for s in (-1, 1):
            b.poly([(-rx, ye, s * ze), (rx, ye, s * ze), (rx, ya, 0.0), (-rx, ya, 0.0)], roof_n(s))
        paint(b, P_TIMBER, 0.5)
        b.poly([(-1.86, ya + 0.04, 0.0), (1.86, ya + 0.04, 0.0), (1.86, ya - 0.04, -0.06), (-1.86, ya - 0.04, -0.06)], (0, 1, -1))
        b.poly([(-1.86, ya + 0.04, 0.0), (-1.86, ya - 0.04, 0.06), (1.86, ya - 0.04, 0.06), (1.86, ya + 0.04, 0.0)], (0, 1, 1))
        paint(b, P_LEATHER, 0.45)
        b.poly([(hx + 0.01, 0.0, -0.55), (hx + 0.01, 0.0, 0.55), (hx + 0.01, 1.55, 0.2), (hx + 0.01, 1.55, -0.2)], (1, 0, 0))
        paint(b, P_RED, 0.5)
        b.poly([(-hx - 0.01, 1.0, -0.32), (-hx - 0.01, 1.0, 0.32), (-hx - 0.01, 1.62, 0.32), (-hx - 0.01, 1.62, -0.32)], (-1, 0, 0))
        return
    # roof: three panels a side, the middle one a shade lighter; leather seams over the panel joints
    xs = (-rx, -0.6, 0.6, rx)
    for s in (-1, 1):
        for i in range(3):
            # canvas on its cloth surface (the leather surface read grey-blue at dusk)
            paint(b, P_CANVAS, 0.5 + (0.05 if i == 1 else 0.0) + (0.02 if s > 0 else 0.0))
            b.poly([R(xs[i], 0, s), R(xs[i + 1], 0, s), R(xs[i + 1], 1, s), R(xs[i], 1, s)], roof_n(s))
        paint(b, P_LEATHER, 0.5)
        off = mul(norm(roof_n(s)), 0.015)
        for xj in (-0.6, 0.6):
            slab(b, [R(xj - 0.04, 0.0, s), R(xj + 0.04, 0.0, s), R(xj + 0.04, 0.97, s), R(xj - 0.04, 0.97, s)], off, back=False)
        # eave band
        slab(b, [R(-rx, 0.0, s), R(rx, 0.0, s), R(rx, 0.07, s), R(-rx, 0.07, s)], off, back=False)
    # ridge pole, bronze finials
    paint(b, P_TIMBER, 0.5)
    box(b, (-1.81, ya - 0.03, -0.04), (1.81, ya + 0.05, 0.04), skip=("-y", "-x", "+x"))
    paint(b, P_BRONZE, 0.55)
    for sx in (-1, 1):
        x0, x1 = sorted((sx * 1.81, sx * 1.89))
        box(b, (x0, ya - 0.05, -0.05), (x1, ya + 0.06, 0.05), chamfer=0.012)
    # -x gable: the gable pole and the unit pennon (red with gold bars and a swallow tail)
    paint(b, P_TIMBER, 0.48)
    box(b, (-hx - 0.06, 0.0, -0.035), (-hx, ya - 0.05, 0.035), skip=("-y", "+x"))
    paint(b, P_RED, 0.5)
    fplate(b, "-x", -hx, [(-0.36, 1.62), (-0.06, 1.62), (-0.06, 1.0), (-0.21, 1.1), (-0.36, 1.0)], 0.0, 0.02)
    fplate(b, "-x", -hx, [(0.06, 1.62), (0.36, 1.62), (0.36, 1.0), (0.21, 1.1), (0.06, 1.0)], 0.0, 0.02)
    paint(b, P_GOLD, 0.5)
    fbox(b, "-x", -hx, -0.4, 0.4, 1.62, 1.68, 0.0, 0.03)
    fquad(b, "-x", -hx, -0.3, -0.12, 1.36, 1.42, 0.021)
    fquad(b, "-x", -hx, 0.12, 0.3, 1.36, 1.42, 0.021)
    # +x gable: two closed leather door flaps overlapping, door poles, bronze toggles across the seam
    paint(b, P_LEATHER, 0.46)
    fplate(b, "+x", hx, [(-0.62, 0.0), (0.06, 0.0), (0.06, 1.72), (-0.62, 1.2)], 0.0, 0.012)
    paint(b, P_LEATHER, 0.52)
    fplate(b, "+x", hx, [(-0.04, 0.0), (0.62, 0.0), (0.62, 1.2), (-0.04, 1.72)], 0.012, 0.024)
    paint(b, P_BRONZE, 0.5)
    for ty in (0.55, 1.1):
        fbox(b, "+x", hx, -0.09, 0.09, ty, ty + 0.05, 0.024, 0.045)
    paint(b, P_TIMBER, 0.48)
    for zp in (-0.68, 0.68):
        fbox(b, "+x", hx, zp - 0.035, zp + 0.035, 0.0, 1.25, 0.0, 0.06, skip=("-y",))
    # guy ropes from the eave corners to bronze pegs
    for sx in (-1, 1):
        for s in (-1, 1):
            top = (sx * 1.82, ye + 0.02, s * ze)
            peg = (sx * 1.86, 0.06, s * 2.05)
            paint(b, ("canvas", "burlap"), 0.42)
            side = mul(norm(cross(sub(peg, top), (0, 1, 0))), 0.012)
            q = [sub(top, side), add(top, side), add(peg, side), sub(peg, side)]
            b.poly(q, cross(sub(q[1], q[0]), sub(q[2], q[0])))
            b.poly(q, mul(cross(sub(q[1], q[0]), sub(q[2], q[0])), -1))
            paint(b, P_BRONZE, 0.5)
            lathe(b, peg[0], peg[2], [(0.0, 0.035), (0.1, 0.0)], 4, phase=math.pi / 4)


def build_stake_row(b, data, level):
    """A cheval de frise on its 4 x 0.9 x 0.7 box: a hewn log, nine sharpened stakes crossing it in alternate
    leans (seeded), bronze-shod tips, rope lashings."""
    near = level == 0
    n = 9
    stakes = []
    for i in range(n):
        x = -1.8 + 3.6 * i / (n - 1)
        s = 1 if i % 2 == 0 else -1
        dx = b.rng.uniform(-0.06, 0.06)
        dz = b.rng.uniform(-0.03, 0.03)
        base = (x - dx * 0.5, 0.0, -s * 0.24)
        tip = (x + dx, 0.93 + b.rng.uniform(-0.04, 0.0), s * (0.42 + dz))
        stakes.append((base, tip))
    if not near:
        paint(b, P_TIMBER, 0.5)
        b.poly([(-1.95, 0.27, -0.12), (1.95, 0.27, -0.12), (1.95, 0.27, 0.12), (-1.95, 0.27, 0.12)], (0, 1, 0))
        for s in (-1, 1):
            b.poly([(-1.95, 0.0, s * 0.14), (1.95, 0.0, s * 0.14), (1.95, 0.27, s * 0.12), (-1.95, 0.27, s * 0.12)], (0, 0, s))
        paint(b, P_TIMBER, 0.42)
        for (base, tip) in stakes:
            p = [(base[0] - 0.05, base[1], base[2]), (base[0] + 0.05, base[1], base[2]), tip]
            nn = cross(sub(p[1], p[0]), sub(p[2], p[0]))
            b.poly(p, nn)
            b.poly(p, mul(nn, -1))
        return
    # the log: an eight-sided hewn beam
    paint(b, P_TIMBER, 0.5, 0.04)
    prof = [(0.14 + 0.13 * math.sin(a), 0.13 * math.cos(a)) for a in [2 * math.pi * k / 8 + math.pi / 8 for k in range(8)]]
    prism(b, "x", prof, -1.95, 1.95, skip=("-y",))
    for i, (base, tip) in enumerate(stakes):
        d = norm(sub(tip, base))
        e1 = norm(cross(d, (1, 0, 0)))
        e2 = norm(cross(d, e1))
        ln = length(sub(tip, base))
        sh = add(base, mul(d, ln * 0.8))
        r0, r1 = 0.055, 0.042
        bot = [add(base, add(mul(e1, a * r0), mul(e2, c * r0))) for (a, c) in ((1, 1), (-1, 1), (-1, -1), (1, -1))]
        mid = [add(sh, add(mul(e1, a * r1), mul(e2, c * r1))) for (a, c) in ((1, 1), (-1, 1), (-1, -1), (1, -1))]
        paint(b, P_TIMBER, 0.42 + 0.03 * (i % 3), 0.03)
        for k in range(4):
            j = (k + 1) % 4
            out = sub(mul(add(bot[k], bot[j]), 0.5), base)
            b.poly([bot[k], bot[j], mid[j], mid[k]], out)
        paint(b, P_BRONZE, 0.5)
        for k in range(4):
            j = (k + 1) % 4
            out = sub(mul(add(mid[k], mid[j]), 0.5), sh)
            b.poly([mid[k], mid[j], tip], add(out, mul(d, 0.02)))
    # rope lashings round the log at every other stake
    paint(b, ("canvas", "burlap"), 0.4)
    for i in range(0, n, 2):
        x = stakes[i][0][0]
        box(b, (x - 0.035, 0.0, -0.145), (x + 0.035, 0.285, 0.145), skip=("-y", "-x", "+x"))


# ---------------------------------------------------------------- item 2: the aqueduct

def build_aqueduct_span(b, data, level):
    """A 10 m span on two half piers (neighbours meet at x = +-5 into 2 m piers): piers with a base, ashlar
    courses and an impost cap, corbels under the deck, a flat arch of voussoirs in shallow relief on the deck
    band (the open way 8 x 4.2 leaves no room for a real arch), a cornice, kerbs with marble copings, coffers in
    the soffit, deck paving and an energy conduit between bronze lips in the deck. Nothing passes x = +-5, so
    spans tile end to end."""
    near = level == 0
    X = 5.0
    Z = 1.4
    piers = ((-X, -4.0, -1), (4.0, X, 1))        # x range and the side the open way lies on (inner face sign)
    if near:
        for (x0, x1, sx) in piers:
            xin = x0 if sx > 0 else x1               # inner face (towards the open way)
            sg = -sx                                  # inner face normal sign along x
            # plinth, the impost cap (0.08 into the open way, 0.1 out over the long faces)
            # (into the open way 0.07 at most: tests/test_world_kit.gd keeps a 0.08 skin of open volumes clear)
            paint(b, P_BASE, 0.5)
            pa, pb = (xin + sg * 0.07, x1) if sx > 0 else (x0, xin + sg * 0.07)
            box(b, (min(pa, pb), 0.0, -Z - 0.1), (max(pa, pb), 0.5, Z + 0.1), chamfer=0.03, skip=("-y",))
            # ashlar courses on the long faces and the inner face
            rows = [(0.5 + 0.5 * i, min(1.0 + 0.5 * i, 3.85)) for i in range(7)]
            for i, (ya, yb) in enumerate(rows):
                paint(b, P_WALL, 0.5, 0.07)
                for s in (-1, 1):
                    pts = [(ya, s * (Z + 0.03))] if i == 0 else [(ya, s * Z), (ya + 0.03, s * (Z + 0.03))]
                    pts += [(yb - 0.03, s * (Z + 0.03)), (yb, s * Z)]
                    if s > 0:
                        pts = list(reversed(pts))
                    xa, xb = (xin - 0.03, x1) if sx > 0 else (x0, xin + 0.03)
                    strip(b, "x", pts, xa, xb)
                # inner face: (u, v) = (x, y) for z prisms
                pts = [(xin + sg * 0.03, ya)] if i == 0 else [(xin, ya), (xin + sg * 0.03, ya + 0.03)]
                pts += [(xin + sg * 0.03, yb - 0.03), (xin, yb)]
                if sg < 0:
                    pts = list(reversed(pts))
                strip(b, "z", [(p[0], p[1]) for p in pts], -Z - 0.03, Z + 0.03)
            paint(b, P_MARBLE, 0.5, 0.03)
            ia, ib = (xin + sg * 0.07, x1) if sx > 0 else (x0, xin + sg * 0.07)
            box(b, (min(ia, ib), 3.85, -Z - 0.1), (max(ia, ib), 4.2, Z + 0.1), chamfer=0.035, skip=("+y",))
            # corbels under the impost
            paint(b, P_MARBLE, 0.46)
            for zc in (-0.75, 0.75):
                side = [(xin, 3.42), (xin, 3.85), (xin + sg * 0.07, 3.85), (xin + sg * 0.07, 3.68)]
                slab(b, [(u, v, zc - 0.17) for (u, v) in side], (0, 0, 0.34))
            # the joint end face (meets the neighbour's)
            paint(b, P_SHADE, 0.5)
            xe = x1 if sx > 0 else x0
            b.poly([(xe, 0.5, -Z), (xe, 0.5, Z), (xe, 3.85, Z), (xe, 3.85, -Z)], (sx, 0, 0))
        # deck band: flat arch of voussoirs (relief) over the open way, the band itself behind
        for s in (-1, 1):
            nm = "+z" if s > 0 else "-z"
            paint(b, P_WALL, 0.5, 0.04)
            fquad(b, nm, s * Z, -X, X, 4.2, 4.85)
            n = 7
            half = 4.3
            apex = 4.2 - 6.0
            for i in range(n):
                xa = -half + 2 * half * i / n
                xb = -half + 2 * half * (i + 1) / n
                key = i == n // 2
                top = 4.85 if not key else 4.92
                kk = (top - apex) / (4.2 - apex)
                g = 0.014
                pts = [(xa + g, 4.2), (xb - g, 4.2), ((xb - g) * kk, top), ((xa + g) * kk, top)]
                paint(b, P_MARBLE if key else P_WALL, 0.5 if key else 0.57, 0.0 if key else 0.06)
                fplate(b, nm, s * Z, pts, 0.0, 0.05 if key else 0.03)
            # cornice under the kerb
            paint(b, P_MARBLE, 0.52, 0.03)
            prof = [(4.85, 0.0), (4.92, 0.06), (5.0, 0.11), (5.08, 0.11), (5.08, 0.0)]
            band_run(b, nm, s * Z, -X, X, prof, (0, 0))
            # kerb outer face over the cornice
            paint(b, P_WALL, 0.5, 0.04)
            fquad(b, nm, s * Z, -X, X, 5.08, 5.42, 0.0)
            # kerb inner face and the coping
            fquad(b, "-z" if s > 0 else "+z", s * 1.1, -X, X, 5.0, 5.42, 0.0)
            paint(b, P_MARBLE, 0.5, 0.04)
            za, zb = sorted((s * 1.09, s * 1.48))
            box(b, (-X, 5.42, za), (X, 5.56, zb), chamfer=0.025, skip=("-y",))
        # deck ends (meet the neighbour)
        paint(b, P_SHADE, 0.5)
        for sx in (-1, 1):
            b.poly([(sx * X, y, z) for (z, y) in ((-Z, 4.2), (Z, 4.2), (Z, 5.42), (1.1, 5.42), (1.1, 5.0), (-1.1, 5.0), (-1.1, 5.42), (-Z, 5.42))], (sx, 0, 0))
        # soffit with three coffers
        paint(b, P_SHADE, 0.47)
        holes = [{"u0": x0, "u1": x1, "v0": -0.85, "v1": 0.85, "depth": 0.1, "back": "travertine_shade", "shade": 0.36}
                 for (x0, x1) in ((-3.55, -1.35), (-1.1, 1.1), (1.35, 3.55))]
        face(b, "-y", 4.2, -4.0, 4.0, -Z, Z, holes)
        # deck paving (eight slabs with chamfered joints), the conduit: bronze lips and an energy line
        g = 0.02
        for k in range(8):
            xa = -X + 2 * X * k / 8
            xb = -X + 2 * X * (k + 1) / 8
            paint(b, P_WALK, 0.5, 0.06)
            b.poly([(xa + g, 5.0, -1.1), (xb - g, 5.0, -1.1), (xb - g, 5.0, 1.1), (xa + g, 5.0, 1.1)], (0, 1, 0))
            b.poly([(xa, 5.0 - g, -1.1), (xa + g, 5.0, -1.1), (xa + g, 5.0, 1.1), (xa, 5.0 - g, 1.1)], (-1, 1, 0))
            b.poly([(xb - g, 5.0, -1.1), (xb, 5.0 - g, -1.1), (xb, 5.0 - g, 1.1), (xb - g, 5.0, 1.1)], (1, 1, 0))
        paint(b, P_BRONZE, 0.45)
        for s in (-1, 1):
            za, zb = sorted((s * 0.09, s * 0.16))
            box(b, (-X, 4.99, za), (X, 5.025, zb), skip=("-y", "-x", "+x"))
        paint(b, P_GLOW, 0.5)
        b.poly([(-X, 5.012, -0.09), (X, 5.012, -0.09), (X, 5.012, 0.09), (-X, 5.012, 0.09)], (0, 1, 0))
    else:
        paint(b, P_WALL, 0.5)
        for (x0, x1, sx) in piers:
            xin = x0 if sx > 0 else x1
            for s in (-1, 1):
                b.poly([(x0, 0.0, s * Z), (x1, 0.0, s * Z), (x1, 4.2, s * Z), (x0, 4.2, s * Z)], (0, 0, s))
            b.poly([(xin, 0.0, -Z), (xin, 0.0, Z), (xin, 4.2, Z), (xin, 4.2, -Z)], (-sx, 0, 0))
            xe = x1 if sx > 0 else x0
            b.poly([(xe, 0.0, -Z), (xe, 0.0, Z), (xe, 4.2, Z), (xe, 4.2, -Z)], (sx, 0, 0))
        paint(b, P_SHADE, 0.5)
        b.poly([(-4.0, 4.2, -Z), (4.0, 4.2, -Z), (4.0, 4.2, Z), (-4.0, 4.2, Z)], (0, -1, 0))
        for s in (-1, 1):
            paint(b, P_WALL, 0.5)
            b.poly([(-X, 4.2, s * Z), (X, 4.2, s * Z), (X, 5.5, s * Z), (-X, 5.5, s * Z)], (0, 0, s))
            paint(b, P_MARBLE, 0.5)
            za, zb = sorted((s * Z, s * (Z + 0.1)))
            box(b, (-X, 4.85, za), (X, 5.08, zb), skip=("-x", "+x", "-z" if s > 0 else "+z"))
            b.poly([(-X, 5.5, s * 1.1), (X, 5.5, s * 1.1), (X, 5.5, s * Z), (-X, 5.5, s * Z)], (0, 1, 0))
            paint(b, P_WALL, 0.5)
            b.poly([(-X, 5.0, s * 1.1), (X, 5.0, s * 1.1), (X, 5.5, s * 1.1), (-X, 5.5, s * 1.1)], (0, 0, -s))
        paint(b, P_SHADE, 0.5)
        for sx in (-1, 1):
            b.poly([(sx * X, y, z) for (z, y) in ((-Z, 4.2), (Z, 4.2), (Z, 5.5), (1.1, 5.5), (1.1, 5.0), (-1.1, 5.0), (-1.1, 5.5), (-Z, 5.5))], (sx, 0, 0))
        paint(b, P_WALK, 0.5)
        b.poly([(-X, 5.0, -1.1), (X, 5.0, -1.1), (X, 5.0, 1.1), (-X, 5.0, 1.1)], (0, 1, 0))
        paint(b, P_GLOW, 0.5)
        b.poly([(-X, 5.012, -0.06), (X, 5.012, -0.06), (X, 5.012, 0.06), (-X, 5.012, 0.06)], (0, 1, 0))


def build_aqueduct_ramp(b, data, level):
    """Steps up the ramp wedge (rising to +x, 5 m over 9.4 m): 25 steps of 0.2 m, each tread at the ramp line
    at its lower edge (+0.03), marble side kerbs just outside the walk, the last riser at the top."""
    near = level == 0
    xr, zr, yb, yt, _ = wedge_ramp(data.colliders("aqueduct_ramp")[0])
    k = (yt - yb) / (xr[1] - xr[0])
    Y = lambda x: yb + k * (x - xr[0])
    zi = 1.385
    if near:
        count = 25
        paints = {"tread": ("travertine", None), "riser": ("travertine_shade", None), "side": ("travertine_shade", None)}
        steps(b, xr[0], xr[1], -zi, zi, yb, yt, count, 0.03, paints, nosing=0.025)
        paint(b, P_SHADE, 0.5)
        last = yb + (yt - yb) * (count - 1) / count + 0.03
        b.poly([(xr[1], last, -zi), (xr[1], yt, -zi), (xr[1], yt, zi), (xr[1], last, zi)], (-1, 0, 0))
        for s in (-1, 1):
            za, zb = sorted((s * zi, s * 1.5))
            zo = zb if s > 0 else za
            paint(b, P_MARBLE, 0.5, 0.03)
            b.poly([(xr[0], Y(xr[0]) + 0.08, za), (xr[1], Y(xr[1]) + 0.08, za), (xr[1], Y(xr[1]) + 0.08, zb), (xr[0], Y(xr[0]) + 0.08, zb)], (-k, 1, 0))
            paint(b, P_WALL, 0.5, 0.03)
            b.poly([(xr[0], 0.0, zo), (xr[1], 0.0, zo), (xr[1], Y(xr[1]) + 0.08, zo), (xr[0], Y(xr[0]) + 0.08, zo)], (0, 0, s))
            paint(b, P_MARBLE, 0.46)
            zin = s * zi
            b.poly([(xr[0], 0.0, zin), (xr[1], Y(xr[1]) - 0.2, zin), (xr[1], Y(xr[1]) + 0.08, zin), (xr[0], Y(xr[0]) + 0.08, zin)], (0, 0, -s))
            b.poly([(xr[0], 0.0, za), (xr[0], 0.0, zb), (xr[0], Y(xr[0]) + 0.08, zb), (xr[0], Y(xr[0]) + 0.08, za)], (-1, 0, 0))
            b.poly([(xr[1], 0.0, za), (xr[1], 0.0, zb), (xr[1], Y(xr[1]) + 0.08, zb), (xr[1], Y(xr[1]) + 0.08, za)], (1, 0, 0))
            # a plinth band on the kerb's outer face
            paint(b, P_BASE, 0.5)
            b.poly([(xr[0] + 0.6, 0.0, zo + s * 0.04), (xr[1], 0.0, zo + s * 0.04), (xr[1], 0.35, zo + s * 0.04), (xr[0] + 0.6, 0.35, zo + s * 0.04)], (0, 0, s))
        paint(b, P_SHADE, 0.5)
        b.poly([(xr[1], 0.0, -1.5), (xr[1], 0.0, 1.5), (xr[1], last, 1.5), (xr[1], last, -1.5)], (1, 0, 0))
    else:
        paint(b, P_WALL, 0.5)
        b.poly([(xr[0], yb + 0.03, -1.45), (xr[1], yt + 0.03, -1.45), (xr[1], yt + 0.03, 1.45), (xr[0], yb + 0.03, 1.45)], (-k, 1, 0))
        for s in (-1, 1):
            b.poly([(xr[0], 0.0, s * 1.45), (xr[1], 0.0, s * 1.45), (xr[1], yt + 0.03, s * 1.45)], (0, 0, s))
        b.poly([(xr[1], 0.0, -1.45), (xr[1], 0.0, 1.45), (xr[1], yt, 1.45), (xr[1], yt, -1.45)], (1, 0, 0))


# ---------------------------------------------------------------- item 2: the barracks

def plaque(b, nm, w, cu, cv, hw, hh, seed_bars):
    """A legion plaque on a face: a bronze frame, a red field and gold bars standing for the numerals (no text)."""
    t = 0.07
    paint(b, P_BRONZE, 0.5)
    fbox(b, nm, w, cu - hw, cu + hw, cv + hh - t, cv + hh, 0.0, 0.06)
    fbox(b, nm, w, cu - hw, cu + hw, cv - hh, cv - hh + t, 0.0, 0.06)
    fbox(b, nm, w, cu - hw, cu - hw + t, cv - hh + t, cv + hh - t, 0.0, 0.06, skip=("-y", "+y"))
    fbox(b, nm, w, cu + hw - t, cu + hw, cv - hh + t, cv + hh - t, 0.0, 0.06, skip=("-y", "+y"))
    paint(b, P_RED, 0.5)
    fquad(b, nm, w, cu - hw + t, cu + hw - t, cv - hh + t, cv + hh - t, 0.02)
    paint(b, P_GOLD, 0.5)
    u = cu - hw + t + 0.08
    end = cu + hw - t - 0.08
    for (wd, tall) in seed_bars:
        if u + wd > end:
            break
        h = (hh - t - 0.08) * tall
        fbox(b, nm, w, u, u + wd, cv - h, cv + h, 0.02, 0.045, skip=("-y",))
        u += wd + 0.07


def build_barracks(b, data, level):
    """The barracks block on its colliders (walls 0.4 thick, the roof slab 9.4 x 6.4 at y 3.0 .. 3.3): a dark
    plinth course, ashlar faces between L-shaped corner pilasters, door surrounds (marble jambs on base blocks,
    a lintel band with a bronze cap, a threshold slab, marble reveals), a bronze lamp housing with an energy core
    beside each door, the window with a frame, a projecting sill and timber shutters folded flat against the wall
    (the opening stays open), legion plaques, a cornice under the roof's overhang, a marble fascia and a coping
    lip outside the walkable roof, roof paving; inside: floor slabs, a skirting, a red dado under a marble rail,
    niches in the end and back walls, a ceiling cornice and timber beams, a lamp over each door."""
    near = level == 0
    t = data.types["barracks"]
    cols, opens = t["colliders"], t["open"]
    (fd0, _, _), (fd1, DH, _) = bounds(opens[0])
    (bd0, _, _), (bd1, _, _) = bounds(opens[1])
    (wn0, wv0, _), (wn1, wv1, _) = bounds(opens[2])
    (rmx0, _, rmz0), (IX_, WH, IZ_) = bounds(opens[3])
    IX, IZ = IX_, IZ_                               # inner faces (4.1, 2.6)
    (_, RY0, _), (RX, RY1, RZ) = bounds(cols[11])    # the roof slab
    HX, HZ = bounds(cols[10])[1][0], bounds(cols[0])[0][2] * -1.0   # outer faces (4.5, 3.0)
    doors = (("-z", -HZ, fd0, fd1, -1), ("+z", HZ, bd0, bd1, 1))
    if not near:
        paint(b, P_WALL, 0.5)
        wall_rects(b, "-z", -HZ, -HX, HX, 0.0, RY0, [(fd0, fd1, 0.0, DH), (wn0, wn1, wv0, wv1)])
        wall_rects(b, "+z", HZ, -HX, HX, 0.0, RY0, [(bd0, bd1, 0.0, DH)])
        fquad(b, "-x", -HX, -HZ, HZ, 0.0, RY0)
        fquad(b, "+x", HX, -HZ, HZ, 0.0, RY0)
        paint(b, P_SLIT, 0.5)
        fquad(b, "-z", -IZ, fd0, fd1, 0.0, DH)
        fquad(b, "-z", -IZ, wn0, wn1, wv0, wv1)
        fquad(b, "+z", IZ, bd0, bd1, 0.0, DH)
        paint(b, P_MARBLE, 0.5)
        ring_run(b, HX, HZ, [(2.72, 0.0), (RY0, RZ - HZ)])
        ring_run(b, RX, RZ, [(RY0, 0.0), (RY1, 0.0)])
        for (nm, w, u0, u1, _) in doors:
            fquad(b, nm, w, u0 - 0.2, u0, 0.0, DH, 0.05)
            fquad(b, nm, w, u1, u1 + 0.2, 0.0, DH, 0.05)
            fquad(b, nm, w, u0 - 0.24, u1 + 0.24, DH, DH + 0.27, 0.07)
        fquad(b, "-z", -HZ, wn0 - 0.2, wn1 + 0.2, wv0 - 0.12, wv0, 0.1)
        paint(b, P_SHADE, 0.5)
        for sx in (-1, 1):
            for sz in (-1, 1):
                fquad(b, "+z" if sz > 0 else "-z", sz * HZ, *sorted((sx * (HX - 0.5), sx * HX)), 0.0, 2.72, 0.06)
                fquad(b, "+x" if sx > 0 else "-x", sx * HX, *sorted((sz * (HZ - 0.5), sz * HZ)), 0.0, 2.72, 0.06)
        paint(b, P_WALK, 0.5)
        b.poly([(-RX, RY1, -RZ), (RX, RY1, -RZ), (RX, RY1, RZ), (-RX, RY1, RZ)], (0, 1, 0))
        return

    # ---- exterior
    gw = 0.22   # door surround half: jamb band 0.18, base block 0.22
    paint(b, P_BASE, 0.5)
    ring_run(b, HX, HZ, [(0.0, 0.0), (0.0, 0.08), (0.38, 0.08), (0.45, 0.0)],
             gaps={"-z": [(fd0 - gw, fd1 + gw)], "+z": [(bd0 - gw, bd1 + gw)]})
    paint(b, P_WALL, 0.5, 0.04)
    wall_rects(b, "-z", -HZ, -HX, HX, 0.38, 2.72, [(fd0, fd1, 0.0, DH), (wn0, wn1, wv0, wv1)])
    wall_rects(b, "+z", HZ, -HX, HX, 0.38, 2.72, [(bd0, bd1, 0.0, DH)])
    for nm, w in (("-x", -HX), ("+x", HX)):
        paint(b, P_WALL, 0.5, 0.04)
        face(b, nm, w, -HZ, HZ, 0.38, 2.72, [{"u0": -2.0, "u1": 2.0, "v0": 0.8, "v1": 2.3, "depth": 0.04,
                                               "back": "travertine_shade", "shade": 0.47}])
    # corner pilasters (an L of two chamfered boxes) with capitals
    for sx in (-1, 1):
        for sz in (-1, 1):
            paint(b, P_MARBLE, 0.44, 0.03)
            xa, xb = sorted((sx * (HX - 0.5), sx * (HX + 0.08)))
            za, zb = sorted((sz * (HZ + 0.08), sz * (HZ - 0.12)))
            box(b, (xa, 0.45, za), (xb, 2.58, zb), chamfer=0.02, skip=("-y", "+y"))
            # the end-face leg starts where the front leg ends (no coplanar overlap)
            xa2, xb2 = sorted((sx * (HX - 0.12), sx * (HX + 0.08)))
            za2, zb2 = sorted((sz * (HZ - 0.12), sz * (HZ - 0.5)))
            box(b, (xa2, 0.45, za2), (xb2, 2.58, zb2), chamfer=0.02, skip=("-y", "+y"))
            paint(b, P_MARBLE, 0.5)
            xa, xb = sorted((sx * (HX - 0.53), sx * (HX + 0.1)))
            za, zb = sorted((sz * (HZ + 0.1), sz * (HZ - 0.12)))
            box(b, (xa, 2.58, za), (xb, 2.72, zb), skip=("+y",))
            xa2, xb2 = sorted((sx * (HX - 0.12), sx * (HX + 0.1)))
            za2, zb2 = sorted((sz * (HZ - 0.12), sz * (HZ - 0.53)))
            box(b, (xa2, 2.58, za2), (xb2, 2.72, zb2), skip=("+y",))
    # cornice under the roof overhang, the fascia, the coping lip (outside the walkable roof)
    paint(b, P_MARBLE, 0.5, 0.03)
    ring_run(b, HX, HZ, [(2.72, 0.0), (2.72, 0.04), (2.8, 0.06), (2.9, 0.13), (RY0, RZ - HZ), (RY0, 0.0)], skip_last=True)
    paint(b, P_MARBLE, 0.46)
    ring_run(b, RX, RZ, [(RY0, 0.0), (RY0, 0.03), (RY1, 0.03), (RY1, 0.0)], skip_last=True)
    paint(b, P_MARBLE, 0.55, 0.03)
    ring_run(b, RX, RZ, [(RY1, -0.015), (RY1, 0.05), (RY1 + 0.06, 0.05), (RY1 + 0.08, 0.03), (RY1 + 0.08, -0.015), (RY1, -0.015)])
    # roof paving inside the lip
    g = 0.02
    n = 7
    ex, ez = RX - 0.015, RZ - 0.015
    for k in range(n):
        xa = -ex + 2 * ex * k / n
        xb = -ex + 2 * ex * (k + 1) / n
        paint(b, P_WALK, 0.5, 0.06)
        ga = g if k > 0 else 0.0
        gb = g if k < n - 1 else 0.0
        b.poly([(xa + ga, RY1, -ez), (xb - gb, RY1, -ez), (xb - gb, RY1, ez), (xa + ga, RY1, ez)], (0, 1, 0))
        if ga:
            b.poly([(xa, RY1 - g, -ez), (xa + ga, RY1, -ez), (xa + ga, RY1, ez), (xa, RY1 - g, ez)], (-1, 1, 0))
        if gb:
            b.poly([(xb - gb, RY1, -ez), (xb, RY1 - g, -ez), (xb, RY1 - g, ez), (xb - gb, RY1, ez)], (1, 1, 0))
    # doors: surrounds, reveals, threshold, the lamp
    for (nm, w, u0, u1, s) in doors:
        paint(b, P_MARBLE, 0.5, 0.03)
        fbox(b, nm, w, u0 - 0.18, u0, 0.45, DH, 0.0, 0.07, chamfer=0.02, skip=("-y", "+y"))
        fbox(b, nm, w, u1, u1 + 0.18, 0.45, DH, 0.0, 0.07, chamfer=0.02, skip=("-y", "+y"))
        paint(b, P_MARBLE, 0.44)
        fbox(b, nm, w, u0 - gw, u0, 0.0, 0.45, 0.0, 0.1, chamfer=0.02, skip=("-y",))
        fbox(b, nm, w, u1, u1 + gw, 0.0, 0.45, 0.0, 0.1, chamfer=0.02, skip=("-y",))
        paint(b, P_MARBLE, 0.54)
        fbox(b, nm, w, u0 - gw, u1 + gw, DH, DH + 0.2, 0.0, 0.09, chamfer=0.02)
        paint(b, P_BRONZE, 0.5)
        fbox(b, nm, w, u0 - gw - 0.04, u1 + gw + 0.04, DH + 0.2, DH + 0.27, 0.0, 0.12, chamfer=0.015)
        paint(b, P_MARBLE, 0.46)
        zo, zi = s * HZ, s * IZ
        b.poly([(u0, 0.0, zo), (u0, 0.0, zi), (u0, DH, zi), (u0, DH, zo)], (1, 0, 0))
        b.poly([(u1, 0.0, zo), (u1, 0.0, zi), (u1, DH, zi), (u1, DH, zo)], (-1, 0, 0))
        b.poly([(u0, DH, zo), (u1, DH, zo), (u1, DH, zi), (u0, DH, zi)], (0, -1, 0))
        paint(b, P_BASE, 0.56)
        za, zb = sorted((s * (HZ + 0.12), s * (IZ - 0.02)))
        box(b, (u0 - 0.05, 0.0, za), (u1 + 0.05, 0.05, zb), chamfer=0.012, skip=("-y",))
        # lamp housing beside the door (on the side towards the middle of the wall)
        lu = (u1 + 0.55) if s < 0 else (u0 - 0.45)
        paint(b, P_BRONZE, 0.5)
        fbox(b, nm, w, lu - 0.09, lu + 0.09, 1.84, 2.2, 0.0, 0.11, chamfer=0.015)
        fbox(b, nm, w, lu - 0.12, lu + 0.12, 2.2, 2.25, 0.0, 0.13)
        paint(b, P_GLOW, 0.5)
        fquad(b, nm, w, lu - 0.05, lu + 0.05, 1.9, 2.14, 0.111)
    # the window: frame, sill, reveals, shutters folded flat
    paint(b, P_MARBLE, 0.5, 0.03)
    fbox(b, "-z", -HZ, wn0 - 0.14, wn0, wv0, wv1, 0.0, 0.06, chamfer=0.015, skip=("-y", "+y"))
    fbox(b, "-z", -HZ, wn1, wn1 + 0.14, wv0, wv1, 0.0, 0.06, chamfer=0.015, skip=("-y", "+y"))
    fbox(b, "-z", -HZ, wn0 - 0.2, wn1 + 0.2, wv1, wv1 + 0.16, 0.0, 0.08, chamfer=0.02)
    fbox(b, "-z", -HZ, wn0 - 0.22, wn1 + 0.22, wv0 - 0.12, wv0, 0.0, 0.13, chamfer=0.02)
    paint(b, P_MARBLE, 0.45)
    b.poly([(wn0, wv0, -HZ), (wn0, wv0, -IZ), (wn0, wv1, -IZ), (wn0, wv1, -HZ)], (1, 0, 0))
    b.poly([(wn1, wv0, -HZ), (wn1, wv0, -IZ), (wn1, wv1, -IZ), (wn1, wv1, -HZ)], (-1, 0, 0))
    b.poly([(wn0, wv0, -HZ), (wn1, wv0, -HZ), (wn1, wv0, -IZ), (wn0, wv0, -IZ)], (0, 1, 0))
    b.poly([(wn0, wv1, -HZ), (wn1, wv1, -HZ), (wn1, wv1, -IZ), (wn0, wv1, -IZ)], (0, -1, 0))
    for (sa, sb) in ((wn0 - 0.98, wn0 - 0.2), (wn1 + 0.2, wn1 + 0.98)):
        paint(b, P_TIMBER, 0.5, 0.04)
        fbox(b, "-z", -HZ, sa, sb, wv0 + 0.02, wv1 - 0.02, 0.0, 0.05, chamfer=0.01)
        paint(b, P_BRONZE, 0.45)
        for sv in (wv0 + 0.2, wv1 - 0.26):
            fbox(b, "-z", -HZ, sa + 0.03, sb - 0.03, sv, sv + 0.06, 0.05, 0.065)
    # plaques
    plaque(b, "-z", -HZ, (fd1 + 0.55 + wn0 - 0.98) * 0.5 + 0.08, 1.75, 0.42, 0.3, [(0.05, 1), (0.05, 1), (0.14, 0.4), (0.05, 1)])
    plaque(b, "+z", HZ, -1.6, 1.8, 0.8, 0.38, [(0.06, 1), (0.16, 0.35), (0.06, 1), (0.06, 1), (0.16, 0.35), (0.06, 1), (0.06, 1)])

    # ---- interior
    # floor slabs: courses running along x (every vertex then lies on an end wall: a vertex in a doorway would be
    # far from any collider)
    n = 5
    fy = 0.04
    for k in range(n):
        za = -IZ + 2 * IZ * k / n
        zb = -IZ + 2 * IZ * (k + 1) / n
        paint(b, P_WALK, 0.46, 0.06)
        ga = g if k > 0 else 0.0
        gb = g if k < n - 1 else 0.0
        b.poly([(-IX, fy, za + ga), (IX, fy, za + ga), (IX, fy, zb - gb), (-IX, fy, zb - gb)], (0, 1, 0))
        if ga:
            b.poly([(-IX, fy - g, za), (IX, fy - g, za), (IX, fy, za + ga), (-IX, fy, za + ga)], (0, 1, -1))
        if gb:
            b.poly([(-IX, fy, zb - gb), (IX, fy, zb - gb), (IX, fy - g, zb), (-IX, fy - g, zb)], (0, 1, 1))
    dv0, dv1 = 1.0, 1.06
    inner = (("+z", -IZ, [(fd0, fd1, 0.0, DH), (wn0, wn1, wv0, wv1)]), ("-z", IZ, [(bd0, bd1, 0.0, DH)]))
    for nm, w, ops in inner:
        paint(b, P_RED, 0.47)
        wall_rects(b, nm, w, -IX, IX, 0.16, dv0, ops)
    paint(b, P_WALL, 0.52, 0.04)
    wall_rects(b, "+z", -IZ, -IX, IX, dv1 - 0.02, 2.82, [(fd0, fd1, 0.0, DH), (wn0, wn1, wv0, wv1)])
    niche = lambda c: {"u0": c - 0.35, "u1": c + 0.35, "v0": 1.3, "v1": 2.25, "depth": 0.12, "back": "travertine_shade", "shade": 0.34,
                       "walls": "marble", "walls_shade": 0.45}
    face(b, "-z", IZ, -IX, bd0, dv1 - 0.02, 2.82, [niche(-3.2), niche(-1.3)])
    wall_rects(b, "-z", IZ, bd0, IX, dv1 - 0.02, 2.82, [(bd0, bd1, 0.0, DH)])
    for nm, w in (("+x", -IX), ("-x", IX)):
        paint(b, P_RED, 0.47)
        fquad(b, nm, w, -IZ, IZ, 0.16, dv0)
        paint(b, P_WALL, 0.52, 0.04)
        face(b, nm, w, -IZ, IZ, dv1 - 0.02, 2.82, [niche(0.0)])
    gaps = {"+z": [(fd0, fd1)], "-z": [(bd0, bd1)]}
    paint(b, P_MARBLE, 0.5)
    ring_run(b, IX, IZ, [(0.0, 0.0), (0.0, 0.03), (0.15, 0.03), (0.18, 0.0)], outer=False, gaps=gaps)
    ring_run(b, IX, IZ, [(dv0 - 0.02, 0.0), (dv0 - 0.02, 0.03), (dv1 - 0.01, 0.03), (dv1 + 0.01, 0.0)], outer=False, gaps=gaps)
    paint(b, P_MARBLE, 0.46)
    # (interior trim stands 0.07 at most into the room: tests/test_world_kit.gd keeps a 0.08 skin of open volumes clear)
    ring_run(b, IX, IZ, [(2.82, 0.0), (2.86, 0.03), (2.94, 0.06), (RY0, 0.07), (RY0, 0.0)], outer=False, skip_last=True)
    paint(b, ("travertine_shade", "plaster"), 0.44)
    fquad(b, "-y", RY0, -IX, IX, -IZ, IZ)
    paint(b, P_TIMBER, 0.45, 0.04)
    for bx in (-3.0, -1.5, 0.0, 1.5, 3.0):
        box(b, (bx - 0.13, RY0 - 0.07, -IZ), (bx + 0.13, RY0, IZ), skip=("+y", "-z", "+z"))
    # a lamp over each door inside
    for (nm, w, u0, u1, s) in (("+z", -IZ, fd0, fd1, -1), ("-z", IZ, bd0, bd1, 1)):
        cu = (u0 + u1) * 0.5
        paint(b, P_BRONZE, 0.5)
        fbox(b, nm, w, cu - 0.16, cu + 0.16, 2.42, 2.66, 0.0, 0.07, chamfer=0.015)
        paint(b, P_GLOW, 0.5)
        fquad(b, nm, w, cu - 0.11, cu + 0.11, 2.48, 2.6, 0.071)


BUILDERS = {
    "barracks": build_barracks,
    "tent": build_tent,
    "stake_row": build_stake_row,
    "aqueduct_span": build_aqueduct_span,
    "aqueduct_ramp": build_aqueduct_ramp,
    "column": build_column,
    "colonnade": build_colonnade,
    "pediment_front": build_pediment_front,
    "terrace_block": build_terrace_block,
    "ramp_block": build_ramp_block,
    "eagle_standard": build_eagle_standard,
    "wall_walk": build_wall_walk,
    "wall_stair": build_wall_stair,
    "gate": build_gate,
    "watchtower": build_watchtower,
}


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    data = Data()
    out = os.path.join(REPO, data.cfg["glb"].replace("res://", ""))
    only = []
    for a in argv:
        if a.startswith("--out="):
            out = a[6:]
        if a.startswith("--only="):
            only = a[7:].split(",")
    bpy.ops.wm.read_factory_settings(use_empty=True)
    joint = data.cfg.get("joint", {})
    report = []
    for type_name, entry in data.cfg["types"].items():
        if type_name.startswith("_") or (only and type_name not in only):
            continue
        build = BUILDERS[type_name]
        levels = [(0, entry["node"])]
        if entry.get("lod1_node"):
            levels.append((1, entry["lod1_node"]))   # a type may have no far mesh (data/art_world_kit.json)
        for level, node in levels:
            b = Builder(data, type_name + "/" + str(level))
            build(b, data, level)
            tris = b.tris
            if type_name in joint.get("types", []):
                tris = joint_bend(tris, joint)
            make_object(node, tris)
            report.append("M2W1_KIT %s triangles=%d %s" % (node, len(tris), fit_check(data, type_name, tris)))
    export(out)
    for line in report:
        print(line)
    print("M2W1_KIT wrote", out)


if __name__ == "__main__":
    sys.path.insert(0, HERE)
    main()
