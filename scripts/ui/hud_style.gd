class_name HudStyle
extends RefCounted
## M2 H1b: the in-match HUD's share of the menu look (docs/UI_STYLE.md): dark warm plates with cut corners (top-left and
## bottom-right) and a gold hairline, marble text, gold for state. Colours by menu_style name (MenuStyle.color);
## which name each HUD part uses and the plate alpha are data/ui.json hud_arrangement.colors (OQ-HUD).


static func colors() -> Dictionary:
	return HudArrangement.cfg().get("colors", {})


## A HUD colour by role (hud_arrangement.colors.<role> names a menu_style colour).
static func role(role_name: String) -> Color:
	return MenuStyle.color(str(colors().get(role_name, "marble")))


## Plate stylebox: menu "surface" at the HUD plate alpha, a gold hairline, chamfered corners of `cut` px.
static func plate(cut: float, line: float, fill_alpha: float = -1.0, border: Color = Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	var fill := MenuStyle.color("surface")
	fill.a = float(colors().get("plate_alpha", 0.72)) if fill_alpha < 0.0 else fill_alpha
	s.bg_color = fill
	var b := border
	if b.a <= 0.0:
		b = MenuStyle.color("gold")
		b.a = 0.45
	s.border_color = b
	s.set_border_width_all(maxi(1, roundi(line)))
	s.corner_radius_top_left = roundi(cut)
	s.corner_radius_bottom_right = roundi(cut)
	s.corner_detail = 1
	s.anti_aliasing = false
	return s


## A text label for the HUD: never takes input, fixed rect (text that is too long is cut with an ellipsis, so the rect the
## layout tests check is the rect on screen), outline for contrast over the 3D view.
static func label(parent: Node, h_align: HorizontalAlignment, color: Color) -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = h_align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.clip_text = true
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", MenuStyle.color("night"))
	parent.add_child(l)
	return l


static func set_font_px(l: Control, px: float) -> void:
	var size := maxi(1, roundi(px))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_constant_override("outline_size", maxi(1, roundi(px * 0.12)))


## Places a child Control at a rect of its parent (top-left anchors, explicit offsets).
static func place(c: Control, r: Rect2) -> void:
	c.set_anchors_preset(Control.PRESET_TOP_LEFT)
	c.position = r.position
	c.size = r.size
