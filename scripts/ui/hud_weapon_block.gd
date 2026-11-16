class_name HudWeaponBlock
extends Control
## M2 H1b: the compact weapon block (passive, never takes a touch): the pawn's weapon slots with the held one marked,
## magazine / reserve and the name of the held weapon, and the shield and health bars. Placed by HudArrangement
## (data/ui.json hud_arrangement.weapon_block, OQ-HUD); slot icons are drawn here in code (no image files).
## GameHud owns the values: it fills shield_bar / health_bar / ammo_label / weapon_label and calls set_slots().

const KIND_EMPTY := ""
const KIND_RIFLE := "rifle"
const KIND_PISTOL := "pistol"
const KIND_BLADE := "blade"

var shield_bar: ProgressBar
var health_bar: ProgressBar
var ammo_label: Label
var weapon_label: Label
## One entry per loadout slot: {"kind": KIND_*, "held": bool}.
var slots: Array = [{"kind": KIND_EMPTY, "held": false}, {"kind": KIND_EMPTY, "held": false}, {"kind": KIND_EMPTY, "held": false}]
var _u: float = 1.0
var _slot_rects: Array[Rect2] = []


func _init() -> void:
	name = "WeaponBlock"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	shield_bar = _bar(HudStyle.role("shield"))
	health_bar = _bar(HudStyle.role("health"))
	ammo_label = HudStyle.label(self, HORIZONTAL_ALIGNMENT_RIGHT, HudStyle.role("text"))
	ammo_label.name = "Ammo"
	weapon_label = HudStyle.label(self, HORIZONTAL_ALIGNMENT_RIGHT, HudStyle.role("caption"))
	weapon_label.name = "WeaponName"


func _bar(fill: Color) -> ProgressBar:
	var b := ProgressBar.new()
	b.show_percentage = false
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var f := StyleBoxFlat.new()
	f.bg_color = fill
	b.add_theme_stylebox_override("fill", f)
	var bg := StyleBoxFlat.new()
	bg.bg_color = MenuStyle.color("field")
	b.add_theme_stylebox_override("background", bg)
	add_child(b)
	return b


## Lays the block out for a HUD of `view` size (rect from HudArrangement).
func layout(view: Vector2) -> void:
	var wb: Dictionary = HudArrangement.cfg()["weapon_block"]
	_u = HudArrangement.unit(view)
	HudStyle.place(self, HudArrangement.weapon_block_rect(view))
	var u := _u
	var pad := float(wb["pad_units"]) * u
	var sw := float(wb["slot_w_units"]) * u
	var sh := float(wb["slot_h_units"]) * u
	var gap := float(wb["slot_gap_units"]) * u
	var ammo_px := float(wb["ammo_font_units"]) * u
	var name_px := float(wb["name_font_units"]) * u
	HudStyle.set_font_px(ammo_label, ammo_px)
	HudStyle.set_font_px(weapon_label, name_px)
	# The top row is as tall as the ammo + name column (each label tall enough for its line) or the slots.
	var ammo_h := maxf(ammo_px * 1.25, ammo_label.get_minimum_size().y)
	var name_h := maxf(name_px * 1.3, weapon_label.get_minimum_size().y)
	var row_h := maxf(sh, ammo_h + name_h)
	_slot_rects.clear()
	for i in slots.size():
		_slot_rects.append(Rect2(pad + i * (sw + gap), pad + (row_h - sh) * 0.5, sw, sh))
	var ax := pad + slots.size() * (sw + gap) - gap + float(wb["row_gap_units"]) * u
	var aw := maxf(size.x - pad - ax, 0.0)
	var col_top := pad + (row_h - ammo_h - name_h) * 0.5
	HudStyle.place(ammo_label, Rect2(ax, col_top, aw, ammo_h))
	HudStyle.place(weapon_label, Rect2(ax, col_top + ammo_h, aw, name_h))
	var y := pad + row_h + float(wb["row_gap_units"]) * u
	var bw := size.x - 2.0 * pad
	var shield_h := float(wb["shield_h_units"]) * u
	HudStyle.place(shield_bar, Rect2(pad, y, bw, shield_h))
	HudStyle.place(health_bar, Rect2(pad, y + shield_h + float(wb["bar_gap_units"]) * u, bw, float(wb["health_h_units"]) * u))
	queue_redraw()


## The slot shown for a loadout entry (Weapon or null) at slot index `i`.
static func kind_of(weapon: Weapon, i: int) -> String:
	if weapon == null or weapon.def == null:
		return KIND_EMPTY
	if weapon.def.is_melee():
		return KIND_BLADE
	return KIND_PISTOL if i == Loadout.SLOT_NAMES.find("sidearm") else KIND_RIFLE


func set_slots(entries: Array) -> void:
	if entries == slots:
		return
	slots = entries
	queue_redraw()


func get_slot_rect(i: int) -> Rect2:
	return _slot_rects[i] if i < _slot_rects.size() else Rect2()


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var line := maxf(1.0, _u * 0.06)
	draw_style_box(HudStyle.plate(_u * 0.35, line), Rect2(Vector2.ZERO, size))
	var gold := HudStyle.role("held_slot")
	for i in mini(slots.size(), _slot_rects.size()):
		var r: Rect2 = _slot_rects[i]
		var kind := str(slots[i].get("kind", KIND_EMPTY))
		var held := bool(slots[i].get("held", false)) and kind != KIND_EMPTY
		var border := gold
		border.a = 1.0 if held else (0.4 if kind != KIND_EMPTY else 0.18)
		var box := HudStyle.plate(_u * 0.2, line, 1.0 if held else 0.55, border)
		if held:
			box.bg_color = gold
		draw_style_box(box, r)
		if kind != KIND_EMPTY:
			var ic := MenuStyle.color("night") if held else HudStyle.role("text")
			if not held:
				ic.a = 0.85
			_draw_icon(kind, r.grow(-r.size.y * 0.16), ic)


## Our own flat icons, in a box (normalised 0..1 coordinates, drawn left to right with the muzzle to the right).
func _draw_icon(kind: String, box: Rect2, c: Color) -> void:
	var p := func(x: float, y: float) -> Vector2: return box.position + Vector2(x, y) * box.size
	match kind:
		KIND_RIFLE:
			draw_colored_polygon(PackedVector2Array([p.call(0.02, 0.42), p.call(0.26, 0.36), p.call(0.26, 0.62), p.call(0.06, 0.72)]), c)
			draw_rect(Rect2(p.call(0.26, 0.32), box.size * Vector2(0.46, 0.24)), c)
			draw_rect(Rect2(p.call(0.72, 0.38), box.size * Vector2(0.27, 0.08)), c)
			draw_colored_polygon(PackedVector2Array([p.call(0.47, 0.56), p.call(0.58, 0.56), p.call(0.54, 0.86), p.call(0.44, 0.83)]), c)
			draw_colored_polygon(PackedVector2Array([p.call(0.31, 0.56), p.call(0.39, 0.56), p.call(0.36, 0.78), p.call(0.28, 0.76)]), c)
			draw_rect(Rect2(p.call(0.4, 0.2), box.size * Vector2(0.2, 0.08)), c)  # sight rail
		KIND_PISTOL:
			draw_rect(Rect2(p.call(0.2, 0.3), box.size * Vector2(0.6, 0.2)), c)
			draw_colored_polygon(PackedVector2Array([p.call(0.24, 0.5), p.call(0.42, 0.5), p.call(0.4, 0.86), p.call(0.22, 0.84)]), c)
			draw_rect(Rect2(p.call(0.42, 0.5), box.size * Vector2(0.1, 0.12)), c)  # trigger guard
		KIND_BLADE:
			draw_colored_polygon(PackedVector2Array([p.call(0.04, 0.5), p.call(0.16, 0.42), p.call(0.64, 0.42), p.call(0.64, 0.58), p.call(0.16, 0.58)]), c)
			draw_rect(Rect2(p.call(0.64, 0.26), box.size * Vector2(0.06, 0.48)), c)  # guard
			draw_rect(Rect2(p.call(0.7, 0.44), box.size * Vector2(0.18, 0.12)), c)  # grip
			draw_circle(p.call(0.92, 0.5), box.size.y * 0.1, c)  # pommel
