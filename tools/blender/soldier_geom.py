"""The legionary's skinned mesh as plain Python lists (no bpy), M2 AN2 item 1. Godot metres, +Y up, the soldier faces
-Z, his right is +X. Shape numbers: tools/blender/soldier_design.json; bone rests: soldier_data.rest_table().

build(design, lod, rests) -> Geo with
  pos[i]      vertex position (Godot)
  wts[i]      {bone: weight}, at most 4, normalized
  faces[k]    (vertex indices (3 or 4, counter-clockwise seen from outside), style, shade)
Every piece is its own set of vertices (plates do not share vertices), so normals smooth within a piece only and a
hard edge shows at every plate border; build_soldier.py adds sharp edges by angle inside a piece.

Winding convention of the ring helpers: a ring's points go round with angle a, x = cos a, z = sin a (so a = 270 deg
is the front, -Z); rings listed top to bottom along a profile (over the outside of the shape) give outward faces.
"""

import math

TAU = 2.0 * math.pi


# --- small vector helpers -------------------------------------------------------------------------------------------
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


def lerp(a, b, t):
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t)


def newell(pts):
    n = [0.0, 0.0, 0.0]
    for i in range(len(pts)):
        p, q = pts[i], pts[(i + 1) % len(pts)]
        n[0] += (p[1] - q[1]) * (p[2] + q[2])
        n[1] += (p[2] - q[2]) * (p[0] + q[0])
        n[2] += (p[0] - q[0]) * (p[1] + q[1])
    return tuple(n)


def centroid(pts):
    s = (0.0, 0.0, 0.0)
    for p in pts:
        s = add(s, p)
    return mul(s, 1.0 / len(pts))


def smoothstep(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0))) if e1 != e0 else (1.0 if x >= e1 else 0.0)
    return t * t * (3.0 - 2.0 * t)


# --- weights ----------------------------------------------------------------------------------------------------------
def normalize_weights(w: dict) -> dict:
    items = [(b, float(v)) for b, v in w.items() if v > 1e-4]
    items.sort(key=lambda bv: (-bv[1], bv[0]))
    items = items[:4]
    total = sum(v for _, v in items)
    return {b: v / total for b, v in items}


def rigid(bone):
    return lambda p: {bone: 1.0}


def chain(bones, blends):
    """Weights along a vertical chain: bones top to bottom, blends [(joint y, half width)] top to bottom."""
    def f(p):
        y = p[1]
        for k, (yj, h) in enumerate(blends):
            if y > yj + h:
                return {bones[k]: 1.0}
            if y >= yj - h:
                t = smoothstep(yj + h, yj - h, y)
                return {bones[k]: 1.0 - t, bones[k + 1]: t}
        return {bones[-1]: 1.0}
    return f


# --- geometry store -----------------------------------------------------------------------------------------------------
class Geo:
    def __init__(self):
        self.pos = []
        self.wts = []
        self.faces = []

    def v(self, p, w):
        self.pos.append((float(p[0]), float(p[1]), float(p[2])))
        self.wts.append(normalize_weights(w))
        return len(self.pos) - 1

    def f(self, idx, style, shade=0.5, away=None):
        """A face; `away` is a point the face must point away from (None keeps the given winding). Degenerate faces
        (no area) are dropped."""
        pts = [self.pos[i] for i in idx]
        n = newell(pts)
        if length(n) < 1e-9:
            return
        if away is not None and dot(n, sub(centroid(pts), away)) < 0.0:
            idx = list(reversed(idx))
        self.faces.append((tuple(idx), style, shade))

    def triangles(self):
        return sum(len(f[0]) - 2 for f in self.faces)


def ring(c, rx, rzf, rzb, n, power=2.0, phase=0.0, push=0.0, push_deg=0.0):
    """n points round centre c (x, y, z): superellipse of half widths rx and rz (front rzf toward -Z, back rzb).
    push moves the front point (a = 270 deg) forward: a centre ridge; push_deg > 0 spreads it over that sector."""
    pts = []
    e = 2.0 / power
    for j in range(n):
        a = phase + TAU * j / n
        ca, sa = math.cos(a), math.sin(a)
        x = rx * math.copysign(abs(ca) ** e, ca)
        rz = rzb if sa > 0.0 else rzf
        z = rz * math.copysign(abs(sa) ** e, sa)
        if push != 0.0:
            off = abs(((math.degrees(a) - 270.0) + 180.0) % 360.0 - 180.0)
            if off < 1e-6 or (push_deg > 0.0 and off < push_deg):
                z -= push * (1.0 - off / push_deg if push_deg > 0.0 else 1.0)
        pts.append((c[0] + x, c[1], c[2] + z))
    return pts


def angle_from_front(a):
    """Degrees between ring angle a (radians) and the front (a = 270 deg)."""
    return abs(((math.degrees(a) - 270.0) + 180.0) % 360.0 - 180.0)


def loft(g, rings, wf, style, shade=0.5, closed=True):
    """Quads between consecutive rings (top to bottom). style: a name or f(row, col) -> name or None (no face)."""
    idx = [[g.v(p, wf(p)) for p in r] for r in rings]
    n = len(rings[0])
    cols = n if closed else n - 1
    for i in range(len(rings) - 1):
        for j in range(cols):
            k = (j + 1) % n
            st = style(i, j) if callable(style) else style
            if st is not None:
                g.f([idx[i][j], idx[i][k], idx[i + 1][k], idx[i + 1][j]], st, shade)
    return idx


def cap(g, pts, wf, style, up, shade=0.5):
    """A fan over a closed ring, facing up (+Y) when up else down."""
    c = centroid(pts)
    ci = g.v(c, wf(c))
    idx = [g.v(p, wf(p)) for p in pts]
    n = len(pts)
    for j in range(n):
        k = (j + 1) % n
        g.f([ci, idx[k], idx[j]] if up else [ci, idx[j], idx[k]], style, shade)


def prism(g, outline, axis_o, axis_d, depth, wf, style, shade=0.5, cap_far=True, cap_near=False, inset=0.0):
    """An outline (list of 3D points on a plane through axis_o) extruded by depth along axis_d; faces point away from
    the prism's middle. inset shrinks the far cap toward its centre (a chamfer)."""
    d = norm(axis_d)
    near = list(outline)
    c0 = centroid(near)
    far = [add(lerp(p, c0, inset), mul(d, depth)) for p in near]
    mid = add(c0, mul(d, depth * 0.5))
    ni = [g.v(p, wf(p)) for p in near]
    fi = [g.v(p, wf(p)) for p in far]
    n = len(near)
    for j in range(n):
        k = (j + 1) % n
        g.f([ni[j], ni[k], fi[k], fi[j]], style, shade, away=mid)
    for pts, cap_it, idx in ((far, cap_far, fi), (near, cap_near, ni)):
        if not cap_it:
            continue
        cc = centroid(pts)
        ci = g.v(cc, wf(cc))
        for j in range(n):
            k = (j + 1) % n
            g.f([ci, idx[j], idx[k]], style, shade, away=mid)


def box(g, centre, size, wf, style, shade=0.5, chamfer=0.25):
    """A box with chamfered vertical edges (8-sided outline, flat caps); chamfer 0: a plain box."""
    hx, hy, hz = size[0] * 0.5, size[1] * 0.5, size[2] * 0.5
    cut = min(hx, hz) * chamfer
    out = [(hx - cut, -hz), (hx, -hz + cut), (hx, hz - cut), (hx - cut, hz), (-hx + cut, hz), (-hx, hz - cut), (-hx, -hz + cut), (-hx + cut, -hz)]
    if chamfer <= 0.0:
        out = [(hx, -hz), (hx, hz), (-hx, hz), (-hx, -hz)]
    base = [(centre[0] + x, centre[1] - hy, centre[2] + z) for x, z in out]
    prism(g, base, base[0], (0.0, 1.0, 0.0), size[1], wf, style, shade, cap_far=True, cap_near=True)


# --- the soldier ------------------------------------------------------------------------------------------------------
class Soldier:
    def __init__(self, design, lod, rests):
        self.D = design
        self.L = design["lods"][lod]
        self.lod = lod
        self.R = {name: at for name, _parent, at in rests}
        self.g = Geo()

    def detail(self):
        return bool(self.L["detail"])

    def build(self):
        self.counts = {}

        def run(name, fn, *args):
            before = self.g.triangles()
            fn(*args)
            self.counts[name] = self.counts.get(name, 0) + self.g.triangles() - before
        run("helmet", self.helmet)
        run("neck", self.neck)
        run("torso", self.torso)
        run("cape", self.cape)
        for s in (1, -1):
            run("pauldrons", self.pauldron, s)
            run("arms", self.arm, s)
            run("hands", self.hand, s)
            run("legs", self.leg, s)
            run("boots", self.boot, s)
            run("tassets", self.tasset, s)
        run("pteruges", self.pteruges)
        return self.g

    # ---------------------------------------------------------------- helmet (Head, rigid)
    def helmet(self):
        H = self.D["helmet"]
        g = self.g
        n = int(self.L["helmet_n"])
        w = rigid("Head")
        cy, rx, ry, rz = H["centre_y"], H["rx"], H["ry"], H["rz"]
        lats = H["bowl_lat_deg"] if self.detail() else [0, 40, 70, 90]
        # Bowl: an ellipsoid cap from the crown down to its equator; the crown is a fan.
        rings = []
        for lat in lats[1:]:
            phi = math.radians(lat)
            rings.append(ring((0.0, cy + ry * math.cos(phi), 0.0), rx * math.sin(phi), rz * math.sin(phi), rz * math.sin(phi), n))
        top = (0.0, cy + ry, 0.0)
        ti = g.v(top, w({}))
        idx = loft(g, rings, w, "steel", 0.55)
        for j in range(n):
            k = (j + 1) % n
            g.f([ti, idx[0][k], idx[0][j]], "steel", 0.55, away=(0.0, cy, 0.0))
        # Lower shell: the full-face mask in front (visor glass above the energy slit, dark steel below, a chin
        # ridge), tapering in toward the jaw; cheek guards and the neck guard are plates laid over it.
        lower = H["lower"]
        lrings = []
        for i, (y, lrx, lzf, lzb) in enumerate(lower if self.detail() else lower[:4] + lower[-1:]):
            r = ring((0.0, y, 0.0), lrx, lzf, lzb, n, push=H["face_ridge"] if i >= 3 else 0.0)
            if i in (1, 2):
                for j in range(n):
                    if angle_from_front(TAU * j / n) <= H["slit_deg"]:
                        k = 1.0 - H["slit_recess"] / max(1e-6, math.hypot(r[j][0], r[j][2]))
                        r[j] = (r[j][0] * k, r[j][1], r[j][2] * k)
            lrings.append(r)

        def lower_style(i, j):
            off = angle_from_front(TAU * (j + 0.5) / n)
            if i == 1 and off <= H["slit_deg"]:
                return "glow"
            if i == 1 and off <= H["slit_deg"] + 14:
                return "face"
            if off <= H["face_deg"]:
                return "steel_dark"
            return "steel_dark" if off >= H["cheek_deg"] else "steel"
        loft(g, lrings, w, lower_style, 0.5)
        # The T's stem: a short vertical energy slot on the mask's centre line under the slit.
        Na = H["nasal"]
        y0, y1 = Na["y"]
        z0 = -(lower[2][2] - H["slit_recess"]) - Na["proud"]
        z1 = -(lower[3][2] + H["face_ridge"]) - Na["proud"]
        hw = Na["half_w"]
        rows = [[(-hw, y0, z0 + 0.0015), (0.0, y0, z0), (hw, y0, z0 + 0.0015)], [(-hw, y1, z1 + 0.0015), (0.0, y1, z1), (hw, y1, z1 + 0.0015)]]
        ni = [[g.v(p, w(p)) for p in r] for r in rows]
        for q in range(2):
            mid = centroid([rows[0][q], rows[1][q + 1]])
            g.f([ni[0][q], ni[0][q + 1], ni[1][q + 1], ni[1][q]], "glow", 0.5, away=(mid[0], mid[1], 0.0))
        if self.detail():
            sy, srx, szf, szb = H["seal"]
            seal = ring((0.0, sy, 0.0), srx, szf, szb, n)
            loft(g, [lrings[-1], seal], w, "suit", 0.4)

        def shell(y, d, out):
            """A point on the lower shell at height y, d degrees from the front toward +x, pushed out by `out`."""
            rows = lower
            for (y0, a0, f0, b0), (y1, a1, f1, b1) in zip(rows, rows[1:]):
                if y1 <= y <= y0:
                    t = (y0 - y) / (y0 - y1)
                    lrx, lzf, lzb = a0 + (a1 - a0) * t, f0 + (f1 - f0) * t, b0 + (b1 - b0) * t
                    break
            else:
                _, lrx, lzf, lzb = rows[-1] if y < rows[-1][0] else rows[0]
            a = math.radians(270.0 + d)
            ca, sa = math.cos(a), math.sin(a)
            p = (lrx * ca, y, (lzb if sa > 0 else lzf) * sa)
            nrm = norm((p[0] / (lrx * lrx), 0.0, p[2] / ((lzb if sa > 0 else lzf) ** 2)))
            return add(p, mul(nrm, out))

        def plate(rows, style, cols, edge=None, mirror=1):
            """rows: [(y, d0, d1, out)] top to bottom, columns from d0 to d1 (degrees from the front). edge: a style
            for a border strip along the front column and the bottom row (the cheek guards' bronze edge). The bottom
            edge turns in by plate_lip (the plate's thickness) in the near LOD."""
            if edge is not None and self.detail():
                ey, ed = H["edge_m"], H["edge_deg"]
                y1, a1, b1, o1 = rows[-2]
                y2, a2, b2, o2 = rows[-1]
                t = ey / (y1 - y2)
                rows = rows[:-1] + [(y2 + ey, a2 + (a1 - a2) * t, b2 + (b1 - b2) * t, o2 + (o1 - o2) * t), rows[-1]]
                e = ed / max(1.0, rows[0][2] - rows[0][1])
                fracs = [0.0] + [e + (1.0 - e) * q / cols for q in range(cols + 1)]
            else:
                fracs = [q / cols for q in range(cols + 1)]
            grid = [[shell(y, mirror * (d0 + (d1 - d0) * f), out) for f in fracs] for y, d0, d1, out in rows]
            if self.detail():
                y, d0, d1, out = rows[-1]
                grid.append([shell(y + 0.004, mirror * (d0 + (d1 - d0) * f), out - H["plate_lip"]) for f in fracs])
            idx = [[g.v(p, w(p)) for p in row] for row in grid]
            nr = len(rows)
            for r in range(len(grid) - 1):
                for q in range(len(fracs) - 1):
                    quad = [idx[r][q], idx[r][q + 1], idx[r + 1][q + 1], idx[r + 1][q]]
                    if r < nr - 1:
                        st = edge if edge is not None and self.detail() and (q == 0 or r == nr - 2) else style
                        g.f(quad, st, 0.5, away=(0.0, g.pos[idx[r][q]][1], 0.0))
                    else:
                        mid = centroid([g.pos[i] for i in quad])
                        g.f(quad, "steel_dark", 0.4, away=(mid[0], mid[1] + 0.05, mid[2]))
        # Cheek guards: wide under the brow, narrowing forward and down to the jaw, bronze-edged.
        cheek = [tuple(r) for r in H["cheek_rows"]]
        cols = int(H["plate_cols"]) if self.detail() else 2
        for side in (1, -1):
            plate(cheek, "steel", cols, edge="bronze", mirror=side)
        # Neck guard: two flared lames across the back, the lower one sweeping out over the collar.
        for lame in H["neck_lames"]:
            plate([tuple(r) for r in lame], "steel", int(H["plate_cols"]) + 1 if self.detail() else 3)
        # Brow band (bronze tier trim) over the bowl's lower edge, ridged forward.
        B = H["brow"]
        brings = []
        pairs = list(zip(B["y"], B["out"]))
        for y, out in (pairs[1:] if self.detail() else pairs[1:3]):
            t = max(0.0, 1.0 - ((y - cy) / ry) ** 2)
            s = math.sqrt(t)
            brings.append(ring((0.0, y, 0.0), rx * s + out, rz * s + out, rz * s + out, n, push=B["ridge"] if out > 0 else 0.0))
        brings.reverse()  # top to bottom
        loft(g, brings, w, "trim", 0.5)
        if self.detail() and int(H["ear"]["sides"]) > 0:
            E = H["ear"]
            for side in (1, -1):
                base = shell(E["y"], side * E["deg"], E["out"] - 0.006)
                nrm = norm(sub(shell(E["y"], side * E["deg"], E["out"] + 0.01), base))
                tan = norm(cross((0.0, 1.0, 0.0), nrm))
                pts = []
                for j in range(E["sides"]):
                    a = TAU * j / E["sides"]
                    pts.append(add(base, add(mul((0.0, 1.0, 0.0), E["r"] * math.cos(a)), mul(tan, E["r"] * math.sin(a)))))
                prism(g, pts, pts[0], nrm, E["depth"] + 0.006, w, "bronze", 0.6, inset=0.3)
        self.crest(w)

    def crest(self, w):
        H = self.D["helmet"]
        C = H["crest"]
        g = self.g
        cy, ry, rz = H["centre_y"], H["ry"], H["rz"]
        m = int(self.L["crest_stations"])
        z0, z1 = C["z"]

        def surface(z):
            return cy + ry * math.sqrt(max(0.0, 1.0 - (z / rz) ** 2))

        def height(z):
            half = max(C["peak_z"] - z0, z1 - C["peak_z"])
            t = (z - C["peak_z"]) / half
            return max(C["end_height"], C["height"] * math.sqrt(max(0.0, 1.0 - t * t)))
        holder, crest = [], []
        for k in range(m):
            z = z0 + (z1 - z0) * k / (m - 1)
            base = surface(z)
            hw, hh = C["holder_w"] * 0.5, C["holder_h"]
            holder.append([(-hw, base - 0.01, z), (0.0, base + hh, z), (hw, base - 0.01, z)])
            top = min(C["top"], base + hh + height(z))
            bw, tw = C["base_w"] * 0.5, C["top_w"] * 0.5
            crest.append([(-bw, base + hh * 0.6, z), (-tw, top, z), (tw, top, z), (bw, base + hh * 0.6, z)])
        for stations, style, shade in ((holder, "bronze", 0.5), (crest, "crest", 0.5)):
            idx = [[g.v(p, w(p)) for p in st] for st in stations]
            for k in range(m - 1):
                for j in range(len(stations[0]) - 1):
                    pts = [idx[k][j], idx[k][j + 1], idx[k + 1][j + 1], idx[k + 1][j]]
                    mid = ((0.0, stations[k][0][1] - 0.02, stations[k][0][2]))
                    g.f(pts, style, shade, away=mid)
            for k, nb in ((0, 1), (m - 1, m - 2)):
                ref = centroid(stations[nb])
                g.f(list(idx[k]), style, shade, away=ref)

    # ---------------------------------------------------------------- neck (Neck)
    def neck(self):
        """Round 2: a flexible neck seal (bellows) from inside the gorget up into the helmet: the bottom ring rides the
        Chest, the top ones the Head, blended between, so the helmet (locked on the hitbox) never parts from the body.
        Rings above the head box's clearance floor are dominantly Head: they count as helmet (inside the shell)."""
        n = max(6, int(self.L["limb_n"]))
        N = self.D["neck"]
        rows = N["rings"] if self.detail() else [N["rings"][0], N["rings"][1], N["rings"][-1]]
        rings = [ring((0.0, y, 0.0), rx, zf, zb, n) for y, rx, zf, zb, _h in rows]
        heads = {round(r[0], 4): r[4] for r in rows}

        def wf(p):
            h = heads[round(p[1], 4)]
            return {"Head": h, "Chest": 1.0 - h}
        rings.reverse()  # top (in the helmet) to bottom (in the gorget)
        loft(self.g, rings, wf, "suit", 0.35)

    # ---------------------------------------------------------------- torso
    def torso(self):
        T = self.D["torso"]
        g = self.g
        n = int(self.L["torso_n"])
        p = T["power"]
        chest = rigid("Chest")
        # Gorget ring.
        gor = T["gorget"] if self.detail() else T["gorget"][2:]
        loft(g, [ring((0.0, y, 0.0), rx, zf, zb, int(T["gorget_n"])) for y, rx, zf, zb in gor], chest, "steel_dark", 0.45)
        # Chest: deep, ridged down the middle, its lower edge turned in (the last ring).
        rows = T["chest"] if self.detail() else T["chest"][:-1]
        rings = []
        for i, (y, rx, zf, zb) in enumerate(rows):
            ridge = T["chest_ridge"] if 1 <= i <= 4 else 0.0
            rings.append(ring((0.0, y, 0.0), rx, zf, zb, n, power=p, push=ridge))
        loft(g, rings, chest, "steel", 0.55)
        # Girdle bands, upper ones on the Chest, lower on the Spine; each tucks under the one above.
        nb = int(self.L["band_n"])
        for band in T["bands"]:
            rows = band["rings"] if (self.detail() and band.get("lip", False)) else band["rings"][:2]
            rings = [ring((0.0, y, 0.0), rx, zf, zb, nb, power=p, push=T["band_ridge"] if i < 2 else 0.0) for i, (y, rx, zf, zb) in enumerate(rows)]
            loft(g, rings, rigid(band["bone"]), band["style"], 0.5)
        # Belt (Hips) with its bronze buckle.
        rows = T["belt"][:3]
        loft(g, [ring((0.0, y, 0.0), rx, zf, zb, nb, power=p) for y, rx, zf, zb in rows], rigid("Hips"), "leather", 0.5)
        bk = T["buckle"]
        zf = T["belt"][1][2]
        self._front_plate((0.0, bk["y"], -zf - 0.006), bk["w"], bk["h"], bk["depth"], rigid("Hips"), "trim", 6 if self.detail() else 4)
        em = T["emblem"]
        self._front_plate((0.0, em["y"], -T["chest"][2][2] - T["chest_ridge"] - 0.006), em["w"], em["h"], em["depth"], chest, "trim",
                          6 if self.detail() else 4)
        # Back power cell, two short energy lines on its back.
        c = T["cell"]
        hw, hh, ch = c["w"] * 0.5, c["h"] * 0.5, c["chamfer"]
        outline = [(-hw + ch, -hh), (hw - ch, -hh), (hw, -hh + ch), (hw, hh - ch), (hw - ch, hh), (-hw + ch, hh), (-hw, hh - ch), (-hw, -hh + ch)]
        z0, z1, z2 = c["z"]
        rings = []
        for z, k in ((z0, 1.0), (z1, 1.0), (z2, 0.86)):
            rings.append([(x * k, c["y"] + y * k, z) for x, y in outline])
        idx = [[g.v(q, chest(q)) for q in r] for r in rings]
        mid = (0.0, c["y"], z0)
        for i in range(2):
            for j in range(8):
                k = (j + 1) % 8
                g.f([idx[i][j], idx[i][k], idx[i + 1][k], idx[i + 1][j]], "steel_dark", 0.45, away=mid)
        cc = (0.0, c["y"], z2)
        ci = g.v(cc, chest(cc))
        for j in range(8):
            g.f([ci, idx[2][j], idx[2][(j + 1) % 8]], "steel_dark", 0.45, away=mid)
        zg = z2 + c["glow_proud"]
        for sx in (-1, 1):
            x0, x1 = sx * c["glow_x"] - c["glow_w"] * 0.5, sx * c["glow_x"] + c["glow_w"] * 0.5
            y0, y1 = c["y"] - c["glow_h"] * 0.5, c["y"] + c["glow_h"] * 0.5
            q = [g.v(pt, chest(pt)) for pt in ((x0, y0, zg), (x1, y0, zg), (x1, y1, zg), (x0, y1, zg))]
            g.f(q, "glow", 0.5, away=(0.0, c["y"], 0.0))

    def _front_plate(self, centre, w, h, depth, wf, style, sides):
        """A plate on the body's front: a rounded polygon facing -Z, depth thick (backs into the body)."""
        pts = []
        for j in range(sides):
            a = TAU * (j + 0.5) / sides
            pts.append((centre[0] + 0.5 * w * math.cos(a), centre[1] + 0.5 * h * math.sin(a), centre[2] + depth))
        prism(self.g, pts, pts[0], (0.0, 0.0, -1.0), depth, wf, style, 0.6, inset=0.18)

    # ---------------------------------------------------------------- cape (squad colour, sways)
    def cape(self):
        C = self.D["cape"]
        g = self.g
        cols, rows = int(self.L["cape_cols"]), int(self.L["cape_rows"])
        zs = C["z"]

        def z_at(y):
            for (y0, z0), (y1, z1) in zip(zs, zs[1:]):
                if y1 <= y <= y0:
                    return z0 + (z1 - z0) * (y0 - y) / (y0 - y1)
            return zs[-1][1] if y < zs[-1][0] else zs[0][1]

        def wf(p):
            y = p[1]
            if y >= 1.25:
                return {"Chest": 1.0}
            if y >= 1.05:
                t = smoothstep(1.25, 1.05, y)
                return {"Chest": 1.0 - t, "Spine": t}
            t = smoothstep(1.05, 0.8, y) * 0.5
            return {"Spine": 1.0 - t, "Hips": t}
        f0, f1 = C["fold"]
        grid, inner = [], []
        for r in range(rows + 1):
            t = r / rows
            y = C["top_y"] + (C["bottom_y"] - C["top_y"]) * t
            half = C["top_half_w"] + (C["bottom_half_w"] - C["top_half_w"]) * t
            fold = f0 + (f1 - f0) * t
            row, row_in = [], []
            for c in range(cols + 1):
                u = -1.0 + 2.0 * c / cols
                x = half * u
                base = z_at(y) - C["wrap"] * u * u * (1.0 - 0.7 * t)
                zig = 0.0 if c in (0, cols) else (fold if c % 2 else -fold) * 0.5
                row.append((x, y, base + zig))
                row_in.append((x, y, base - fold * 0.5 - 0.003))
            grid.append(row)
            inner.append(row_in)
        front = [[g.v(p, wf(p)) for p in row] for row in grid]
        for r in range(rows):
            for c in range(cols):
                a, b = grid[r][c], grid[r + 1][c + 1]
                ref = (0.0, (a[1] + b[1]) * 0.5, z_at((a[1] + b[1]) * 0.5) - 0.3)
                quad = [front[r][c], front[r][c + 1], front[r + 1][c + 1], front[r + 1][c]]
                g.f(quad, "cape", 0.5, away=ref)
        # The inside (seen between the legs and from the side): a coarser sheet just in front of the folds.
        step = max(1, cols // int(self.L["cape_inner_cols"]))
        cs = list(range(0, cols + 1, step))
        if cs[-1] != cols:
            cs.append(cols)
        back = [[g.v(row[c], wf(row[c])) for c in cs] for row in inner]
        for r in range(rows):
            for k in range(len(cs) - 1):
                a = inner[r][cs[k]]
                ref_in = (0.0, a[1], z_at(a[1]) + 0.3)
                quad = [back[r][k], back[r + 1][k], back[r + 1][k + 1], back[r][k + 1]]
                g.f(quad, "cape", 0.5, away=ref_in)

    # ---------------------------------------------------------------- pauldrons
    def pauldron(self, s):
        P = self.D["pauldron"]
        g = self.g
        side = "Right" if s > 0 else "Left"
        cx, cy, cz = P["centre"]
        c = (s * cx, cy, cz)
        rx, ry, rz = P["r"]
        def weights(arm_share):
            """The lame hangs from the cuirass: arm_share of it follows the upper arm, less toward the neck."""
            def f(p):
                t = arm_share * (1.0 - smoothstep(P["chest_from_x"], P["chest_to_x"], abs(p[0])))
                return {side + "UpperArm": t, "Chest": 1.0 - t}
            return f

        def at(theta, phi, k):
            """A dome over the shoulder, pole up: theta latitude (0 = level with the centre, 90 = the top, never
            past it), phi azimuth from straight out (0) round the front (-) and the back (+); past 90 it wraps in
            toward the neck."""
            return (c[0] + s * rx * k * math.cos(theta) * math.cos(phi), c[1] + ry * k * math.sin(theta), c[2] + rz * k * math.cos(theta) * math.sin(phi))
        bands = P["bands"] if self.detail() else P["bands"][:2]
        for b in bands:
            th0, th1 = (math.radians(t) for t in b["theta_deg"])
            k = b["scale"]
            rows = int(b["rows"]) if self.detail() else 1
            phim = math.radians(b["phi_deg"])
            cols = int(b["cols"]) if self.detail() else max(3, int(b["cols"]) - 3)
            wf = weights(float(b["arm"]))
            grid = []
            flare = float(b.get("flare", 0.0))
            for r in range(rows + 1):
                th = th1 + (th0 - th1) * r / rows  # top to bottom
                kk = k * (1.0 + flare * r / rows)  # each lame flares out toward its lower edge
                grid.append([at(th, -phim + 2.0 * phim * q / cols, kk) for q in range(cols + 1)])
            # the rim: the lower edge turned in by the plate's thickness
            lip = [at(th0, -phim + 2.0 * phim * q / cols, k * (1.0 + flare) - P["lip"] / rx) for q in range(cols + 1)]
            lip = [(p[0], p[1] + 0.004, p[2]) for p in lip]
            idx = [[g.v(p, wf(p)) for p in row] for row in grid + [lip]]
            field_row = int(b.get("field_row", -1)) if self.detail() else (0 if "field_row" in b else -1)
            for r in range(rows + 1):
                for q in range(cols):
                    quad = [idx[r][q], idx[r][q + 1], idx[r + 1][q + 1], idx[r + 1][q]]
                    if r < rows:
                        st = b["style"]
                        if r == field_row:  # the squad field: an inset stripe, bronze at its ends
                            st = "bronze" if q in (0, cols - 1) else "squad_plate"
                        g.f(quad, st, 0.5, away=c)
                    else:
                        mid = centroid([g.pos[i] for i in quad])
                        g.f(quad, b["rim"], 0.5, away=(mid[0], mid[1] + 0.05, mid[2]))
            if b.get("two_sided", False):
                # the underside, seen from the far side and when the arm is raised (the plate's inner face)
                inner = [[lerp(p, c, P["lip"] / rx) for p in row] for row in (grid[0], grid[-1])]
                ii = [[g.v(p, wf(p)) for p in row] for row in inner]
                for r in range(1):
                    for q in range(cols):
                        quad = [ii[r][q], ii[r + 1][q], ii[r + 1][q + 1], ii[r][q + 1]]
                        mid = centroid([g.pos[i] for i in quad])
                        g.f(quad, "steel_dark", 0.4, away=add(mid, mul(norm(sub(mid, c)), 0.1)))

    # ---------------------------------------------------------------- arms
    def _arm_axis(self, s):
        side = "Right" if s > 0 else "Left"
        S, E, H = self.R[side + "UpperArm"], self.R[side + "ForeArm"], self.R[side + "Hand"]
        top = (S[0] - s * 0.005, 1.6, S[2])
        return side, [top, S, E, H]

    @staticmethod
    def _axis_at(points, y):
        for a, b in zip(points, points[1:]):
            if b[1] <= y <= a[1]:
                t = (a[1] - y) / (a[1] - b[1]) if a[1] != b[1] else 0.0
                return lerp(a, b, t)
        return points[-1] if y < points[-1][1] else points[0]

    def arm(self, s):
        A = self.D["arm"]
        g = self.g
        n = int(self.L["limb_n"])
        side, axis = self._arm_axis(s)
        wf = chain(["Chest", side + "UpperArm", side + "ForeArm", side + "Hand"], A["blend"])
        tube = A["tube"] if self.detail() else [A["tube"][0], A["tube"][2], A["tube"][4], A["tube"][-1]]
        rings = [ring(self._axis_at(axis, y), r, r, r, n, phase=math.pi / n) for y, r in tube]
        loft(g, rings, wf, "suit", 0.45)
        # Rerebrace: a steel wrap on the upper arm between the spaulder and the elbow (gives the arm volume).
        if self.detail():
            loft(g, [ring(self._axis_at(axis, y), r, r * 1.05, r, n, phase=math.pi / n) for y, r in A["rerebrace"]], rigid(side + "UpperArm"), "steel", 0.5)
        E = self.R[side + "ForeArm"]
        # Elbow cap behind the joint, half on each side of it.
        ec = A["elbow_cap"]
        if self.detail():
            cc = (E[0], E[1], E[2] + ec["back"] * 0.4)
            m = 6
            ring1 = [(cc[0] + ec["r"][0] * math.cos(TAU * j / m), cc[1] + ec["r"][1] * math.sin(TAU * j / m), cc[2] + ec["r"][2] * 0.55) for j in range(m)]
            tip = (cc[0], cc[1], cc[2] + ec["r"][2])
            elbow_w = lambda p: {side + "UpperArm": 0.45, side + "ForeArm": 0.55}
            ti = g.v(tip, elbow_w(tip))
            ri = [g.v(p, elbow_w(p)) for p in ring1]
            base = [g.v((p[0] * 0.9 + cc[0] * 0.1, p[1] * 0.9 + cc[1] * 0.1, cc[2] - 0.01), elbow_w(p)) for p in ring1]
            for j in range(m):
                k = (j + 1) % m
                g.f([ti, ri[j], ri[k]], "steel_dark", 0.5, away=cc)
                g.f([ri[j], base[j], base[k], ri[k]], "steel_dark", 0.5, away=(cc[0], cc[1], cc[2] - 0.02))
        # Vambrace (steel) and its bronze band, rigid on the forearm.
        fw = rigid(side + "ForeArm")
        vb = A["vambrace"] if self.detail() else A["vambrace"][1:3]
        loft(g, [ring(self._axis_at(axis, y), r * 1.0, r * 1.08, r * 0.95, n, phase=math.pi / n) for y, r in vb], fw, "steel", 0.55)
        if self.detail():
            loft(g, [ring(self._axis_at(axis, y), r, r * 1.08, r * 0.95, n, phase=math.pi / n) for y, r in A["band"]], fw, "bronze", 0.55)
        # Glove cuff (both LODs: it joins the forearm to the fist).
        loft(g, [ring(self._axis_at(axis, y), r, r, r, n, phase=math.pi / n) for y, r in A["cuff"]],
             lambda p: {side + "Hand": 0.8, side + "ForeArm": 0.2} if p[1] > 0.88 else {side + "Hand": 1.0}, "steel_dark", 0.45)

    def hand(self, s):
        A = self.D["arm"]
        g = self.g
        side = "Right" if s > 0 else "Left"
        H = self.R[side + "Hand"]
        hw = rigid(side + "Hand")
        if not self.detail():
            box(g, (H[0] + s * 0.008, H[1], H[2] - 0.01), A["far_fist"], hw, "steel_dark", 0.5)
            return
        hb = A["hand_back"]
        box(g, (H[0] + s * hb["at"][0], H[1] + hb["at"][1], H[2] + hb["at"][2]), hb["size"], hw, "steel_dark", 0.5)
        self._bar(A["fingers"], H, s, rigid(side + "Fingers"), "suit", 0.5)
        self._bar(A["thumb"], H, s, hw, "suit", 0.45)

    def _bar(self, F, H, s, wf, style, shade):
        """A rectangular bar along a bent path (hand-relative [x, y, z], x mirrored by side), half_t thick across
        the path in the x-z plane, half_h tall in y; the far end capped (finger block bent at the knuckle, thumb)."""
        g = self.g
        path = [(H[0] + s * p[0], H[1] + p[1], H[2] + p[2]) for p in F["path"]]
        stations = []
        for k, c in enumerate(path):
            a = path[max(0, k - 1)]
            b = path[min(len(path) - 1, k + 1)]
            d = norm((b[0] - a[0], 0.0, b[2] - a[2]))
            t = (d[2], 0.0, -d[0])  # across the path, in the x-z plane
            ht, hh = F["half_t"], F["half_h"]
            stations.append([add(c, add(mul(t, sx * ht), (0.0, sy * hh, 0.0))) for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1))])
        idx = [[g.v(p, wf(p)) for p in st] for st in stations]
        for k in range(len(stations) - 1):
            mid = centroid(stations[k] + stations[k + 1])
            for j in range(4):
                jj = (j + 1) % 4
                g.f([idx[k][j], idx[k][jj], idx[k + 1][jj], idx[k + 1][j]], style, shade, away=mid)
        g.f(list(idx[-1]), style, shade, away=centroid(stations[-2]))

    # ---------------------------------------------------------------- legs
    def _leg_axis(self, s):
        side = "Right" if s > 0 else "Left"
        Hp, K = self.R[side + "UpperLeg"], self.R[side + "LowerLeg"]
        ank = self.D["leg"]["ankle"]
        A = (K[0], ank[1], ank[2])
        top = (Hp[0], 1.1, Hp[2])
        return side, [top, Hp, K, A, (A[0], 0.0, A[2])]

    def leg(self, s):
        Lg = self.D["leg"]
        g = self.g
        n = int(self.L["limb_n"])
        side, axis = self._leg_axis(s)
        wf = chain(["Hips", side + "UpperLeg", side + "LowerLeg", side + "Foot"], Lg["blend"])
        tube = Lg["tube"] if self.detail() else [Lg["tube"][0], Lg["tube"][2], Lg["tube"][4], Lg["tube"][-1]]
        loft(g, [ring(self._axis_at(axis, y), rx, rz, rz, n, phase=math.pi / n) for y, rx, rz in tube], wf, "suit", 0.45)

        def radius_at(y):
            t = Lg["tube"]
            for (y0, rx0, rz0), (y1, rx1, rz1) in zip(t, t[1:]):
                if y1 <= y <= y0:
                    u = (y0 - y) / (y0 - y1)
                    return rx0 + (rx1 - rx0) * u, rz0 + (rz1 - rz0) * u
            return t[-1][1], t[-1][2]

        def arc(y, out, deg0, deg1, cols, extra_back=0.0, ridge=0.0):
            c = self._axis_at(axis, y)
            rx, rz = radius_at(y)
            pts = []
            for q in range(cols + 1):
                d = deg0 + (deg1 - deg0) * q / cols  # degrees from the front, toward the outside (+)
                a = math.radians(270.0 + d * s)
                ca, sa = math.cos(a), math.sin(a)
                rzz = rz + out + (extra_back if sa > 0 else 0.0)
                p = (c[0] + (rx + out) * ca, y, c[2] + rzz * sa)
                if abs(d) < 1e-6:
                    p = (p[0], p[1], p[2] - ridge)
                pts.append(p)
            if s < 0:
                pts.reverse()
            return pts
        # Cuisse: front and outside of the thigh.
        Cu = Lg["cuisse"]
        cols = int(Cu["cols"]) if self.detail() else 4
        rows = Cu["rows"] if self.detail() else [Cu["rows"][0], Cu["rows"][-1]]
        grid = [arc(y, Cu["out"], Cu["deg"][0], Cu["deg"][1], cols) for y in rows]
        uw = rigid(side + "UpperLeg")
        idx = [[g.v(p, uw(p)) for p in row] for row in grid]
        for r in range(len(grid) - 1):
            for q in range(cols):
                quad = [idx[r][q], idx[r][q + 1], idx[r + 1][q + 1], idx[r + 1][q]]
                mid = centroid([g.pos[i] for i in quad])
                ax = self._axis_at(axis, mid[1])
                g.f(quad, "steel" if r < len(rows) - 1 else "steel_dark", 0.55, away=ax if r < len(rows) - 1 else (mid[0], mid[1] + 0.05, mid[2]))
        # Knee cop (poleyn), half on each side of the joint, a bronze stud on it.
        K = self.R[side + "LowerLeg"]
        kn = Lg["knee"]
        kc = (K[0], K[1], K[2] - kn["front"] + kn["r"][2] * 0.4)
        kw = lambda p: {side + "LowerLeg": 0.6, side + "UpperLeg": 0.4}
        m = 8 if self.detail() else 6
        ring1 = [(kc[0] + kn["r"][0] * math.cos(TAU * j / m), kc[1] + kn["r"][1] * math.sin(TAU * j / m), kc[2]) for j in range(m)]
        ring2 = [(kc[0] + (p[0] - kc[0]) * 0.6, kc[1] + (p[1] - kc[1]) * 0.6, kc[2] - kn["r"][2] * 0.75) for p in ring1]
        tip = (kc[0], kc[1], kc[2] - kn["r"][2])
        i1 = [g.v(p, kw(p)) for p in ring1]
        i2 = [g.v(p, kw(p)) for p in ring2]
        ti = g.v(tip, kw(tip))
        back = (kc[0], kc[1], kc[2] + 0.05)
        for j in range(m):
            k = (j + 1) % m
            g.f([i1[j], i1[k], i2[k], i2[j]], "steel", 0.55, away=back)
            g.f([ti, i2[j], i2[k]], "steel", 0.55, away=back)
        if self.detail() and kn["stud"] > 0.0:
            st = kn["stud"]
            base = [(tip[0] + st * math.cos(TAU * j / 4 + math.pi / 4), tip[1] + st * math.sin(TAU * j / 4 + math.pi / 4), tip[2] + 0.004) for j in range(4)]
            prism(g, base, base[0], (0.0, 0.0, -1.0), 0.012, kw, "trim", 0.6, inset=0.7)
        # Greave: shin front wrapped to the calf, ridged; a bronze strip on the ridge.
        Gr = Lg["greave"]
        cols = int(Gr["cols"]) if self.detail() else 6
        lw = rigid(side + "LowerLeg")
        rows = list(zip(Gr["rows"], Gr["out"])) if self.detail() else [(Gr["rows"][0], Gr["out"][0]), (Gr["rows"][-1], Gr["out"][-1])]
        grid = [arc(y, out, -Gr["deg"], Gr["deg"], cols, extra_back=Gr["calf"] if 0.3 < y < 0.42 else 0.0, ridge=Gr["ridge"]) for y, out in rows]
        idx = [[g.v(p, lw(p)) for p in row] for row in grid]
        for r in range(len(grid) - 1):
            for q in range(cols):
                quad = [idx[r][q], idx[r][q + 1], idx[r + 1][q + 1], idx[r + 1][q]]
                mid = centroid([g.pos[i] for i in quad])
                ax = self._axis_at(axis, mid[1])
                lip = r >= len(rows) - 1
                g.f(quad, "steel_dark" if lip else "steel", 0.5, away=(mid[0], mid[1] + 0.05, mid[2]) if lip else ax)
        if self.detail():
            ridge = []
            for y, out in rows[:-1] + [rows[-1]]:
                c = self._axis_at(axis, y)
                rx, rz = radius_at(y)
                f = (c[0], y, c[2] - rz - out - Gr["ridge"])
                ridge.append([(f[0] - 0.009, y, f[2] + 0.004), (f[0], y, f[2] - 0.006), (f[0] + 0.009, y, f[2] + 0.004)])
            ridge = [ridge[0], ridge[-1]]
            idx = [[g.v(p, lw(p)) for p in st] for st in ridge]
            for j in range(2):
                quad = [idx[0][j], idx[0][j + 1], idx[1][j + 1], idx[1][j]]
                mid = centroid([g.pos[i] for i in quad])
                g.f(quad, "bronze", 0.6, away=(mid[0], mid[1], mid[2] + 0.05))
        # Ankle collar (both LODs: it closes the boot's top opening).
        if True:
            mid_y = 0.5 * (Lg["collar"][0][0] + Lg["collar"][-1][0])
            loft(g, [ring(self._axis_at(axis, y), r, r * 1.05, r, n, phase=math.pi / n) for y, r in Lg["collar"]],
                 lambda p: {side + "LowerLeg": 0.65, side + "Foot": 0.35} if p[1] > mid_y else {side + "LowerLeg": 0.35, side + "Foot": 0.65}, "steel_dark", 0.45)

    def boot(self, s):
        Lg = self.D["leg"]
        g = self.g
        side = "Right" if s > 0 else "Left"
        F = self.R[side + "Foot"]
        x0 = F[0]
        toe, full, frm = Lg["toe_cap_z"], Lg["toes_full_z"], Lg["toes_from_z"]

        def wf(p):
            t = smoothstep(frm, full, p[2])
            return {side + "Foot": 1.0 - t, side + "Toes": t}

        def outline(z_toe, z_heel, half, k_pts):
            """A rounded foot outline, k_pts points, ordered with angle (x = cos, z = sin)."""
            zc = (z_toe + z_heel) * 0.5
            hl = (z_heel - z_toe) * 0.5
            pts = []
            for j in range(k_pts):
                a = TAU * j / k_pts
                ca, sa = math.cos(a), math.sin(a)
                # fuller toe: the front half is rounder, the heel narrower
                w = half * (1.0 if sa < 0 else 0.88)
                pts.append((x0 + w * math.copysign(abs(ca) ** 0.8, ca), zc + hl * math.copysign(abs(sa) ** 0.9, sa)))
            return pts
        k = 12 if self.detail() else 8  # multiples of 4: a point at the toe tip and at the heel
        so = Lg["sole"]
        y0, y1 = so["y"]
        boot = Lg["boot"]
        # Upper: rounded outlines from the sole up to the ankle opening.
        rings = []
        for y, _u, zt, zh, hw in (boot if self.detail() else [boot[0], boot[3]]):
            rings.append([(x, y, z) for x, z in outline(zt, zh, hw, k)])
        rings.reverse()  # top to bottom
        rings[0] = [(p[0], p[1], p[2]) for p in rings[0]]

        def style(i, j):
            a = TAU * (j + 0.5) / k
            z = sum(r[j][2] for r in rings[i:i + 2]) / 2.0
            return "steel" if z < toe else "steel_dark"
        loft(g, rings, wf, style, 0.5)
        # Sole under the upper (toe to arch) and a heel block.
        sole_top = [(x, y1, z) for x, z in outline(so["toe_z"], so["heel_z"] + 0.1, boot[0][4] + 0.006, k)]
        sole_bot = [(p[0], y0, p[2]) for p in sole_top]
        loft(g, [sole_top, sole_bot], wf, "suit", 0.35)
        cap(g, sole_bot, wf, "suit", up=False, shade=0.35)
        if not self.detail():
            return
        he = Lg["heel"]
        hz0, hz1 = he["z"]
        hw = he["half_w"]
        hb = [(x0 - hw, he["y"][0], hz0), (x0 + hw, he["y"][0], hz0), (x0 + hw * 0.8, he["y"][0], hz1), (x0 - hw * 0.8, he["y"][0], hz1)]
        prism(g, hb, hb[0], (0.0, 1.0, 0.0), he["y"][1] - he["y"][0], rigid(side + "Foot"), "leather", 0.4, cap_far=False, cap_near=True)

    # ---------------------------------------------------------------- waist
    def tasset(self, s):
        T = self.D["waist"]["tasset"]
        g = self.g
        side = "Right" if s > 0 else "Left"
        cols = int(T["cols"]) if self.detail() else 2
        rows = T["rows"] if self.detail() else [T["rows"][0], T["rows"][-1]]
        d0, d1 = T["deg"]
        grid = []
        for y, rx, rz in rows:
            row = []
            for q in range(cols + 1):
                d = d0 + (d1 - d0) * q / cols  # around the side direction; + toward the back
                a = (0.0 if s > 0 else math.pi) + math.radians(d) * s
                row.append((rx * math.cos(a), y, rz * math.sin(a)))
            if s < 0:
                row.reverse()
            grid.append(row)
        if self.detail() and T["lip"] > 0.0:
            y, rx, rz = rows[-1]
            grid.append([(p[0] * (1.0 - T["lip"] / rx), p[1] + 0.004, p[2] * (1.0 - T["lip"] / rx)) for p in grid[-1]])

        def wf(p):
            t = smoothstep(0.98, 0.86, p[1]) * T["leg_share"]
            return {"Hips": 1.0 - t, side + "UpperLeg": t}
        idx = [[g.v(p, wf(p)) for p in row] for row in grid]
        for r in range(len(grid) - 1):
            for q in range(cols):
                quad = [idx[r][q], idx[r][q + 1], idx[r + 1][q + 1], idx[r + 1][q]]
                mid = centroid([g.pos[i] for i in quad])
                lip = r >= len(rows) - 1
                g.f(quad, "trim" if lip else ("steel_shade" if r % 2 else "steel"), 0.5,
                    away=(mid[0], mid[1] + 0.05, mid[2]) if lip else (0.0, mid[1], 0.0))

    def pteruges(self):
        P = self.D["waist"]["pteruges"]
        g = self.g
        count = int(self.L["pteruges"])
        belt = self.D["torso"]["belt"][2]
        rx, rzf = belt[1], belt[2]
        arc = math.radians(P["arc_deg"])
        for i in range(count):
            u = -1.0 + 2.0 * i / (count - 1)
            a = 1.5 * math.pi + arc * u
            ca, sa = math.cos(a), math.sin(a)
            top_c = (rx * ca, P["top"], rzf * sa)
            outward = norm((ca, 0.0, sa))
            tangent = (-sa, 0.0, ca)
            bot_c = add((top_c[0], P["bottom"], top_c[2]), mul(outward, P["flare"]))
            tip_c = lerp(bot_c, top_c, P["tip"] / (P["top"] - P["bottom"]))
            hw = P["half_w"] * (1.0 if self.detail() else 1.25)
            rows = [top_c, tip_c, bot_c] if self.detail() else [top_c, bot_c]

            def wf(p, x=top_c[0]):
                t = smoothstep(P["top"], P["bottom"], p[1]) * P["leg_share"]
                if abs(x) < 0.03:
                    return {"Hips": 1.0 - t, "LeftUpperLeg": t * 0.5, "RightUpperLeg": t * 0.5}
                return {"Hips": 1.0 - t, ("RightUpperLeg" if x > 0 else "LeftUpperLeg"): t}
            pts = [[add(c, mul(tangent, -hw)), add(c, mul(tangent, hw))] for c in rows]
            for flip in (False, True):
                idx = [[g.v(p, wf(p)) for p in row] for row in pts]
                for r in range(len(rows) - 1):
                    quad = [idx[r][0], idx[r][1], idx[r + 1][1], idx[r + 1][0]]
                    mid = centroid([g.pos[q] for q in quad])
                    ref = sub(mid, outward) if not flip else add(mid, outward)
                    style = "bronze" if (self.detail() and r == len(rows) - 2) or (not self.detail() and False) else "leather"
                    g.f(quad, style, 0.5, away=ref)
