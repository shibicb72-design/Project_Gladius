class_name UiScale
extends RefCounted
## Touch-sized menus: sizes every Button under a root (and the theme font) from the viewport height.
## Fractions come from data/ui.json (OQ-54 placeholders). Re-applied on viewport size_changed.


## Applies now and keeps the root updated when its viewport is resized.
static func bind(root: Control) -> void:
	var apply := func() -> void: apply_to(root)
	apply.call()
	var vp := root.get_viewport()
	if vp != null:
		vp.size_changed.connect(apply)
		root.tree_exiting.connect(func() -> void:
			if vp.size_changed.is_connected(apply):
				vp.size_changed.disconnect(apply))


## Sets the minimum height of every Button below `root` and the font size of the root's theme.
static func apply_to(root: Control, viewport_height: float = -1.0) -> void:
	var cfg := DataRegistry.new().load_file("res://data/ui.json")
	var h := viewport_height if viewport_height > 0.0 else _viewport_height(root)
	var min_h := h * float(cfg.get("min_touch_target_frac_of_height", 0.0))
	var font := roundi(h * float(cfg.get("font_size_frac_of_height", 0.0)))
	if root.theme != null and font > 0:
		root.theme = root.theme.duplicate()
		root.theme.default_font_size = font
	_apply_buttons(root, min_h)


static func _viewport_height(root: Control) -> float:
	var vp := root.get_viewport()
	return vp.get_visible_rect().size.y if vp != null else 0.0


static func _apply_buttons(node: Node, min_h: float) -> void:
	for c in node.get_children():
		if c is Button:
			(c as Button).custom_minimum_size.y = min_h
		_apply_buttons(c, min_h)
