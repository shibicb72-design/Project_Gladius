class_name HapticsScreen
extends Control
## Haptics settings (G2f): master switch, per-category toggles (weapons, status, sound cues) and High / Low
## quality. Every change is saved to the profile at once. On a device that cannot vibrate it shows
## "Not available on this device" and the controls are disabled. Opened from the shared SettingsPanel.
## Layout uses containers and anchors; all targets are at least 48 dp (UiScale).

signal closed
## Emitted after every change was saved to the profile.
signal changed

const _Theme := preload("res://scenes/ui/theme.tres")
const CATEGORY_TITLES := {"weapons": "Weapons (fire, reload, melee hit)",
		"status": "Status (damage, shield break, death)", "sound_cues": "Sound cues"}
const QUALITY_TITLES := {"high": "High", "low": "Low"}
## Text prefix on the chosen quality, so the choice reads without relying on the pressed style alone.
const SELECTED_MARKER := "[x] "

var save := SaveService.new()
## Injected by tests and the capture tool; defaults to the shared service.
var service: HapticsService
var back_button: Button
var master_button: Button
var category_buttons: Dictionary = {}  # category -> Button
var quality_buttons: Dictionary = {}  # quality -> Button
var unsupported_label: Label
var _built: bool = false


func _ready() -> void:
	theme = _Theme
	set_anchors_preset(Control.PRESET_FULL_RECT)
	process_mode = Node.PROCESS_MODE_ALWAYS
	build()
	UiScale.bind(self)


func build() -> void:
	if _built:
		return
	_built = true
	if service == null:
		service = Haptics.get_service()
	service.apply_settings(save.load_profile()["haptics"])
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.05, 0.07, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	add_child(margin)
	var root := VBoxContainer.new()
	margin.add_child(root)
	var head := HBoxContainer.new()
	root.add_child(head)
	back_button = _button(head, "Back", _on_back, false)
	var title := Label.new()
	title.text = "Haptics"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_child(title)
	unsupported_label = Label.new()
	unsupported_label.text = "Not available on this device"
	root.add_child(unsupported_label)
	master_button = _button(root, "", _on_master)
	for cat in service.cfg["categories"]:
		category_buttons[cat] = _button(root, CATEGORY_TITLES[cat], _on_category.bind(cat))
	var quality_row := HBoxContainer.new()
	root.add_child(quality_row)
	var ql := Label.new()
	ql.text = "Quality:"
	quality_row.add_child(ql)
	for q in service.cfg["qualities"]:
		quality_buttons[q] = _button(quality_row, QUALITY_TITLES[q], _on_quality.bind(q))
	_refresh()


func _button(parent: Node, text: String, handler: Callable, toggle: bool = true) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = toggle
	b.pressed.connect(handler)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL if parent is HBoxContainer and text != "Back" else Control.SIZE_FILL
	parent.add_child(b)
	return b


func _on_back() -> void:
	closed.emit()


func _on_master() -> void:
	service.set_enabled(not service.enabled)
	_persist()


func _on_category(cat: String) -> void:
	service.set_category(cat, not service.is_category_enabled(cat))
	_persist()


func _on_quality(q: String) -> void:
	service.set_quality(q)
	_persist()
	service.play("weapon_fire")  # a sample at the new strength


## Syncs buttons and labels to the service without re-emitting signals.
func _refresh() -> void:
	var supported := service.is_supported()
	unsupported_label.visible = not supported
	master_button.text = "Haptics: %s" % ("On" if service.is_enabled() else "Off")
	master_button.set_pressed_no_signal(service.is_enabled())
	master_button.disabled = not supported
	for cat in category_buttons:
		var b: Button = category_buttons[cat]
		b.set_pressed_no_signal(service.is_category_enabled(cat))
		b.text = "%s: %s" % [CATEGORY_TITLES[cat], "On" if service.is_category_enabled(cat) else "Off"]
		b.disabled = not supported or not service.enabled
	for q in quality_buttons:
		var b: Button = quality_buttons[q]
		b.set_pressed_no_signal(q == service.quality)
		b.text = (SELECTED_MARKER if q == service.quality else "") + QUALITY_TITLES[q]
		b.disabled = not supported or not service.enabled


func _persist() -> void:
	var profile := save.load_profile()
	profile["haptics"] = service.to_dict()
	save.save_profile(profile)
	AppFlow.profile = save.load_profile()
	_refresh()
	changed.emit()
