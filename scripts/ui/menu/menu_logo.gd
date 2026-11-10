class_name MenuLogo
extends Control
## The game logo drawn in code: a letter-spaced "PROJECT" caption, the word "GLADIUS" in the display face with a
## soft drop shadow, and a gladius lying under the word as a rule exactly as wide as the word. The size follows the
## canvas height (font_size_frac_of_height x menu_type_scale.logo) and shrinks to fit the control's width.

const UI_PATH := "res://data/ui.json"
const WORD := "GLADIUS"
const CAPTION := "PROJECT"
const _WIDE: Font = preload("res://assets/third_party/kenney_fonts/kenney_future.ttf")
const _NARROW: Font = preload("res://assets/third_party/kenney_fonts/kenney_future_narrow.ttf")
const CAPTION_FRAC := 0.22 ## caption size, fraction of the big size
const TRACKING_EM := 0.55 ## extra caption letter spacing, fraction of the caption size
const SHADOW_FRAC := 0.04 ## drop shadow offset, fraction of the big size
const BLADE_FRAC := 0.045 ## blade thickness at the guard, fraction of the big size

## Where the block sits inside the control's width (LEFT for the menu hero, CENTER for the boot screen).
var align: int = HORIZONTAL_ALIGNMENT_LEFT

var _frac_of_height: float = 0.035
var _logo_scale: float = 3.4
var _colors: Dictionary = {}
var _px: int = 16
var _vp: Viewport


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	var ui: Dictionary = DataRegistry.new().load_file(UI_PATH)
	_frac_of_height = float(ui.get("font_size_frac_of_height", 0.035))
	var ts: Dictionary = ui.get("menu_type_scale", {})
	_logo_scale = float(ts.get("logo", 3.4))
	var style: Dictionary = ui.get("menu_style", {})
	_colors = style.get("colors", {})
	resized.connect(_relayout)
	_relayout()


func _enter_tree() -> void:
	_vp = get_viewport()
	if _vp != null and not _vp.size_changed.is_connected(_relayout):
		_vp.size_changed.connect(_relayout)


func _exit_tree() -> void:
	if _vp != null and _vp.size_changed.is_connected(_relayout):
		_vp.size_changed.disconnect(_relayout)
	_vp = null


## The big (word) font size in use, in canvas pixels.
func get_font_px() -> float:
	return float(_px)


## Fades the logo in over `seconds` (a no-op when headless, so tests see it at full alpha).
func play_intro(seconds: float) -> void:
	if DisplayServer.get_name() == "headless" or seconds <= 0.0 or not is_inside_tree():
		modulate.a = 1.0
		return
	modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, seconds).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_SINE)


func _c(name: String, fallback: String) -> Color:
	var v: Variant = _colors.get(name)
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)
	return Color(fallback)


func _caption_px() -> int:
	return maxi(roundi(float(_px) * CAPTION_FRAC), 8)


func _caption_width(cpx: int) -> float:
	var w := 0.0
	var track := float(cpx) * TRACKING_EM
	for i in CAPTION.length():
		w += _NARROW.get_char_size(CAPTION.unicode_at(i), cpx).x
		if i < CAPTION.length() - 1:
			w += track
	return w


func _word_width(px: int) -> float:
	return _WIDE.get_string_size(WORD, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x


## Vertical layout of the block: caption top, word baseline, rule centre, total height.
func _metrics() -> Dictionary:
	var px := float(_px)
	var cpx := _caption_px()
	var cap_h := _NARROW.get_ascent(cpx)
	var word_asc := _WIDE.get_ascent(_px)
	var gap1 := px * 0.08
	var caption_base := cap_h
	var word_base := caption_base + gap1 + word_asc * 0.92
	var rule_y := word_base + px * 0.20
	var total := rule_y + px * 0.12 + px * SHADOW_FRAC
	return {"caption_base": caption_base, "word_base": word_base, "rule_y": rule_y, "total": total}


func _relayout() -> void:
	if not is_inside_tree():
		return
	var vis_h := get_viewport().get_visible_rect().size.y
	var px := float(roundi(vis_h * _frac_of_height)) * _logo_scale
	var p := maxi(roundi(px), 12)
	if size.x > 1.0:
		var ww := _word_width(p)
		if ww > size.x:
			p = maxi(floori(float(p) * size.x / ww), 8)
			while p > 8 and _word_width(p) > size.x:
				p -= 1
	_px = p
	var h := ceilf(float(_metrics()["total"]))
	if not is_equal_approx(custom_minimum_size.y, h):
		custom_minimum_size = Vector2(custom_minimum_size.x, h)
	queue_redraw()


func _draw() -> void:
	var m := _metrics()
	var px := float(_px)
	var ww := _word_width(_px)
	var x0 := 0.0
	if align == HORIZONTAL_ALIGNMENT_CENTER:
		x0 = (size.x - ww) * 0.5
	elif align == HORIZONTAL_ALIGNMENT_RIGHT:
		x0 = size.x - ww
	var y0 := maxf((size.y - float(m["total"])) * 0.5, 0.0) if align == HORIZONTAL_ALIGNMENT_CENTER else 0.0
	var shadow := Color(0, 0, 0, 0.5)
	var off := Vector2(0, px * SHADOW_FRAC)
	# Caption: letter-spaced, glyph by glyph.
	var cpx := _caption_px()
	var cw := _caption_width(cpx)
	var cx := x0
	if align == HORIZONTAL_ALIGNMENT_CENTER:
		cx = x0 + (ww - cw) * 0.5
	elif align == HORIZONTAL_ALIGNMENT_RIGHT:
		cx = x0 + ww - cw
	var cy := y0 + float(m["caption_base"])
	var dim := _c("marble_dim", "#A89C88")
	var track := float(cpx) * TRACKING_EM
	for i in CAPTION.length():
		var ch := CAPTION.substr(i, 1)
		draw_char(_NARROW, Vector2(cx, cy + maxf(1.0, px * 0.02)), ch, cpx, shadow)
		draw_char(_NARROW, Vector2(cx, cy), ch, cpx, dim)
		cx += _NARROW.get_char_size(CAPTION.unicode_at(i), cpx).x + track
	# The word with its drop shadow.
	var base := Vector2(x0, y0 + float(m["word_base"]))
	draw_string(_WIDE, base + off, WORD, HORIZONTAL_ALIGNMENT_LEFT, -1, _px, shadow)
	draw_string(_WIDE, base, WORD, HORIZONTAL_ALIGNMENT_LEFT, -1, _px, _c("gold_hi", "#F3D27A"))
	# The gladius rule.
	var ry := y0 + float(m["rule_y"])
	_draw_sword(x0, x0 + ww, ry + off.y * 0.6, px, true)
	_draw_sword(x0, x0 + ww, ry, px, false)


## A gladius lying left to right: pommel, grip, guard, blade with a centre line, point at x1.
func _draw_sword(x0: float, x1: float, y: float, px: float, as_shadow: bool) -> void:
	var shadow := Color(0, 0, 0, 0.45)
	var gold := shadow if as_shadow else _c("gold", "#D9A93A")
	var gold_hi := shadow if as_shadow else _c("gold_hi", "#F3D27A")
	var crimson := shadow if as_shadow else _c("crimson", "#B3211F")
	var dark := Color(_c("gold", "#D9A93A").darkened(0.45), 0.9)
	var bt := px * BLADE_FRAC
	var pr := px * 0.052
	var pommel_c := Vector2(x0 + pr, y)
	var grip_x0 := x0 + pr * 1.6
	var grip_x1 := grip_x0 + px * 0.34
	var guard_w := px * 0.05
	var guard_h := px * 0.17
	var blade_x0 := grip_x1 + guard_w
	# Pommel: a flattened sphere with a small neck.
	draw_set_transform(pommel_c, 0.0, Vector2(1.0, 0.85))
	draw_circle(Vector2.ZERO, pr, gold, true, -1.0, true)
	draw_set_transform(Vector2.ZERO)
	draw_rect(Rect2(pommel_c.x + pr * 0.6, y - pr * 0.45, grip_x0 - pommel_c.x - pr * 0.6, pr * 0.9), gold)
	# Grip with three ribs.
	var gh := px * 0.052
	draw_rect(Rect2(grip_x0, y - gh * 0.5, grip_x1 - grip_x0, gh), crimson)
	if not as_shadow:
		for i in 3:
			var rx := lerpf(grip_x0, grip_x1, (float(i) + 1.0) / 4.0)
			draw_line(Vector2(rx, y - gh * 0.5), Vector2(rx, y + gh * 0.5), Color(gold, 0.55), maxf(1.0, px * 0.01))
	# Guard: a short vertical bar with rounded ends.
	var gpoly := PackedVector2Array([
			Vector2(grip_x1, y - guard_h * 0.5 + guard_w * 0.3), Vector2(grip_x1 + guard_w * 0.3, y - guard_h * 0.5),
			Vector2(blade_x0 - guard_w * 0.3, y - guard_h * 0.5), Vector2(blade_x0, y - guard_h * 0.5 + guard_w * 0.3),
			Vector2(blade_x0, y + guard_h * 0.5 - guard_w * 0.3), Vector2(blade_x0 - guard_w * 0.3, y + guard_h * 0.5),
			Vector2(grip_x1 + guard_w * 0.3, y + guard_h * 0.5), Vector2(grip_x1, y + guard_h * 0.5 - guard_w * 0.3)])
	draw_colored_polygon(gpoly, gold)
	# Blade: parallel edges with a slight waist, then a long point.
	var blade_len := x1 - blade_x0
	var tip_x0 := blade_x0 + blade_len * 0.80
	var waist := bt * 0.86
	var blade := PackedVector2Array([
			Vector2(blade_x0, y - bt * 0.5), Vector2(blade_x0 + blade_len * 0.45, y - waist * 0.5),
			Vector2(tip_x0, y - bt * 0.48), Vector2(x1, y),
			Vector2(tip_x0, y + bt * 0.48), Vector2(blade_x0 + blade_len * 0.45, y + waist * 0.5),
			Vector2(blade_x0, y + bt * 0.5)])
	draw_colored_polygon(blade, gold_hi)
	var outline := blade.duplicate()
	outline.append(blade[0])
	draw_polyline(outline, gold_hi, 1.0, true)
	if not as_shadow:
		draw_line(Vector2(blade_x0 + px * 0.04, y), Vector2(tip_x0 + blade_len * 0.1, y), dark, maxf(1.0, bt * 0.22), true)
