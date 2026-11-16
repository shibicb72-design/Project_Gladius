"""The soldier's rig data as the game reads it, in plain Python (no bpy), so that the Blender scripts and the
game agree by construction (M2 AN2 item 1).

- parts(): data/art_astra.json soldier.parts with data/art_soldier.json soldier.part_overrides laid over them by name
  and soldier.parts_add appended (scripts/visual/soldier_look.gd parts()).
- config(): data/anim.json with data/anim_third_person.json deep-merged over it (scripts/visual/soldier_rig.gd
  config()).
- rest_table(): every bone of the runtime skeleton in order, name -> parent and GLOBAL rest origin (Godot metres),
  computed exactly as SoldierRig.build does: anim.json "bones" (pivot "center", "top" or "head_shell") followed by
  the added bones of anim_third_person.json "bones_add" (pivot "offset": the named part's "at" plus offset_m), so
  that moving a pivot part in the data moves both the game's skeleton and the Blender armature.
- surface_id(), paint(): surface ids by name from data/art_materials.json surface_order and sRGB paint numbers from
  data/art_astra.json colors (never hard-coded).

Run as a script (python tools/blender/soldier_data.py) it prints the rest table.
"""

import json
import os

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
HEAD_AT = (0.0, 1.75, 0.0)  # the pawn's Head node (scenes/pawn.tscn); the head hitbox centre, r 0.22


def read_json(rel: str) -> dict:
    if rel.startswith("res://"):
        rel = rel[len("res://"):]
    with open(os.path.join(REPO, *rel.split("/")), "r", encoding="utf-8") as f:
        return json.load(f)


def _copy(v):
    return json.loads(json.dumps(v))


def parts() -> list:
    astra = read_json("data/art_astra.json")
    soldier = read_json("data/art_soldier.json")["soldier"]
    over = soldier.get("part_overrides", {})
    out = []
    for part in astra["soldier"]["parts"]:
        merged = _copy(part)
        name = str(part["name"])
        if name in over:
            for key, value in over[name].items():
                if not key.startswith("_"):
                    merged[key] = _copy(value)
        if not bool(merged.get("hidden", False)):
            out.append(merged)
    for part in soldier.get("parts_add", []):
        out.append({k: _copy(v) for k, v in part.items() if not k.startswith("_")})
    return out


def _merge(into: dict, over: dict) -> None:
    for key, value in over.items():
        if isinstance(into.get(key), dict) and isinstance(value, dict):
            _merge(into[key], value)
        else:
            into[key] = _copy(value)


def config() -> dict:
    merged = read_json("data/anim.json")
    overlay = {k: v for k, v in read_json("data/anim_third_person.json").items() if not k.startswith("_")}
    _merge(merged, overlay)
    return merged


def bone_rows() -> list:
    """anim.json "bones" followed by anim_third_person.json "bones_add" (SoldierRig.bone_rows)."""
    cfg = config()
    return list(cfg["bones"]) + [b for b in cfg.get("bones_add", []) if isinstance(b, dict)]


def rest_table(head_at=HEAD_AT) -> list:
    """[(name, parent, (x, y, z) global rest origin)] in skeleton order, Godot metres; every basis is identity."""
    by_name = {p["name"]: p for p in parts()}
    out = []
    for bone in bone_rows():
        part = by_name[bone["part"]]
        at = [float(part["at"][0]), float(part["at"][1]), float(part["at"][2])]
        pivot = bone["pivot"]
        if pivot == "top":
            at[1] += float(part["size"][1]) * 0.5
        elif pivot == "head_shell":
            at = [float(head_at[0]), float(head_at[1]), float(head_at[2])]
        elif pivot == "offset":
            off = bone["offset_m"]
            at = [at[0] + float(off[0]), at[1] + float(off[1]), at[2] + float(off[2])]
        elif pivot != "center":
            raise ValueError("unknown pivot %s of bone %s" % (pivot, bone["name"]))
        out.append((bone["name"], bone["parent"], tuple(at)))
    return out


_ORDER = None


def surface_id(name: str) -> int:
    """Place of `name` in data/art_materials.json surface_order (WorldSurface.surface_id); unknown -> error."""
    global _ORDER
    if _ORDER is None:
        _ORDER = list(read_json("data/art_materials.json")["surface_order"])
    if name not in _ORDER:
        raise KeyError("no surface named %s in data/art_materials.json surface_order" % name)
    return _ORDER.index(name)


def paint(name: str) -> tuple:
    """sRGB RGBA of data/art_astra.json colors[name] (alpha 0 = a squad field)."""
    c = read_json("data/art_astra.json")["colors"][name]
    return (float(c[0]), float(c[1]), float(c[2]), float(c[3]) if len(c) > 3 else 1.0)


if __name__ == "__main__":
    for name, parent, at in rest_table():
        print("%-14s %-14s (%.4f, %.4f, %.4f)" % (name, parent or "-", at[0], at[1], at[2]))
    for p in parts():
        print("PART %-16s %-10s at=%s size=%s %s %s" % (p["name"], p.get("shape", "box"), p["at"], p["size"],
                                                      p.get("color"), p.get("surface", "")))
