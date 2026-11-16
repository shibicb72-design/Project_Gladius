"""Shared helpers for the Blender asset scripts of Project Gladius (M2 AN2).

Every .glb under assets/generated/characters and assets/generated/weapons is written by a committed script in
tools/blender/ that builds its scene from nothing (no .blend file, no hand edits). Run a script headless:

    blender.cmd -b --factory-startup --python tools/blender/<script>.py -- [--key=value ...]

This module holds what those scripts share: the arguments after "--", a factory-empty scene, the one set of glTF
export settings, a reader for the repo's data files, the axis conversion from Godot to Blender, a small reader of
the written .glb (to check and summarize it without Godot), and the manifest (tools/blender/manifest.json) that
tools/asset_hashes.gd reads to record which script made each file.

Axis convention. Godot and glTF are +Y up, -Z forward; Blender is +Z up. Positions given in Godot metres go
through godot_to_blender(). A Blender bone whose head-to-tail direction is Blender +Z and whose roll is 0 exports
as a glTF joint with an identity rotation, i.e. an identity rest basis in Godot's Skeleton3D, which is the
convention of the code-built soldier (scripts/visual/soldier_rig.gd: every rest is Basis.IDENTITY).
"""

import hashlib
import json
import os
import struct
import sys

import bpy

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
MANIFEST = "tools/blender/manifest.json"
FPS = 30


def args() -> dict:
    """The --key=value (or bare --flag) arguments after Blender's own "--"."""
    out = {}
    argv = sys.argv
    rest = argv[argv.index("--") + 1:] if "--" in argv else []
    for arg in rest:
        if not arg.startswith("--"):
            continue
        key, _, value = arg[2:].partition("=")
        out[key] = value if value != "" else True
    return out


def repo_path(rel: str) -> str:
    """An absolute path for a repo-relative path ("data/anim.json" or "res://data/anim.json")."""
    if rel.startswith("res://"):
        rel = rel[len("res://"):]
    return os.path.join(REPO, *rel.split("/"))


def read_json(rel: str) -> dict:
    with open(repo_path(rel), "r", encoding="utf-8") as f:
        return json.load(f)


def reset_scene() -> bpy.types.Scene:
    """A factory-empty scene: no objects, no user prefs, the bundled add-ons only, 30 fps, frame 0."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.fps = FPS
    scene.render.fps_base = 1.0
    scene.frame_start = 0
    scene.frame_current = 0
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.scale_length = 1.0
    return scene


def godot_to_blender(v) -> tuple:
    """A Godot / glTF position (x, y up, z toward the viewer) as Blender (x, y, z up)."""
    return (float(v[0]), -float(v[2]), float(v[1]))


# The one set of export settings every character and weapon .glb uses. Everything is named so that a change of
# the exporter's defaults cannot change the output silently.
EXPORT_SETTINGS = {
    "export_format": "GLB",
    "export_copyright": "",
    "export_yup": True,
    "export_apply": False,
    "use_selection": False,
    "use_visible": False,
    "use_renderable": False,
    "use_active_collection": False,
    "use_active_scene": False,
    "export_cameras": False,
    "export_lights": False,
    "export_extras": False,
    "export_texcoords": True,
    "export_normals": True,
    "export_tangents": False,  # Godot generates them (meshes/ensure_tangents in the .import)
    "export_materials": "NONE",  # the game supplies the material; no textures, no images in the file
    "export_image_format": "NONE",
    "export_vertex_color": "ACTIVE",  # COLOR_0 = the active colour attribute, RGBA (alpha marks squad fields)
    "export_all_vertex_colors": False,
    "export_active_vertex_color_when_no_material": True,
    "export_attributes": False,
    "export_gn_mesh": False,
    "use_mesh_edges": False,
    "use_mesh_vertices": False,
    "export_shared_accessors": False,
    "export_draco_mesh_compression_enable": False,
    "export_meshopt_compression_enable": False,
    "export_use_gltfpack": False,
    "export_skins": True,
    "export_influence_nb": 4,
    "export_all_influences": False,
    "export_def_bones": False,
    "export_leaf_bone": False,
    "export_hierarchy_flatten_bones": False,
    "export_armature_object_remove": False,
    "export_rest_position_armature": True,
    "export_morph": False,
    "export_animations": True,
    "export_animation_mode": "ACTIONS",
    "export_frame_range": False,
    "export_frame_step": 1,
    "export_force_sampling": True,
    "export_sampling_interpolation_fallback": "LINEAR",
    "export_optimize_animation_size": False,  # keep every sampled key; Godot's importer compresses if asked
    "export_optimize_animation_keep_anim_armature": True,
    "export_anim_single_armature": True,
    "export_reset_pose_bones": True,
    "export_current_frame": False,
    "export_bake_animation": False,
    "export_anim_slide_to_zero": False,
    "export_negative_frame": "SLIDE",
    "export_merge_animation": "ACTION",
    "export_nla_strips": True,
    "export_pointer_animation": False,
    "export_extra_animations": False,
    "will_save_settings": False,
    "check_existing": False,
}


def export_glb(out_rel: str, **overrides) -> str:
    """Writes the whole scene to the repo-relative path out_rel as glTF binary and returns the absolute path."""
    path = repo_path(out_rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    settings = dict(EXPORT_SETTINGS)
    settings.update(overrides)
    result = bpy.ops.export_scene.gltf(filepath=path, **settings)
    if "FINISHED" not in result:
        raise RuntimeError("glTF export failed: %s" % (result,))
    return path


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def read_glb(path: str):
    """The JSON chunk (as a dict) and the BIN chunk (bytes) of a .glb."""
    with open(path, "rb") as f:
        data = f.read()
    magic, version, _length = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF" or version != 2:
        raise ValueError("not a glTF 2 binary: " + path)
    offset = 12
    doc, binary = None, b""
    while offset < len(data):
        size, kind = struct.unpack_from("<I4s", data, offset)
        chunk = data[offset + 8: offset + 8 + size]
        if kind == b"JSON":
            doc = json.loads(chunk.decode("utf-8"))
        elif kind == b"BIN\x00":
            binary = chunk
        offset += 8 + size
    return doc, binary


_COMPONENTS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}
_FORMATS = {5120: "b", 5121: "B", 5122: "h", 5123: "H", 5125: "I", 5126: "f"}


def accessor(doc: dict, binary: bytes, index: int) -> list:
    """The values of a glTF accessor as a list of tuples (normalized integers are mapped to 0..1)."""
    acc = doc["accessors"][index]
    view = doc["bufferViews"][acc["bufferView"]]
    n = _COMPONENTS[acc["type"]]
    fmt = _FORMATS[acc["componentType"]]
    size = struct.calcsize("<" + fmt)
    stride = view.get("byteStride", size * n)
    base = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
    scale = None
    if acc.get("normalized"):
        scale = float((1 << (8 * size)) - 1) if fmt in "BHI" else float((1 << (8 * size - 1)) - 1)
    out = []
    for i in range(acc["count"]):
        vals = struct.unpack_from("<%d%s" % (n, fmt), binary, base + i * stride)
        out.append(tuple(v / scale for v in vals) if scale else vals)
    return out


def summary(path: str) -> dict:
    """Triangles, joints, clip names and lengths (s), bytes, and the attribute names of a written .glb."""
    doc, binary = read_glb(path)
    tris = 0
    attributes = set()
    for mesh in doc.get("meshes", []):
        for prim in mesh["primitives"]:
            attributes.update(prim["attributes"].keys())
            if "indices" in prim:
                tris += doc["accessors"][prim["indices"]]["count"] // 3
            else:
                tris += doc["accessors"][prim["attributes"]["POSITION"]]["count"] // 3
    joints = sum(len(skin["joints"]) for skin in doc.get("skins", []))
    clips = {}
    for anim in doc.get("animations", []):
        length = 0.0
        for sampler in anim["samplers"]:
            length = max(length, float(doc["accessors"][sampler["input"]]["max"][0]))
        clips[anim["name"]] = length
    return {
        "triangles": tris,
        "bones": joints,
        "clips": clips,
        "bytes": os.path.getsize(path),
        "attributes": sorted(attributes),
        "sha256": sha256(path),
    }


def update_manifest(out_rel: str, made_by: str, derived_from: str = "") -> None:
    """Records in tools/blender/manifest.json that made_by (a repo-relative tools/blender/*.py) wrote out_rel.
    derived_from is the data/asset_catalog.json id of a CC0 source the file is derived from, or ""."""
    path = repo_path(MANIFEST)
    manifest = {}
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            manifest = json.load(f)
    files = manifest.setdefault("files", {})
    key = "res://" + out_rel if not out_rel.startswith("res://") else out_rel
    files[key] = {"made_by": made_by, "derived_from": derived_from}
    manifest["_note"] = ("M2 AN2: which committed script under tools/blender/ wrote each generated .glb, and the "
                         "data/asset_catalog.json id of its CC0 source if it has one. Each script updates its own "
                         "rows; tools/asset_hashes.gd reads this file.")
    manifest["files"] = {k: files[k] for k in sorted(files)}
    text = json.dumps({"_note": manifest["_note"], "files": manifest["files"]}, indent="\t", sort_keys=False) + "\n"
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
