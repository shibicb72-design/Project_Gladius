"""Rebuild the A1 props with Blender 5.3.

blender.cmd -b --factory-startup --python tools/blender/a1_tripo_props.py
Pass -- --pilot PATH once to also reduce the two original Tripo exports.
Painting samples the source-space surface through the exported UV atlas.
"""

import argparse
import json
import math
from pathlib import Path
import struct
import sys
import zlib

import bmesh
import bpy
from mathutils import Matrix
import numpy as np


ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "assets/third_party/tripo"
WORLD = ROOT / "assets/generated/world"
PROVENANCE = "AI-generated with Tripo AI (tripo3d.ai), repainted in Blender"
ORIGINALS = {
    "forum_stall": "stall/market_stall_h25.glb",
    "farm_cart": "cart/cart_h25.glb",
}


def glb_parts(path):
    data = path.read_bytes()
    length, kind = struct.unpack_from("<I4s", data, 12)
    if kind != b"JSON":
        raise ValueError(path)
    return json.loads(data[20:20 + length]), data[20 + length:]


def write_glb(path, doc, binary):
    encoded = json.dumps(doc, separators=(",", ":"), ensure_ascii=False).encode()
    encoded += b" " * (-len(encoded) % 4)
    path.write_bytes(
        struct.pack("<4sIII4s", b"glTF", 2, 20 + len(encoded) + len(binary), len(encoded), b"JSON")
        + encoded + binary
    )


def open_mesh(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(path))
    meshes = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    if len(meshes) != 1:
        raise ValueError(f"{path}: expected one source mesh")
    obj = meshes[0]
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    return obj


def simplify(obj, cap):
    bpy.context.view_layer.objects.active = obj
    mesh = obj.data
    mesh.calc_loop_triangles()
    modifier = obj.modifiers.new("Triangle budget", "DECIMATE")
    modifier.ratio = (cap - 1) / len(mesh.loop_triangles)
    modifier.use_collapse_triangulate = True
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    obj.data.calc_loop_triangles()
    count = len(obj.data.loop_triangles)
    if count > cap:
        raise ValueError(f"{obj.name}: {count} exceeds {cap}")
    for face in obj.data.polygons:
        face.use_smooth = True
    return count


def export(path):
    bpy.ops.export_scene.gltf(
        filepath=str(path), export_format="GLB", export_tangents=True,
        export_animations=False, export_cameras=False, export_lights=False,
    )


def source_path(name):
    return SOURCES / f"{name}_reduced.glb"


def reduce_sources(pilot):
    SOURCES.mkdir(parents=True, exist_ok=True)
    for name, relative in ORIGINALS.items():
        original = pilot / relative
        doc, _ = glb_parts(original)
        obj = open_mesh(original)
        count = simplify(obj, 60000)
        path = source_path(name)
        export(path)
        reduced, binary = glb_parts(path)
        reduced["asset"]["copyright"] = PROVENANCE
        reduced["asset"]["extras"] = {"original_asset": doc["asset"]}
        write_glb(path, reduced, binary)
        print(f"A1 SOURCE {name} triangles={count}", flush=True)


def unwrap(obj):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(64), island_margin=0.003, margin_method="FRACTION")
    bpy.ops.object.mode_set(mode="OBJECT")


def repair_stall_far(obj, cap):
    """Replace the thin, folded scan layers before collapse can cross them."""
    source = bmesh.new()
    source.from_mesh(obj.data)
    obsolete = []
    for face in source.faces:
        x, y, z = face.calc_center_median()
        ridge_post = abs(y) > .315 and abs(x) < .033 and z < .956
        if (z > .826 and not ridge_post) or (abs(x) > .278 and z > .674):
            obsolete.append(face)
    bmesh.ops.delete(source, geom=obsolete, context="FACES")
    source.to_mesh(obj.data)
    source.free()

    # Cross-sections from the asymmetrical Tripo canopy, including the longer
    # slope on the positive-X side and the rise toward its ridge.
    profile = [
        (-.307, .842), (-.269, .846), (-.229, .853), (-.184, .862),
        (-.145, .877), (-.105, .907), (-.067, .936), (-.03, .973),
        (.001, .996), (.039, .992), (.078, .961), (.121, .925),
        (.164, .891), (.206, .866), (.254, .851), (.307, .844),
    ]
    intervals = 22
    cloth_triangles = 2 * (len(profile) + 1) * intervals
    body_count = simplify(obj, cap - cloth_triangles)
    source = bmesh.new()
    source.from_mesh(obj.data)
    cloth = source.faces.layers.int.new("a1_cloth")

    def panel(corners):
        face = source.faces.new(corners)
        face.smooth = True
        face[cloth] = 1

    width = .394
    span = np.linspace(-width, width, intervals + 1)
    roof = []
    for x, top in profile:
        roof.append([
            source.verts.new((x, y, top - .011 * (1 - (y / width) ** 2)))
            for y in span
        ])
    for left, right in zip(roof, roof[1:]):
        for j in range(intervals):
            panel((left[j], right[j], right[j + 1], left[j + 1]))
    for edge, side in ((roof[0], -1), (roof[-1], 1)):
        hem = [
            source.verts.new((side * (.306 + .0015 * (j % 2)), y, .724 - .032 * (j % 2)))
            for j, y in enumerate(span)
        ]
        for j in range(intervals):
            corners = (edge[j], hem[j], hem[j + 1], edge[j + 1])
            panel(corners if side > 0 else corners[::-1])
    source.to_mesh(obj.data)
    source.free()
    obj.data.update()
    return body_count + cloth_triangles


def paint(name, points, normal, is_cloth):
    x, y, z = points.T
    nx, ny, nz = normal
    # Mottling and grain remain in source space, so disconnected UV islands agree at seams.
    axis = y if name == "forum_stall" else x
    cross = z + (x if name == "forum_stall" else y) * (0.55 + 0.40 * abs(nz))
    if z.mean() > 0.33 and name == "forum_stall" and abs(nx) + abs(ny) > 1.0:
        axis, cross = z, x + y
    warp = 1.8 * np.sin(axis * 44 + cross * 18) + 1.2 * np.sin(axis * 93)
    grain = np.sin(cross * 820 + warp) * 0.6 + np.sin(cross * 2070 + warp) * 0.4
    streak = np.sin(cross * 240 + np.sin(axis * 31))
    age = np.sin(x * 93 + y * 51 + z * 89) * np.sin(x * 46 - y * 69 + z * 37)
    wood_dark = (0.5 + 0.5 * np.cos(z * (175 if name == "forum_stall" else 250))) ** 16
    wood_value = 0.99 + 0.085 * grain + 0.075 * streak + 0.09 * age - 0.14 * wood_dark + 0.13 * max(nz, 0)
    rgb = np.outer(wood_value, (145, 99, 61))
    height = grain * 0.19 + streak * 0.12
    ao = np.full_like(z, 0.91 - 0.12 * max(-nz, 0)) - 0.035 * wood_dark
    rough = np.full_like(z, 0.81) + grain * 0.05
    metal = np.zeros_like(z)

    def coat(mask, color, value, relief, occlusion, roughness, metallic):
        rgb[mask] = np.outer(value[mask], color)
        height[mask] = relief[mask]
        ao[mask] = occlusion
        rough[mask] = roughness
        metal[mask] = metallic

    weave = np.sin(x * 1100 + z * 260) * np.sin(y * 1400)
    if name == "forum_stall":
        ax = abs(x)
        roof_line = np.where(x >= 0,
                             np.interp(ax, (0, .047, .18, .24, .31), (.954, .951, .84, .83, .816)),
                             np.interp(ax, (0, .05, .17, .24, .31), (.954, .912, .835, .827, .816)))
        cloth = ((z > roof_line) & (z > .8)) | ((ax > .278) & (z > .675))
        if is_cloth:
            cloth = np.ones_like(cloth, dtype=bool)
        stripe = np.floor((y + .033 + .0014 * np.sin(x * 50)) / .071) % 2 == 0
        hem = (0.5 + 0.5 * np.cos(z * 550)) ** 10
        daylight = .88 + .15 * max(nz, 0) + .04 * age + .032 * weave
        daylight += 0.07 * np.sin(y * 87) - .09 * hem * (ax > .276)
        coat(cloth & stripe, (164, 50, 39), daylight, weave * .19, .91, .93, 0)
        coat(cloth & ~stripe, (210, 164, 75), daylight, weave * .19, .91, .93, 0)
        pots = (z > .329) & (z < .545) & (abs(y) < .315)
        band = .96 + .09 * age + .045 * np.cos(z * 405)
        coat(pots & (y < .065), (171, 78, 47), band, grain * .07, .92, .78, 0)
        coat(pots & (y >= .065), (154, 110, 53), band, grain * .07, .92, .56, .63)
    else:
        radius = np.hypot(x - .256, z - .189)
        wheel = abs(y) > .218
        tyre = wheel & (radius > .171)
        hub = (abs(y) > .276) & (radius < .053)
        coat(tyre, (68, 69, 65), .97 + .17 * age + .12 * abs(nz), grain * .12, .9, .64, .8)
        coat(hub, (147, 113, 53), .99 + .14 * age + .10 * abs(ny), grain * .08, .93, .59, .7)
        cargo = (abs(y) < .203) & (x > .017) & (x < .455) & (z > .398)
        pottery = cargo & (x > .296)
        sack = cargo & (x < .275) & (y > -.025)
        roll = cargo & ~pottery & ~sack & (y < -.025)
        band = .96 + .11 * age + .05 * np.cos(z * 382)
        coat(pottery, (173, 86, 55), band, grain * .08, .92, .78, 0)
        coat(sack, (174, 153, 110), .91 + .13 * age + .05 * weave, weave * .19, .91, .97, 0)
        trim = (abs(x - .14) < .012) | (abs(x - .268) < .012)
        coat(roll & ~trim, (137, 47, 37), band, weave * .17, .89, .92, 0)
        coat(roll & trim, (187, 142, 63), band, weave * .17, .89, .92, 0)
    return np.column_stack((rgb, height, ao, rough, metal))


def bake(obj, name, size):
    mesh = obj.data
    mesh.calc_loop_triangles()
    uv_data = mesh.uv_layers.active.data
    cloth = mesh.attributes.get("a1_cloth")
    atlas = np.zeros((size, size, 7), np.float32)
    mask = np.zeros((size, size), bool)
    for face in mesh.loop_triangles:
        uv = np.array([uv_data[i].uv[:] for i in face.loops]) * size - .5
        uv[:, 1] = size - 1 - uv[:, 1]
        low = np.maximum(0, np.ceil(uv.min(axis=0)).astype(int))
        high = np.minimum(size - 1, np.floor(uv.max(axis=0)).astype(int))
        if np.any(high < low):
            continue
        delta_x, delta_y = (uv[1:] - uv[0]).T
        det = delta_x[0] * delta_y[1] - delta_x[1] * delta_y[0]
        if abs(det) < 1e-8:
            continue
        rows, cols = np.ogrid[low[1]:high[1] + 1, low[0]:high[0] + 1]
        dx, dy = cols - uv[0, 0], rows - uv[0, 1]
        b = (dx * delta_y[1] - dy * delta_x[1]) / det
        c = (dy * delta_x[0] - dx * delta_y[0]) / det
        inside = (b >= -1e-6) & (c >= -1e-6) & (b + c <= 1.000001)
        if not inside.any():
            continue
        corners = np.array([mesh.vertices[v].co[:] for v in face.vertices])
        points = corners[0] + b[inside, None] * (corners[1] - corners[0]) + c[inside, None] * (corners[2] - corners[0])
        r, col = np.nonzero(inside)
        indexes = (r + low[1], col + low[0])
        is_cloth = cloth is not None and bool(cloth.data[face.polygon_index].value)
        atlas[indexes] = paint(name, points, face.normal, is_cloth)
        mask[indexes] = True
    print(f"A1 ATLAS {obj.name} occupied={mask.mean():.3f}", flush=True)
    # Extend island edges into their gutters before lower-resolution sampling and mipmap generation.
    for _ in range(8):
        before = mask.copy()
        for axis, step in ((0, -1), (0, 1), (1, -1), (1, 1)):
            promoted = np.roll(before, step, axis=axis) & ~mask
            row, col = np.nonzero(promoted)
            atlas[row, col] = atlas[(row - step) % size, col] if axis == 0 else atlas[row, (col - step) % size]
            mask[promoted] = True
    return atlas


def png(path, rgb):
    height, width, _ = rgb.shape
    pixels = np.rint(np.clip(rgb, 0, 255)).astype(np.uint8)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    # PNG Sub filter reduces the size of the smooth paint and of the empty atlas gutters.
    filtered = pixels.copy()
    filtered[:, 1:] -= pixels[:, :-1]
    raw = b"".join(b"\x01" + row.tobytes() for row in filtered)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
    )


def texture_maps(obj, name, far):
    size = 512 if far else 2048
    atlas = bake(obj, name, size)
    folder = WORLD / "a1"
    folder.mkdir(parents=True, exist_ok=True)
    paths = [folder / f"{obj.name}_albedo.png"]
    png(paths[0], atlas[:, :, :3])
    if not far:
        small = atlas.reshape(1024, 2, 1024, 2, 7).mean(axis=(1, 3))
        relief = small[:, :, 3]
        dy, dx = np.gradient(relief)
        normal = np.stack((-dx * .65, dy * .65, np.ones_like(dx)), axis=2)
        normal /= np.linalg.norm(normal, axis=2, keepdims=True)
        paths += [folder / f"{obj.name}_normal.png", folder / f"{obj.name}_orm.png"]
        png(paths[1], (normal * .5 + .5) * 255)
        png(paths[2], small[:, :, 4:] * 255)
    return [path.relative_to(WORLD).as_posix() for path in paths]


def finish_glb(path, textures, original):
    doc, binary = glb_parts(path)
    doc["asset"]["copyright"] = PROVENANCE
    doc["asset"]["extras"] = {
        "provenance": PROVENANCE,
        "original_asset": original["asset"]["extras"]["original_asset"],
        "original_nodes": [node["name"] for node in original["nodes"]],
    }
    doc["images"] = []
    doc["textures"] = []
    doc["materials"] = []
    for node in doc["nodes"]:
        name = node["name"]
        indices = []
        for uri in textures[name]:
            index = len(doc["images"])
            doc["images"].append({"uri": uri, "name": Path(uri).stem})
            doc["textures"].append({"source": index})
            indices.append({"index": index})
        pbr = {"baseColorTexture": indices[0], "roughnessFactor": .86, "metallicFactor": 0}
        material = {"name": f"{name}_paint", "pbrMetallicRoughness": pbr, "doubleSided": True}
        if len(indices) == 3:
            pbr.update(metallicRoughnessTexture=indices[2], roughnessFactor=1, metallicFactor=1)
            material.update(normalTexture=indices[1], occlusionTexture=indices[2])
        primitive, = doc["meshes"][node["mesh"]]["primitives"]
        primitive["material"] = len(doc["materials"])
        doc["materials"].append(material)
    write_glb(path, doc, binary)


def build(name, config):
    source = source_path(name)
    near = open_mesh(source)
    far = near.copy()
    far.data = near.data.copy()
    bpy.context.collection.objects.link(far)
    budget = config["budgets"]
    fit = config["types"][name]["_a1_fit"]
    transform = Matrix.Rotation(math.radians(fit["blender_yaw_deg"]), 4, "Z") @ Matrix.Scale(fit["uniform_scale"], 4)
    textures = {}
    for obj, suffix, cap in (
        (near, "", budget["near_tris"][name]),
        (far, "_lod1", config["lod1_max_tris_by_type"][name]),
    ):
        obj.name = name + suffix
        if name == "forum_stall" and obj == far:
            count = repair_stall_far(obj, cap)
        else:
            count = simplify(obj, cap)
        unwrap(obj)
        textures[obj.name] = texture_maps(obj, name, obj == far)
        obj.data.transform(transform)
        coords = np.array([v.co[:] for v in obj.data.vertices])
        print(f"A1 MESH {obj.name} triangles={count} Blender bounds={coords.min(0)} .. {coords.max(0)}", flush=True)
    path = WORLD / f"a1_{name}.glb"
    export(path)
    finish_glb(path, textures, glb_parts(source)[0])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pilot", type=Path)
    args = parser.parse_args(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
    if args.pilot:
        reduce_sources(args.pilot)
    config = json.loads((ROOT / "data/art_world_kit.json").read_text(encoding="utf-8"))
    for name in ORIGINALS:
        build(name, config)


if __name__ == "__main__":
    main()
