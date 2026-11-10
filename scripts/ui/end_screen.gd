class_name EndScreen
extends Control
## Victory / Draw / "Placed N of M" and the local player's kills, then back to the main menu.
## Layout (docs/UI_STYLE.md): hero backdrop; the laurel, title and kills at the top-left across the full width;
## Main menu (the screen's one primary action) at the bottom-right.

const _Theme := preload("res://scenes/ui/menu_theme.tres")
## Laurel side as a fraction of the canvas height.
const LAUREL_FRAC_OF_HEIGHT := 0.14

var result: Dictionary = {}
## data/ui.json hud.roman_numerals (OQ-38); tests may override.
var roman_numerals: bool = HudNumbers.roman_enabled()
var title_label: Label
var scores_label: Label
var laurel: MenuIcon


func _ready() -> void:
	theme = _Theme
	set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(MenuBackdrop.make("hero"))
	var margin := MenuStyle.safe_margin()
	add_child(margin)
	var content := VBoxContainer.new()
	content.name = "Content"
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	MenuStyle.gap(content, 1.5)
	margin.add_child(content)
	laurel = MenuIcon.make("laurel")
	laurel.tint = MenuStyle.color("gold")
	laurel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	content.add_child(laurel)
	title_label = Label.new()
	MenuStyle.set_role(title_label, "hero")
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	title_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	content.add_child(title_label)
	scores_label = Label.new()
	MenuStyle.set_role(scores_label, "headline")
	scores_label.theme_type_variation = &""  # headline size, but marble like body text
	scores_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	content.add_child(scores_label)
	var spacer := Control.new()
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(spacer)
	# Bottom row: the button keeps the old right column's share of the width (1.0 against 1.3).
	var bottom := HBoxContainer.new()
	bottom.name = "Actions"
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	MenuStyle.gap(bottom, 3.0)
	content.add_child(bottom)
	var pad := Control.new()
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.size_flags_stretch_ratio = 1.3
	bottom.add_child(pad)
	var b := Button.new()
	b.text = "Main menu"
	MenuStyle.primary(b)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.size_flags_stretch_ratio = 1.0
	b.pressed.connect(_on_menu)
	bottom.add_child(b)
	resized.connect(_size_laurel)
	_size_laurel()
	UiScale.bind(self)
	show_result(result if not result.is_empty() else AppFlow.last_result)
	MenuStyle.fade_in(content)


## The laurel is a standalone icon (UiScale only sizes icons inside buttons): about 14% of the canvas height.
func _size_laurel() -> void:
	var vp := get_viewport()
	var h := vp.get_visible_rect().size.y if vp != null else size.y
	if laurel != null and h > 0.0:
		laurel.px = float(roundi(h * LAUREL_FRAC_OF_HEIGHT))


## Battle royale result (BrRules.result() plus MatchRoot's local_player_id / local_squad_id / squad_count).
## The title uses the display face (role `result`) only when its text has no digits, K or X; otherwise `hero` in
## the body face. A role change needs a new font size, so the sizes are re-applied when in the tree.
func show_result(r: Dictionary) -> void:
	result = r
	if title_label == null:
		return
	var text := title_text(r)
	MenuStyle.set_role(title_label, "result" if MenuStyle.display_ok(text) else "hero")
	MenuStyle.set_display_text(title_label, text)
	if is_inside_tree():
		UiScale.apply_to(self)
	var me := int(r.get("local_player_id", -1))
	var kills: Dictionary = r.get("kills", {})
	scores_label.text = "Kills %s" % HudNumbers.number(int(kills.get(me, 0)), roman_numerals) if me >= 0 else ""


func title_text(r: Dictionary) -> String:
	var mine := int(r.get("local_squad_id", -1))
	var placements: Dictionary = r.get("placements", {})
	if bool(r.get("draw", false)):
		return "Draw"
	if mine >= 0 and r.get("winner") != null and int(r["winner"]) == mine:
		return "Victory"
	if mine >= 0 and placements.has(mine):
		var total := int(r.get("squad_count", placements.size()))
		return "Placed %s of %s" % [HudNumbers.number(int(placements[mine]), roman_numerals),
				HudNumbers.number(total, roman_numerals)]
	if r.get("winner") == null or int(r["winner"]) < 0:
		return "Match over"
	return "%s wins" % HudNumbers.squad_name(int(r["winner"]), roman_numerals)


func _on_menu() -> void:
	AppFlow.end_session()
	AppFlow.go(get_tree(), AppFlow.MENU_SCENE)
