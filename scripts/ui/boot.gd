class_name Boot
extends Control
## Boot: applies the default graphics preset and the saved profile, shows the logo over the dusk backdrop for
## `menu_style.boot.hold_s` (OQ-UI-BOOT), then routes to the main menu. A tap skips the hold.
## Layout (docs/UI_STYLE.md): hero backdrop full-bleed; the logo sits where the main menu shows it (top of the left
## hero column inside the safe margin), so the cut to the menu only adds its card; no other text.

## Hold ceiling: a bad data value must never trap the player on the boot screen.
const MAX_HOLD_S := 3.0
const MAX_FADE_S := 2.0

## When false the screen stays still (tools set it before add_child); when true it goes to the menu after the hold.
@export var auto_advance: bool = true

## Tests set this to observe navigation; when valid it is called instead of AppFlow.go. Shipping code never sets it.
var navigate: Callable = Callable()
var logo: MenuLogo

var _went: bool = false


func _ready() -> void:
	PlatformServices.new().log_display_info()
	GraphicsPresets.new().apply("", get_viewport())
	AppFlow.profile = SaveService.new().load_profile()
	theme = MenuStyle.THEME
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# Nothing here takes the mouse, so a click or tap reaches _unhandled_input and skips the hold.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(MenuBackdrop.make("hero"))
	var margin := MenuStyle.safe_margin()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)
	# Same split as the main menu's home page (main_menu.gd _ready / _build_hero), so the cut does not move the logo.
	var home := HBoxContainer.new()
	home.name = "Home"
	home.mouse_filter = Control.MOUSE_FILTER_IGNORE
	MenuStyle.gap(home, 3.0)
	margin.add_child(home)
	var hero := VBoxContainer.new()
	hero.name = "Hero"
	hero.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hero.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hero.size_flags_stretch_ratio = 1.3
	home.add_child(hero)
	logo = MenuLogo.new()
	logo.name = "Logo"
	logo.align = HORIZONTAL_ALIGNMENT_LEFT
	hero.add_child(logo)
	# Empty stand-in for the menu's action card.
	var card_slot := Control.new()
	card_slot.name = "CardSlot"
	card_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card_slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card_slot.size_flags_stretch_ratio = 1.0
	home.add_child(card_slot)
	UiScale.bind(self)
	if not MenuStyle.motion_disabled:
		logo.play_intro(logo_fade_seconds())
	if auto_advance:
		get_tree().create_timer(hold_seconds()).timeout.connect(go_to_menu)


func _unhandled_input(event: InputEvent) -> void:
	var tap := false
	if event is InputEventScreenTouch:
		tap = (event as InputEventScreenTouch).pressed
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		tap = mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT
	elif event.is_action_pressed("ui_accept"):
		tap = true
	if tap:
		get_viewport().set_input_as_handled()
		go_to_menu()


## The single place that leaves the boot screen; goes at most once, and never once the node has left the tree.
func go_to_menu() -> void:
	if _went or not is_inside_tree():
		return
	_went = true
	if navigate.is_valid():
		navigate.call()
	else:
		AppFlow.go(get_tree(), AppFlow.MENU_SCENE)


## Seconds the logo is held: data `menu_style.boot.hold_s`, bounded; 0 when headless (no waiting in test runs).
static func hold_seconds() -> float:
	if DisplayServer.get_name() == "headless":
		return 0.0
	return clamp_hold(float(_boot_cfg().get("hold_s", 0.9)))


## Logo fade-in seconds: data `menu_style.boot.logo_fade_s`, bounded to 0 .. MAX_FADE_S.
static func logo_fade_seconds() -> float:
	return clampf(float(_boot_cfg().get("logo_fade_s", 0.35)), 0.0, MAX_FADE_S)


## Bounds a hold value to 0 .. MAX_HOLD_S.
static func clamp_hold(v: float) -> float:
	return clampf(v, 0.0, MAX_HOLD_S)


static func _boot_cfg() -> Dictionary:
	var v: Variant = MenuStyle.cfg().get("boot", {})
	if v is Dictionary:
		return v
	return {}
