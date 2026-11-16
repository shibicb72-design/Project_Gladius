class_name HudChip
extends Control
## M2 H1b: the small top-left chip (passive, never takes a touch): players alive (and squads alive in squads) and the
## zone timer, each behind an icon drawn here in code. Placed by HudArrangement (data/ui.json hud_arrangement.chip,
## OQ-HUD). GameHud fills alive_label / squads_label / zone_label and sets zone_state and show_squads.

var alive_label: Label
var squads_label: Label
var zone_label: Label
var show_squads := false:
	set(v):
		if v != show_squads:
			show_squads = v
			_relayout()
var zone_state := "":
	set(v):
		if v != zone_state:
			zone_state = v
			queue_redraw()
var _u: float = 1.0
var _icons: Dictionary = {}  # icon name -> Rect2


func _init() -> void:
	name = "Chip"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	alive_label = HudStyle.label(self, HORIZONTAL_ALIGNMENT_LEFT, HudStyle.role("text"))
	alive_label.name = "Alive"
	squads_label = HudStyle.label(self, HORIZONTAL_ALIGNMENT_LEFT, HudStyle.role("text"))
	squads_label.name = "Squads"
	zone_label = HudStyle.label(self, HORIZONTAL_ALIGNMENT_LEFT, HudStyle.role("text"))
	zone_label.name = "Zone"


func layout(view: Vector2) -> void:
	_u = HudArrangement.unit(view)
	HudStyle.place(self, HudArrangement.chip_rect(view))
	_relayout()


func _relayout() -> void:
	var c: Dictionary = HudArrangement.cfg()["chip"]
	var u := _u
	var pad := 0.3 * u
	var icon := float(c["icon_units"]) * u
	var row_h := (size.y - 2.0 * pad) * 0.5
	var font := float(c["font_units"]) * u
	for l: Label in [alive_label, squads_label, zone_label]:
		HudStyle.set_font_px(l, font)
	var text_x := pad + icon + 0.2 * u
	var half := (size.x - 2.0 * pad) * 0.5
	_icons.clear()
	_icons["alive"] = Rect2(pad, pad + (row_h - icon) * 0.5, icon, icon)
	if show_squads:
		HudStyle.place(alive_label, Rect2(text_x, pad, half - (text_x - pad), row_h))
		_icons["squads"] = Rect2(pad + half, pad + (row_h - icon) * 0.5, icon, icon)
		HudStyle.place(squads_label, Rect2(pad + half + icon + 0.2 * u, pad, half - icon - 0.2 * u, row_h))
	else:
		HudStyle.place(alive_label, Rect2(text_x, pad, size.x - pad - text_x, row_h))
		HudStyle.place(squads_label, Rect2(text_x, pad, 0.0, row_h))
	squads_label.visible = show_squads
	_icons["zone"] = Rect2(pad, pad + row_h + (row_h - icon) * 0.5, icon, icon)
	HudStyle.place(zone_label, Rect2(text_x, pad + row_h, size.x - pad - text_x, row_h))
	queue_redraw()


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var line := maxf(1.0, _u * 0.06)
	draw_style_box(HudStyle.plate(_u * 0.3, line), Rect2(Vector2.ZERO, size))
	var text := HudStyle.role("text")
	var gold := MenuStyle.color("gold")
	if _icons.has("alive"):
		_person(_icons["alive"], text)
	if show_squads and _icons.has("squads"):
		var r: Rect2 = _icons["squads"]
		_person(Rect2(r.position + Vector2(r.size.x * 0.22, 0), r.size * 0.8), gold)
		_person(Rect2(r.position + Vector2(-r.size.x * 0.1, r.size.y * 0.2), r.size * 0.8), text)
	if _icons.has("zone"):
		var r: Rect2 = _icons["zone"]
		var col := gold if zone_state == "final" else (HudStyle.role("status") if zone_state == "shrinking" else text)
		draw_arc(r.get_center(), r.size.x * 0.42, 0.0, TAU, 32, col, maxf(1.0, r.size.x * 0.12), true)
		draw_circle(r.get_center(), r.size.x * 0.12, col)


## A head and shoulders in a box.
func _person(r: Rect2, c: Color) -> void:
	draw_circle(r.position + r.size * Vector2(0.5, 0.3), r.size.y * 0.2, c)
	var cx := r.position.x + r.size.x * 0.5
	var top := r.position.y + r.size.y * 0.55
	var bot := r.position.y + r.size.y * 0.98
	var hw := r.size.x * 0.4
	var pts := PackedVector2Array([Vector2(cx - hw, bot), Vector2(cx - hw * 0.8, top + (bot - top) * 0.15), Vector2(cx - hw * 0.4, top),
		Vector2(cx + hw * 0.4, top), Vector2(cx + hw * 0.8, top + (bot - top) * 0.15), Vector2(cx + hw, bot)])
	draw_colored_polygon(pts, c)
