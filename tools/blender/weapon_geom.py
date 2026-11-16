"""The three first-person weapons as plain Python geometry (no bpy), M2 AN2 item 4a. Weapon frame of
data/art_soldier.json (line 3): origin at the right hand's grip point (the blade: the hilt's middle), -z forward, +y up,
metres at natural size. Every anchor the game uses is READ from the weapon's art entry (muzzle_m, dot_m / sight_m, the
cell and charge rests, the reticle boxes) and the shapes are modelled around them; nothing here moves a point.

build(id, art, lod) -> {"Mesh": ViewGeo, "Cell": ViewGeo, "Charge": ViewGeo} (cell and charge in their own frames,
origin = their rest "at"). lod: "fp" (first person, full detail), "near" / "far" (the third-person LODs: the same shapes
with fewer facets and the small details left out). Face styles are data/art_soldier.json material class names.
"""

import view_geom as vg
from view_geom import Xf

STEEL = "steel"


class Detail:
    def __init__(self, lod: str):
        self.lod = lod
        self.fp = lod == "fp"
        self.far = lod == "far"

    def sides(self, n: int) -> int:
        if self.fp:
            return n
        return max(4, min(n, 6)) if not self.far else 4

    def seg(self, s: int) -> int:
        if self.fp:
            return s
        return min(s, 1) if not self.far else 0

    def bevel(self, b: float) -> float:
        return b if self.fp else 0.0


def _vec(a):
    return (float(a[0]), float(a[1]), float(a[2]))


def _part(art: dict, name: str) -> dict:
    for group in [art.get("parts", [])] + [art[k]["parts"] for k in ("cell", "charge") if k in art]:
        for p in group:
            if p.get("name") == name:
                return p
    return {}


def _housing(g, stations, d, style, cap0="poly", cap1="poly", seg_t=2, seg_b=1, rt=0.01, rb=0.006):
    """A loft along z of rounded rectangles: stations [z, width, y bottom, y top] (+ optional per-gap style)."""
    rings = []
    for st in stations:
        z, w, yb, yt = st[0], st[1], st[2], st[3]
        r_t = min(rt, (yt - yb) * 0.45, w * 0.45)
        r_b = min(rb, (yt - yb) * 0.45, w * 0.45)
        rings.append(vg.ring_z(vg.rrect(w, yb, yt, r_t, r_b, d.seg(seg_t), d.seg(seg_b)), z))
    styles = [st[4] if len(st) > 4 else style for st in stations]
    return vg.tube(g, rings, None, lambda gap, j: styles[max(gap, 0)] if gap < len(styles) else styles[-1], cap0, cap1)


def _grip(g, d, top, bottom, mat, cap_mat="bronze", swell=1.0):
    """The pistol grip: a loft from `top` down to `bottom` (weapon frame) with a palm swell at the back."""
    axis = vg.sub(bottom, top)
    fwd = vg.norm(vg.sub((0.0, 0.0, -1.0), vg.mul(vg.norm(axis), vg.dot((0.0, 0.0, -1.0), vg.norm(axis)))))
    n = 8 if d.fp else (6 if not d.far else 4)
    # [t along the grip, half width x, front half depth, back half depth (the palm swell)]
    st = [(0.0, 0.0145, 0.016, 0.016), (0.32, 0.0162, 0.0165, 0.019 * swell), (0.66, 0.0165, 0.016, 0.0195 * swell),
          (0.9, 0.015, 0.0152, 0.017)]
    if d.fp:
        st += [(0.915, 0.0172, 0.0185, 0.0205), (1.0, 0.0168, 0.018, 0.02)]
    rings = []
    for t, hx, df, db in st:
        c = vg.lerp(top, bottom, t)
        pts = vg.sect(n, hx, df, power=2.3, ry_dn=db, phase_deg=0.0 if n != 4 else 45.0)
        rings.append(vg.place(pts, c, (1.0, 0.0, 0.0), fwd))
    styles = [mat, mat, mat, cap_mat, cap_mat]
    vg.tube(g, rings, None, lambda gap, j: styles[min(max(gap, 0), len(styles) - 1)] if gap >= 0 else mat, None, "flat")


def _guard(g, d, pts_zy, mat="gunmetal", w=0.0075, h=0.0045):
    path = [(0.0, y, z) for z, y in pts_zy]
    sec = [(-w * 0.5, -h * 0.5), (w * 0.5, -h * 0.5), (w * 0.5, h * 0.5), (-w * 0.5, h * 0.5)]
    vg.sweep(g, path, sec, None, mat, up=(1.0, 0.0, 0.0), cap0="flat", cap1="flat")


def _slab(g, profile, width, d, mat, bevel=0.0, axis="x", steps=1, centre=0.0):
    vg.slab(g, profile, width, d.bevel(bevel), axis, steps if d.fp else 1, None, mat, centre)


def _box(g, centre, size, mat, bevel=0.0, d=None, rot=None):
    if rot is not None:
        g.push(Xf.euler_yxz(rot, centre))
        vg.box(g, (0.0, 0.0, 0.0), size, None, mat, bevel if (d is None or d.fp) else 0.0)
        g.pop()
    else:
        vg.box(g, centre, size, None, mat, bevel if (d is None or d.fp) else 0.0)


def _bolt(g, at, axis, r=0.0026):
    vg.lathe(g, [(r, 0.0), (r, 0.0014), (r * 0.55, 0.0019), (0.0, 0.002)], 6, at, axis, (0.0, 1.0, 0.0), None, "bronze")


def _trigger(g, d):
    _slab(g, [(-0.011, 0.018), (-0.017, 0.018), (-0.0215, 0.006), (-0.02, -0.003), (-0.0155, -0.0045), (-0.0135, 0.004)],
          0.006, d, "bronze")


def _butt(g, d, z0, z1, w, yb, yt):
    """A recoil pad from z0 to the rear face z1: dark polymer, bevelled edge loops, a recessed dark centre panel. The rear
    face stays at z1 (the part-list stock's depth, where the near-plane tests pass)."""
    if not d.fp:
        return
    r = 0.009

    def ring(z, ins):
        return vg.ring_z(vg.rrect(w - 2 * ins, yb + ins, yt - ins, max(r - ins, 0.002), max(r - ins, 0.002), 1, 1), z)
    rings = [ring(z0, 0.0), ring(z1 - 0.0045, 0.0), ring(z1 - 0.0015, 0.0018),
             ring(z1, 0.0045), ring(z1, 0.009), ring(z1 - 0.0028, 0.009)]
    styles = ["polymer", "polymer", "polymer", "polymer", "gunmetal_black", "gunmetal_black"]
    vg.tube(g, rings, None, lambda gap, j: styles[min(max(gap, 0), len(styles) - 1)], None, "flat")


def _guard_and_trigger(g, d):
    if d.far:
        return
    path = [(0.006, 0.019), (0.006, -0.006), (-0.003, -0.013), (-0.03, -0.0135), (-0.039, -0.006), (-0.041, 0.016)]
    if not d.fp:
        path = [(0.006, 0.019), (0.004, -0.012), (-0.036, -0.012), (-0.041, 0.016)]
    _guard(g, d, path)
    if d.fp:
        _trigger(g, d)


def _lower(g, d, mat, well_bottom):
    _slab(g, [(0.07, 0.049), (0.07, 0.025), (0.0, 0.018), (-0.036, 0.018), (-0.041, well_bottom), (-0.104, well_bottom),
              (-0.11, 0.025), (-0.15, 0.03), (-0.15, 0.049)], 0.04, d, mat, bevel=0.004)


# --- Pilum BR ----------------------------------------------------------------------------------------------------------
def pilum(art: dict, d: Detail) -> dict:
    mesh, cell, charge = vg.ViewGeo(), vg.ViewGeo(), vg.ViewGeo()
    muzzle = _vec(art["muzzle_m"])
    dot_p = _vec(art["dot_m"])
    bore_y = muzzle[1]
    tip = -muzzle[2]
    g = mesh
    # Receiver merging into the bullpup stock, a sloped top line, a raised red enamel band edged in bronze.
    # the butt ends at z 0.12 like the part-list stock: further back the gun's kick and pickup cut the near plane
    st = [[0.108, 0.036, 0.05, 0.096], [0.1, 0.042, 0.044, 0.101]]
    if d.fp:
        st += [[0.079, 0.046, 0.041, 0.106, "bronze"], [0.077, 0.0496, 0.0395, 0.1085, "enamel"],
               [0.036, 0.0496, 0.0395, 0.1085, "bronze"], [0.034, 0.046, 0.042, 0.108]]
    else:
        st[-1] += ["gunmetal"]
        st += [[0.078, 0.046, 0.041, 0.106, "enamel"], [0.035, 0.046, 0.042, 0.108]]
    st += [[-0.02, 0.046, 0.045, 0.108], [-0.10, 0.046, 0.046, 0.108], [-0.15, 0.044, 0.048, 0.104],
           [-0.166, 0.041, 0.051, 0.099], [-0.172, 0.036, 0.055, 0.094]]
    for s in st:
        if len(s) == 4:
            s.append("gunmetal")
    _housing(g, st, d, "gunmetal", seg_t=2, seg_b=0, rt=0.011)
    # Butt pad
    _butt(g, d, 0.103, 0.12, 0.038, 0.047, 0.098)
    _lower(g, d, "polymer", -0.005)
    _grip(g, d, (0.0, 0.036, 0.016), (0.0, -0.081, 0.046), "polymer")
    _guard_and_trigger(g, d)
    # Handguard (vented, a cyan glow behind the louvres) and its bronze cap.
    hg = [[-0.166, 0.044, 0.052, 0.098], [-0.18, 0.054, 0.049, 0.101], [-0.33, 0.054, 0.049, 0.101],
          [-0.35, 0.05, 0.052, 0.098]]
    _housing(g, hg, d, "gunmetal", cap0=None, cap1="poly", seg_t=2, seg_b=1, rt=0.012, rb=0.009)
    cap = [vg.ring_z(vg.rrect(0.052, 0.05, 0.1, 0.01, 0.008, d.seg(1), d.seg(1)), z) for z in (-0.346, -0.362)]
    vg.tube(g, cap, None, "bronze", None, "flat")
    for side in ((1.0, -1.0) if d.fp else ()):
        x = side * 0.0272
        _box(g, (x, 0.075, -0.258), (0.0016, 0.012, 0.118), "energy")
        if d.fp:
            for k in range(4):
                _box(g, (side * 0.0284, 0.075, -0.212 - k * 0.031), (0.0026, 0.02, 0.011), "gunmetal_black", rot=(0.0, 0.0, 0.0))
    # Emitter: shroud, shank, three swept bronze fins, the energy ring and the pilum point (its tip is the muzzle).
    sides = d.sides(10)
    bore = (0.0, bore_y, 0.0)
    vg.lathe(g, [(0.0175, 0.355), (0.0175, 0.386), (0.0135, 0.406), (0.0068, 0.412)], sides, bore, (0.0, 0.0, -1.0),
             (0.0, 1.0, 0.0), None, "gunmetal", phase_deg=18.0)
    vg.lathe(g, [(0.0066, 0.411), (0.0056, tip - 0.044)], d.sides(6), bore, (0.0, 0.0, -1.0), (0.0, 1.0, 0.0), None, STEEL)
    for ang in ((90.0, 210.0, 330.0) if not d.far else ()):
        g.push(Xf.translate(bore) * Xf.rot_z(ang - 90.0))
        _slab(g, [(-0.366, 0.012), (-0.39, 0.0315), (-0.443, 0.0275), (-tip + 0.043, 0.0078), (-tip + 0.043, 0.0052),
                  (-0.366, 0.0052)], 0.0042 if d.fp else 0.006, d, "bronze")
        g.pop()
    if d.fp:
        vg.lathe(g, [(0.0, tip - 0.05), (0.0088, tip - 0.05), (0.0088, tip - 0.043), (0.0, tip - 0.043)], d.sides(6), bore,
                 (0.0, 0.0, -1.0), (0.0, 1.0, 0.0), None, "energy")
    vg.lathe(g, [(0.0, tip - 0.046), (0.0066, tip - 0.043), (0.0118, tip - 0.029), (0.0, tip)], 4, bore, (0.0, 0.0, -1.0),
             (0.0, 1.0, 0.0), None, STEEL, phase_deg=45.0)
    # Rail with cross teeth, the reflex sight (mount, hood with a bronze rim, glass) round the data's dot.
    _box(g, (0.0, 0.111, -0.035), (0.02, 0.007, 0.18), "gunmetal_dark", bevel=0.0015, d=d)
    if d.fp:
        for z in (0.04, -0.06, -0.085, -0.11):
            _box(g, (0.0, 0.1155, z), (0.024, 0.004, 0.007), "gunmetal_dark")
    if not d.far:
        _box(g, (0.0, dot_p[1] - 0.0275, dot_p[2] + 0.002), (0.03, 0.013, 0.048), "gunmetal", bevel=0.003, d=d)
        hood_style = ["gunmetal", "gunmetal", "bronze", "bronze", "bronze", "gunmetal_black"]
        hood = [(0.0175, -0.014), (0.021, -0.014), (0.0225, 0.017), (0.0245, 0.019), (0.0245, 0.026), (0.0178, 0.026)]
        if not d.fp:
            hood = [(0.0175, -0.014), (0.022, -0.014), (0.0235, 0.026), (0.0178, 0.026)]
            hood_style = ["gunmetal", "gunmetal", "bronze", "gunmetal_black"]
        vg.lathe(g, hood, d.sides(8) if d.fp else 4, dot_p, (0.0, 0.0, -1.0), (0.0, 1.0, 0.0), None,
                 lambda gap, j: hood_style[gap % len(hood_style)], scale=(1.15, 1.0), phase_deg=22.5 if d.fp else 45.0,
                 closed=True)
    if d.fp:
        vg.lathe(g, [(0.0, 0.004), (0.0177, 0.004)], 8, dot_p, (0.0, 0.0, -1.0), (0.0, 1.0, 0.0), None, "glass",
                 scale=(1.15, 1.0), phase_deg=22.5)
        # A bronze eagle wing raised on the receiver's left side, panel lines, bolts, the status light, the charge slot.
        wing = [(0.0, 0.2), (0.1, 0.75), (0.35, 0.95), (0.7, 1.0), (1.0, 0.92), (0.8, 0.72), (0.86, 0.55), (0.62, 0.5),
                (0.68, 0.32), (0.44, 0.32), (0.48, 0.12), (0.24, 0.16), (0.22, 0.0), (0.05, 0.05)]
        prof = [(0.03 - s * 0.13, 0.057 + t * 0.042) for s, t in wing]
        _slab(g, prof, 0.0022, d, "bronze", centre=-0.0236)
        for side in (1.0, -1.0):
            _box(g, (side * 0.0233, 0.052, -0.095), (0.0016, 0.0022, 0.11), "gunmetal_black")
        _bolt(g, (-0.0272, 0.092, -0.192), (-1.0, 0.0, 0.0))
        _bolt(g, (-0.0272, 0.092, -0.322), (-1.0, 0.0, 0.0))
        _bolt(g, (-0.0225, 0.06, 0.098), (-1.0, 0.0, 0.0))
        _box(g, (0.0, 0.1035, 0.095), (0.012, 0.004, 0.016), "energy", rot=(-12.0, 0.0, 0.0))
        _box(g, (0.0234, 0.09, 0.07), (0.0024, 0.013, 0.05), "gunmetal_black")
    # The energy cell (its own node: the reload takes it out): a raked cell with a bronze cap and glowing strips.
    g = cell
    cn = 8 if d.fp else 4
    rings = []
    for y, w, dep, inset in ((0.02, 0.028, 0.046, 0.0), (-0.046, 0.028, 0.046, 0.0), (-0.048, 0.0325, 0.053, 0.0),
                             (-0.071, 0.0325, 0.053, 0.0), (-0.077, 0.028, 0.048, 0.0)):
        cz = -0.004 - (0.02 - y) * 0.09
        sec = vg.rrect(w, -dep * 0.5, dep * 0.5, 0.005, 0.005, d.seg(1), d.seg(1)) if cn == 8 else \
            vg.rrect(w, -dep * 0.5, dep * 0.5, 0.0, 0.0, 0, 0)
        rings.append(vg.ring_y(sec, y, 0.0, cz))
    cstyles = ["gunmetal", "bronze", "bronze", "bronze"]
    if not d.fp:
        rings = [rings[0], rings[2], rings[4]]
        cstyles = ["gunmetal", "bronze"]
    vg.tube(g, rings, None, lambda gap, j: cstyles[min(max(gap, 0), len(cstyles) - 1)], "flat", "flat")
    if d.fp:
        for side in (1.0, -1.0):
            _box(g, (side * 0.0145, -0.021, -0.008), (0.0018, 0.036, 0.009), "energy", rot=(-5.0, 0.0, 0.0))
    # The charging handle (its own node: the reload pulls it): a slide and a bronze knob out to the right.
    g = charge
    if d.fp:
        _box(g, (0.0, 0.0, 0.0), (0.006, 0.012, 0.03), "gunmetal_dark")
        vg.lathe(g, [(0.0042, 0.002), (0.0042, 0.009), (0.0078, 0.011), (0.0078, 0.018), (0.0, 0.0195)], d.sides(6),
                 (0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0), None, "bronze")
    return {"Mesh": mesh, "Cell": cell, "Charge": charge}


# --- Sagittarii rifle ----------------------------------------------------------------------------------------------------
def sagittarii(art: dict, d: Detail) -> dict:
    mesh, cell, charge = vg.ViewGeo(), vg.ViewGeo(), vg.ViewGeo()
    muzzle = _vec(art["muzzle_m"])
    dot_p = _vec(art["dot_m"])
    bore_y = muzzle[1]
    tip = -muzzle[2]
    sc_y = dot_p[1]
    g = mesh
    # Receiver and stock: long, slim, dark; a bronze line along the top; a leather cheek rest.
    # the butt ends at z 0.155 like the part-list stock (further back cuts the near plane in the pickup)
    st = [[0.143, 0.034, 0.042, 0.094, "gunmetal_dark"], [0.136, 0.04, 0.038, 0.097, "gunmetal_dark"],
          [0.11, 0.044, 0.042, 0.1, "gunmetal_dark"], [0.0, 0.045, 0.045, 0.101, "gunmetal_dark"],
          [-0.12, 0.045, 0.046, 0.1, "gunmetal_dark"], [-0.172, 0.043, 0.048, 0.096, "gunmetal_dark"],
          [-0.18, 0.038, 0.052, 0.092, "gunmetal_dark"]]
    _housing(g, st, d, "gunmetal_dark", seg_t=2, seg_b=0, rt=0.012)
    if not d.far:
        _slab(g, [(0.112, 0.097), (0.153, 0.095), (0.153, 0.107), (0.132, 0.112), (0.116, 0.107)], 0.034, d, "leather",
              bevel=0.005, steps=2)
    if d.fp:
        _box(g, (0.0, 0.1, -0.035), (0.0465, 0.003, 0.24), "bronze")
    _butt(g, d, 0.138, 0.155, 0.036, 0.04, 0.095)
    _lower(g, d, "polymer", 0.002)
    _grip(g, d, (0.0, 0.036, 0.016), (0.0, -0.081, 0.046), "leather")
    _guard_and_trigger(g, d)
    # Slender handguard with a bronze trim and glowing vent slots; a long barrel with a bronze band; a glowing brake.
    hg = [[-0.176, 0.042, 0.05, 0.092], [-0.19, 0.05, 0.048, 0.094], [-0.335, 0.05, 0.048, 0.094],
          [-0.35, 0.044, 0.052, 0.09]]
    _housing(g, hg, d, "gunmetal", cap0=None, cap1="poly", seg_t=2, seg_b=1, rt=0.011, rb=0.008)
    if d.fp:
        _box(g, (0.0, 0.07, -0.262), (0.0515, 0.004, 0.15), "bronze")
        for k in range(3):
            _box(g, (0.0, 0.0945, -0.29 - k * 0.018), (0.024, 0.0016, 0.007), "energy")
    sides = d.sides(10)
    bore = (0.0, bore_y, 0.0)
    prof = [(0.0118, 0.345), (0.0112, 0.398), (0.0142, 0.4), (0.0142, 0.412), (0.011, 0.414), (0.0104, tip - 0.036)]
    if not d.fp:
        prof = [(0.0118, 0.345), (0.0104, tip - 0.036)]
    bst = ["steel", "bronze", "bronze", "bronze", "steel"]
    vg.lathe(g, prof, sides, bore, (0.0, 0.0, -1.0), (0.0, 1.0, 0.0), None,
             lambda gap, j: bst[min(max(gap, 0), len(bst) - 1)] if d.fp else STEEL, phase_deg=18.0)
    g.push(Xf.translate((0.0, 0.0, -(tip - 0.018))))
    _slab(g, [(-0.015, bore_y - 0.011), (0.015, bore_y - 0.011), (0.0195, bore_y), (0.015, bore_y + 0.011),
              (-0.015, bore_y + 0.011), (-0.0195, bore_y)], 0.036, d, "gunmetal_dark", bevel=0.004, axis="z")
    g.pop()
    if d.fp:
        for z in (-(tip - 0.026), -(tip - 0.012)):
            _box(g, (0.0, bore_y, z), (0.0405, 0.0035, 0.005), "energy")
    # The scope: a slim eyepiece tube with a bronze rim ring and a dark bluish lens, a slim main tube between the
    # mounts, flaring into the objective bell with its bronze rings and front lens; the bore flares from the eyepiece
    # toward the objective; the reticle sits at the dot's plane. Profile [radius, -z] counter-clockwise.
    sc = (0.0, sc_y, 0.0)
    if d.fp:
        sp = [(0.0205, -0.15), (0.0268, -0.15), (0.0268, -0.137), (0.0245, -0.134), (0.0245, -0.104),
              (0.034, -0.085), (0.0438, -0.066), (0.0455, -0.06), (0.0462, -0.028), (0.0476, -0.026),
              (0.0476, -0.018), (0.041, -0.018), (0.0386, -0.07), (0.0222, -0.1), (0.0207, -0.148)]
        sst = ["bronze", "bronze", "gunmetal_dark", "gunmetal_dark", "gunmetal_dark", "gunmetal_dark",
               "gunmetal_dark", "gunmetal_dark", "bronze", "bronze", "bronze", "scope_bore",
               "scope_bore", "scope_bore", "scope_bore"]
    else:
        sp = [(0.021, -0.15), (0.0265, -0.15), (0.0265, -0.1), (0.044, -0.064), (0.0465, -0.018), (0.0405, -0.018),
              (0.0222, -0.1)]
        sst = ["gunmetal_black"] * 7
    vg.lathe(g, sp, d.sides(8), sc, (0.0, 0.0, -1.0), (0.0, 1.0, 0.0), None, lambda gap, j: sst[gap % len(sst)],
             phase_deg=22.5, closed=True)
    if d.fp:
        vg.lathe(g, [(0.0, -0.024), (0.0412, -0.024)], 8, sc, (0.0, 0.0, -1.0), (0.0, 1.0, 0.0), None, "glass_clear",
                 phase_deg=22.5)
        vg.lathe(g, [(0.0, -0.147), (0.0209, -0.147)], 8, sc, (0.0, 0.0, -1.0), (0.0, 1.0, 0.0), None,
                 "glass_eyepiece", phase_deg=22.5)
        for p in art["parts"]:
            if str(p.get("name", "")).startswith("reticle") and p.get("shape", "box") == "box" and \
                    str(p["name"]) in ("reticle_post_l", "reticle_post_r", "reticle_post_b", "reticle_fine_h", "reticle_fine_v"):
                _box(g, _vec(p["at"]), _vec(p["size"]), str(p.get("mat", "reticle")))
    # Turrets (top and side) on a saddle, the scope light, two mounts down to the rail.
    if not d.far:
        tp = [(0.0095, 0.022), (0.0095, 0.03), (0.0072, 0.036), (0.0, 0.037)]
        if not d.fp:
            tp = [(0.0075, 0.022), (0.0075, 0.035), (0.0, 0.036)]
        vg.lathe(g, tp, d.sides(6), (0.0, sc_y, 0.11), (0.0, 1.0, 0.0), (0.0, 0.0, -1.0), None,
                 lambda gap, j: "gunmetal_dark" if gap == 0 else "bronze")
        vg.lathe(g, tp, d.sides(6), (0.0, sc_y, 0.11), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0), None,
                 lambda gap, j: "gunmetal_dark" if gap == 0 else "bronze")
    if d.fp:
        _box(g, (-0.0258, sc_y, 0.12), (0.003, 0.01, 0.003), "energy")
    rail_top = 0.112
    _box(g, (0.0, 0.108, -0.04), (0.022, 0.008, 0.2), "gunmetal", bevel=0.0015, d=d)
    for z, ring_r in ((0.122, 0.0245), (0.06, 0.044)):
        if d.far:
            continue
        if d.fp:
            vg.lathe(g, [(ring_r, -z - 0.006), (ring_r + 0.0035, -z - 0.006), (ring_r + 0.0035, -z + 0.006),
                         (ring_r, -z + 0.006)], d.sides(8), sc, (0.0, 0.0, -1.0), (0.0, 1.0, 0.0), None, "gunmetal",
                     phase_deg=22.5, closed=True)
        _slab(g, [(-0.012, rail_top), (0.012, rail_top), (0.016, sc_y - ring_r - 0.002), (-0.016, sc_y - ring_r - 0.002)],
              0.011, d, "gunmetal", bevel=0.002, axis="z", centre=z)
    # The cell (its own node; the data's rest is in front of the grip) and the bolt handle.
    g = cell
    rings = []
    for y, w, dep in ((0.016, 0.03, 0.044), (-0.036, 0.03, 0.044), (-0.038, 0.035, 0.05), (-0.046, 0.035, 0.05),
                      (-0.05, 0.03, 0.046)):
        sec = vg.rrect(w, -dep * 0.5, dep * 0.5, 0.005, 0.005, d.seg(1), d.seg(1)) if d.fp else \
            vg.rrect(w, -dep * 0.5, dep * 0.5, 0.0, 0.0, 0, 0)
        rings.append(vg.ring_y(sec, y, 0.0, -0.002))
    cstyles = ["gunmetal", "bronze", "bronze", "bronze"]
    if not d.fp:
        rings = [rings[0], rings[2], rings[4]]
        cstyles = ["gunmetal", "bronze"]
    vg.tube(g, rings, None, lambda gap, j: cstyles[min(max(gap, 0), len(cstyles) - 1)], "flat", "flat")
    if d.fp:
        for y in (-0.012, -0.026):
            _box(g, (0.0, y, -0.002), (0.0315, 0.004, 0.0455), "energy")
    g = charge
    if d.fp:
        _box(g, (0.0, 0.0, 0.0), (0.006, 0.012, 0.03), "gunmetal")
        vg.lathe(g, [(0.0035, 0.002), (0.0035, 0.024)], d.sides(6), (0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0),
                 None, STEEL)
        vg.lathe(g, [(0.003, 0.022), (0.008, 0.026), (0.008, 0.034), (0.004, 0.037), (0.0, 0.0375)], d.sides(6),
                 (0.0, -0.004, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0), None, "bronze")
    return {"Mesh": mesh, "Cell": cell, "Charge": charge}


# --- Gladius Lux ------------------------------------------------------------------------------------------------------------
BLADE = [  # [y, core half width, edge half width]
    (0.078, 0.0135, 0.021), (0.12, 0.0122, 0.0195), (0.17, 0.0118, 0.019), (0.23, 0.0145, 0.0225),
    (0.3, 0.0175, 0.0265), (0.36, 0.0182, 0.0275), (0.41, 0.0145, 0.0235), (0.45, 0.0085, 0.0165)]


def gladius(art: dict, d: Detail) -> dict:
    g = vg.ViewGeo()
    up = (0.0, 1.0, 0.0)
    side = (0.0, 0.0, -1.0)
    n = d.sides(10)
    # Round pommel, ribbed grip, bronze ferrule and guard, the emitter.
    vg.lathe(g, [(0.0, -0.075), (0.011, -0.0738), (0.0185, -0.0685), (0.0205, -0.061), (0.0185, -0.0535), (0.0125, -0.0485)],
             n, (0.0, 0.0, 0.0), up, side, None, "bronze")
    grip = [(0.0122 if k % 2 == 0 else 0.0142, -0.049 + k * 0.0098) for k in range(11)]
    vg.lathe(g, grip, d.sides(8), (0.0, 0.0, 0.0), up, side, None, "leather_light", phase_deg=22.5)
    vg.lathe(g, [(0.0145, 0.046), (0.0165, 0.048), (0.0165, 0.056)], n, (0.0, 0.0, 0.0), up, side, None, "bronze")
    _slab(g, [(-0.045, 0.056), (0.045, 0.056), (0.051, 0.064), (0.026, 0.078), (-0.026, 0.078), (-0.051, 0.064)], 0.03, d,
          "bronze", bevel=0.006, axis="z", steps=2)
    _box(g, (0.0, 0.0792, 0.0), (0.036, 0.0025, 0.009), "energy")
    # The leaf blade: a bright diamond core inside a translucent hard-light edge (glass pass).
    t_core, t_edge = 0.0034, 0.0062
    rings = [[(w, y, 0.0), (0.0, y, -t_core), (-w, y, 0.0), (0.0, y, t_core)] for y, w, _we in BLADE]
    vg.tube(g, rings, None, "blade_core", "flat", (0.0, 0.48, 0.0))
    if d.fp or not d.far:
        rings = []
        for y, _w, we in BLADE:
            rings.append([(we, y, 0.0), (we * 0.45, y, -t_edge), (-we * 0.45, y, -t_edge), (-we, y, 0.0),
                          (-we * 0.45, y, t_edge), (we * 0.45, y, t_edge)])
        vg.tube(g, rings, None, "blade_edge" if d.fp else "energy", "flat", (0.0, 0.52, 0.0))
    return {"Mesh": g, "Cell": vg.ViewGeo(), "Charge": vg.ViewGeo()}


BUILDERS = {"pilum_br": pilum, "sagittarii_rifle": sagittarii, "gladius_lux": gladius}


def build(weapon_id: str, art: dict, lod: str) -> dict:
    return BUILDERS[weapon_id](art, Detail(lod))


def merged(parts: dict, art: dict) -> vg.ViewGeo:
    """Mesh + Cell + Charge in the weapon frame (the third-person gun is one mesh)."""
    out = vg.ViewGeo()
    for key in ("Mesh", "Cell", "Charge"):
        src = parts[key]
        xf = Xf()
        if key == "Cell" and "cell" in art:
            xf = Xf.euler_yxz(art["cell"].get("rot", [0, 0, 0]), _vec(art["cell"]["at"]))
        elif key == "Charge" and "charge" in art:
            xf = Xf.euler_yxz(art["charge"].get("rot", [0, 0, 0]), _vec(art["charge"]["at"]))
        base = len(out.pos)
        out.pos += [xf.apply(p) for p in src.pos]
        out.wts += list(src.wts)
        out.faces += [(tuple(i + base for i in f[0]), f[1], f[2]) for f in src.faces]
    return out


def triangles(geo) -> int:
    return geo.triangles()
