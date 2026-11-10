class_name MenuStyle
extends RefCounted
## The front-end style kit (docs/UI_STYLE.md): palette, type roles, spacing units, safe margins, icons and motion.
## Builders tag controls with metas; `apply_scale` (called by UiScale.apply_to on every resize) turns the metas into
## sizes derived from the canvas height. Numbers live in data/ui.json `menu_style` / `menu_type_scale`.

const THEME := preload("res://scenes/ui/menu_theme.tres")
const DISPLAY_FONT := preload("res://assets/third_party/kenney_fonts/kenney_future.ttf")
const CAPTION_FONT := preload("res://assets/third_party/kenney_fonts/kenney_future_narrow.ttf")
const UI_PATH := "res://data/ui.json"

const META_ROLE := &"ui_type_role"
const META_MIN_H_MULT := &"ui_min_h_mult"
const META_SEP_UNITS := &"ui_sep_units"
const META_MIN_W_UNITS := &"ui_min_w_units"
const META_SAFE_MARGIN := &"ui_safe_margin_units"
const META_PRESS_WIRED := &"ui_press_wired"

## Canvas units on the left of an Icon button variation reserved for its MenuIcon (matches menu_theme.tres).
const ICON_AREA := 60.0
const DISPLAY_ROLES: Array[String] = ["logo", "hero", "headline", "title"]

static var _ui: Dictionary = {}
static var _grabbers: Dictionary = {}


static func _data() -> Dictionary:
	if _ui.is_empty():
		_ui = DataRegistry.new().load_file(UI_PATH)
	return _ui


## data/ui.json `menu_style`.
static func cfg() -> Dictionary:
	return _data().get("menu_style", {})


## data/ui.json `menu_type_scale` (role -> multiplier of the UiScale font size).
static func type_scale() -> Dictionary:
	return _data().get("menu_type_scale", {})


## A palette colour by name (magenta when missing, so a typo shows).
static func color(color_name: String) -> Color:
	var arr: Variant = (cfg().get("colors", {}) as Dictionary).get(color_name)
	if arr is Array and (arr as Array).size() >= 3:
		var a: Array = arr
		return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)
	return Color.MAGENTA


## One spacing unit in canvas units for a canvas of this height.
static func unit(canvas_h: float) -> float:
	return canvas_h * float(cfg().get("spacing_frac_of_height", 0.0))


## True when the display / caption faces can set this text: no digits and no K or X (they read as S and H there).
static func display_ok(text: String) -> bool:
	if text.is_empty():
		return false
	for ch in text.to_upper():
		if ch == "K" or ch == "X" or (ch >= "0" and ch <= "9"):
			return false
	return true


## Gives a control a type role (a key of menu_type_scale); apply_scale sizes it. Labels also get the role's colour.
static func set_role(c: Control, role: String) -> void:
	c.set_meta(META_ROLE, role)
	if c is Label:
		match role:
			"logo", "hero", "headline":
				c.theme_type_variation = &"HeadlineLabel"
			"caption":
				c.theme_type_variation = &"CaptionLabel"
	_apply_face(c)


## Sets the text and re-picks the face (display face only for display_ok text).
static func set_display_text(c: Control, text: String) -> void:
	c.set(&"text", text)
	_apply_face(c)


static func _apply_face(c: Control) -> void:
	var role := String(c.get_meta(META_ROLE, ""))
	var text: Variant = c.get(&"text")
	var face: Font = null
	if role in DISPLAY_ROLES:
		face = DISPLAY_FONT
	elif role == "caption":
		face = CAPTION_FONT
	if face != null and text is String and display_ok(text):
		c.add_theme_font_override(&"font", face)
	else:
		c.remove_theme_font_override(&"font")


## A caption label (caller passes the text in the case it wants shown).
static func caption(text: String) -> Label:
	var l := Label.new()
	l.text = text
	set_role(l, "caption")
	return l


## A headline label (gold, display face when the text allows it).
static func headline(text: String) -> Label:
	var l := Label.new()
	l.text = text
	set_role(l, "headline")
	return l


## Marks the screen's one primary action: crimson, title size, taller.
static func primary(b: Button) -> void:
	b.theme_type_variation = &"PrimaryButton"
	set_role(b, "title")
	b.set_meta(META_MIN_H_MULT, float(cfg().get("primary_height_mult", 1.0)))


## A list row: dark surface, gold left edge, left-aligned text.
static func row(b: Button) -> void:
	b.theme_type_variation = &"RowButton"
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT


## Adds a code-drawn icon in the button's reserved left area and switches to the Icon twin variation.
static func add_icon(b: Button, kind: String) -> MenuIcon:
	match String(b.theme_type_variation):
		"", "Button":
			b.theme_type_variation = &"IconButton"
		"PrimaryButton":
			b.theme_type_variation = &"PrimaryIconButton"
		"RowButton":
			b.theme_type_variation = &"RowIconButton"
	var icon := MenuIcon.make(kind)
	b.add_child(icon)
	_place_icon(icon, icon.px)
	return icon


static func _place_icon(icon: MenuIcon, side: float) -> void:
	icon.px = side
	icon.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	icon.offset_left = ICON_AREA * 0.5 - side * 0.5
	icon.offset_right = ICON_AREA * 0.5 + side * 0.5
	icon.offset_top = -side * 0.5
	icon.offset_bottom = side * 0.5


## A card panel; pass "HeroCard" for the gold-topped variant.
static func card(variation: String = "") -> PanelContainer:
	var p := PanelContainer.new()
	if not variation.is_empty():
		p.theme_type_variation = StringName(variation)
	return p


## A full-rect margin that keeps content inside the platform safe area plus `units` spacing units.
static func safe_margin(units: float = -1.0) -> MarginContainer:
	var m := MarginContainer.new()
	m.name = "SafeMargin"
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var u := units if units >= 0.0 else float(cfg().get("screen_margin_units", 0.0))
	m.set_meta(META_SAFE_MARGIN, u)
	return m


## Sets a container's gap in spacing units (applied by apply_scale).
static func gap(c: Control, units: float) -> void:
	c.set_meta(META_SEP_UNITS, units)


## Sets a control's minimum width in spacing units (applied by apply_scale).
static func min_width(c: Control, units: float) -> void:
	c.set_meta(META_MIN_W_UNITS, units)


## A sub-page header: Back (with chevron) at the left, then the title. Returns {"row", "back", "title"}.
static func page_header(title_text: String, on_back: Callable) -> Dictionary:
	var row_box := HBoxContainer.new()
	row_box.name = "Header"
	gap(row_box, 2.0)
	var back := Button.new()
	back.name = "Back"
	back.text = "Back"
	back.mouse_filter = Control.MOUSE_FILTER_PASS
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	add_icon(back, "chevron_left")
	min_width(back, 14.0)
	if on_back.is_valid():
		back.pressed.connect(on_back)
	row_box.add_child(back)
	var title := headline(title_text)
	title.name = "Title"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row_box.add_child(title)
	return {"row": row_box, "back": back, "title": title}


static func _motion() -> Dictionary:
	return cfg().get("motion", {})


static func _motion_on() -> bool:
	return bool(_motion().get("enabled", false)) and DisplayServer.get_name() != "headless"


## Screen enter: fades the content in. Does nothing when motion is off, headless or out of the tree.
static func fade_in(content: CanvasItem) -> void:
	if not _motion_on() or not content.is_inside_tree():
		return
	content.modulate.a = 0.0
	var tw := content.create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.tween_property(content, "modulate:a", 1.0, float(_motion().get("screen_fade_s", 0.18)))


## Turns the style metas under `root` (root included) into sizes for this font size and canvas height.
static func apply_scale(root: Control, font_px: int, canvas_h: float) -> void:
	var u := unit(canvas_h)
	var scales := type_scale()
	var vp_size := Vector2.ZERO
	var vp := root.get_viewport()
	if vp != null:
		vp_size = vp.get_visible_rect().size
	var insets := PlatformServices.new().get_safe_insets()
	_apply_node(root, font_px, u, scales, vp_size, insets, _motion_on())


static func _apply_node(n: Node, font_px: int, u: float, scales: Dictionary, vp_size: Vector2, insets: Vector4,
		motion: bool) -> void:
	if n is Control:
		var c := n as Control
		if c.has_meta(META_ROLE):
			var mult := float(scales.get(String(c.get_meta(META_ROLE)), 1.0))
			c.add_theme_font_size_override(&"font_size", roundi(font_px * mult))
		if c.has_meta(META_SEP_UNITS):
			var sep := roundi(float(c.get_meta(META_SEP_UNITS)) * u)
			if c is GridContainer or c is FlowContainer:
				c.add_theme_constant_override(&"h_separation", sep)
				c.add_theme_constant_override(&"v_separation", sep)
			else:
				c.add_theme_constant_override(&"separation", sep)
		if c.has_meta(META_MIN_W_UNITS):
			c.custom_minimum_size.x = float(c.get_meta(META_MIN_W_UNITS)) * u
		if c.has_meta(META_SAFE_MARGIN):
			var base := float(c.get_meta(META_SAFE_MARGIN)) * u
			c.add_theme_constant_override(&"margin_left", roundi(base + insets.x * vp_size.x))
			c.add_theme_constant_override(&"margin_top", roundi(base + insets.y * vp_size.y))
			c.add_theme_constant_override(&"margin_right", roundi(base + insets.z * vp_size.x))
			c.add_theme_constant_override(&"margin_bottom", roundi(base + insets.w * vp_size.y))
		if c is MenuIcon and c.get_parent() is Button:
			_place_icon(c as MenuIcon, float(roundi(font_px * 1.15)))
		if c is HSlider:
			var knob := slider_grabber(roundi(font_px * 1.3))
			for icon_name in [&"grabber", &"grabber_highlight", &"grabber_disabled"]:
				c.add_theme_icon_override(icon_name, knob)
		if c is Button and motion and not c.has_meta(META_PRESS_WIRED):
			_wire_press(c as Button)
	for child in n.get_children():
		_apply_node(child, font_px, u, scales, vp_size, insets, motion)


static func _wire_press(b: Button) -> void:
	b.set_meta(META_PRESS_WIRED, true)
	var m := _motion()
	var press_scale := float(m.get("press_scale", 1.0))
	var t_in := float(m.get("press_in_s", 0.06))
	var t_out := float(m.get("press_out_s", 0.1))
	b.button_down.connect(func() -> void: _tween_scale(b, press_scale, t_in))
	b.button_up.connect(func() -> void: _tween_scale(b, 1.0, t_out))


static func _tween_scale(b: Button, to: float, duration: float) -> void:
	if not b.is_inside_tree():
		return
	b.pivot_offset = b.size * 0.5
	var tw := b.create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.tween_property(b, "scale", Vector2(to, to), duration)


## A round gold slider knob, px by px, cached per size.
static func slider_grabber(px: int) -> Texture2D:
	var side := maxi(px, 2)
	if _grabbers.has(side):
		return _grabbers[side]
	var g := Gradient.new()
	var gold := color("gold")
	var night := color("night")
	g.offsets = PackedFloat32Array([0.0, 0.62, 0.66, 0.86, 0.9, 1.0])
	g.colors = PackedColorArray([color("gold_hi"), gold, night, night, Color(night, 0.0), Color(night, 0.0)])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.width = side
	tex.height = side
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	_grabbers[side] = tex
	return tex
