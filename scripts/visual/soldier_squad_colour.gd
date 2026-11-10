class_name SoldierSquadColour
extends RefCounted
## C3 (decision D2, Shibi, Nov 9 2026): a colour per squad. Every soldier shares one material; the squad colour is
## a per-instance shader value on the armor MeshInstance3D. The mesh marks its squad fields with vertex alpha 0
## (a colour in data/art_astra.json "colors" whose alpha is 0, today "squad": crest, cape, pauldrons).
## Palette: data/art_astra.json soldier.squad_colour (placeholder, OQ-3D-SQUAD-COLOUR). Presentation only.

const PARAM := &"squad_paint"
const TIER_PARAM := &"tier_paint"
const _SHADER := preload("res://scripts/visual/shaders/soldier_armor.gdshader")
static var _material: ShaderMaterial


static func config() -> Dictionary:
	return LowpolyKit.config()["soldier"]["squad_colour"]


## The one material resource of every soldier and corpse.
static func material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = _SHADER
		# S4: the soldier's paint sits on the same textured surfaces as the world (data/art_materials.json).
		WorldSurface.adopt(_material)
		var look: Dictionary = LowpolyKit.config()["soldier"]["material"]
		_material.set_shader_parameter(&"tier_surface", WorldSurface.surface_id(String(look["tier_surface"])))
		_material.set_shader_parameter(&"part_shade", float(look["part_shade"]))
		_material.set_shader_parameter(&"rim_color", GreyboxArt.color_value(look["rim_color"]))
		_material.set_shader_parameter(&"rim", float(look["rim"]))
		_material.set_shader_parameter(&"rim_power", float(look["rim_power"]))
	return _material


## S4: the armor tier a soldier shows (Pawn.armor_tier, read-only): the tier trim's paint and glow, per instance.
## Tier 0, or a tier the data does not list, keeps the trim's own paint.
static func apply_tier(armor: GeometryInstance3D, tier: int) -> void:
	var tiers: Array = LowpolyKit.config()["soldier"]["material"]["armor_tiers"]
	if tier <= 0 or tier > tiers.size():
		armor.set_instance_shader_parameter(TIER_PARAM, Vector4(0.0, 0.0, 0.0, -1.0))
		return
	var entry: Dictionary = tiers[tier - 1]
	var c := GreyboxArt.color_value(entry["paint"])
	armor.set_instance_shader_parameter(TIER_PARAM, Vector4(c.r, c.g, c.b, float(entry["glow"])))


## The squad's paint as written in data (sRGB). Ids past the palette wrap around; a negative id is "no squad".
static func paint(squad_id: int) -> Color:
	var cfg := config()
	var palette: Array = cfg["palette"]
	if squad_id < 0 or palette.is_empty():
		return GreyboxArt.color_value(cfg["no_squad"])
	return GreyboxArt.color_value(palette[squad_id % palette.size()])


static func apply(armor: GeometryInstance3D, squad_id: int) -> void:
	var c := paint(squad_id)
	armor.set_instance_shader_parameter(PARAM, Vector3(c.r, c.g, c.b))


## The paint an instance shows now (sRGB), or null before apply().
static func shown(armor: GeometryInstance3D) -> Variant:
	return armor.get_instance_shader_parameter(PARAM)


## A corpse keeps the colour its soldier had.
static func copy(from: GeometryInstance3D, to: GeometryInstance3D) -> void:
	to.set_instance_shader_parameter(PARAM, from.get_instance_shader_parameter(PARAM))
	var tier: Variant = from.get_instance_shader_parameter(TIER_PARAM)
	if tier != null:
		to.set_instance_shader_parameter(TIER_PARAM, tier)
