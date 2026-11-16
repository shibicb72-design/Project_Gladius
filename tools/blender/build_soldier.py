"""M2 AN2 item 1: the third-person legionary as one skinned mesh in two LODs, built from nothing by code.

    blender.cmd -b --factory-startup --python tools/blender/build_soldier.py -- [--out=<repo-relative .glb>]
        [--preview=<name>] [--pose-check]

Writes assets/generated/characters/soldier.glb: the armature "Armature" (the 17 bones of data/anim.json plus
data/anim_third_person.json bones_add, rests from the game's own part data: gladius_bl.soldier_armature) and two
meshes skinned to it, "SoldierNear" and "SoldierFar" (tools/blender/soldier_geom.py, numbers in
tools/blender/soldier_design.json). No animation, no material, no texture. The vertex stream is the soldier shader's
(scripts/visual/shaders/soldier_armor.gdshader): COLOR = sRGB paint (alpha 0 on squad fields), UV = metres on the
face's main plane (as LowpolyKit._triangle), UV2 = (surface id, shade), on the cape (surface squad_cape) UV2.y = how far
the vertex hangs below the cape's top. Surface ids and paints are read from data/art_materials.json and
data/art_astra.json. Prints one SOLDIER_GLB line and records the file in tools/blender/manifest.json.

--preview=<name>: Workbench stills (front, three-quarter, side, back of the near LOD, front and three-quarter of the far
LOD) under build/an2/preview/<name>/. --pose-check adds stills with the arms raised 90 degrees forward and the knees
bent 90 degrees.
"""

import json
import math
import os
import sys

import bpy
from mathutils import Euler, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gladius_bl as gbl  # noqa: E402
import soldier_data  # noqa: E402
import soldier_geom  # noqa: E402

OUT = "assets/generated/characters/soldier.glb"
ME = "tools/blender/build_soldier.py"
DESIGN = "tools/blender/soldier_design.json"
MESHES = (("SoldierNear", "near"), ("SoldierFar", "far"))


def _srgb_to_linear(c: float) -> float:
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _uv_axes(n):
    """The planar UV axes LowpolyKit._triangle uses for a face of normal n (Godot axes)."""
    ax, ay, az = abs(n[0]), abs(n[1]), abs(n[2])
    u, v = (1.0, 0.0, 0.0), (0.0, -1.0, 0.0)
    if ay >= ax and ay >= az:
        v = (0.0, 0.0, 1.0)
        if ay < 0.985:
            h = soldier_geom.norm((n[0], 0.0, n[2]))
            sign = 1.0 if n[1] >= 0.0 else -1.0
            v = (h[0] * sign, 0.0, h[2] * sign)
            u = (v[2], 0.0, -v[0])
    elif ax >= az:
        u = (0.0, 0.0, 1.0)
    return u, v


def build_object(name: str, geo, arm, design: dict, bones: list) -> bpy.types.Object:
    styles = design["styles"]
    paints, surfaces = {}, {}
    for style, entry in styles.items():
        if style.startswith("_"):
            continue
        paint, surface = entry
        paints[style] = soldier_data.paint(paint)
        surfaces[style] = soldier_data.surface_id(surface)
    sway_surface = soldier_data.surface_id(soldier_data.read_json("data/art_astra.json")["soldier"]["material"]["cape"]["surface"])
    cape = design["cape"]
    me = bpy.data.meshes.new(name)
    me.from_pydata([gbl.godot_to_blender(p) for p in geo.pos], [], [list(f[0]) for f in geo.faces])
    me.update()
    if len(me.polygons) != len(geo.faces):
        raise RuntimeError("%s: %d polygons for %d faces" % (name, len(me.polygons), len(geo.faces)))
    col = me.color_attributes.new("Col", "FLOAT_COLOR", "CORNER")
    uv0 = me.uv_layers.new(name="UVMap")
    uv1 = me.uv_layers.new(name="UV2")
    colours, uvs0, uvs1 = [0.0] * (len(me.loops) * 4), [0.0] * (len(me.loops) * 2), [0.0] * (len(me.loops) * 2)
    for poly, (idx, style, shade) in zip(me.polygons, geo.faces):
        pts = [geo.pos[i] for i in idx]
        n = soldier_geom.norm(soldier_geom.newell(pts))
        u_axis, v_axis = _uv_axes(n)
        paint = paints[style]
        sid = surfaces[style]
        for li, vi in zip(poly.loop_indices, idx):
            p = geo.pos[vi]
            colours[li * 4: li * 4 + 4] = paint
            uvs0[li * 2] = soldier_geom.dot(p, u_axis)
            uvs0[li * 2 + 1] = 1.0 - soldier_geom.dot(p, v_axis)
            if sid == sway_surface:
                hang = max(0.0, min(1.0, (cape["top_y"] - p[1]) / (cape["top_y"] - cape["bottom_y"])))
                second = hang
            else:
                second = shade
            uvs1[li * 2] = float(sid)
            uvs1[li * 2 + 1] = 1.0 - second
    col.data.foreach_set("color", colours)
    uv0.data.foreach_set("uv", uvs0)
    uv1.data.foreach_set("uv", uvs1)
    me.color_attributes.active_color = col
    me.color_attributes.render_color_index = me.color_attributes.active_color_index
    uv0.active = True
    uv0.active_render = True
    me.shade_smooth()
    me.set_sharp_from_angle(angle=math.radians(float(design["sharp_deg"])))
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    obj.parent = arm
    mod = obj.modifiers.new("Armature", "ARMATURE")
    mod.object = arm
    groups = {b: obj.vertex_groups.new(name=b) for b in bones}
    for i, w in enumerate(geo.wts):
        for b, value in w.items():
            groups[b].add([i], value, "REPLACE")
    return obj


def mesh_summary(path: str) -> dict:
    doc, _ = gbl.read_glb(path)
    out = {}
    for mesh in doc.get("meshes", []):
        tris = 0
        for prim in mesh["primitives"]:
            tris += doc["accessors"][prim["indices"]]["count"] // 3
        out[mesh["name"]] = {"triangles": tris, "primitives": len(mesh["primitives"]), "vertices": doc["accessors"][mesh["primitives"][0]["attributes"]["POSITION"]]["count"]}
    return out


# --- previews ---------------------------------------------------------------------------------------------------------
def _preview_colours(obj, design):
    """A second colour attribute for Workbench: the paint as linear values and squad fields in the default squad red."""
    me = obj.data
    src = me.color_attributes["Col"]
    squad = soldier_data.read_json("data/art_astra.json")["soldier"]["squad_colour"]["palette"][0]
    prev = me.color_attributes.new("Preview", "FLOAT_COLOR", "CORNER")
    vals = [0.0] * (len(me.loops) * 4)
    data = [0.0] * (len(me.loops) * 4)
    src.data.foreach_get("color", data)
    for i in range(len(me.loops)):
        r, g, b, a = data[i * 4: i * 4 + 4]
        if a < 0.5:
            r, g, b = squad[0], squad[1], squad[2]
        vals[i * 4: i * 4 + 4] = (_srgb_to_linear(r), _srgb_to_linear(g), _srgb_to_linear(b), 1.0)
    prev.data.foreach_set("color", vals)
    me.color_attributes.active_color = prev


def _look(cam, eye, target):
    cam.location = Vector(eye)
    direction = Vector(target) - Vector(eye)
    cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()


def render_previews(out_dir: str, objs: dict, arm, design: dict, pose_check: bool) -> list:
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "VERTEX"
    scene.display.shading.show_backface_culling = True
    scene.display.shading.show_cavity = True
    scene.display.shading.cavity_type = "WORLD"
    scene.display.shading.show_object_outline = True
    scene.display.shading.background_type = "VIEWPORT"
    scene.display.shading.background_color = (0.32, 0.33, 0.35)
    scene.view_settings.view_transform = "Standard"
    scene.render.resolution_x = 800
    scene.render.resolution_y = 1000
    scene.render.film_transparent = False
    scene.render.image_settings.file_format = "PNG"
    for obj in objs.values():
        _preview_colours(obj, design)
    cam_data = bpy.data.cameras.new("PreviewCam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = 2.3
    cam = bpy.data.objects.new("PreviewCam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    target = (0.0, 0.0, 1.06)
    # Blender: the soldier faces +Y (Godot -Z), his right is +X.
    views = {"front": (0.0, 6.0, 1.06), "threequarter": (4.2, 4.2, 1.4), "side": (6.0, 0.0, 1.06), "back": (0.0, -6.0, 1.06),
             "top": (0.0, 0.01, 7.0)}
    os.makedirs(out_dir, exist_ok=True)
    written = []

    def shoot(which, view, tag):
        for name, obj in objs.items():
            obj.hide_render = name != which
        _look(cam, views[view], target)
        path = os.path.join(out_dir, "%s_%s.png" % (tag, view))
        scene.render.filepath = path
        bpy.ops.render.render(write_still=True)
        written.append(path)
    for view in ("front", "threequarter", "side", "back"):
        shoot("SoldierNear", view, "near")
    for view in ("front", "threequarter"):
        shoot("SoldierFar", view, "far")
    # close-ups of the head and a hand
    cam_data.ortho_scale = 0.75
    target = (0.0, 0.0, 1.62)
    views.update({"head_front": (0.0, 6.0, 1.62), "head_tq": (4.2, 4.2, 1.9), "head_back": (-4.2, -4.2, 1.9)})
    for view in ("head_front", "head_tq", "head_back"):
        shoot("SoldierNear", view, "near")
    cam_data.ortho_scale = 0.6
    target = (0.39, 0.0, 0.95)
    views.update({"hand": (6.0, 3.0, 1.2), "legs": (3.0, 6.0, 0.3)})
    shoot("SoldierNear", "hand", "near")
    target = (0.0, 0.0, 0.3)
    shoot("SoldierNear", "legs", "near")
    cam_data.ortho_scale = 2.3
    target = (0.0, 0.0, 1.06)
    if pose_check:
        pose = arm.pose.bones
        for pb in pose:
            pb.rotation_mode = "QUATERNION"
        rad = math.radians
        wanted = {"LeftUpperArm": (90, 0, 0), "RightUpperArm": (90, 0, 0), "LeftUpperLeg": (90, 0, 0), "RightUpperLeg": (90, 0, 0),
                  "LeftLowerLeg": (-90, 0, 0), "RightLowerLeg": (-90, 0, 0), "LeftForeArm": (60, 0, 0)}
        for bone, (x, y, z) in wanted.items():
            pose[bone].rotation_quaternion = Euler((rad(x), rad(y), rad(z)), "XYZ").to_quaternion()
        bpy.context.view_layer.update()
        for view in ("front", "threequarter", "side", "back"):
            shoot("SoldierNear", view, "pose")
        shoot("SoldierFar", "threequarter", "posefar")
        for pb in pose:
            pb.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
    return written


def main() -> None:
    a = gbl.args()
    out = str(a.get("out", OUT))
    design = json.loads(open(gbl.repo_path(DESIGN), "r", encoding="utf-8").read())
    gbl.reset_scene()
    rests = soldier_data.rest_table()
    bones = [b for b, _p, _a in rests]
    arm = gbl.soldier_armature()
    objs = {}
    for name, lod in MESHES:
        sol = soldier_geom.Soldier(design, lod, rests)
        geo = sol.build()
        print("SOLDIER_PARTS %s %d %s" % (lod, geo.triangles(), " ".join("%s=%d" % kv for kv in sol.counts.items())))
        objs[name] = build_object(name, geo, arm, design, bones)
    path = gbl.export_glb(out)
    s = gbl.summary(path)
    per = mesh_summary(path)
    if out == OUT:
        gbl.update_manifest(out, ME, "")
    print("SOLDIER_GLB out=%s near_tris=%d far_tris=%d near_verts=%d far_verts=%d bones=%d bytes=%d sha256=%s" % (
        out, per["SoldierNear"]["triangles"], per["SoldierFar"]["triangles"], per["SoldierNear"]["vertices"], per["SoldierFar"]["vertices"],
        s["bones"], s["bytes"], s["sha256"]))
    if a.get("preview"):
        out_dir = gbl.repo_path("build/an2/preview/" + str(a["preview"]))
        written = render_previews(out_dir, objs, arm, design, bool(a.get("pose-check")))
        print("SOLDIER_PREVIEW %d stills in %s" % (len(written), out_dir))


if __name__ == "__main__":
    main()
