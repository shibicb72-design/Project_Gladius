"""M2 AN2 item 4a: the first-person right arm (armoured gauntlet over a dark glove, forearm under a vambrace), built
from nothing by code and skinned with blended weights to the game's 17-bone arm skeleton.

    blender.cmd -b --factory-startup --python tools/blender/build_view_arms.py -- [--out=<repo-relative .glb>]
        [--preview=<dir>]

Writes assets/generated/characters/view_arms.glb: the armature "Armature" (hand, forearm, index/middle/ring/pinky/thumb
_0.._2 with EXACTLY the rests scripts/visual/view_hands.gd builds from data/art_soldier.json hands: right_rests() below
reads the same data the same way) and one mesh "Arm" skinned to it (one primitive, the first-person vertex stream of
view_bl.py). The left arm is this mesh mirrored in x at load (ViewHands). Hand frame: origin at the wrist, fingers
-z, back of the hand +y, thumb -x; the forearm runs from the wrist along +z (ViewHands.aim_forearm turns it).
Shape numbers: ARM below. Material classes: data/art_soldier.json materials (glove, undersuit, plate, bronze, energy).
Prints one VIEW_ARMS line and records the file in tools/blender/manifest.json.

--preview=<dir>: Workbench stills of the hand (back, palm, side, open, grip, trigger, foregrip) under <dir>.
"""

import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gladius_bl as gbl  # noqa: E402
import view_bl  # noqa: E402
import view_geom as vg  # noqa: E402
from view_geom import Xf, add, lerp, mul, norm, sub  # noqa: E402

OUT = "assets/generated/characters/view_arms.glb"
ME = "tools/blender/build_view_arms.py"
FINGERS = ("index", "middle", "ring", "pinky", "thumb")
SEGMENTS = 3

# Shape numbers (OQ-ART-SOLDIER: a trial look for the lead), hand frame metres.
ARM = {
    "finger_sides": 6,
    "finger_flat": 0.84,            # finger section height / width
    "knuckle_grow": 1.1,            # knuckle rings are this much wider than the segment
    # palm loft: [z, rx right, rx left, ry up, ry down, cx, cy, thenar bulge (m)]
    "palm": [[0.016, 0.029, 0.030, 0.013, 0.013, -0.001, 0.0, 0.0],
             [-0.004, 0.034, 0.036, 0.016, 0.017, -0.002, 0.0, 0.004],
             [-0.028, 0.039, 0.043, 0.0165, 0.018, -0.002, -0.001, 0.009],
             [-0.054, 0.042, 0.043, 0.016, 0.015, -0.001, 0.0, 0.004],
             [-0.078, 0.043, 0.042, 0.0135, 0.012, 0.0, 0.001, 0.0],
             [-0.092, 0.040, 0.039, 0.010, 0.009, 0.0, 0.002, 0.0]],
    "palm_sides": 12,
    "palm_tip_z": -0.096,
    # forearm loft (undersuit): [z, rx, ry]; closed at the elbow end
    "forearm": [[0.012, 0.030, 0.024], [0.06, 0.034, 0.028], [0.12, 0.039, 0.033], [0.18, 0.044, 0.037],
                [0.235, 0.0465, 0.039], [0.27, 0.045, 0.038]],
    "forearm_end_z": 0.282,
    "forearm_sides": 10,
    # cuff (flexible dark band over the wrist): [z, rx, ry]
    "cuff": [[-0.012, 0.031, 0.019], [-0.004, 0.0375, 0.025], [0.01, 0.0365, 0.0265], [0.026, 0.0375, 0.029]],
    # vambrace lames: [front z, rear z], 4 mm of undersuit between them; offsets over the forearm surface: the front
    # edge lies lame_front over the suit, the rear edge lame_step higher (the step down to the next lame), the rear
    # lame_band metres are the bronze edge band; a centre ridge (lame_ridge) on top so it shades as armour
    "lames": [[0.024, 0.086], [0.09, 0.15], [0.154, 0.214]],
    "lame_front": 0.0022, "lame_step": 0.0045, "lame_band": 0.006, "lame_ridge": 0.0045, "lame_ridge_deg": 34.0,
    "energy_line": [0.0011, 0.0014],   # half width, height over the ridge
}


# --- rests (mirror of scripts/visual/view_hands.gd _right_rests / _finger_basis) -------------------------------------
def hands_cfg() -> dict:
    return gbl.read_json("data/art_soldier.json")["hands"]


def bone_names() -> list:
    out = ["hand", "forearm"]
    for f in FINGERS:
        out += ["%s_%d" % (f, s) for s in range(SEGMENTS)]
    return out


def parent_of(bone: str) -> str:
    if bone == "hand":
        return ""
    if bone == "forearm":
        return "hand"
    f, s = bone.split("_")
    return "hand" if int(s) == 0 else "%s_%d" % (f, int(s) - 1)


def finger_basis(fd: dict) -> Xf:
    if "dir" not in fd:
        return Xf.euler_yxz(fd.get("rot", [0, 0, 0]))
    z = mul(norm(fd["dir"]), -1.0)
    up = tuple(float(c) for c in fd.get("up", [0, 1, 0]))
    y = norm(sub(up, mul(z, vg.dot(up, z))))
    return Xf((vg.cross(y, z), y, z))


def right_rests(c: dict) -> dict:
    rests = {"hand": Xf(), "forearm": Xf()}
    for f in FINGERS:
        fd = c["fingers"][f]
        lengths = fd["lengths"]
        rests["%s_0" % f] = Xf(finger_basis(fd).b, fd["base"])
        for s in range(1, SEGMENTS):
            rests["%s_%d" % (f, s)] = Xf.translate((0.0, 0.0, -float(lengths[s - 1])))
    return rests


def globals_of(local: dict) -> dict:
    out = {}
    for n in bone_names():
        p = parent_of(n)
        out[n] = out[p] * local[n] if p else local[n]
    return out


def posed_globals(c: dict, pose: dict, to_elbow=None) -> dict:
    """Global pose transforms for a finger pose (ViewHands.apply_pose) and an optional forearm aim."""
    local = right_rests(c)
    posed = dict(local)
    spread = pose.get("spread", [0, 0, 0, 0, 0])
    for fi, f in enumerate(FINGERS):
        curls = pose.get(f, [0, 0, 0])
        for s in range(SEGMENTS):
            bone = "%s_%d" % (f, s)
            q = Xf(local[bone].b)
            if s == 0:
                q = q * Xf.axis_angle((0, 1, 0), float(spread[fi]))
                if f == "thumb":
                    q = q * Xf.axis_angle((0, 0, 1), float(pose.get("thumb_roll", 0.0)))
            q = q * Xf.axis_angle((1, 0, 0), -float(curls[s]))
            posed[bone] = Xf(q.b, local[bone].o)
    if to_elbow is not None:
        d = norm(to_elbow)
        axis = vg.cross((0.0, 0.0, 1.0), d)
        ang = math.degrees(math.acos(max(-1.0, min(1.0, d[2]))))
        if vg.length(axis) > 1e-9:
            posed["forearm"] = Xf.axis_angle(axis, ang)
    return globals_of(posed)


# --- geometry ----------------------------------------------------------------------------------------------------------
def _bone_ring(gx: Xf, z: float, r: float, sides: int, flat: float):
    return [gx.apply((math.cos(vg.TAU * j / sides) * r, math.sin(vg.TAU * j / sides) * r * flat, z)) for j in range(sides)]


def build_arm(c: dict) -> vg.ViewGeo:
    g = vg.ViewGeo()
    rests = globals_of(right_rests(c))
    sides = ARM["finger_sides"]
    flat = ARM["finger_flat"]
    grow = ARM["knuckle_grow"]
    hand = {"hand": 1.0}
    fore = {"forearm": 1.0}

    # Palm and back of the hand: one loft, tapered, thicker at the heel, a thenar mound toward the thumb (-x, -y).
    rows = []
    wts = []
    for z, rx, rxl, ryu, ryd, cx, cy, thenar in ARM["palm"]:
        pts = vg.sect(ARM["palm_sides"], rx, ryu, power=2.4, ry_dn=ryd, rx_l=rxl, cx=cx, cy=cy,
                      bulges=((215.0, 50.0, thenar),) if thenar > 0.0 else ())
        rows.append(vg.ring_z(pts, z))
        wts.append(hand)
    palm_style = lambda gap, j: "glove"  # noqa: E731
    vg.tube(g, rows, wts, palm_style, None, (0.0, 0.002, ARM["palm_tip_z"]))

    # Back plate (steel) over the metacarpals and a knuckle ridge plate (steel, bronze front edge).
    def top_y(x, z):
        # the palm's upper surface height near x at depth z (interpolated rows, a little proud)
        prof = ARM["palm"]
        for k in range(len(prof) - 1):
            z0, z1 = prof[k][0], prof[k + 1][0]
            if z1 <= z <= z0:
                t = (z0 - z) / (z0 - z1)
                ry = lerp((prof[k][3], 0, 0), (prof[k + 1][3], 0, 0), t)[0]
                rx = lerp((prof[k][1], 0, 0), (prof[k + 1][1], 0, 0), t)[0]
                cy = lerp((prof[k][6], 0, 0), (prof[k + 1][6], 0, 0), t)[0]
                u = min(abs(x) / rx, 0.999)
                return cy + ry * (1.0 - u ** 2.4) ** (1.0 / 2.4)
        return 0.0

    def plate(zs, xs, lift, thick, styles, ridge=None):
        rings = []
        for i, z in enumerate(zs):
            top = []
            for x in xs:
                y = top_y(x, z) + lift + (ridge[i] if ridge else 0.0)
                top.append((x, y + thick, z))
            bottom = [(x, y - thick, z) for (x, y, z) in reversed(top)]
            rings.append(top + bottom)
        vg.tube(g, rings, [hand] * len(rings), styles, "poly", "poly")

    plate([-0.006, -0.03, -0.054], [0.03, 0.012, -0.008, -0.03], 0.0035, 0.0018, "plate")
    plate([-0.057, -0.073, -0.084, -0.092], [0.036, 0.018, -0.002, -0.022, -0.038], 0.004, 0.002,
          lambda gap, j: "bronze" if gap == 2 else "plate", ridge=[0.0, 0.0035, 0.0025, 0.0005])

    # Fingers: tapered six-sided segments, wider knuckle rings, rounded tips, blended weights at every joint.
    for f in FINGERS:
        fd = c["fingers"][f]
        lengths = [float(v) for v in fd["lengths"]]
        r0, r1 = float(fd["radius"][0]), float(fd["radius"][1])

        def rad(s):
            return r0 + (r1 - r0) * s / SEGMENTS
        b0, b1, b2 = ("%s_0" % f, "%s_1" % f, "%s_2" % f)
        base_w = {"hand": 0.6, b0: 0.4} if f == "thumb" else {"hand": 0.5, b0: 0.5}
        stations = [
            (b0, 0.008 if f != "thumb" else 0.014, rad(0) * (grow if f != "thumb" else 1.25), base_w),
            (b0, -0.45 * lengths[0], rad(0.5) * 0.97, {b0: 1.0}),
            (b0, -0.82 * lengths[0], rad(0.9), {b0: 0.85, b1: 0.15}),
            (b1, 0.0, rad(1) * grow, {b0: 0.5, b1: 0.5}),
            (b1, -0.5 * lengths[1], rad(1.5) * 0.95, {b1: 1.0}),
            (b2, 0.0, rad(2) * grow * 0.97, {b1: 0.5, b2: 0.5}),
            (b2, -0.5 * lengths[2], rad(2.5) * 0.96, {b2: 1.0}),
            (b2, -0.84 * lengths[2], rad(3) * 0.9, {b2: 1.0}),
        ]
        rings = [_bone_ring(rests[b], z, r, sides, flat) for b, z, r, _w in stations]
        ws = [w for _b, _z, _r, w in stations]
        tip = rests[b2].apply((0.0, -0.001, -lengths[2] * 0.98))
        vg.tube(g, rings, ws, "glove", None, tip)
        # an armour scale on the back of the first segment (the thumb: on its middle segment)
        seg = 1 if f == "thumb" else 0
        bone = "%s_%d" % (f, seg)
        rr = rad(seg + 0.5)
        ln = lengths[seg]
        plate_pts = []
        for z, k in ((-0.14 * ln, 1.0), (-0.8 * ln, 0.9)):
            plate_pts.append([rests[bone].apply((x * rr * k, y * rr * flat, z)) for x, y in
                              ((0.72, 0.74), (0.0, 1.04), (-0.72, 0.74), (0.0, 0.84))])
        vg.tube(g, plate_pts, [{bone: 1.0}] * 2, "plate", "poly", "poly")

    # Cuff: the flexible dark band over the wrist (hand -> forearm blend).
    rings, ws = [], []
    for z, rx, ry in ARM["cuff"]:
        rings.append(vg.ring_z(vg.sect(ARM["forearm_sides"], rx, ry, power=2.2, cx=-0.001), z))
        t = vg.smoothstep(-0.006, 0.02, z)
        ws.append({"hand": 1.0 - t, "forearm": t} if 0.0 < t < 1.0 else (hand if t <= 0.0 else fore))
    vg.tube(g, rings, ws, "undersuit")

    # Forearm (undersuit), elliptical, wider toward the elbow, closed at the elbow end.
    def fore_r(z):
        prof = ARM["forearm"]
        if z <= prof[0][0]:
            return prof[0][1], prof[0][2]
        for k in range(len(prof) - 1):
            if prof[k][0] <= z <= prof[k + 1][0]:
                t = (z - prof[k][0]) / (prof[k + 1][0] - prof[k][0])
                return prof[k][1] + (prof[k + 1][1] - prof[k][1]) * t, prof[k][2] + (prof[k + 1][2] - prof[k][2]) * t
        return prof[-1][1], prof[-1][2]
    fs = ARM["forearm_sides"]
    rings = [vg.ring_z(vg.sect(fs, rx, ry, power=2.1), z) for z, rx, ry in ARM["forearm"]]
    vg.tube(g, rings, [fore] * len(rings), "undersuit", None, (0.0, 0.0, ARM["forearm_end_z"]))

    # Vambrace: three overlapping steel lames (a lip turned in at the front), a bronze rivet band, a cyan line.
    lames = ARM["lames"]
    ridge = ((90.0, ARM["lame_ridge_deg"], ARM["lame_ridge"]),)
    for k, (z0, z1) in enumerate(lames):
        def ring_off(z, off, rdg=True):
            rx, ry = fore_r(z)
            return vg.ring_z(vg.sect(fs, rx + off, ry + off, power=2.1, bulges=ridge if rdg else ()), z)
        # A shingled lame: low at its front edge, rising toward its rear edge, which stands lame_step proud of the
        # next lame and drops back to the suit in a bronze edge band (the step faces the eye from the hip view).
        lo, hi, band = ARM["lame_front"], ARM["lame_front"] + ARM["lame_step"], ARM["lame_band"]
        rings = [ring_off(z0, lo), ring_off(z1 - band - 0.002, hi - 0.0006), ring_off(z1 - 0.0015, hi),
                 ring_off(z1, lo)]
        styles = ["armor", "bronze", "bronze"]
        vg.tube(g, rings, [fore] * len(rings), lambda gap, j: styles[min(max(gap, 0), 2)])
        # the thin cyan line along the ridge of the middle and rear lame
        if k >= 1:
            line = []
            za, zb = z0 + 0.008, z1 - band - 0.004
            for z in (za, zb):
                rx, ry = fore_r(z)
                t = (z - z0) / (z1 - band - 0.002 - z0)
                top = ry + lo + (hi - 0.0006 - lo) * t + ARM["lame_ridge"] + 0.0004
                hw, h = ARM["energy_line"]
                line.append([(hw, top - 0.0012, z), (hw, top + h, z), (-hw, top + h, z), (-hw, top - 0.0012, z)])
            vg.tube(g, line, [fore] * 2, "energy", "flat", "flat")
    return g


# --- preview -------------------------------------------------------------------------------------------------------------
def posed_geo(g: vg.ViewGeo, c: dict, pose: dict) -> vg.ViewGeo:
    rest = globals_of(right_rests(c))
    pg = posed_globals(c, pose)
    mats = {b: pg[b] * rest[b].inverse() for b in bone_names()}
    out = vg.ViewGeo()
    out.pos = vg.skin_points(g.pos, g.wts, mats)
    out.wts = g.wts
    out.faces = g.faces
    return out


def render_previews(out_dir: str, g, c: dict, mats: dict) -> list:
    cam = view_bl.preview_setup((900, 700))
    written = []
    poses = c["poses"]
    shots = [("rest_back", None, (0.05, 0.35, -0.02), (0.0, 0.0, 0.0), 0.42),
             ("rest_palm", None, (0.05, -0.35, -0.02), (0.0, 0.0, 0.0), 0.42),
             ("rest_side", None, (0.35, 0.05, 0.0), (0.0, 0.0, 0.03), 0.42),
             ("rest_thumbside", None, (-0.35, 0.05, -0.05), (0.0, 0.0, -0.03), 0.3),
             ("rest_tq", None, (-0.2, 0.2, -0.25), (0.0, 0.0, -0.04), 0.3)]
    for pose in ("open", "reach", "grip", "trigger", "foregrip", "blade"):
        shots.append(("%s_side" % pose, pose, (0.35, 0.03, -0.06), (0.0, -0.01, -0.07), 0.24))
        shots.append(("%s_tq" % pose, pose, (-0.22, 0.12, -0.28), (0.0, -0.01, -0.07), 0.24))
    current = None
    for tag, pose, eye, target, ortho in shots:
        if current is not None:
            bpy.data.objects.remove(current, do_unlink=True)
        geo = g if pose is None else posed_geo(g, c, poses[pose])
        current = view_bl.static_object("Preview_" + tag, geo, mats)
        view_bl.look(cam, eye, target, ortho=ortho)
        written.append(view_bl.shoot(os.path.join(out_dir, "arm_%s.png" % tag)))
    if current is not None:
        bpy.data.objects.remove(current, do_unlink=True)
    return written


def rest_deviation(path: str, c: dict) -> tuple:
    """(worst origin error m, worst basis axis error, worst bone) of the written joints against right_rests()."""
    doc, _ = gbl.read_glb(path)
    local = right_rests(c)
    worst = (0.0, 0.0, "")
    for node in doc["nodes"]:
        name = node.get("name", "")
        if name not in local:
            continue
        t = node.get("translation", [0.0, 0.0, 0.0])
        q = node.get("rotation", [0.0, 0.0, 0.0, 1.0])
        got = Xf(Xf.from_quat(q).b, t)
        want = local[name]
        eo = vg.length(sub(got.o, want.o))
        eb = max(vg.length(sub(got.b[k], want.b[k])) for k in range(3))
        if eo + eb > worst[0] + worst[1]:
            worst = (eo, eb, name)
    return worst


def main() -> None:
    a = gbl.args()
    out = str(a.get("out", OUT))
    c = hands_cfg()
    mats = view_bl.materials()
    gbl.reset_scene()
    g = build_arm(c)
    missing = [s for s in g.styles() if s not in mats]
    if missing:
        raise RuntimeError("material classes missing from data/art_soldier.json materials: %s" % missing)
    rests = globals_of(right_rests(c))
    arm = view_bl.armature("Armature", [(b, parent_of(b), rests[b]) for b in bone_names()])
    obj = view_bl.view_object("Arm", g, mats)
    view_bl.skin_to(obj, arm, g)
    path = gbl.export_glb(out, export_materials="PLACEHOLDER")
    s = gbl.summary(path)
    per = view_bl.mesh_summary(path)
    if out == OUT:
        gbl.update_manifest(out, ME, "")
    print("VIEW_ARMS out=%s triangles=%d vertices=%d primitives=%d bones=%d bytes=%d sha256=%s" % (
        out, per["Arm"]["triangles"], per["Arm"]["vertices"], per["Arm"]["primitives"], s["bones"], s["bytes"], s["sha256"]))
    eo, eb, bone = rest_deviation(path, c)
    print("VIEW_ARMS_RESTS worst_origin_m=%.7f worst_basis=%.7f at=%s" % (eo, eb, bone))
    if a.get("preview"):
        out_dir = gbl.repo_path(str(a["preview"]))
        obj.hide_render = True
        written = render_previews(out_dir, g, c, mats)
        print("VIEW_ARMS_PREVIEW %d stills in %s" % (len(written), out_dir))


if __name__ == "__main__":
    main()
