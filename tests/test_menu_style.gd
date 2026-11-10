extends "res://tests/test_case.gd"
## M2U1 stop 1: the front-end theme mirrors the data palette, type roles scale from the UiScale font size, the
## display face only sets safe words, safe margins add the platform inset, and every MenuIcon kind draws.

const ROLES: Array[String] = ["logo", "result", "hero","headline", "title", "body", "caption"]


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _themed_root() -> Control:
	var root := Control.new()
	root.theme = MenuStyle.THEME
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_tree().root.add_child(root)
	return root


func _close(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) <= 0.002 and absf(a.g - b.g) <= 0.002 and absf(a.b - b.b) <= 0.002 \
			and absf(a.a - b.a) <= 0.002


func _bg(style: String, type_name: String) -> Color:
	return (MenuStyle.THEME.get_stylebox(style, type_name) as StyleBoxFlat).bg_color


func test_type_scale_derives_from_font_size_at_two_heights() -> void:
	var root := _themed_root()
	var labels := {}
	for role in ROLES:
		var l := Label.new()
		l.text = "Gladius"
		MenuStyle.set_role(l, role)
		root.add_child(l)
		labels[role] = l
	var frac := float(DataRegistry.new().load_file("res://data/ui.json").get("font_size_frac_of_height", 0.0))
	var scales := MenuStyle.type_scale()
	for h in [648.0, 959.0]:
		UiScale.apply_to(root, h)
		var base := roundi(h * frac)
		var prev := 1 << 30
		for role in ROLES:
			var got := (labels[role] as Label).get_theme_font_size("font_size")
			assert_eq(got, roundi(base * float(scales[role])), "%s size at h=%d" % [role, int(h)])
			assert_true(got < prev, "%s is smaller than the role above it at h=%d" % [role, int(h)])
			prev = got
	root.free()


func test_theme_mirrors_the_data_palette() -> void:
	assert_true(_close(_bg("normal", "Button"), MenuStyle.color("surface_hi")), "Button normal is surface_hi")
	assert_true(_close(_bg("pressed", "Button"), MenuStyle.color("gold")), "Button pressed is gold")
	assert_true(_close(_bg("normal", "PrimaryButton"), MenuStyle.color("crimson")), "PrimaryButton normal is crimson")
	assert_true(_close(_bg("normal", "RowButton"), MenuStyle.color("surface")), "RowButton normal is surface")
	assert_true(_close(_bg("panel", "PanelContainer"), MenuStyle.color("surface")), "PanelContainer panel is surface")
	assert_true(_close(_bg("normal", "LineEdit"), MenuStyle.color("field")), "LineEdit normal is field")
	var t := MenuStyle.THEME
	assert_true(_close(t.get_color("font_color", "Label"), MenuStyle.color("marble")), "Label text is marble")
	assert_true(_close(t.get_color("font_color", "HeadlineLabel"), MenuStyle.color("gold")), "HeadlineLabel is gold")
	assert_true(_close(t.get_color("font_color", "CaptionLabel"), MenuStyle.color("marble_dim")),
			"CaptionLabel is marble_dim")


func test_every_button_variation_has_a_distinct_pressed_style() -> void:
	var t := MenuStyle.THEME
	for type_name in ["Button", "PrimaryButton", "RowButton", "IconButton", "PrimaryIconButton", "RowIconButton"]:
		for style in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
			assert_true(t.has_stylebox(style, type_name), "%s has %s" % [type_name, style])
		assert_true(not _close(_bg("pressed", type_name), _bg("normal", type_name)),
				"%s pressed differs from normal" % type_name)


func test_display_face_only_for_safe_words() -> void:
	for ok in ["GLADIUS", "Settings", "Host", "Victory", "Draw"]:
		assert_true(MenuStyle.display_ok(ok), "display face sets '%s'" % ok)
	for bad in ["Back", "Kills 3", "Placed 2 of 3", "Squad 2 wins", "192.168.43.1", "Max", ""]:
		assert_true(not MenuStyle.display_ok(bad), "display face refuses '%s'" % bad)
	var l := Label.new()
	l.text = "Settings"
	MenuStyle.set_role(l, "headline")
	assert_true(l.has_theme_font_override("font"), "headline 'Settings' has a font override")
	assert_true(l.get_theme_font("font") == MenuStyle.DISPLAY_FONT, "headline 'Settings' uses the display face")
	MenuStyle.set_display_text(l, "Placed 2 of 3")
	assert_eq(l.text, "Placed 2 of 3", "set_display_text sets the text")
	assert_true(not l.has_theme_font_override("font"), "digits fall back to the body face")
	l.free()


func test_safe_margin_adds_the_platform_inset() -> void:
	var vis := _tree().root.get_visible_rect().size
	var holder := _themed_root()
	var m := MenuStyle.safe_margin()
	holder.add_child(m)
	var h := vis.y
	var u := MenuStyle.unit(h)
	PlatformServices.safe_insets_override = Vector4(0.05, 0.0, 0.03, 0.02)
	UiScale.apply_to(holder, h)
	assert_true(absf(m.get_theme_constant("margin_left") - (3.0 * u + 0.05 * vis.x)) <= 1.0, "left adds 5% of width")
	assert_true(absf(m.get_theme_constant("margin_right") - (3.0 * u + 0.03 * vis.x)) <= 1.0, "right adds 3% of width")
	assert_true(absf(m.get_theme_constant("margin_top") - 3.0 * u) <= 1.0, "top is the plain margin")
	assert_true(absf(m.get_theme_constant("margin_bottom") - (3.0 * u + 0.02 * vis.y)) <= 1.0,
			"bottom adds 2% of height")
	PlatformServices.safe_insets_override = null
	UiScale.apply_to(holder, h)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		assert_true(absf(m.get_theme_constant(side) - 3.0 * u) <= 1.0, "%s without insets is 3 units" % side)
	PlatformServices.safe_insets_override = null
	holder.free()


func test_pad_sets_margins_in_spacing_units() -> void:
	var root := _themed_root()
	var m := MarginContainer.new()
	MenuStyle.pad(m, 0.0, 0.0, 1.5, 0.0)
	root.add_child(m)
	UiScale.apply_to(root, 800.0)
	assert_eq(m.get_theme_constant("margin_right"), roundi(1.5 * MenuStyle.unit(800.0)), "right is 1.5 units")
	for side in ["margin_left", "margin_top", "margin_bottom"]:
		assert_eq(m.get_theme_constant(side), 0, "%s is 0" % side)
	root.free()


func test_text_fields_and_primary_buttons_get_touch_heights() -> void:
	var root := _themed_root()
	var field := LineEdit.new()
	var plain := Button.new()
	plain.text = "Settings"
	var main := Button.new()
	main.text = "Host"
	MenuStyle.primary(main)
	root.add_child(field)
	root.add_child(plain)
	root.add_child(main)
	UiScale.apply_to(root, 1000.0)
	assert_true(field.custom_minimum_size.y >= 0.09 * 1000.0 - 0.001, "text field is a full touch target")
	assert_true(main.custom_minimum_size.y >= 1.25 * plain.custom_minimum_size.y - 0.001,
			"primary is 1.25x a plain button")
	assert_eq(String(main.theme_type_variation), "PrimaryButton", "primary variation")
	root.free()


func test_icons_exist_for_every_kind() -> void:
	var root := _themed_root()
	for kind in MenuIcon.KINDS:
		var icon := MenuIcon.make(kind, 24.0)
		root.add_child(icon)
		assert_eq(icon.kind, kind, "icon kind %s" % kind)
		assert_true(is_equal_approx(icon.size.x, 24.0), "icon %s is 24 px" % kind)
	await _tree().process_frame
	var b := Button.new()
	b.text = "Settings"
	root.add_child(b)
	var icon := MenuStyle.add_icon(b, "gear")
	assert_eq(String(b.theme_type_variation), "IconButton", "add_icon switches to the Icon twin")
	assert_true(icon.get_parent() == b and b.get_node_or_null("Icon") is MenuIcon, "button has a MenuIcon child")
	await _tree().process_frame
	root.queue_free()
