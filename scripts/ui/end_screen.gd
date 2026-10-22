class_name EndScreen
extends Control
## Winner/draw and per-squad scores, then back to the main menu.

const _Theme := preload("res://scenes/ui/theme.tres")

var result: Dictionary = {}
var title_label: Label
var scores_label: Label


func _ready() -> void:
	theme = _Theme
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var box := VBoxContainer.new()
	center.add_child(box)
	title_label = Label.new()
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title_label)
	scores_label = Label.new()
	scores_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(scores_label)
	var b := Button.new()
	b.text = "Main menu"
	b.pressed.connect(_on_menu)
	box.add_child(b)
	show_result(result if not result.is_empty() else AppFlow.last_result)


func show_result(r: Dictionary) -> void:
	result = r
	if title_label == null:
		return
	if bool(r.get("draw", false)):
		title_label.text = "Draw"
	elif r.get("winner") == null:
		title_label.text = "Match over"
	else:
		title_label.text = "Squad %s wins" % RomanNumerals.to_roman(int(r["winner"]) + 1)
	var scores: Dictionary = r.get("scores", {})
	var keys := scores.keys()
	keys.sort()
	var lines: Array[String] = []
	for squad in keys:
		lines.append("Squad %s: %s" % [RomanNumerals.to_roman(int(squad) + 1), RomanNumerals.to_roman(int(scores[squad]))])
	scores_label.text = "\n".join(lines)


func _on_menu() -> void:
	AppFlow.end_session()
	AppFlow.go(get_tree(), AppFlow.MENU_SCENE)
