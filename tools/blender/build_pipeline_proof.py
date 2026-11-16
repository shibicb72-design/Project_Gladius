"""M2 AN2 task 1: proves the Blender to Godot pipeline with a trivial rigged asset.

    blender.cmd -b --factory-startup --python tools/blender/build_pipeline_proof.py -- [--out=<repo-relative .glb>] [--variant=attrs]

Builds, from a factory-empty scene, a box-man of 8 boxes (96 triangles) skinned to 8 bones that take their names
and parents from data/anim.json "bones" (the soldier's Godot humanoid-profile names; Neck is a second root there,
and stays one here), with:
- COLOR_0 = RGBA vertex colour written as the sRGB numbers the soldier shader expects
  (scripts/visual/shaders/soldier_armor.gdshader), alpha 0 on the chest plate: the squad-colour field marker
  (scripts/visual/soldier_squad_colour.gd:3-5);
- TEXCOORD_0 = a plain per-face UV, TEXCOORD_1 (Godot UV2) = (surface id, shade) as the soldier mesh carries them;
- the forearm's upper corners weighted half to the upper arm (a blended weight, not only rigid ones);
- one looping action "proof_wave_Loop" (1 s at 30 fps; Godot's importer loops a clip whose name ends in _Loop
  and drops the suffix, so the clip arrives as "proof_wave").
Every bone points along Blender +Z with roll 0, so every glTF joint has an identity rest rotation (soldier_rig.gd
convention). Writes assets/generated/characters/pipeline_proof.glb and its row in tools/blender/manifest.json.
--variant=attrs (experiments only, written under build/): adds third and fourth UV maps and a custom "_SURF"
float attribute to see what Godot's importer keeps.
"""

import os
import sys

import bpy
from mathutils import Euler, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gladius_bl as gbl  # noqa: E402

OUT = "assets/generated/characters/pipeline_proof.glb"
ME = "tools/blender/build_pipeline_proof.py"
BONES = ["Hips", "Spine", "Chest", "Neck", "Head", "RightUpperArm", "RightForeArm", "RightHand"]
# Godot metres: bone head (pivot) positions of the proof figure. Not the soldier's; a stand-in of the same shape.
PIVOTS = {
    "Hips": (0.0, 0.95, 0.0), "Spine": (0.0, 1.15, 0.0), "Chest": (0.0, 1.38, 0.0),
    "Neck": (0.0, 1.5, 0.0), "Head": (0.0, 1.6, 0.0),
    "RightUpperArm": (0.24, 1.41, 0.0), "RightForeArm": (0.24, 1.15, 0.0), "RightHand": (0.24, 0.91, 0.0),
}
# name, centre (Godot m), size (m), bone, sRGB paint RGBA (alpha 0 = squad field), surface id, shade
PARTS = [
    ("pelvis", (0.0, 0.95, 0.0), (0.32, 0.16, 0.2), "Hips", (0.42, 0.36, 0.3, 1.0), 4, 0.5),
    ("torso", (0.0, 1.18, 0.0), (0.36, 0.3, 0.22), "Spine", (0.62, 0.64, 0.68, 1.0), 1, 0.4),
    ("chest_plate", (0.0, 1.38, 0.0), (0.4, 0.14, 0.24), "Chest", (1.0, 1.0, 1.0, 0.0), 2, 0.6),
    ("neck", (0.0, 1.5, 0.0), (0.1, 0.08, 0.1), "Neck", (0.5, 0.4, 0.33, 1.0), 5, 0.5),
    ("head", (0.0, 1.62, 0.0), (0.2, 0.2, 0.22), "Head", (0.7, 0.7, 0.72, 1.0), 1, 0.75),
    ("upper_arm_r", (0.24, 1.28, 0.0), (0.09, 0.26, 0.09), "RightUpperArm", (0.55, 0.45, 0.35, 1.0), 6, 0.5),
    ("fore_arm_r", (0.24, 1.03, 0.0), (0.08, 0.24, 0.08), "RightForeArm", (0.55, 0.45, 0.35, 1.0), 6, 0.25),
    ("hand_r", (0.24, 0.86, 0.0), (0.07, 0.1, 0.07), "RightHand", (0.3, 0.25, 0.2, 1.0), 6, 0.5),
]
CLIP = "proof_wave_Loop"
CLIP_FRAMES = 30  # 1.0 s at 30 fps; frame 30 repeats frame 0


def _bone_table() -> dict:
    """name -> parent ("" for a root) for the proof's bones, from data/anim.json "bones"."""
    table = {}
    for bone in gbl.read_json("data/anim.json")["bones"]:
        table[bone["name"]] = bone["parent"]
    missing = [b for b in BONES if b not in table]
    if missing:
        raise RuntimeError("data/anim.json has no bones " + ", ".join(missing))
    return {b: table[b] for b in BONES}


def build_armature(parents: dict) -> bpy.types.Object:
    data = bpy.data.armatures.new("Armature")
    arm = bpy.data.objects.new("Armature", data)
    bpy.context.scene.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    for name in BONES:
        eb = data.edit_bones.new(name)
        head = gbl.godot_to_blender(PIVOTS[name])
        eb.head = head
        eb.tail = (head[0], head[1], head[2] + 0.1)  # along Blender +Z, roll 0: an identity rest basis in Godot
        eb.roll = 0.0
        eb.use_connect = False
        eb.use_deform = True
    for name in BONES:
        if parents[name] != "":
            data.edit_bones[name].parent = data.edit_bones[parents[name]]
    bpy.ops.object.mode_set(mode="OBJECT")
    return arm


def build_mesh(arm: bpy.types.Object, variant: str) -> bpy.types.Object:
    verts, faces, face_part, vert_part, vert_top = [], [], [], [], []
    for p, (name, centre, size, _bone, _paint, _surface, _shade) in enumerate(PARTS):
        base = len(verts)
        hx, hy, hz = size[0] * 0.5, size[1] * 0.5, size[2] * 0.5
        for sx in (-1, 1):
            for sy in (-1, 1):
                for sz in (-1, 1):
                    verts.append(gbl.godot_to_blender((centre[0] + sx * hx, centre[1] + sy * hy, centre[2] + sz * hz)))
                    vert_part.append(p)
                    vert_top.append(sy > 0)
        # corner index = (sx > 0) * 4 + (sy > 0) * 2 + (sz > 0), Godot axes; outward winding in Blender space
        quads = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
        for q in quads:
            faces.append(tuple(base + i for i in q))
            face_part.append(p)
    me = bpy.data.meshes.new("pipeline_proof")
    me.from_pydata(verts, [], faces)
    me.validate()
    me.update()
    # from_pydata keeps the given winding; make every face point away from its box centre.
    for poly in me.polygons:
        part = PARTS[face_part[poly.index]]
        c = gbl.godot_to_blender(part[1])
        to_face = poly.center - Vector(c)
        if poly.normal.dot(to_face) < 0.0:
            poly.flip()
    me.update()
    for poly in me.polygons:
        poly.use_smooth = False
    # Colour: FLOAT_COLOR is stored and exported as written, so the file carries the sRGB numbers themselves.
    colour = me.color_attributes.new("Col", "FLOAT_COLOR", "POINT")
    for i, v in enumerate(me.vertices):
        colour.data[i].color = PARTS[vert_part[i]][4]
    me.color_attributes.active_color = colour
    me.color_attributes.render_color_index = me.color_attributes.active_color_index
    # UV maps are per corner. Blender's exporter writes v as 1 - v (glTF's origin is top left), so the second map
    # stores 1 - shade to arrive in Godot's UV2 as (surface id, shade).
    uv0 = me.uv_layers.new(name="UVMap")
    uv1 = me.uv_layers.new(name="UV2")
    corner_uv = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
    for poly in me.polygons:
        part = PARTS[face_part[poly.index]]
        for k, li in enumerate(poly.loop_indices):
            uv0.data[li].uv = corner_uv[k % 4]
            uv1.data[li].uv = (float(part[5]), 1.0 - float(part[6]))
    if variant == "attrs":
        uv2 = me.uv_layers.new(name="UV3")
        uv3 = me.uv_layers.new(name="UV4")
        for poly in me.polygons:
            part = PARTS[face_part[poly.index]]
            for li in poly.loop_indices:
                uv2.data[li].uv = (0.25, 1.0 - 0.75)
                uv3.data[li].uv = (float(part[5]) * 0.1, 1.0 - 0.5)
        surf = me.attributes.new("_SURF", "FLOAT", "POINT")
        for i in range(len(me.vertices)):
            surf.data[i].value = float(PARTS[vert_part[i]][5])
    uv0.active = True
    uv0.active_render = True
    obj = bpy.data.objects.new("pipeline_proof", me)
    bpy.context.scene.collection.objects.link(obj)
    obj.parent = arm
    mod = obj.modifiers.new("Armature", "ARMATURE")
    mod.object = arm
    groups = {name: obj.vertex_groups.new(name=name) for name in BONES}
    for i in range(len(me.vertices)):
        part = PARTS[vert_part[i]]
        if part[0] == "fore_arm_r" and vert_top[i]:
            groups["RightForeArm"].add([i], 0.5, "REPLACE")
            groups["RightUpperArm"].add([i], 0.5, "REPLACE")
        else:
            groups[part[3]].add([i], 1.0, "REPLACE")
    return obj


def build_action(arm: bpy.types.Object) -> None:
    act = bpy.data.actions.new(CLIP)
    arm.animation_data_create()
    arm.animation_data.action = act
    pose = arm.pose.bones
    for pb in pose:
        pb.rotation_mode = "QUATERNION"
    # Bone local axes here: X = Blender X, Y = along the bone (Blender +Z), Z = Blender -Y (Godot +Z).
    keys = [(0, 0.0), (CLIP_FRAMES // 4, 35.0), (CLIP_FRAMES // 2, 0.0), (3 * CLIP_FRAMES // 4, -35.0), (CLIP_FRAMES, 0.0)]
    for frame, swing in keys:
        for pb in pose:
            pb.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
        pose["RightUpperArm"].rotation_quaternion = Euler((0.0, 0.0, 2.6), "XYZ").to_quaternion()
        pose["RightForeArm"].rotation_quaternion = Euler((0.0, 0.0, swing * 3.14159265 / 180.0), "XYZ").to_quaternion()
        for pb in pose:
            pb.keyframe_insert("rotation_quaternion", frame=frame)
    for pb in pose:
        pb.rotation_quaternion = (1.0, 0.0, 0.0, 0.0)
    bpy.context.scene.frame_end = CLIP_FRAMES


def rest_rotation_error(path: str) -> float:
    """The largest |w| deviation from identity of any joint's rest rotation in the written file."""
    doc, _ = gbl.read_glb(path)
    worst = 0.0
    for skin in doc.get("skins", []):
        for j in skin["joints"]:
            q = doc["nodes"][j].get("rotation", [0.0, 0.0, 0.0, 1.0])
            worst = max(worst, abs(q[0]), abs(q[1]), abs(q[2]), abs(1.0 - abs(q[3])))
    return worst


def main() -> None:
    a = gbl.args()
    out = str(a.get("out", OUT))
    variant = str(a.get("variant", ""))
    gbl.reset_scene()
    parents = _bone_table()
    arm = build_armature(parents)
    build_mesh(arm, variant)
    build_action(arm)
    bpy.context.scene.frame_set(0)
    overrides = {"export_attributes": True} if variant == "attrs" else {}
    path = gbl.export_glb(out, **overrides)
    if out == OUT:
        gbl.update_manifest(OUT, ME, "")
    s = gbl.summary(path)
    clips = " ".join("%s:%.3fs" % (k, v) for k, v in sorted(s["clips"].items()))
    print("PIPELINE_PROOF out=%s triangles=%d bones=%d clips=%s bytes=%d attributes=%s rest_rot_err=%.6f sha256=%s"
          % (out, s["triangles"], s["bones"], clips, s["bytes"], ",".join(s["attributes"]),
             rest_rotation_error(path), s["sha256"]))


main()
