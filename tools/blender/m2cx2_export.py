"""Shared GLB export for original Alesia 500 families using W1's mesh and vertex format."""

from pathlib import Path
import bpy
import m2w1_world_kit as kit


def export_family(family, builders):
    data = kit.Data()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    kit.SHADE_RANGE[0] = float(data.cfg["shade_bake"]["shade_range"])
    for key, build in builders.items():
        look = data.cfg["types"][key]
        for near, node in ((True, look["node"]), (False, look.get("lod1_node"))):
            if not node:
                continue
            mesh = kit.Builder(data, node)
            build(mesh, data, near)
            fit = kit.fit_check(data, key, mesh.tris)
            print(f"CX2_MESH {node} triangles={len(mesh.tris)} {fit}")
            if "FIT_FAIL" in fit:
                raise ValueError(f"{node}: {fit}")
            tris = kit.bake_shade(data, mesh.tris, "structure", 0 if near else 1)
            kit.make_object(node, tris)
    kit.export(str(Path(kit.REPO) / "assets/generated/world" / f"m2cx2_{family}.glb"))
