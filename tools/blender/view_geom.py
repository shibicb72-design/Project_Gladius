"""Shared geometry for the first-person view model (M2 AN2 item 4a): plain Python (no bpy), Godot metres and axes
(+Y up, -Z forward). Built on soldier_geom's vector helpers and its Geo store (positions, weights, faces with a style);
here a face's style is a material class name of data/art_soldier.json "materials".

Primitives (all write into a ViewGeo; every point goes through the geo's current transform, see ViewGeo.at):
  tube(rings)       quads between consecutive rings (any ring order: oriented outward by the travel direction), with
                    optional end caps (an apex point, "flat" = a fan from the ring's centre, or "poly" = ear clipping)
  lathe(profile)    a [radius, height] profile turned about an axis (open silhouette or a closed ring polygon)
  slab(profile)     a 2D profile extruded along x, y or z with a chamfered or rounded edge on both faces
  sweep(path)       a 2D section carried along a 3D polyline
  box(...)          a slab with a rectangular profile
Sections (2D, counter-clockwise): sect() superellipse with optional bulges, rrect() rounded / chamfered rectangle.
Xf is a small affine transform (columns, Godot conventions: euler_yxz = Basis.from_euler's default YXZ order).
"""

import math

from soldier_geom import Geo, add, centroid, cross, dot, length, lerp, mul, newell, norm, smoothstep, sub  # noqa: F401

TAU = 2.0 * math.pi
STATIC = {"_static": 1.0}


# --- transforms -------------------------------------------------------------------------------------------------------
class Xf:
    """Affine transform: basis columns (x, y, z) and origin, Godot metres."""

    def __init__(self, basis=None, origin=(0.0, 0.0, 0.0)):
        self.b = tuple(tuple(float(c) for c in col) for col in (basis or ((1, 0, 0), (0, 1, 0), (0, 0, 1))))
        self.o = tuple(float(c) for c in origin)

    def dir(self, v):
        x, y, z = self.b
        return (x[0] * v[0] + y[0] * v[1] + z[0] * v[2], x[1] * v[0] + y[1] * v[1] + z[1] * v[2],
                x[2] * v[0] + y[2] * v[1] + z[2] * v[2])

    def apply(self, p):
        return add(self.dir(p), self.o)

    def __mul__(self, other):
        return Xf(tuple(self.dir(c) for c in other.b), self.apply(other.o))

    def inverse(self):
        x, y, z = self.b
        det = dot(x, cross(y, z))
        # the rows of the inverse basis are the cross products / det; transpose them into columns
        r = (mul(cross(y, z), 1.0 / det), mul(cross(z, x), 1.0 / det), mul(cross(x, y), 1.0 / det))
        basis = ((r[0][0], r[1][0], r[2][0]), (r[0][1], r[1][1], r[2][1]), (r[0][2], r[1][2], r[2][2]))
        o = Xf(basis).dir(self.o)
        return Xf(basis, (-o[0], -o[1], -o[2]))

    @staticmethod
    def translate(p):
        return Xf(None, p)

    @staticmethod
    def rot_x(deg):
        c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
        return Xf(((1, 0, 0), (0, c, s), (0, -s, c)))

    @staticmethod
    def rot_y(deg):
        c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
        return Xf(((c, 0, -s), (0, 1, 0), (s, 0, c)))

    @staticmethod
    def rot_z(deg):
        c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
        return Xf(((c, s, 0), (-s, c, 0), (0, 0, 1)))

    @staticmethod
    def euler_yxz(deg, origin=(0.0, 0.0, 0.0)):
        """Godot's Basis.from_euler(Vector3(x, y, z) degrees) with its default YXZ order: Ry * Rx * Rz."""
        r = Xf.rot_y(deg[1]) * Xf.rot_x(deg[0]) * Xf.rot_z(deg[2])
        return Xf(r.b, origin)

    @staticmethod
    def axis_angle(axis, deg):
        a = norm(axis)
        c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
        t = 1.0 - c
        x, y, z = a
        return Xf(((t * x * x + c, t * x * y + s * z, t * x * z - s * y),
                   (t * x * y - s * z, t * y * y + c, t * y * z + s * x),
                   (t * x * z + s * y, t * y * z - s * x, t * z * z + c)))

    @staticmethod
    def from_quat(q):
        """q = (x, y, z, w)."""
        x, y, z, w = q
        return Xf(((1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w)),
                   (2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w)),
                   (2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y))))

    @staticmethod
    def look(fwd, up=(0.0, 1.0, 0.0), origin=(0.0, 0.0, 0.0)):
        """A basis whose -z points along fwd and whose y is as close to up as possible (Godot's looking_at)."""
        z = norm(mul(fwd, -1.0))
        x = norm(cross(up, z))
        y = cross(z, x)
        return Xf((x, y, z), origin)


def frame(w, up=(0.0, 1.0, 0.0)):
    """Right-handed (u, v, w) with w the given direction and v as close to `up` as possible (u x v = w)."""
    w = norm(w)
    if abs(dot(w, norm(up))) > 0.999:
        up = (1.0, 0.0, 0.0)
    u = norm(cross(up, w))
    v = cross(w, u)
    return u, v, w


# --- the geometry store -------------------------------------------------------------------------------------------------
class ViewGeo(Geo):
    """Geo with a transform stack (every point is placed by the current transform before it is stored) and a weight
    function (static meshes weigh every vertex to one dummy bone)."""

    def __init__(self):
        super().__init__()
        self.xf = Xf()
        self._stack = []

    def v(self, p, w):
        q = self.xf.apply(p)
        return super().v(q, w if w else STATIC)

    def push(self, xf):
        self._stack.append(self.xf)
        self.xf = self.xf * xf

    def pop(self):
        self.xf = self._stack.pop()

    def styles(self):
        return sorted({f[1] for f in self.faces})


def _wf(wf):
    return wf if wf is not None else (lambda p: STATIC)


# --- 2D sections (counter-clockwise) ----------------------------------------------------------------------------------
def sect(n, rx, ry, power=2.0, phase_deg=0.0, ry_dn=None, rx_l=None, cx=0.0, cy=0.0, bulges=()):
    """n points of a superellipse (half widths rx right / rx_l left, ry up / ry_dn down) round (cx, cy), angle from +x
    toward +y. bulges: (angle_deg, half_width_deg, amount_m) push the outline outward round that angle (a thenar)."""
    e = 2.0 / power
    out = []
    for j in range(n):
        a = math.radians(phase_deg) + TAU * j / n
        ca, sa = math.cos(a), math.sin(a)
        rxx = rx if ca >= 0.0 or rx_l is None else rx_l
        ryy = ry if sa >= 0.0 or ry_dn is None else ry_dn
        x = rxx * math.copysign(abs(ca) ** e, ca)
        y = ryy * math.copysign(abs(sa) ** e, sa)
        for ang, half, amount in bulges:
            off = abs(((math.degrees(a) - ang) + 180.0) % 360.0 - 180.0)
            if off < half:
                k = 0.5 + 0.5 * math.cos(math.pi * off / half)
                d = norm((ca, sa, 0.0))
                x += d[0] * amount * k
                y += d[1] * amount * k
        out.append((cx + x, cy + y))
    return out


def rrect(w, yb, yt, rt, rb=None, seg_t=2, seg_b=None, cx=0.0, taper_top=1.0):
    """A rectangle from yb to yt, w wide (centred on cx), corners rounded by radius rt (top) / rb (bottom) with seg
    segments each (0: a sharp corner; 1: a chamfer). taper_top < 1 narrows the top edge. Counter-clockwise from the
    lower right corner; the point count is fixed by the segment counts."""
    rb = rt if rb is None else rb
    seg_b = seg_t if seg_b is None else seg_b
    hw = w * 0.5
    hwt = hw * taper_top
    out = []
    corners = ((cx + hw - rb, yb + rb, -90.0, rb, seg_b), (cx + hwt - rt, yt - rt, 0.0, rt, seg_t),
               (cx - hwt + rt, yt - rt, 90.0, rt, seg_t), (cx - hw + rb, yb + rb, 180.0, rb, seg_b))
    for ccx, ccy, a0, r, seg in corners:
        if seg <= 0 or r <= 0.0:
            ang = math.radians(a0 + 45.0)
            out.append((ccx + math.copysign(r, math.cos(ang)), ccy + math.copysign(r, math.sin(ang))))
            continue
        for k in range(seg + 1):
            a = math.radians(a0 + 90.0 * k / seg)
            out.append((ccx + r * math.cos(a), ccy + r * math.sin(a)))
    return out


def scale2(pts, sx, sy=None, cx=0.0, cy=0.0):
    sy = sx if sy is None else sy
    return [(cx + (p[0] - cx) * sx, cy + (p[1] - cy) * sy) for p in pts]


def inset2(poly, d):
    """The polygon moved inward by d along each corner's mitre (counter-clockwise polygon; small d only)."""
    out = []
    n = len(poly)
    for i in range(n):
        p = poly[i]
        a = poly[(i - 1) % n]
        b = poly[(i + 1) % n]
        e1 = norm((p[0] - a[0], p[1] - a[1], 0.0))
        e2 = norm((b[0] - p[0], b[1] - p[1], 0.0))
        n1 = (-e1[1], e1[0])
        n2 = (-e2[1], e2[0])
        m = (n1[0] + n2[0], n1[1] + n2[1])
        ml = math.hypot(m[0], m[1])
        m = (m[0] / ml, m[1] / ml) if ml > 1e-9 else n1
        k = d / max(m[0] * n1[0] + m[1] * n1[1], 0.35)
        out.append((p[0] + m[0] * k, p[1] + m[1] * k))
    return out


def area2(poly):
    s = 0.0
    for i in range(len(poly)):
        p, q = poly[i], poly[(i + 1) % len(poly)]
        s += p[0] * q[1] - q[0] * p[1]
    return 0.5 * s


def ccw(poly):
    return list(poly) if area2(poly) >= 0.0 else list(reversed(poly))


def place(pts2d, origin, u, v):
    return [add(origin, add(mul(u, p[0]), mul(v, p[1]))) for p in pts2d]


def ring_z(pts2d, z, dx=0.0, dy=0.0):
    """A section in the (x, y) plane at depth z."""
    return [(dx + p[0], dy + p[1], z) for p in pts2d]


def ring_y(pts2d, y, dx=0.0, dz=0.0):
    """A section in the (x, z) plane at height y (2D (a, b) = (x, -z) so counter-clockwise looks down from +y)."""
    return [(dx + p[0], y, dz - p[1]) for p in pts2d]


# --- triangulation --------------------------------------------------------------------------------------------------
def triangulate(pts2d):
    """Ear clipping of a simple polygon (counter-clockwise); index triples, counter-clockwise."""
    idx = list(range(len(pts2d)))
    if area2(pts2d) < 0.0:
        idx.reverse()
    out = []

    def is_convex(a, b, c):
        return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]) > 1e-14

    def inside(p, a, b, c):
        d1 = (p[0] - b[0]) * (a[1] - b[1]) - (a[0] - b[0]) * (p[1] - b[1])
        d2 = (p[0] - c[0]) * (b[1] - c[1]) - (b[0] - c[0]) * (p[1] - c[1])
        d3 = (p[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (p[1] - a[1])
        neg = d1 < 0 or d2 < 0 or d3 < 0
        pos = d1 > 0 or d2 > 0 or d3 > 0
        return not (neg and pos)
    guard = 0
    while len(idx) > 3 and guard < 10000:
        guard += 1
        found = False
        for k in range(len(idx)):
            i0, i1, i2 = idx[k - 1], idx[k], idx[(k + 1) % len(idx)]
            a, b, c = pts2d[i0], pts2d[i1], pts2d[i2]
            if not is_convex(a, b, c):
                continue
            if any(inside(pts2d[j], a, b, c) for j in idx if j not in (i0, i1, i2)):
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


def _cap_poly(g, ids, pts, normal, style, flip):
    """Ear-clipped cap over 3D points pts (ids already stored) facing `normal` (flip reverses)."""
    u, v, _w = frame(normal, (0.0, 1.0, 0.0) if abs(normal[1]) < 0.9 else (0.0, 0.0, -1.0))
    c = centroid(pts)
    flat = [(dot(sub(p, c), u), dot(sub(p, c), v)) for p in pts]
    for a, b, cc in triangulate(flat):
        tri = [ids[a], ids[b], ids[cc]]
        g.f(list(reversed(tri)) if flip else tri, style)


# --- primitives --------------------------------------------------------------------------------------------------------
def tube(g, rings, wf=None, style="gunmetal", cap0=None, cap1=None, closed=True):
    """Quads between consecutive rings (same point count). Rings are re-ordered once so that they run
    counter-clockwise about the travel direction (first ring centre -> last): every side face then points outward.
    cap0 / cap1: None (open), "flat" (fan from the ring centre), "poly" (ear clipping), or a 3D apex point.
    style: a material name or f(gap, j) -> name (None: no face). wf: f(world point) -> weights, or a list of weights
    dicts, one per ring (the caps take their ring's). Returns the ring vertex ids."""
    ring_w = wf if isinstance(wf, list) else None
    wf = _wf(None if ring_w is not None else wf)
    travel = sub(centroid([g.xf.apply(p) for p in rings[-1]]), centroid([g.xf.apply(p) for p in rings[0]]))
    probe = rings[0] if length(newell(rings[0])) > 1e-12 else rings[1]
    n0 = g.xf.dir(newell(probe))
    if dot(n0, travel) < 0.0:
        rings = [list(reversed(r)) for r in rings]
    if ring_w is not None:
        idx = [[g.v(p, ring_w[i]) for p in r] for i, r in enumerate(rings)]
        wf = None
    else:
        idx = [[g.v(p, wf(g.xf.apply(p))) for p in r] for r in rings]
    n = len(rings[0])
    cols = n if closed else n - 1
    for i in range(len(rings) - 1):
        for j in range(cols):
            k = (j + 1) % n
            st = style(i, j) if callable(style) else style
            if st is not None:
                g.f([idx[i][j], idx[i][k], idx[i + 1][k], idx[i + 1][j]], st)
    cst = style(-1, 0) if callable(style) else style
    cst_end = style(len(rings) - 1, 0) if callable(style) else style
    for which, cap, flip in ((0, cap0, True), (len(rings) - 1, cap1, False)):
        if cap is None:
            continue
        st = cst if which == 0 else cst_end
        if st is None:
            continue
        ring_pts = rings[which]
        ids = idx[which]
        if cap == "poly":
            world = [g.xf.apply(p) for p in ring_pts]
            nrm = norm(travel)
            # _cap_poly works in world space: store with an identity transform
            saved = g.xf
            g.xf = Xf()
            _cap_poly(g, ids, world, nrm, st, flip)
            g.xf = saved
            continue
        apex = centroid(ring_pts) if cap == "flat" else cap
        ai = g.v(apex, ring_w[which] if ring_w is not None else wf(g.xf.apply(apex)))
        for j in range(n):
            k = (j + 1) % n
            g.f([ai, ids[k], ids[j]] if flip else [ids[j], ids[k], ai], st)
    return idx


def lathe(g, profile, sides, origin=(0.0, 0.0, 0.0), axis=(0.0, 0.0, -1.0), up=(0.0, 1.0, 0.0), wf=None,
          style="gunmetal", scale=(1.0, 1.0), phase_deg=0.0, closed=False):
    """A [radius, height] profile turned about `axis` through origin with `sides` facets (elliptical by scale: u, v).
    Open: a silhouette from one end to the other (zero radius ends become apex points; others are left open unless
    they are the first/last point, which get a flat cap when the radius is > 0 and `closed` is "caps"). closed=True:
    the profile is a ring polygon (a hollow tube: outer wall, lips, bore). style may be f(gap, j)."""
    u, v, w = frame(axis, up)
    ph = math.radians(phase_deg)

    def ring(r, h):
        return [add(origin, add(mul(w, h), add(mul(u, math.cos(ph + TAU * j / sides) * r * scale[0]),
                                                mul(v, math.sin(ph + TAU * j / sides) * r * scale[1]))))
                for j in range(sides)]
    if closed is True:
        prof = [(float(r), float(h)) for r, h in profile]
        if area2(prof) < 0.0:
            prof.reverse()
        rings = [ring(r, h) for r, h in prof]
        wfn = _wf(wf)
        idx = [[g.v(p, wfn(g.xf.apply(p))) for p in rr] for rr in rings]
        m = len(prof)
        for i in range(m):
            i2 = (i + 1) % m
            st = style(i, 0) if callable(style) else style
            if st is None:
                continue
            for j in range(sides):
                k = (j + 1) % sides
                g.f([idx[i][j], idx[i][k], idx[i2][k], idx[i2][j]], st)
        return idx
    prof = [(float(r), float(h)) for r, h in profile]
    cap0 = cap1 = None
    if prof[0][0] <= 1e-9:
        cap0 = add(origin, mul(w, prof[0][1]))
        prof = prof[1:]
    elif closed == "caps":
        cap0 = "flat"
    if prof[-1][0] <= 1e-9:
        cap1 = add(origin, mul(w, prof[-1][1]))
        prof = prof[:-1]
    elif closed == "caps":
        cap1 = "flat"
    rings = [ring(r, h) for r, h in prof]
    if len(rings) == 1:
        rings = [rings[0], rings[0]]
    return tube(g, rings, wf, style, cap0, cap1)


def _map(axis, a, b, c):
    """(profile u, profile v, extrusion w) -> (x, y, z) as scripts/visual/view_mesh.gd _map: x: (w, v, u); y: (u, w,
    v); z: (u, v, w)."""
    if axis == "x":
        return (c, b, a)
    if axis == "y":
        return (a, c, b)
    return (a, b, c)


def slab(g, profile, width, bevel=0.0, axis="x", steps=1, wf=None, style="gunmetal", centre=0.0):
    """A profile polygon (u, v) extruded along `axis` over width (centred on `centre`), both faces bevelled by `bevel`
    in `steps` steps (1: a 45 degree chamfer; 2+: a rounded edge). Caps are ear-clipped (concave profiles work)."""
    prof = ccw([(float(p[0]), float(p[1])) for p in profile])
    hw = width * 0.5
    b = min(bevel, hw * 0.95)
    layers = []
    if b > 0.0:
        for k in range(steps + 1):
            th = (math.pi * 0.5) * k / steps
            layers.append((b * (1.0 - math.sin(th)), -hw + b * (1.0 - math.cos(th))))
        back = [(ins, -wv) for ins, wv in reversed(layers)]
        layers = layers + back
    else:
        layers = [(0.0, -hw), (0.0, hw)]
    rings = []
    for ins, wv in layers:
        poly = inset2(prof, ins) if ins > 0.0 else prof
        rings.append([_map(axis, p[0], p[1], wv + centre) for p in poly])
    return tube(g, rings, wf, style, "poly", "poly")


def box(g, centre, size, wf=None, style="gunmetal", bevel=0.0, steps=1):
    hx, hy, hz = size[0] * 0.5, size[1] * 0.5, size[2] * 0.5
    g.push(Xf.translate(centre))
    slab(g, [(-hz, -hy), (hz, -hy), (hz, hy), (-hz, hy)], size[0], bevel, "x", steps, wf, style)
    g.pop()


def sweep(g, path, section, wf=None, style="gunmetal", up=(1.0, 0.0, 0.0), cap0="flat", cap1="flat", scales=None):
    """A 2D section (u, v) carried along a polyline; v is kept as close to `up` as possible; scales: per point."""
    rings = []
    for i, p in enumerate(path):
        a = path[max(i - 1, 0)]
        b = path[min(i + 1, len(path) - 1)]
        u, v, _w = frame(sub(b, a), up)
        s = scales[i] if scales else 1.0
        rings.append(place([(q[0] * s, q[1] * s) for q in section], p, u, v))
    return tube(g, rings, wf, style, cap0, cap1)


# --- skinning (preview and checks) -----------------------------------------------------------------------------------
def skin_points(pos, wts, mats):
    """Linear blend skinning: mats[bone] = global pose * global rest^-1 (Xf)."""
    out = []
    for p, w in zip(pos, wts):
        acc = (0.0, 0.0, 0.0)
        for bone, k in w.items():
            acc = add(acc, mul(mats[bone].apply(p), k))
        out.append(acc)
    return out
