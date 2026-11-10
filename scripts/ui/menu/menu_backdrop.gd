class_name MenuBackdrop
extends Control
## Full-bleed dusk view of Alesia drawn in code (docs/UI_STYLE.md section 6): sky, low sun, the citadel hill with
## its temple and beacon, the outer wall with towers, the aqueduct, embers and a vignette. No images, no shaders.
## Every static layer is its own CanvasItem that redraws only on resize. Per frame (hero mode, animated) only the
## three silhouette layers move sideways and the small embers item redraws. Geometry is in units of the height h.

const UI_PATH := "res://data/ui.json"
const FOCAL_X := 0.34 ## sun, hill and temple centre, fraction of the width
const HORIZON_Y := 0.66 ## fraction of the height
const HILL_HALF := 0.72 ## half width of the citadel hill, heights
const DEPTH_FAR := 0.35
const DEPTH_MID := 0.65
const DEPTH_NEAR := 1.0
const STAR_SEED := 1907
const EMBER_SEED := 52

## Painter callbacks per child: each child draws once per queue_redraw.
class _Layer extends Node2D:
	var paint: Callable

	func _draw() -> void:
		if paint.is_valid():
			paint.call(self)


## "hero" (full art, drift, embers) or "page" (dimmed, still). Set before the node enters the tree.
var mode: String = "hero"

var _colors: Dictionary = {}
var _animate: bool = true
var _drift_period_s: float = 48.0
var _drift_frac: float = 0.012
var _ember_count: int = 22
var _page_dim: float = 0.62
var _t: float = 0.0
var _animated: bool = false

var _sky: _Layer
var _far: _Layer
var _mid: _Layer
var _haze: _Layer
var _near: _Layer
var _embers: _Layer
var _top: _Layer
## Per-ember constants (x frac, speed, sway, phase, radius, alpha), 6 floats each, built once per resize.
var _ember_params: PackedFloat32Array = PackedFloat32Array()
var _sky_tex: GradientTexture2D
var _glow_tex: GradientTexture2D
var _vignette_tex: GradientTexture2D
var _haze_tex: GradientTexture2D
var _halo_tex: GradientTexture2D


static func make(p_mode: String) -> MenuBackdrop:
	var b := MenuBackdrop.new()
	b.mode = p_mode
	return b


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true


func _ready() -> void:
	_load_cfg()
	_build_textures()
	_sky = _add_layer(_paint_sky)
	_far = _add_layer(_paint_far)
	_mid = _add_layer(_paint_mid)
	_haze = _add_layer(_paint_haze)
	_near = _add_layer(_paint_near)
	if mode == "hero":
		_embers = _add_layer(_paint_embers)
	_top = _add_layer(_paint_top)
	resized.connect(_on_resized)
	_on_resized()
	set_animated(_animate)


## Turns the drift and embers motion on or off. Off (or headless, or page mode) gives a still image.
func set_animated(on: bool) -> void:
	_animated = on and mode == "hero" and DisplayServer.get_name() != "headless"
	set_process(_animated)
	if not _animated:
		_apply_time()


## Sets the animation clock (tools and tests use this for deterministic stills).
func set_time(t: float) -> void:
	_t = t
	_apply_time()


func get_time() -> float:
	return _t


func _process(delta: float) -> void:
	_t += delta
	_apply_time()


func _apply_time() -> void:
	if _far == null:
		return
	var off := 0.0
	if mode == "hero":
		off = sin(TAU * _t / maxf(_drift_period_s, 0.001)) * _drift_frac * size.x
	_far.position.x = off * DEPTH_FAR
	_mid.position.x = off * DEPTH_MID
	_near.position.x = off * DEPTH_NEAR
	if _embers != null:
		_embers.queue_redraw()


func _on_resized() -> void:
	_build_embers()
	for l: _Layer in [_sky, _far, _mid, _haze, _near, _embers, _top]:
		if l != null:
			l.queue_redraw()
	_apply_time()


func _add_layer(painter: Callable) -> _Layer:
	var l := _Layer.new()
	l.paint = painter
	add_child(l, false, Node.INTERNAL_MODE_FRONT)
	return l


# --- config ---------------------------------------------------------------------------------------------------

func _load_cfg() -> void:
	var ui: Dictionary = DataRegistry.new().load_file(UI_PATH)
	var style: Dictionary = ui.get("menu_style", {})
	_colors = style.get("colors", {})
	var bd: Dictionary = style.get("backdrop", {})
	_animate = bool(bd.get("animate", true))
	_drift_period_s = float(bd.get("drift_period_s", 48.0))
	_drift_frac = float(bd.get("drift_frac_of_width", 0.012))
	_ember_count = int(bd.get("ember_count", 22))
	_page_dim = float(bd.get("page_dim", 0.62))


## Palette colour `name` from data/ui.json, or the docs/UI_STYLE.md hex.
func _c(name: String, fallback: String) -> Color:
	var v: Variant = _colors.get(name)
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)
	return Color(fallback)


func _night() -> Color:
	return _c("night", "#0C0809")


func _ember() -> Color:
	return _c("ember", "#C4532A")


func _gold_hi() -> Color:
	return _c("gold_hi", "#F3D27A")


func _build_textures() -> void:
	var night := _night()
	var g := Gradient.new()
	# Night-dark top (the logo sits there), then a tall dusk band climbing from oxblood into ember at the horizon.
	g.offsets = PackedFloat32Array([0.0, 0.28, 0.42, 0.50, 0.57, 0.62, HORIZON_Y - 0.002, HORIZON_Y, 0.70, 0.86,
			1.0])
	g.colors = PackedColorArray([
			night, Color("#140A0D"), _c("oxblood", "#2A0D10"), Color("#451612"), Color("#682315"),
			Color("#8A3118"), Color("#A63E1D"), Color("#2A0F10"), Color("#1E0C0D"), Color("#140A0B"), night])
	_sky_tex = _gradient_tex(g, Vector2(0.5, 0.0), Vector2(0.5, 1.0), GradientTexture2D.FILL_LINEAR, 4, 512)

	var e := _ember()
	var gg := Gradient.new()
	gg.offsets = PackedFloat32Array([0.0, 0.12, 0.3, 0.55, 0.8, 1.0])
	gg.colors = PackedColorArray([
			Color(Color("#F2A04A"), 0.55), Color(e, 0.42), Color(e, 0.22), Color(e, 0.08), Color(e, 0.02),
			Color(e, 0.0)])
	_glow_tex = _gradient_tex(gg, Vector2(0.5, 0.5), Vector2(1.0, 0.5), GradientTexture2D.FILL_RADIAL, 256, 256)

	var gv := Gradient.new()
	gv.offsets = PackedFloat32Array([0.0, 0.55, 0.8, 1.0])
	gv.colors = PackedColorArray([Color(night, 0.0), Color(night, 0.0), Color(night, 0.28), Color(night, 0.75)])

	# The big soft dusk halo (and the reflections): ember, peak alpha 0.6, a smooth fall to 0.
	var halo := Color("#D2622E")
	var gb := Gradient.new()
	gb.offsets = PackedFloat32Array([0.0, 0.2, 0.42, 0.62, 0.82, 1.0])
	gb.colors = PackedColorArray([Color(halo, 0.6), Color(halo, 0.5), Color(e, 0.32), Color(e, 0.15),
			Color(e, 0.04), Color(e, 0.0)])
	_halo_tex = _gradient_tex(gb, Vector2(0.5, 0.5), Vector2(1.0, 0.5), GradientTexture2D.FILL_RADIAL, 256, 256)
	_vignette_tex = _gradient_tex(gv, Vector2(0.5, 0.5), Vector2(0.5 + 0.7072, 0.5),
			GradientTexture2D.FILL_RADIAL, 256, 256)

	var gh := Gradient.new()
	gh.offsets = PackedFloat32Array([0.0, 0.4, 0.62, 1.0])
	gh.colors = PackedColorArray([Color(e, 0.0), Color(e, 0.07), Color(e, 0.13), Color(e, 0.02)])
	_haze_tex = _gradient_tex(gh, Vector2(0.5, 0.0), Vector2(0.5, 1.0), GradientTexture2D.FILL_LINEAR, 4, 128)


func _gradient_tex(g: Gradient, from: Vector2, to: Vector2, fill: int, w: int, h: int) -> GradientTexture2D:
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = fill as GradientTexture2D.Fill
	t.fill_from = from
	t.fill_to = to
	t.width = w
	t.height = h
	return t


# --- geometry helpers -----------------------------------------------------------------------------------------

func _h() -> float:
	return maxf(size.y, 1.0)


func _xf() -> float:
	return FOCAL_X * size.x


func _yh() -> float:
	return HORIZON_Y * size.y


## Horizontal margin each moving layer draws past the screen edges so the drift never shows an edge.
func _pad() -> float:
	return _drift_frac * size.x * 1.2 + 2.0


## Hill height above the horizon at x (0 outside the hill).
func _hill_y(x: float) -> float:
	var h := _h()
	var half := HILL_HALF * h
	var u := absf(x - _xf()) / half
	if u >= 1.0:
		return _yh()
	# Flat crown for the citadel, a round shoulder, then a long concave foot.
	var v := clampf((u - 0.18) / 0.82, 0.0, 1.0)
	var f := pow(1.0 - v * v, 0.9) * (1.0 - 0.25 * v)
	return _yh() - 0.20 * h * f


## Circle cut off below `clip_y` (the low sun behind the horizon).
func _clipped_disc(ci: CanvasItem, c: Vector2, r: float, clip_y: float, col: Color) -> void:
	if clip_y >= c.y + r:
		ci.draw_circle(c, r, col, true, -1.0, true)
		return
	if clip_y <= c.y - r:
		return
	var t0 := asin(clampf((clip_y - c.y) / r, -1.0, 1.0))
	var pts := PackedVector2Array()
	var n := 40
	for i in n + 1:
		var a := lerpf(t0, -PI - t0, float(i) / float(n))
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	ci.draw_colored_polygon(pts, col)
	ci.draw_polyline(pts, col, 1.0, true)


func _rect(ci: CanvasItem, x0: float, y0: float, x1: float, y1: float, col: Color) -> void:
	ci.draw_rect(Rect2(x0, y0, x1 - x0, y1 - y0), col)


# --- painters -------------------------------------------------------------------------------------------------

func _paint_sky(ci: CanvasItem) -> void:
	var w := size.x
	var h := _h()
	ci.draw_texture_rect(_sky_tex, Rect2(0, 0, w, size.y), false)
	# Stars in the top third, fewer toward the horizon.
	var rng := RandomNumberGenerator.new()
	rng.seed = STAR_SEED
	var star := Color("#EDE6D6")
	for i in 40:
		var sx := rng.randf() * w
		var sy := pow(rng.randf(), 1.4) * 0.34 * size.y
		var a := rng.randf_range(0.12, 0.45) * (1.0 - 0.6 * sy / (0.34 * size.y))
		var r := rng.randf_range(0.0012, 0.0022) * h
		ci.draw_circle(Vector2(sx, sy), maxf(r, 0.6), Color(star, a), true, -1.0, true)
	# Sun glow and core, centred on the horizon at the focal point.
	var c := Vector2(_xf(), _yh())
	# Big dusk halo above the horizon (upper half of the radial texture), wider than tall.
	var hsz := Vector2(_halo_tex.width, _halo_tex.height)
	ci.draw_texture_rect_region(_halo_tex, Rect2(c.x - 1.05 * h, c.y - 0.7 * h, 2.1 * h, 0.7 * h),
			Rect2(0, 0, hsz.x, hsz.y * 0.5))
	var gr := 0.55 * h
	var tsz := Vector2(_glow_tex.width, _glow_tex.height)
	# Upper half full strength; the lower half (light on the plain) much weaker.
	ci.draw_texture_rect_region(_glow_tex, Rect2(c.x - gr * 1.6, c.y - gr, gr * 3.2, gr),
			Rect2(0, 0, tsz.x, tsz.y * 0.5))
	ci.draw_texture_rect_region(_glow_tex, Rect2(c.x - gr * 1.6, c.y, gr * 3.2, gr * 0.6),
			Rect2(0, tsz.y * 0.5, tsz.x, tsz.y * 0.5), Color(1, 1, 1, 0.35))
	# The sun sits on the citadel crest so the temple stands against it.
	var core := Color("#F2A04A")
	var sc := Vector2(c.x, _hill_y(c.x) + 0.012 * h)
	ci.draw_texture_rect(_glow_tex, Rect2(sc.x - 0.26 * h, sc.y - 0.26 * h, 0.52 * h, 0.52 * h), false,
			Color(1, 1, 1, 0.8))
	var clip := _yh()
	_clipped_disc(ci, sc, 0.11 * h, clip, Color(core, 0.16))
	_clipped_disc(ci, sc, 0.085 * h, clip, Color(core, 0.9))
	_clipped_disc(ci, sc, 0.068 * h, clip, Color(Color("#FAC27A"), 0.55))


func _paint_far(ci: CanvasItem) -> void:
	var h := _h()
	var col := Color("#3A1216")
	var xf := _xf()
	var half := HILL_HALF * h
	var pts := PackedVector2Array()
	var n := 64
	for i in n + 1:
		var x := xf - half + 2.0 * half * float(i) / float(n)
		pts.append(Vector2(x, _hill_y(x)))
	# Bottoms stop inside the wall body (which ends at the horizon + 0.012 h).
	var bot := _yh() + 0.008 * h
	pts.append(Vector2(xf + half, bot))
	pts.append(Vector2(xf - half, bot))
	# A faint far ridge behind the hill so the horizon is never a bare line.
	var ridge := Color("#4A1719")
	var rp := PackedVector2Array()
	var x0 := -_pad()
	var x1 := size.x + _pad()
	var m := 48
	for i in m + 1:
		var x := lerpf(x0, x1, float(i) / float(m))
		var y := _yh() - 0.058 * h - 0.016 * h * sin(x / h * 4.3 + 0.7) - 0.006 * h * sin(x / h * 11.3 + 2.0)
		rp.append(Vector2(x, y))
	rp.append(Vector2(x1, bot))
	rp.append(Vector2(x0, bot))
	ci.draw_colored_polygon(rp, ridge)
	ci.draw_polyline(rp.slice(0, m + 1), ridge, 1.0, true)
	# The citadel first; the shaded hill then covers its footings so they sit in the ground.
	_paint_citadel(ci, col)
	# The hill: lit a touch near the crest by the sun, darker toward its foot.
	var hill_cols := PackedColorArray()
	var dark := Color("#2C0E12")
	for i in pts.size():
		var p := pts[i]
		var lift := clampf((_yh() - p.y) / (0.2 * h), 0.0, 1.0) if i <= n else 0.0
		hill_cols.append(dark.lerp(col, clampf(lift * 1.3, 0.0, 1.0)))
	ci.draw_polygon(pts, hill_cols)
	var crest := pts.slice(0, n + 1)
	ci.draw_polyline(crest, col, 1.0, true)
	# Rim light along the hill crest, strongest by the sun.
	var rim := PackedColorArray()
	for p in crest:
		var bare := smoothstep(0.30 * h, 0.36 * h, absf(p.x - xf)) # no rim under the citadel
		rim.append(Color(_ember(), 0.22 * _sun_falloff(p.x) * _sun_falloff(p.x) * bare))
	ci.draw_polyline_colors(crest, rim, maxf(0.0016 * h, 1.0), true)


func _paint_citadel(ci: CanvasItem, col: Color) -> void:
	var h := _h()
	var xf := _xf()
	var top := _hill_y(xf)
	# Flanking citadel walls with crenellations on the shoulders.
	for side: float in [-1.0, 1.0]:
		var bx0 := xf + side * 0.17 * h
		var bx1 := xf + side * 0.30 * h
		var lo := minf(bx0, bx1)
		var hi := maxf(bx0, bx1)
		var wall_top := _hill_y(hi if side > 0 else lo) - 0.03 * h
		wall_top = minf(wall_top, top - 0.022 * h)
		_rect(ci, lo, wall_top, hi, _yh(), col)
		var mx := lo
		while mx + 0.008 * h <= hi + 0.0001:
			_rect(ci, mx, wall_top - 0.009 * h, mx + 0.008 * h, wall_top, col)
			mx += 0.017 * h
		# A squat tower at the outer end.
		var tx := xf + side * 0.30 * h
		_rect(ci, tx - 0.022 * h, wall_top - 0.038 * h, tx + 0.022 * h, _yh(), col)
		_rect(ci, tx - 0.028 * h, wall_top - 0.046 * h, tx + 0.028 * h, wall_top - 0.036 * h, col)
		_rect(ci, tx - 0.002 * h, wall_top - 0.026 * h, tx + 0.002 * h, wall_top - 0.019 * h,
				Color(_gold_hi(), 0.55))
	# Temple: stepped base, 7 columns, entablature, pediment.
	var tw := 0.30 * h
	var base_y := top + 0.004 * h
	_rect(ci, xf - tw * 0.5 - 0.022 * h, base_y - 0.010 * h, xf + tw * 0.5 + 0.022 * h, base_y + 0.03 * h, col)
	_rect(ci, xf - tw * 0.5 - 0.012 * h, base_y - 0.018 * h, xf + tw * 0.5 + 0.012 * h, base_y, col)
	var col_bot := base_y - 0.018 * h
	var col_top := col_bot - 0.07 * h
	var cw := 0.012 * h
	for i in 7:
		var cx := xf - tw * 0.5 + cw * 0.5 + (tw - cw) * float(i) / 6.0
		_rect(ci, cx - cw * 0.5, col_top, cx + cw * 0.5, col_bot, col)
		_rect(ci, cx - cw * 0.8, col_top, cx + cw * 0.8, col_top + 0.004 * h, col)
	var ent_bot := col_top
	var ent_top := ent_bot - 0.016 * h
	_rect(ci, xf - tw * 0.5 - 0.01 * h, ent_top, xf + tw * 0.5 + 0.01 * h, ent_bot, col)
	var apex := Vector2(xf, ent_top - 0.045 * h)
	var ped := PackedVector2Array([
			Vector2(xf - tw * 0.5 - 0.014 * h, ent_top), apex, Vector2(xf + tw * 0.5 + 0.014 * h, ent_top)])
	ci.draw_colored_polygon(ped, col)
	ci.draw_polyline(ped, col, 1.0, true)
	# Rim light on the temple roof line.
	ci.draw_polyline(ped, Color(_ember(), 0.35), maxf(0.0016 * h, 1.0), true)
	# The beacon: a thin shaft of light from the apex, fading upward, with a faint halo.
	var gh := _gold_hi()
	# Short: the apex is at about 0.31 h from the top and the hero logo ends near 0.20 h.
	_beacon(ci, apex, 0.085 * h, 0.012 * h, Color(gh, 0.12))
	_beacon(ci, apex, 0.085 * h, 0.003 * h, Color(gh, 0.7))
	ci.draw_circle(apex, 0.006 * h, Color(gh, 0.35), true, -1.0, true)
	ci.draw_circle(apex, 0.0025 * h, Color(gh, 0.9), true, -1.0, true)


func _beacon(ci: CanvasItem, base: Vector2, length: float, width: float, col: Color) -> void:
	# Two stacked quads: bright at the base, a quick fall-off, then a long faint tail.
	var clear := Color(col, 0.0)
	var mid := Color(col, col.a * 0.3)
	var hw := width * 0.5
	var ym := base.y - length * 0.35
	var hm := hw * 0.75
	ci.draw_polygon(PackedVector2Array([
			Vector2(base.x - hw, base.y), Vector2(base.x + hw, base.y),
			Vector2(base.x + hm, ym), Vector2(base.x - hm, ym)]), PackedColorArray([col, col, mid, mid]))
	ci.draw_polygon(PackedVector2Array([
			Vector2(base.x - hm, ym), Vector2(base.x + hm, ym),
			Vector2(base.x + hw * 0.4, base.y - length), Vector2(base.x - hw * 0.4, base.y - length)]),
			PackedColorArray([mid, mid, clear, clear]))


func _paint_mid(ci: CanvasItem) -> void:
	var h := _h()
	var col := Color("#220B0E")
	var x0 := -_pad()
	var x1 := size.x + _pad()
	var wall_top := _yh() - 0.035 * h
	var wall_bot := _yh() + 0.012 * h
	_rect(ci, x0, wall_top, x1, wall_bot, col)
	var merlon := 0.012 * h
	var step := 0.024 * h
	var mx := x0
	while mx < x1:
		_rect(ci, mx, wall_top - merlon, mx + merlon, wall_top, col)
		mx += step
	# Rim light along the wall walk and the merlon tops, strongest near the sun.
	var rim_w := maxf(0.0018 * h, 1.0)
	_rim_line(ci, x0, x1, wall_top + rim_w * 0.5, rim_w, 0.4)
	mx = x0
	while mx < x1:
		var a := 0.4 * _sun_falloff(mx)
		if a > 0.02:
			_rect(ci, mx, wall_top - merlon, mx + merlon, wall_top - merlon + rim_w, Color(_ember(), a))
		mx += step
	# Towers.
	var spacing := 0.42 * h
	var tw := 0.05 * h
	var first := fposmod(_xf() + 0.21 * h, spacing) - spacing
	var tx := first
	var idx := 0
	var gh := _gold_hi()
	while tx < x1 + spacing:
		var t_top := wall_top - 0.11 * h
		_rect(ci, tx - tw * 0.5, t_top, tx + tw * 0.5, wall_bot, col)
		var cap_w := 0.066 * h
		var cap_h := 0.016 * h
		_rect(ci, tx - cap_w * 0.5, t_top - cap_h, tx + cap_w * 0.5, t_top, col)
		# Two merlons on the cap.
		_rect(ci, tx - cap_w * 0.5, t_top - cap_h - 0.008 * h, tx - cap_w * 0.5 + 0.01 * h, t_top - cap_h, col)
		_rect(ci, tx + cap_w * 0.5 - 0.01 * h, t_top - cap_h - 0.008 * h, tx + cap_w * 0.5, t_top - cap_h, col)
		var ra := 0.4 * _sun_falloff(tx)
		_rect(ci, tx - cap_w * 0.5, t_top - cap_h, tx + cap_w * 0.5, t_top - cap_h + rim_w, Color(_ember(), ra))
		# Rim on the sun-facing side of the tower.
		var side := -1.0 if tx > _xf() else 1.0
		var ex := tx + side * tw * 0.5
		_rect(ci, minf(ex, ex - side * rim_w), t_top, maxf(ex, ex - side * rim_w), wall_top, Color(_ember(), ra * 0.6))
		# Lit window.
		var win := 0.004 * h
		var wy := t_top + 0.03 * h
		_rect(ci, tx - win * 0.5, wy, tx + win * 0.5, wy + win * 1.8, Color(gh, 0.85))
		if idx % 2 == 1:
			_beacon(ci, Vector2(tx, t_top - cap_h - 0.008 * h), 0.06 * h, 0.002 * h, Color(gh, 0.45))
		tx += spacing
		idx += 1


## 1 at the sun, falling toward the edges (rim light strength).
func _sun_falloff(x: float) -> float:
	var d := absf(x - _xf()) / _h()
	return 0.3 + 0.7 * exp(-d * d * 1.4)


func _rim_line(ci: CanvasItem, x0: float, x1: float, y: float, width: float, peak: float) -> void:
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	var n := 24
	for i in n + 1:
		var x := lerpf(x0, x1, float(i) / float(n))
		pts.append(Vector2(x, y))
		cols.append(Color(_ember(), peak * _sun_falloff(x)))
	ci.draw_polyline_colors(pts, cols, width, true)


func _paint_haze(ci: CanvasItem) -> void:
	var h := _h()
	var y0 := _yh() + 0.02 * size.y
	ci.draw_texture_rect(_haze_tex, Rect2(0, y0, size.x, size.y - y0), false)
	var xf := _xf()
	# Warm reflection of the sun on the plain: a soft vertical smear under the wall.
	ci.draw_texture_rect(_halo_tex, Rect2(xf - 0.13 * h, _yh() - 0.06 * h, 0.26 * h, 0.30 * h), false,
			Color(1, 1, 1, 0.24))
	ci.draw_texture_rect(_halo_tex, Rect2(xf - 0.5 * h, _yh() - 0.04 * h, 1.0 * h, 0.18 * h), false,
			Color(1, 1, 1, 0.12))
	# Stronger haze through the aqueduct arches near the sun.
	ci.draw_texture_rect(_halo_tex, Rect2(xf - 0.7 * h, 0.80 * size.y, 1.4 * h, 0.36 * h), false,
			Color(1, 1, 1, 0.22))


func _paint_near(ci: CanvasItem) -> void:
	var h := _h()
	var col := Color("#0B0607")
	var x0 := -_pad()
	var x1 := size.x + _pad()
	var deck_top := 0.80 * size.y
	var deck_bot := deck_top + 0.03 * h
	# Parapet and deck.
	_rect(ci, x0, deck_top, x1, deck_bot, col)
	_rect(ci, x0, deck_top - 0.006 * h, x1, deck_top, col)
	var bay := 0.16 * h
	var pier := 0.035 * h
	var r := (bay - pier) * 0.5
	var spring := deck_bot + r + 0.006 * h
	var bottom := size.y + 2.0
	var px := fposmod(_xf(), bay) - bay
	while px < x1 + bay:
		# Pier with a small impost.
		_rect(ci, px - pier * 0.5, deck_bot, px + pier * 0.5, bottom, col)
		_rect(ci, px - pier * 0.5 - 0.004 * h, spring - 0.006 * h, px + pier * 0.5 + 0.004 * h, spring, col)
		# Spandrel over the arch to the next pier.
		var ax0 := px + pier * 0.5
		var ax1 := ax0 + 2.0 * r
		var cx := (ax0 + ax1) * 0.5
		var poly := PackedVector2Array([Vector2(ax0 - 0.5, deck_bot - 0.5), Vector2(ax1 + 0.5, deck_bot - 0.5),
				Vector2(ax1 + 0.5, spring)])
		var arc := PackedVector2Array()
		var seg := 20
		for i in seg + 1:
			var ang := float(i) / float(seg) * PI
			arc.append(Vector2(cx + cos(ang) * r, spring - sin(ang) * r))
		poly.append_array(arc)
		poly.append(Vector2(ax0 - 0.5, spring))
		ci.draw_colored_polygon(poly, col)
		ci.draw_polyline(arc, col, 1.0, true)
		px += bay
	# Rim light along the deck top.
	_rim_line(ci, x0, x1, deck_top - 0.006 * h + 0.5, maxf(0.0016 * h, 1.0), 0.3)


func _build_embers() -> void:
	_ember_params.resize(_ember_count * 6)
	var rng := RandomNumberGenerator.new()
	rng.seed = EMBER_SEED
	for i in _ember_count:
		var k := i * 6
		_ember_params[k] = rng.randf_range(0.02, 0.66) # x frac, kept off the right-hand card
		_ember_params[k + 1] = rng.randf_range(0.012, 0.03) # rise speed, heights per second
		_ember_params[k + 2] = rng.randf_range(0.004, 0.016) # sway, heights
		_ember_params[k + 3] = rng.randf() # phase
		_ember_params[k + 4] = rng.randf_range(0.002, 0.004) # radius, heights
		_ember_params[k + 5] = rng.randf_range(0.2, 0.7) # alpha


func _paint_embers(ci: CanvasItem) -> void:
	var h := _h()
	var e := Color("#E8743A")
	var span := 0.75 # embers rise from the bottom through 75% of the height, then fade
	for i in _ember_count:
		var k := i * 6
		var life := fposmod(_ember_params[k + 3] + _t * _ember_params[k + 1] / span, 1.0)
		var y := size.y * (1.02 - life * span)
		var x := _ember_params[k] * size.x + sin(_t * 0.7 + _ember_params[k + 3] * TAU) * _ember_params[k + 2] * h \
				+ life * 0.04 * h
		var a := _ember_params[k + 5] * sin(life * PI)
		var r := _ember_params[k + 4] * h
		ci.draw_circle(Vector2(x, y), r * 2.4, Color(e, a * 0.18), true, -1.0, true)
		ci.draw_circle(Vector2(x, y), r, Color(e, a), true, -1.0, true)


func _paint_top(ci: CanvasItem) -> void:
	var r := Rect2(Vector2.ZERO, size)
	ci.draw_texture_rect(_vignette_tex, r, false)
	if mode == "page":
		ci.draw_rect(r, Color(_night(), _page_dim))
