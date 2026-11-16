"""bpy glue shared by build_view_arms.py and build_weapons.py (M2 AN2 item 4a): ViewGeo -> Blender mesh objects in the
two vertex streams the game draws, an armature from Godot rest transforms, and Workbench previews.

First-person (view-model) stream, read by scripts/visual/view_mesh.gd (ViewMesh.from_glb):
  COLOR_0   = the material class's colour from data/art_soldier.json "materials" as sRGB numbers, alpha as written
              (glass and glow use it). The game converts it to linear once at load (the view shader's ALBEDO = COLOR.rgb
              takes linear numbers; 8-bit sRGB keeps the dark classes precise where 8-bit linear would not).
  TEXCOORD_0 = (emission, pass id)       pass id: 0 opaque, 1 glass, 2 glow (Blender v = 1 - value)
  TEXCOORD_1 = (metallic, roughness)     (Blender v = 1 - roughness)
  one placeholder material slot per pass used (export_materials="PLACEHOLDER": one primitive per pass, no material)
Third-person (soldier) stream (interface notes 1.3, scripts/visual/soldier_look.gd _emit):
  COLOR_0 = sRGB paint, alpha 1; TEXCOORD_0 = (x + z, y) metres; TEXCOORD_1 = (surface id, 0.5); one primitive.
"""

import math
import os

import bpy
from mathutils import Matrix, Vector

import gladius_bl as gbl
import soldier_data

PASSES = ("opaque", "glass", "glow")
SHARP_DEG = 40.0


def materials() -> dict:
    return gbl.read_json("data/art_soldier.json")["materials"]


def _srgb_to_linear(c: float) -> float:
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _mesh(name: str, geo, scale: float = 1.0):
    me = bpy.data.meshes.new(name)
    me.from_pydata([gbl.godot_to_blender((p[0] * scale, p[1] * scale, p[2] * scale)) for p in geo.pos], [],
                   [list(f[0]) for f in geo.faces])
    me.update()
    if len(me.polygons) != len(geo.faces):
        raise RuntimeError("%s: %d polygons for %d faces" % (name, len(me.polygons), len(geo.faces)))
    return me


def _finish(me, sharp_deg: float):
    me.shade_smooth()
    me.set_sharp_from_angle(angle=math.radians(sharp_deg))


def godot_matrix(xf) -> Matrix:
    """A Godot transform (view_geom.Xf) as a Blender world matrix (C * M * C^-1, C: Godot -> Blender axes)."""
    c = Matrix(((1, 0, 0), (0, 0, -1), (0, 1, 0)))
    m = Matrix(((xf.b[0][0], xf.b[1][0], xf.b[2][0]), (xf.b[0][1], xf.b[1][1], xf.b[2][1]),
                (xf.b[0][2], xf.b[1][2], xf.b[2][2])))
    r = c @ m @ c.inverted()
    out = r.to_4x4()
    out.translation = Vector(gbl.godot_to_blender(xf.o))
    return out


def bone_matrix(xf) -> Matrix:
    """A Godot rest (view_geom.Xf, armature space) as a Blender edit-bone matrix: the bone's axes are the Godot basis
    columns written in Blender axes (C * M), so that the identity is a bone along Blender +Z with roll 0, which the
    exporter writes as a joint without rotation (gladius_bl's convention)."""
    c = Matrix(((1, 0, 0), (0, 0, -1), (0, 1, 0)))
    m = Matrix(((xf.b[0][0], xf.b[1][0], xf.b[2][0]), (xf.b[0][1], xf.b[1][1], xf.b[2][1]),
                (xf.b[0][2], xf.b[1][2], xf.b[2][2])))
    out = (c @ m).to_4x4()
    out.translation = Vector(gbl.godot_to_blender(xf.o))
    return out


def view_object(name: str, geo, mats: dict, xf=None, sharp_deg: float = SHARP_DEG) -> bpy.types.Object:
    """A mesh object in the first-person stream; geo is in the object's own frame, xf (Godot) places the object."""
    me = _mesh(name, geo)
    passes = []
    for f in geo.faces:
        p = str(mats[f[1]].get("pass", "opaque"))
        if p not in passes:
            passes.append(p)
    passes = [p for p in PASSES if p in passes]
    for p in passes:
        me.materials.append(bpy.data.materials.get(p) or bpy.data.materials.new(p))
    index = [passes.index(str(mats[f[1]].get("pass", "opaque"))) for f in geo.faces]
    me.polygons.foreach_set("material_index", index)
    col = me.color_attributes.new("Col", "FLOAT_COLOR", "CORNER")
    uv0 = me.uv_layers.new(name="UVMap")
    uv1 = me.uv_layers.new(name="UV2")
    n = len(me.loops)
    colours, a0, a1 = [0.0] * (n * 4), [0.0] * (n * 2), [0.0] * (n * 2)
    for poly, face in zip(me.polygons, geo.faces):
        m = mats[face[1]]
        c = m["color"]
        rgba = (float(c[0]), float(c[1]), float(c[2]), float(c[3]) if len(c) > 3 else 1.0)
        pid = PASSES.index(str(m.get("pass", "opaque")))
        emission = float(m.get("emission", 0.0))
        metallic = float(m.get("metallic", 0.0))
        rough = float(m.get("roughness", 0.8))
        for li in poly.loop_indices:
            colours[li * 4: li * 4 + 4] = rgba
            a0[li * 2] = emission
            a0[li * 2 + 1] = 1.0 - pid
            a1[li * 2] = metallic
            a1[li * 2 + 1] = 1.0 - rough
    col.data.foreach_set("color", colours)
    uv0.data.foreach_set("uv", a0)
    uv1.data.foreach_set("uv", a1)
    me.color_attributes.active_color = col
    me.color_attributes.render_color_index = me.color_attributes.active_color_index
    uv0.active = True
    uv0.active_render = True
    _finish(me, sharp_deg)
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    if xf is not None:
        obj.matrix_world = godot_matrix(xf)
    return obj


def soldier_object(name: str, geo, mats: dict, scale: float, surface_of_mat: dict, sharp_deg: float = SHARP_DEG):
    """A third-person gun mesh in the soldier stream: glass faces left out, positions scaled by `scale`."""
    keep = type(geo)()
    remap = {}
    for f in geo.faces:
        if str(mats[f[1]].get("pass", "opaque")) == "glass":
            continue
        ids = []
        for i in f[0]:
            if i not in remap:
                remap[i] = len(keep.pos)
                keep.pos.append(geo.pos[i])
                keep.wts.append(geo.wts[i])
            ids.append(remap[i])
        keep.faces.append((tuple(ids), f[1], f[2]))
    me = _mesh(name, keep, scale)
    col = me.color_attributes.new("Col", "FLOAT_COLOR", "CORNER")
    uv0 = me.uv_layers.new(name="UVMap")
    uv1 = me.uv_layers.new(name="UV2")
    n = len(me.loops)
    colours, a0, a1 = [0.0] * (n * 4), [0.0] * (n * 2), [0.0] * (n * 2)
    for poly, face in zip(me.polygons, keep.faces):
        c = mats[face[1]]["color"]
        sid = soldier_data.surface_id(str(surface_of_mat.get(face[1], "steel")))
        for li, vi in zip(poly.loop_indices, face[0]):
            p = keep.pos[vi]
            colours[li * 4: li * 4 + 4] = (float(c[0]), float(c[1]), float(c[2]), 1.0)
            a0[li * 2] = (p[0] + p[2]) * scale
            a0[li * 2 + 1] = 1.0 - p[1] * scale
            a1[li * 2] = float(sid)
            a1[li * 2 + 1] = 0.5
    col.data.foreach_set("color", colours)
    uv0.data.foreach_set("uv", a0)
    uv1.data.foreach_set("uv", a1)
    me.color_attributes.active_color = col
    me.color_attributes.render_color_index = me.color_attributes.active_color_index
    uv0.active = True
    uv0.active_render = True
    _finish(me, sharp_deg)
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    return obj, len(keep.faces)


def armature(name: str, bones: list) -> bpy.types.Object:
    """bones: [(name, parent, global rest Xf in Godot)] in order. Each bone's Blender matrix = the Godot basis in
    Blender axes, so the exported joint's local rotation is the Godot local rest (an identity basis exports as no
    rotation, gladius_bl's convention)."""
    data = bpy.data.armatures.new(name)
    arm = bpy.data.objects.new(name, data)
    bpy.context.scene.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    for bone, _parent, xf in bones:
        eb = data.edit_bones.new(bone)
        eb.head = (0.0, 0.0, 0.0)
        eb.tail = (0.0, 0.0, 0.02)
        eb.matrix = bone_matrix(xf)
        eb.use_connect = False
        eb.use_deform = True
    for bone, parent, _xf in bones:
        if parent:
            data.edit_bones[bone].parent = data.edit_bones[parent]
    bpy.ops.object.mode_set(mode="OBJECT")
    return arm


def skin_to(obj, arm, geo) -> None:
    obj.parent = arm
    mod = obj.modifiers.new("Armature", "ARMATURE")
    mod.object = arm
    groups = {}
    for i, w in enumerate(geo.wts):
        for b, value in w.items():
            if b not in groups:
                groups[b] = obj.vertex_groups.new(name=b)
            groups[b].add([i], value, "REPLACE")


def mesh_summary(path: str) -> dict:
    doc, _ = gbl.read_glb(path)
    out = {}
    for mesh in doc.get("meshes", []):
        tris = 0
        verts = 0
        for prim in mesh["primitives"]:
            tris += doc["accessors"][prim["indices"]]["count"] // 3
            verts += doc["accessors"][prim["attributes"]["POSITION"]]["count"]
        out[mesh["name"]] = {"triangles": tris, "primitives": len(mesh["primitives"]), "vertices": verts}
    return out


# --- previews ---------------------------------------------------------------------------------------------------------
def preview_setup(res=(900, 700), background=(0.30, 0.31, 0.33)):
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "VERTEX"
    scene.display.shading.show_backface_culling = True
    scene.display.shading.show_cavity = True
    scene.display.shading.cavity_type = "WORLD"
    scene.display.shading.show_object_outline = False
    scene.display.shading.background_type = "VIEWPORT"
    scene.display.shading.background_color = background
    scene.view_settings.view_transform = "Standard"
    scene.render.resolution_x = res[0]
    scene.render.resolution_y = res[1]
    scene.render.film_transparent = False
    scene.render.image_settings.file_format = "PNG"
    cam_data = bpy.data.cameras.new("PreviewCam")
    cam = bpy.data.objects.new("PreviewCam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    return cam


def preview_colours(obj) -> None:
    """A linear copy of Col for Workbench (it shows colour attributes as linear)."""
    me = obj.data
    src = me.color_attributes["Col"]
    data = [0.0] * (len(me.loops) * 4)
    src.data.foreach_get("color", data)
    vals = []
    for i in range(len(me.loops)):
        r, g, b, _a = data[i * 4: i * 4 + 4]
        vals += [_srgb_to_linear(r), _srgb_to_linear(g), _srgb_to_linear(b), 1.0]
    prev = me.color_attributes.new("Preview", "FLOAT_COLOR", "CORNER")
    prev.data.foreach_set("color", vals)
    me.color_attributes.active_color = prev


def look(cam, eye_godot, target_godot, ortho=None, fov_deg=None):
    eye = Vector(gbl.godot_to_blender(eye_godot))
    target = Vector(gbl.godot_to_blender(target_godot))
    cam.location = eye
    cam.rotation_euler = (target - eye).to_track_quat("-Z", "Y").to_euler()
    if ortho is not None:
        cam.data.type = "ORTHO"
        cam.data.ortho_scale = ortho
    else:
        cam.data.type = "PERSP"
        cam.data.sensor_fit = "VERTICAL"
        cam.data.angle = math.radians(fov_deg or 60.0)
    cam.data.clip_start = 0.005


def shoot(path: str) -> str:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.context.scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    return path


def static_object(name: str, geo, mats: dict, xf=None):
    """A preview-only copy (deleted before export by the caller)."""
    obj = view_object(name, geo, mats, xf)
    preview_colours(obj)
    return obj
