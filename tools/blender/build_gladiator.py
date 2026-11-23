"""Rebuild the procedural Murmillo and its two PBR atlases with Blender 5.3.

blender.cmd -b --factory-startup --python-exit-code 1 --python tools/blender/build_gladiator.py
"""

import json
import math
import os
import re
import struct
import sys
import zlib

import bpy
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_soldier
import gladius_bl as gbl
import gladiator_geom
import soldier_data
import soldier_geom

SCRIPT = "tools/blender/build_gladiator.py"
PROVENANCE = "AI-free, made in Blender by GPT-6.2 Sol"
ATLAS_COLUMNS = 4


def skinned_mesh(name, geo, arm, material_names, bone_names):
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([gbl.godot_to_blender(p) for p in geo.pos], [], [f[0] for f in geo.faces])
    mesh.update()
    uv = mesh.uv_layers.new(name="UVMap")
    texcoords = [0.0] * len(mesh.loops) * 2
    for poly, (indices, style, _) in zip(mesh.polygons, geo.faces):
        cell = material_names.index(style)
        u_cell, v_cell = cell % ATLAS_COLUMNS, cell // ATLAS_COLUMNS
        points = [geo.pos[i] for i in indices]
        normal = soldier_geom.norm(soldier_geom.newell(points))
        u_axis, v_axis = build_soldier._uv_axes(normal)
        for li, pt in zip(poly.loop_indices, points):
            u = .5 + soldier_geom.dot(pt, u_axis) * .68
            v = .5 + (soldier_geom.dot(pt, v_axis) - v_axis[1] * 1.05) * .395
            texcoords[li * 2:li * 2 + 2] = (
                (u_cell + u) / ATLAS_COLUMNS, (v_cell + v) / ATLAS_COLUMNS)
    uv.data.foreach_set("uv", texcoords)
    mesh.shade_smooth()
    mesh.set_sharp_from_angle(angle=math.radians(44))
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    obj.parent = arm
    triangles = obj.modifiers.new("Export triangles", "TRIANGULATE")
    triangles.keep_custom_normals = True
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=triangles.name)
    modifier = obj.modifiers.new("Armature", "ARMATURE")
    modifier.object = arm
    groups = {bone: obj.vertex_groups.new(name=bone) for bone in bone_names}
    for i, weights in enumerate(geo.wts):
        for bone, weight in weights.items():
            groups[bone].add([i], weight, "REPLACE")
    return obj


def surface_pattern(finish, u, v):
    """Analytic, resolution-independent grain and wear. No random sampling or GPU bake."""
    fine = np.sin(2 * np.pi * (43 * u + 59 * v)) * np.sin(2 * np.pi * (87 * u - 31 * v))
    cloud = np.sin(2 * np.pi * (3 * u + 2 * v + .13 * np.sin(23 * v))) * np.cos(2 * np.pi * (4 * v - u))
    if finish == "metal":
        scratch = np.maximum(0, np.sin(2 * np.pi * (7 * u + 91 * v + .26 * np.sin(11 * u)))) ** 9
        scratch *= np.maximum(0, np.cos(49 * u - 8 * v)) ** 5
        return (.44 * cloud + .13 * fine + .42 * scratch, .09 * cloud + .08 * fine + .15 * scratch)
    if finish == "cloth":
        loom = np.cos(2 * np.pi * 48 * u) * np.cos(2 * np.pi * 52 * v)
        return (.27 * cloud + .45 * loom + .11 * fine, .68 * loom + .1 * fine)
    if finish == "hair":
        strands = np.sin(2 * np.pi * (60 * u + 14 * v + .3 * np.sin(17 * v)))
        return (.24 * cloud + .56 * strands + .16 * fine, .47 * strands + .13 * fine)
    if finish == "leather":
        grain = np.sin(2 * np.pi * (23 * u + 1.3 * np.sin(31 * v))) * np.sin(2 * np.pi * (31 * v + np.sin(27 * u)))
        return (.35 * cloud + .25 * grain + .13 * fine, .26 * grain + .18 * fine)
    return (.14 * cloud + .04 * fine, .05 * fine)


def atlas(size, kind, palette):
    """RGB PNG, with glTF/Godot UV-up cells written into PNG's top-down rows."""
    extent = size // ATLAS_COLUMNS
    samples = (np.arange(extent) + .5) / extent
    u, v = samples[None, :], 1 - samples[:, None]
    result = np.zeros((size, size, 3), dtype=np.uint8)
    for cell, (paint, rough, metal, finish, mask) in enumerate(palette.values()):
        grain, height = surface_pattern(finish, u, v)
        if kind == "albedo":
            zone = np.asarray(paint)[None, None, :] * (1 + .21 * grain[:, :, None])
        elif kind == "normal":
            dy, dx = np.gradient(height)
            # PNG rows descend, so image up gives the positive tangent-space Y axis.
            xyz = np.stack((-dx * .25, dy * .25, np.ones_like(dx)), axis=-1)
            zone = .5 + .5 * xyz / np.linalg.norm(xyz, axis=-1, keepdims=True)
        elif kind == "orm":
            zone = np.stack((1 - .11 * np.maximum(0, -grain), rough - .14 * grain,
                             np.full_like(grain, metal)), axis=-1)
        else:
            # Red and green use a little relief from the albedo so paint retains surface grain.
            coverage = np.clip(.87 + .18 * grain, 0, 1)
            zero = np.zeros_like(coverage)
            zone = np.stack((coverage if mask == "squad" else zero,
                             coverage if mask == "tier" else zero, zero), axis=-1)
        x = (cell % ATLAS_COLUMNS) * extent
        y = (ATLAS_COLUMNS - 1 - cell // ATLAS_COLUMNS) * extent
        result[y:y + extent, x:x + extent] = np.rint(np.clip(zone, 0, 1) * 255).astype(np.uint8)
    return result


def write_png(rel, pixels):
    def chunk(name, data):
        return struct.pack(">I", len(data)) + name + data + struct.pack(">I", zlib.crc32(name + data))

    size = len(pixels)
    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    # Sub filtering keeps the high-resolution procedural grain reasonably compact.
    rows = np.zeros((size, size * 3 + 1), dtype=np.uint8)
    rows[:, 0] = 1
    rows[:, 1:4] = pixels[:, 0]
    rows[:, 4:] = (pixels[:, 1:] - pixels[:, :-1]).reshape(size, -1)
    with open(gbl.repo_path(rel), "wb") as out:
        out.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
                  + chunk(b"IDAT", zlib.compress(rows.tobytes(), 9)) + chunk(b"IEND", b""))


def record_manifest(paths):
    manifest_file = gbl.repo_path(gbl.MANIFEST)
    with open(manifest_file, encoding="utf-8") as source:
        original = source.read()
    # Preserve other slices' ledger rows verbatim.
    clean = re.sub(r'^[ \t]+"res://assets/generated/characters/gladiator[^"\n]*":\s*\{[^{}]*\},?[ \t]*\n',
                   "", original, flags=re.MULTILINE)
    files = re.search(r'(?m)^[ \t]+"files":\s*\{\n', clean)
    row = {"made_by": SCRIPT, "derived_from": "", "provenance": PROVENANCE}
    added = "".join(
        "                  " + json.dumps("res://" + path) + ": " + json.dumps(row) + ",\n"
        for path in sorted(paths)
    )
    manifest = clean[:files.end()] + added + clean[files.end():]
    json.loads(manifest)
    with open(manifest_file, "w", encoding="utf-8", newline="\n") as out:
        out.write(manifest)


def main():
    config = soldier_data.read_json("data/cosmetics.json")["armour_sets"]["murmillo"]
    design = soldier_data.read_json("tools/blender/soldier_design.json")
    rests = soldier_data.rest_table()
    palette = config["build"]["palette"]
    path = config["glb"].removeprefix("res://")
    prefix = config["atlas_prefix"].removeprefix("res://")
    gbl.reset_scene()
    arm = gbl.soldier_armature()
    paths = [path]
    for lod in ("near", "far"):
        geom = gladiator_geom.Gladiator(design, lod, rests, config["build"]["segments"][lod]).build()
        skinned_mesh(config[lod + "_node"], geom, arm, list(palette), [name for name, _, _ in rests])
        for kind, size in config["texture_sizes"][lod].items():
            image_path = prefix + lod + "_" + kind + ".png"
            write_png(image_path, atlas(size, kind, palette))
            paths.append(image_path)
    absolute = gbl.export_glb(path, export_tangents=True, export_animations=False)
    record_manifest(paths)
    print("GLADIATOR", build_soldier.mesh_summary(absolute))
    for rel in paths:
        print("GLADIATOR_SHA256", gbl.sha256(gbl.repo_path(rel)), rel)


if __name__ == "__main__":
    main()
