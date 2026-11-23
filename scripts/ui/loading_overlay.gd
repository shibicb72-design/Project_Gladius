class_name LoadingOverlay
extends CanvasLayer
## W1c (OQ-W1C-LOADING): the opaque screen a real solo match shows while it opens (MatchRoot's staged open: map
## build, shader warm-up). Plain text and a progress bar, nothing else: a placeholder UI choice, NOT DESIGN.md's
## warm-up lobby. Anchors and containers only, so it fills any aspect ratio; the look is data/ui.json
## "loading_overlay" (placeholders). It blocks the mouse while it is up and runs while the tree is paused.

const UI_PATH := "res://data/ui.json"

@onready var background: ColorRect = $Background
@onready var label: Label = $Background/Center/Box/Label
@onready var bar: ProgressBar = $Background/Center/Box/Bar


static func config() -> Dictionary:
	var c: Variant = DataRegistry.new().load_file(UI_PATH).get("loading_overlay", {})
	return c if c is Dictionary else {}


static func _color(a: Variant, fallback: Color) -> Color:
	if a is Array and (a as Array).size() >= 3:
		return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if (a as Array).size() > 3 else 1.0)
	return fallback


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var cfg := config()
	layer = int(cfg.get("layer", layer))
	background.color = _color(cfg.get("background_color"), background.color)
	background.mouse_filter = Control.MOUSE_FILTER_STOP
	label.text = String(cfg.get("text", label.text))
	label.add_theme_color_override("font_color", _color(cfg.get("text_color"), Color.WHITE))
	if cfg.has("font_size_px"):
		label.add_theme_font_size_override("font_size", int(cfg["font_size_px"]))
	if cfg.has("bar_size_px"):
		var s: Array = cfg["bar_size_px"]
		bar.custom_minimum_size = Vector2(float(s[0]), float(s[1]))
	if cfg.has("gap_px"):
		($Background/Center/Box as VBoxContainer).add_theme_constant_override("separation", int(cfg["gap_px"]))
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.step = 0.0
	bar.show_percentage = false
	set_progress(0.0)


## 0..1; never goes back.
func set_progress(value: float) -> void:
	if bar != null:
		bar.value = maxf(bar.value, clampf(value, 0.0, 1.0))


func progress() -> float:
	return bar.value if bar != null else 0.0
