class_name StickVisual
extends Control
## Translucent ring with a knob for one virtual stick. Purely visual: TouchHud owns the input
## and positions this node (a square of side 2 * radius centred on the stick).

var ring_alpha: float = 0.35
var knob_frac: float = 0.4
## Knob offset from the ring centre in pixels (clamped to the ring radius when drawn).
var knob_offset: Vector2 = Vector2.ZERO


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE


## Places the ring so its centre is `center` (HUD space) with the given radius.
func place(center: Vector2, radius: float) -> void:
	position = center - Vector2(radius, radius)
	size = Vector2(radius, radius) * 2.0
	queue_redraw()


func set_knob_offset(off: Vector2) -> void:
	knob_offset = off
	queue_redraw()


func _draw() -> void:
	var r := size.x * 0.5
	var c := Vector2(r, r)
	var ring := Color(1, 1, 1, ring_alpha)
	draw_circle(c, r, Color(1, 1, 1, ring_alpha * 0.3))
	draw_arc(c, r, 0.0, TAU, 48, ring, 3.0, true)
	draw_circle(c + knob_offset.limit_length(r), r * knob_frac, Color(1, 1, 1, minf(1.0, ring_alpha * 2.0)))
