"""M2 AN2 item 4a: the three first-person weapons (Pilum BR, Sagittarii rifle, Gladius Lux) and the third-person guns,
built from nothing by code (geometry: tools/blender/weapon_geom.py, shared helpers: view_geom.py, view_bl.py).

    blender.cmd -b --factory-startup --python tools/blender/build_weapons.py -- [--only=<id>] [--out-dir=<repo dir>]
        [--preview=<dir>]

Writes assets/generated/weapons/<id>.glb for pilum_br, sagittarii_rifle and gladius_lux. Each file holds, in the weapon
frame of data/art_soldier.json (origin at the right hand's grip point, -z forward, +y up, natural metres):
  Mesh       the first-person body, one primitive per pass (opaque, glass, glow) in the view-model stream (view_bl.py)
  Cell       the energy cell, its object origin at the data's cell rest (art weapons.<id>.cell.at), mesh in that frame
  Charge     the charging handle, likewise at charge.at
  ThirdNear  the third-person gun (soldier stream, one primitive, scaled by soldier.gun.weapons.<id>.scale, <= 500 tris)
  ThirdFar   its far silhouette
  Muzzle, SightAnchor, Dot  empties at the data's muzzle_m, sight_m (or dot_m) and dot_m: a copy for checks; the game
             keeps reading the points from data/art_soldier.json (one source of truth: this script reads them too).
The blade has Mesh only (no third-person blade: the soldier shows no blade today). Prints one VIEW_WEAPON line per file
and records each in tools/blender/manifest.json.

--preview=<dir>: Workbench stills of each weapon (left, right, top, front, three-quarter) and from the first-person
camera (data/camera.json hold pose, the 75 degree phone FOV) with both arms placed and posed as the game places them.
"""

import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_view_arms as arms  # noqa: E402
import gladius_bl as gbl  # noqa: E402
import view_bl  # noqa: E402
import view_geom as vg  # noqa: E402
import weapon_geom  # noqa: E402
from view_geom import Xf  # noqa: E402

ME = "tools/blender/build_weapons.py"
OUT_DIR = "assets/generated/weapons"
IDS = ("pilum_br", "sagittarii_rifle", "gladius_lux")
TP_MAX = 500


def _vec(a):
    return (float(a[0]), float(a[1]), float(a[2]))


def _empty(name: str, at) -> None:
    e = bpy.data.objects.new(name, None)
    e.location = gbl.godot_to_blender(at)
    bpy.context.scene.collection.objects.link(e)


def sub_xf(art: dict, key: str) -> Xf:
    sub = art[key]
    return Xf.euler_yxz(sub.get("rot", [0, 0, 0]), _vec(sub["at"]))


def build_file(wid: str, art: dict, gun: dict, mats: dict, out: str) -> dict:
    gbl.reset_scene()
    parts = weapon_geom.build(wid, art, "fp")
    for geo in parts.values():
        missing = [s for s in geo.styles() if s not in mats]
        if missing:
            raise RuntimeError("%s: material classes missing from data/art_soldier.json materials: %s" % (wid, missing))
    objs = {"Mesh": view_bl.view_object("Mesh", parts["Mesh"], mats)}
    counts = {"Mesh": parts["Mesh"].triangles()}
    for key, sub in (("Cell", "cell"), ("Charge", "charge")):
        if sub in art and parts[key].faces:
            objs[key] = view_bl.view_object(key, parts[key], mats, sub_xf(art, sub))
            counts[key] = parts[key].triangles()
    if "muzzle_m" in art:
        _empty("Muzzle", art["muzzle_m"])
    if "dot_m" in art:
        _empty("SightAnchor", art.get("sight_m", art["dot_m"]))
        _empty("Dot", art["dot_m"])
    weapons = gun["weapons"]
    if wid in weapons:
        scale = float(weapons[wid]["scale"])
        for name, lod in (("ThirdNear", "near"), ("ThirdFar", "far")):
            geo = weapon_geom.merged(weapon_geom.build(wid, art, lod), art)
            obj, _faces = view_bl.soldier_object(name, geo, mats, scale, gun["surface_of_mat"])
            objs[name] = obj
    path = gbl.export_glb(out, export_materials="PLACEHOLDER")
    per = view_bl.mesh_summary(path)
    s = gbl.summary(path)
    if out.startswith(OUT_DIR + "/"):
        gbl.update_manifest(out, ME, "")
    fp = sum(per[k]["triangles"] for k in ("Mesh", "Cell", "Charge") if k in per)
    line = "VIEW_WEAPON %s out=%s fp_triangles=%d %s bytes=%d sha256=%s" % (
        wid, out, fp, " ".join("%s=%d/%dp" % (k, v["triangles"], v["primitives"]) for k, v in sorted(per.items())),
        s["bytes"], s["sha256"])
    print(line)
    if wid in weapons and per["ThirdNear"]["triangles"] > TP_MAX:
        print("VIEW_WEAPON_OVER %s ThirdNear %d > %d" % (wid, per["ThirdNear"]["triangles"], TP_MAX))
    return {"objs": objs, "per": per, "parts": parts}


# --- previews --------------------------------------------------------------------------------------------------------------
def _placement(h: dict) -> Xf:
    if "fingers" in h:
        b = arms.finger_basis({"dir": h["fingers"], "up": h.get("back", [0, 1, 0])})
    else:
        b = Xf.euler_yxz(h.get("turn", [0, 0, 0])) * Xf.euler_yxz(h.get("rot", [0, 0, 0]))
    return Xf(b.b, _vec(h["at"]))


def _mirror_geo(geo):
    out = vg.ViewGeo()
    out.pos = [(-p[0], p[1], p[2]) for p in geo.pos]
    out.wts = geo.wts
    out.faces = [(tuple(reversed(f[0])), f[1], f[2]) for f in geo.faces]
    return out


def _posed_arm(arm_geo, c, pose, to_elbow, left):
    if left:
        to_elbow = (-to_elbow[0], to_elbow[1], to_elbow[2])
    rest = arms.globals_of(arms.right_rests(c))
    pg = arms.posed_globals(c, pose, to_elbow)
    mats = {b: pg[b] * rest[b].inverse() for b in arms.bone_names()}
    out = vg.ViewGeo()
    out.pos = vg.skin_points(arm_geo.pos, arm_geo.wts, mats)
    out.wts = arm_geo.wts
    out.faces = arm_geo.faces
    return _mirror_geo(out) if left else out


def _fp_scene(wid, art, mats, res):
    """The first-person composition: the weapon at its hold, the arms placed and posed, camera at the eye."""
    cam_cfg = gbl.read_json("data/camera.json")["first_person"]["view_model"]["weapons"][wid]
    hold = Xf.euler_yxz(cam_cfg["hold_rot_deg"], _vec(cam_cfg["hold_m"]))
    c = arms.hands_cfg()
    arm_geo = arms.build_arm(c)
    made = []
    for side in ("r", "l"):
        h = art.get("hands", {}).get(side)
        if not h:
            continue
        xf = _placement(h)
        elbow = _vec(h["elbow"])
        if h.get("frame", "weapon") == "view":
            xf = hold.inverse() * xf
            elbow = hold.inverse().apply(elbow)
        elif "elbow_view" in h:
            elbow = hold.inverse().apply(_vec(h["elbow_view"]))
        to_elbow = xf.inverse().apply(elbow)
        pose = c["poses"].get(h.get("pose", "grip"), c["poses"]["grip"])
        geo = _posed_arm(arm_geo, c, pose, to_elbow, side == "l")
        made.append(view_bl.static_object("PreviewArm_" + side, geo, mats, hold * xf))
    return hold, made


def render_previews(out_dir: str, wid: str, art: dict, mats: dict, built: dict) -> list:
    cam = view_bl.preview_setup((1000, 640))
    written = []
    for obj in built["objs"].values():
        obj.hide_render = True
    prev = []
    for key in ("Mesh", "Cell", "Charge"):
        geo = built["parts"][key]
        if not geo.faces:
            continue
        xf = None
        if key == "Cell":
            xf = sub_xf(art, "cell")
        elif key == "Charge":
            xf = sub_xf(art, "charge")
        prev.append(view_bl.static_object("Prev_" + key, geo, mats, xf))
    blade = wid == "gladius_lux"
    target = (0.0, 0.25, 0.0) if blade else (0.0, 0.05, -0.19)
    span = 0.7 if not blade else 0.65
    views = {"left": (-1.0, 0.0, 0.0), "right": (1.0, 0.0, 0.0), "top": (0.0, 1.0, 0.001), "front": (0.0, 0.0, -1.0),
             "tq": (-0.7, 0.45, -0.55), "tq_back": (-0.6, 0.4, 0.7)}
    for name, d in views.items():
        eye = vg.add(target, vg.mul(vg.norm(d), 2.0))
        view_bl.look(cam, eye, target, ortho=span if name not in ("front",) else 0.3)
        written.append(view_bl.shoot(os.path.join(out_dir, "%s_%s.png" % (wid, name))))
    # first person, hip pose: camera at the eye (Godot origin), looking -z, the game's vertical FOV
    for obj in prev:
        bpy.data.objects.remove(obj, do_unlink=True)
    scene = bpy.context.scene
    scene.render.resolution_x, scene.render.resolution_y = 1260, 540
    hold, made = _fp_scene(wid, art, mats, (1260, 540))
    for key, obj in built["objs"].items():
        if key in ("Mesh", "Cell", "Charge"):
            geo = built["parts"][key]
            xf = hold
            if key == "Cell":
                xf = hold * sub_xf(art, "cell")
            elif key == "Charge":
                xf = hold * sub_xf(art, "charge")
            made.append(view_bl.static_object("FP_" + key, geo, mats, xf))
    view_bl.look(cam, (0.0, 0.0, 0.0), (0.0, 0.0, -1.0), fov_deg=75.0)
    written.append(view_bl.shoot(os.path.join(out_dir, "%s_fp_hip.png" % wid)))
    for obj in made:
        bpy.data.objects.remove(obj, do_unlink=True)
    scene.render.resolution_x, scene.render.resolution_y = 1000, 640
    # the third-person LODs
    for key in ("ThirdNear", "ThirdFar"):
        if key not in built["objs"]:
            continue
        obj = built["objs"][key]
        obj.hide_render = False
        view_bl.preview_colours(obj)
        sc = 1.4
        view_bl.look(cam, vg.add(vg.mul(target, sc), vg.mul(vg.norm((-0.7, 0.45, -0.55)), 3.0)), vg.mul(target, sc),
                     ortho=span * sc)
        written.append(view_bl.shoot(os.path.join(out_dir, "%s_%s.png" % (wid, key))))
        view_bl.look(cam, vg.add(vg.mul(target, sc), (-3.0, 0.0, 0.0)), vg.mul(target, sc), ortho=span * sc)
        written.append(view_bl.shoot(os.path.join(out_dir, "%s_%s_left.png" % (wid, key))))
        obj.hide_render = True
    return written


def main() -> None:
    a = gbl.args()
    art_all = gbl.read_json("data/art_soldier.json")
    mats = art_all["materials"]
    gun = art_all["soldier"]["gun"]
    out_dir = str(a.get("out-dir", OUT_DIR)).rstrip("/")
    only = str(a["only"]).split(",") if a.get("only") else list(IDS)
    for wid in only:
        art = art_all["weapons"][wid]
        built = build_file(wid, art, gun, mats, "%s/%s.glb" % (out_dir, wid))
        if a.get("preview"):
            written = render_previews(gbl.repo_path(str(a["preview"])), wid, art, mats, built)
            print("VIEW_WEAPON_PREVIEW %s %d stills" % (wid, len(written)))


if __name__ == "__main__":
    main()
