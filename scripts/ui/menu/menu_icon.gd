class_name MenuIcon
extends Control
## A line icon drawn in code (no image files; docs/UI_STYLE.md section 8). Stroke = px / 12. Inside a BaseButton it
## takes the button's current font colour each draw, so disabled and pressed states follow the theme.

const KINDS: Array[String] = [
	"chevron_left", "gear", "standard", "enter", "lock", "play", "crosshair", "gyro", "stick", "layout", "vibrate",
	"target", "laurel",
]

## Which icon to draw (one of KINDS; unknown kinds draw nothing).
var kind: String = "":
	set(value):
		kind = value
		queue_redraw()

## Side length of the square icon box in canvas units.
var px: float = 24.0:
	set(value):
		px = maxf(value, 1.0)
		custom_minimum_size = Vector2(px, px)
		size = Vector2(px, px)
		queue_redraw()

## Colour used when the parent is not a BaseButton.
var tint: Color = MenuStyle.color("gold"):
	set(value):
		tint = value
		queue_redraw()

var _watched: BaseButton = null


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	px = px


static func make(icon_kind: String, side_px: float = 24.0) -> MenuIcon:
	var icon := MenuIcon.new()
	icon.name = "Icon"
	icon.kind = icon_kind
	icon.px = side_px
	return icon


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_PARENTED:
			_watch(get_parent() as BaseButton)
		NOTIFICATION_UNPARENTED:
			_watch(null)


func _watch(button: BaseButton) -> void:
	if _watched != null and is_instance_valid(_watched) and _watched.draw.is_connected(queue_redraw):
		_watched.draw.disconnect(queue_redraw)
	_watched = button
	if _watched != null and not _watched.draw.is_connected(queue_redraw):
		_watched.draw.connect(queue_redraw)


## The colour for this draw: the owner button's state colour, else `tint`.
func current_color() -> Color:
	var b := get_parent() as BaseButton
	if b == null:
		return tint
	match b.get_draw_mode():
		BaseButton.DRAW_DISABLED:
			return b.get_theme_color(&"font_disabled_color")
		BaseButton.DRAW_PRESSED, BaseButton.DRAW_HOVER_PRESSED:
			return b.get_theme_color(&"font_pressed_color")
		BaseButton.DRAW_HOVER:
			return b.get_theme_color(&"font_hover_color")
		_:
			return b.get_theme_color(&"font_color")


func _draw() -> void:
	var c := current_color()
	var w := maxf(px / 12.0, 1.5)
	match kind:
		"chevron_left": _draw_chevron_left(c, w)
		"gear": _draw_gear(c, w)
		"standard": _draw_standard(c, w)
		"enter": _draw_enter(c, w)
		"lock": _draw_lock(c, w)
		"play": _draw_play(c, w)
		"crosshair": _draw_crosshair(c, w)
		"gyro": _draw_gyro(c, w)
		"stick": _draw_stick(c, w)
		"layout": _draw_layout(c, w)
		"vibrate": _draw_vibrate(c, w)
		"target": _draw_target(c, w)
		"laurel": _draw_laurel(c, w)


## A point in the unit box scaled to px.
func _p(x: float, y: float) -> Vector2:
	return Vector2(x, y) * px


func _line(points: Array[Vector2], c: Color, w: float, closed: bool = false) -> void:
	var pts := PackedVector2Array()
	for p in points:
		pts.append(p * px)
	if closed:
		pts.append(points[0] * px)
	draw_polyline(pts, c, w, true)


func _ring(cx: float, cy: float, r: float, c: Color, w: float, from: float = 0.0, to: float = TAU) -> void:
	draw_arc(_p(cx, cy), r * px, from, to, 32, c, w, true)


func _rect(x0: float, y0: float, x1: float, y1: float, c: Color, w: float) -> void:
	_line([Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(x0, y1)], c, w, true)


## A small V arrowhead at `tip` pointing along `dir` (unit-box units).
func _arrowhead(tip: Vector2, dir: Vector2, c: Color, w: float, s: float = 0.12) -> void:
	var d := dir.normalized()
	var n := Vector2(-d.y, d.x)
	_line([tip - d * s + n * s * 0.8, tip, tip - d * s - n * s * 0.8], c, w)


func _draw_chevron_left(c: Color, w: float) -> void:
	_line([Vector2(0.62, 0.18), Vector2(0.3, 0.5), Vector2(0.62, 0.82)], c, w * 1.2)


func _draw_gear(c: Color, w: float) -> void:
	_ring(0.5, 0.5, 0.25, c, w)
	_ring(0.5, 0.5, 0.08, c, w)
	for i in 8:
		var a := TAU * float(i) / 8.0
		var d := Vector2(cos(a), sin(a))
		_line([Vector2(0.5, 0.5) + d * 0.27, Vector2(0.5, 0.5) + d * 0.42], c, w * 1.6)


func _draw_standard(c: Color, w: float) -> void:
	_ring(0.5, 0.1, 0.05, c, w)
	_line([Vector2(0.5, 0.15), Vector2(0.5, 0.24)], c, w)
	_line([Vector2(0.24, 0.24), Vector2(0.76, 0.24)], c, w)
	_line([Vector2(0.3, 0.24), Vector2(0.3, 0.6), Vector2(0.7, 0.6), Vector2(0.7, 0.24)], c, w)
	for x: float in [0.38, 0.5, 0.62]:
		_line([Vector2(x, 0.6), Vector2(x, 0.68)], c, w * 0.8)
	_line([Vector2(0.5, 0.68), Vector2(0.5, 0.92)], c, w)


func _draw_enter(c: Color, w: float) -> void:
	_line([Vector2(0.55, 0.14), Vector2(0.84, 0.14), Vector2(0.84, 0.86), Vector2(0.55, 0.86)], c, w)
	_line([Vector2(0.14, 0.5), Vector2(0.64, 0.5)], c, w)
	_arrowhead(Vector2(0.64, 0.5), Vector2(1, 0), c, w, 0.16)


func _draw_lock(c: Color, w: float) -> void:
	_rect(0.24, 0.46, 0.76, 0.88, c, w)
	_line([Vector2(0.34, 0.46), Vector2(0.34, 0.32)], c, w)
	_line([Vector2(0.66, 0.46), Vector2(0.66, 0.32)], c, w)
	_ring(0.5, 0.32, 0.16, c, w, PI, TAU)
	draw_circle(_p(0.5, 0.65), maxf(w * 0.9, px * 0.05), c, true, -1.0, true)


func _draw_play(c: Color, w: float) -> void:
	var tri := PackedVector2Array([_p(0.32, 0.2), _p(0.8, 0.5), _p(0.32, 0.8)])
	draw_colored_polygon(tri, Color(c, c.a * 0.35))
	_line([Vector2(0.32, 0.2), Vector2(0.8, 0.5), Vector2(0.32, 0.8)], c, w, true)


func _draw_crosshair(c: Color, w: float) -> void:
	_ring(0.5, 0.5, 0.3, c, w)
	for d: Vector2 in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		_line([Vector2(0.5, 0.5) + d * 0.16, Vector2(0.5, 0.5) + d * 0.46], c, w)
	draw_circle(_p(0.5, 0.5), maxf(w * 0.6, 1.0), c, true, -1.0, true)


func _draw_gyro(c: Color, w: float) -> void:
	_rect(0.37, 0.24, 0.63, 0.76, c, w)
	var r := 0.4
	var a0 := -0.3 * PI
	var a1 := 0.3 * PI
	_ring(0.5, 0.5, r, c, w, a0, a1)
	_ring(0.5, 0.5, r, c, w, PI + a0, PI + a1)
	# Arrowheads at the clockwise ends, along the tangent.
	for a: float in [a1, PI + a1]:
		var tip := Vector2(0.5, 0.5) + Vector2(cos(a), sin(a)) * r
		_arrowhead(tip, Vector2(-sin(a), cos(a)), c, w, 0.11)


func _draw_stick(c: Color, w: float) -> void:
	_ring(0.5, 0.5, 0.4, c, w)
	draw_circle(_p(0.5, 0.5), px * 0.18, c, true, -1.0, true)


func _draw_layout(c: Color, w: float) -> void:
	_rect(0.1, 0.24, 0.9, 0.76, c, w)
	var s := 0.13 * px
	for p: Vector2 in [Vector2(0.2, 0.52), Vector2(0.62, 0.36), Vector2(0.67, 0.55)]:
		draw_rect(Rect2(p * px, Vector2(s, s)), c, true, -1.0, true)


func _draw_vibrate(c: Color, w: float) -> void:
	_rect(0.37, 0.2, 0.63, 0.8, c, w)
	_line([Vector2(0.46, 0.7), Vector2(0.54, 0.7)], c, w * 0.8)
	for r: float in [0.24, 0.38]:
		_ring(0.5, 0.5, r, c, w, -0.18 * PI, 0.18 * PI)
		_ring(0.5, 0.5, r, c, w, 0.82 * PI, 1.18 * PI)


func _draw_target(c: Color, w: float) -> void:
	_ring(0.5, 0.5, 0.4, c, w)
	_ring(0.5, 0.5, 0.23, c, w)
	draw_circle(_p(0.5, 0.5), px * 0.07, c, true, -1.0, true)


## Two mirrored branches of leaves curving up from the bottom, open at the top.
func _draw_laurel(c: Color, w: float) -> void:
	var centre := Vector2(0.5, 0.5)
	var r := 0.34
	for side: float in [-1.0, 1.0]:
		# Angle 0.5 PI is straight down (y grows downward); the branch climbs to about 50 degrees above horizontal.
		var start := 0.5 * PI
		var end := 0.5 * PI + side * 0.78 * PI
		var from := minf(start, end)
		var to := maxf(start, end)
		_ring(centre.x, centre.y, r, c, w * 0.8, from, to)
		var leaves := 5
		for i in leaves:
			var t := (float(i) + 0.7) / float(leaves)
			var a := lerpf(start, end, t)
			var base := centre + Vector2(cos(a), sin(a)) * r
			var tangent := Vector2(-sin(a), cos(a)) * side
			var outward := Vector2(cos(a), sin(a))
			var sz := lerpf(0.15, 0.1, t)
			for dir: Vector2 in [(tangent + outward * 0.9).normalized(), (tangent - outward * 0.5).normalized()]:
				_leaf(base, dir, sz, c)


func _leaf(base: Vector2, dir: Vector2, length: float, c: Color) -> void:
	var n := Vector2(-dir.y, dir.x)
	var mid := base + dir * length * 0.5
	var pts := PackedVector2Array([
			base * px, (mid + n * length * 0.28) * px, (base + dir * length) * px, (mid - n * length * 0.28) * px])
	draw_colored_polygon(pts, c)
