class_name SoldierSquadColour
extends RefCounted
## C3 (decision D2, Shibi, Nov 9 2026): a colour per squad. Every soldier shares one material; the squad colour is
## a per-instance shader value on the armor MeshInstance3D. The mesh marks its squad fields with vertex alpha 0
## (a colour in data/art_astra.json "colors" whose alpha is 0, today "squad": crest, cape, pauldrons).
## Palette: data/art_astra.json soldier.squad_colour (placeholder, OQ-3D-SQUAD-COLOUR). Presentation only.

const PARAM := &"squad_paint"
const _SHADER := preload("res://scripts/visual/shaders/soldier_armor.gdshader")
static var _material: ShaderMaterial


static func config() -> Dictionary:
	return LowpolyKit.config()["soldier"]["squad_colour"]


## The one material resource of every soldier and corpse.
static func material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = _SHADER
		_material.set_shader_parameter(&"roughness", float(LowpolyKit.config()["kit"]["roughness"]))
	return _material


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
