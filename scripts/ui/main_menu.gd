class_name MainMenu
extends Control
## Main menu: Play solo (W0, no network), Host, Join (manual IP, OQ-41), gamertag (OQ-39). Later-milestone entries are
## shown disabled. In a web build Host and Join are disabled with a note (PlatformServices.can_lan()).
## Two pages (docs/UI_STYLE.md 5): HOME (logo left, action card right) and SETTINGS (the shared panel in a
## centred column under a Back header). Both pages sit on the code-drawn backdrop.

const _Theme := preload("res://scenes/ui/menu_theme.tres")
const LATER_ENTRIES: Array[String] = ["Loadout", "Profile", "Shop", "Tutorials"]
## Home row stretch ratios: the hero column (logo) and the action card. The later grid's column decision reads
## the same numbers, so they cannot drift. The boot screen mirrors this layout (scripts/ui/boot.gd).
const HERO_RATIO := 1.3
const CARD_RATIO := 1.0
## W0: the note under Host / Join in a web build (LAN in the browser is slice W2).
const LAN_LATER_NOTE := "LAN in the browser comes later"

const _SettingsScene := preload("res://scenes/ui/settings_panel.tscn")
const _WebArgs := preload("res://scripts/platform/web_args.gd")

## Profile store; assigning it also points the shared settings panel at it.
var save := SaveService.new():
	set(value):
		save = value
		if settings != null:
			settings.save = value
var settings: SettingsPanel
## The home page: the hero column (logo) and the action card.
var home: HBoxContainer
var logo: MenuLogo
## The action card's column scrolls: on short screens (Fold cover) it can be taller than the card.
var scroll: ScrollContainer
var name_edit: LineEdit
var ip_edit: LineEdit
var status_label: Label
## W0: the first, largest button: a local match with bots, no network (AppFlow.solo).
var solo_button: Button
var host_button: Button
var join_button: Button
## W0: shown under Join when LAN is unavailable here (the browser); hidden otherwise.
var lan_note: Label
## Test hook (W0): when valid, Play solo calls go_scene.call(scene_path) instead of AppFlow.go.
var go_scene: Callable
var settings_button: Button
## The settings page, drawn over the home page with its own dimmed backdrop. Built in _ready (Host and Join
## persist through the panel), shown by open_settings().
var settings_page: Control
var settings_scroll: ScrollContainer
var settings_back_button: Button
var _settings_content: Control
var settings_open: bool:
	get: return settings_page != null and settings_page.visible
var gyro_button: Button:
	get: return settings.gyro_button
var gyro_enabled: bool:
	get: return settings.gyro_enabled
var move_stick_button: Button:
	get: return settings.move_stick_button
var stick_layout_button: Button:
	get: return settings.stick_layout_button
var move_stick_mode: String:
	get: return settings.move_stick_mode
var vjoy_layout: String:
	get: return settings.vjoy_layout
var sprint_label: Label:
	get: return settings.sprint_label
var sprint_slider: HSlider:
	get: return settings.sprint_slider
var sprint_lock_pos: Array:
	get: return settings.sprint_lock_pos
var later_buttons: Array[Button] = []
## Holds later_buttons: 2 columns when two of the widest fit side by side, else 1.
var later_grid: GridContainer
var _card: PanelContainer
var _gutter: MarginContainer


func _ready() -> void:
	theme = _Theme
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var profile := save.load_profile()
	add_child(MenuBackdrop.make("hero"))
	var margin := MenuStyle.safe_margin()
	add_child(margin)
	home = HBoxContainer.new()
	home.name = "Home"
	home.mouse_filter = Control.MOUSE_FILTER_IGNORE
	MenuStyle.gap(home, 3.0)
	margin.add_child(home)
	_build_hero(home)
	_build_card(home, profile)
	_build_settings_page()
	UiScale.bind(self)
	MenuStyle.fade_in(home)
	# Deferred: on a window resize UiScale (viewport size_changed) may re-size the fonts after home resizes.
	home.resized.connect(_update_later_columns, CONNECT_DEFERRED)
	_update_later_columns.call_deferred()  # after the first layout and UiScale's sizes
	# W0: debug web builds only (WebArgs): ?autosolo=1 plays solo straight from the URL, for the browser smoke test.
	_WebArgs.debug_marker("GLADIUS_MENU_READY")
	apply_autosolo(_WebArgs.take_autosolo())


## W0: an autosolo request (WebArgs.parse) presses Play solo and hands the request to the solo lobby, which applies
## the length and presses Start. {} does nothing. Returns whether it started.
func apply_autosolo(request: Dictionary) -> bool:
	if request.is_empty():
		return false
	_on_solo()
	_WebArgs.pending = request.duplicate()
	return true


## Left: the logo at the top-left; the space below it shows the backdrop art. Nothing interactive.
func _build_hero(parent: Control) -> void:
	var hero := VBoxContainer.new()
	hero.name = "Hero"
	hero.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hero.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hero.size_flags_stretch_ratio = HERO_RATIO
	parent.add_child(hero)
	logo = MenuLogo.new()
	logo.name = "Logo"
	logo.align = HORIZONTAL_ALIGNMENT_LEFT
	hero.add_child(logo)


## Right: the action card. Full-height card, scrolling column centred in it while it fits.
func _build_card(parent: Control, profile: Dictionary) -> void:
	var card := MenuStyle.card("HeroCard")
	card.name = "HeroCard"
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.size_flags_stretch_ratio = CARD_RATIO
	parent.add_child(card)
	_card = card
	# Not inside a CenterContainer (that would shrink the scroll to its own minimum size). The expand +
	# shrink-center flags keep the column centred while it fits; taller than the card, it scrolls.
	scroll = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	card.add_child(scroll)
	# A right gutter keeps the scrollbar off the fields; the gutter, not the column, is centred while it fits.
	var gutter := MarginContainer.new()
	gutter.mouse_filter = Control.MOUSE_FILTER_PASS
	gutter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gutter.size_flags_vertical = Control.SIZE_EXPAND | Control.SIZE_SHRINK_CENTER
	MenuStyle.pad(gutter, 0.0, 0.0, 1.75, 0.0)
	scroll.add_child(gutter)
	_gutter = gutter
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	MenuStyle.gap(box, 1.5)
	gutter.add_child(box)
	box.add_child(MenuStyle.caption("GAMERTAG"))
	name_edit = LineEdit.new()
	name_edit.placeholder_text = "Gamertag"
	name_edit.text = str(profile["gamertag"])
	box.add_child(name_edit)
	# W0: Play solo is the first and largest button and the screen's one crimson control; Host is a normal button.
	solo_button = _button(box, "Play solo", _on_solo)
	MenuStyle.primary(solo_button)  # before add_icon (picks the Icon twin)
	MenuStyle.add_icon(solo_button, "play")
	# Wraps rather than pinning its title-size text width: on a near-square canvas (the Fold's inner screen, a square
	# browser window) the pinned width would push the card past its share and squeeze the hero column. On 16:9 it
	# stays one line.
	solo_button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	host_button = _button(box, "Host", _on_host, "standard")
	box.add_child(MenuStyle.caption("HOST IP"))
	var join_row := HFlowContainer.new()
	MenuStyle.gap(join_row, 1.5)
	box.add_child(join_row)
	ip_edit = LineEdit.new()
	ip_edit.placeholder_text = "Host IP"
	ip_edit.text = str(profile["last_ip"])
	ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	MenuStyle.min_width(ip_edit, 22.0)
	join_row.add_child(ip_edit)
	join_button = _button(join_row, "Join", _on_join, "enter")
	join_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# W0: in the browser there is no ENet, so Host and Join are disabled with a short note instead of failing.
	lan_note = Label.new()
	lan_note.name = "LanNote"
	lan_note.text = LAN_LATER_NOTE
	lan_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lan_note.theme_type_variation = &"CaptionLabel"
	box.add_child(lan_note)
	apply_lan_availability()
	box.add_child(HSeparator.new())
	settings_button = _button(box, "Settings", open_settings, "gear")
	# A grid, not a flow: a flow wraps 1 / 2 / 1. Two columns when two of the widest fit, else one.
	later_grid = GridContainer.new()
	later_grid.name = "LaterGrid"
	later_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	later_grid.mouse_filter = Control.MOUSE_FILTER_PASS
	MenuStyle.gap(later_grid, 1.5)
	box.add_child(later_grid)
	for entry: String in LATER_ENTRIES:
		var b := _button(later_grid, "%s (later)" % entry, Callable(), "lock")
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.disabled = true
		# Trims instead of pinning its text width: on a near-square canvas the widest entry alone would push the
		# card past its share and squeeze the hero column (the boot screen's logo would then not match).
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		later_buttons.append(b)
	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.theme_type_variation = &"WarnLabel"
	box.add_child(status_label)


## The width the action card is allotted: its CARD_RATIO share of the home row, never its current width (two
## grid columns pin a minimum width, so measuring the grid or the card would feed back into the decision).
func card_share() -> float:
	var home_gap := float(home.get_theme_constant(&"separation"))
	return maxf(home.size.x - home_gap, 0.0) * CARD_RATIO / (HERO_RATIO + CARD_RATIO)


## Picks the later grid's column count from the card's allotted share and the widest button (fonts and gaps
## come from UiScale): 2 columns when two of the widest fit inside the card's content area, else 1.
func _update_later_columns() -> void:
	if later_grid == null or _card == null or _gutter == null:
		return
	var panel := _card.get_theme_stylebox(&"panel")
	var avail := card_share() - float(_gutter.get_theme_constant(&"margin_right"))
	if panel != null:
		avail -= panel.get_margin(SIDE_LEFT) + panel.get_margin(SIDE_RIGHT)
	var widest := 0.0
	for b: Button in later_buttons:
		widest = maxf(widest, natural_width(b))
	var sep := float(later_grid.get_theme_constant(&"h_separation"))
	var cols := 2 if 2.0 * widest + sep <= avail else 1
	if later_grid.columns != cols:
		later_grid.columns = cols


## A button's untrimmed width: its text at its font size plus the current stylebox's content margins (the later
## buttons trim, so their minimum size no longer tells).
static func natural_width(b: Button) -> float:
	var style := b.get_theme_stylebox(&"disabled" if b.disabled else &"normal")
	var w := b.get_theme_font(&"font").get_string_size(b.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			b.get_theme_font_size(&"font_size")).x
	if style != null:
		w += style.get_margin(SIDE_LEFT) + style.get_margin(SIDE_RIGHT)
	return ceilf(w)


## The settings page: own dimmed backdrop, Back header, then the shared panel in a centred column that scrolls.
func _build_settings_page() -> void:
	settings_page = Control.new()
	settings_page.name = "SettingsPage"
	settings_page.set_anchors_preset(Control.PRESET_FULL_RECT)
	settings_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	settings_page.visible = false
	add_child(settings_page)
	settings_page.add_child(MenuBackdrop.make("page"))
	var margin := MenuStyle.safe_margin()
	settings_page.add_child(margin)
	_settings_content = margin
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	MenuStyle.gap(col, 1.5)
	margin.add_child(col)
	var header := MenuStyle.page_header("Settings", close_settings)
	settings_back_button = header["back"]
	col.add_child(header["row"])
	col.add_child(HSeparator.new())
	settings_scroll = ScrollContainer.new()
	settings_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	settings_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	settings_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	col.add_child(settings_scroll)
	# No card: the rows sit straight on the dimmed page backdrop (as the lobby rows do), so they read as rows.
	var list := MarginContainer.new()
	list.name = "List"
	list.mouse_filter = Control.MOUSE_FILTER_PASS  # inside the scroll: a drag from a row must reach settings_scroll
	list.size_flags_horizontal = Control.SIZE_EXPAND | Control.SIZE_SHRINK_CENTER
	MenuStyle.min_width(list, 78.0)
	MenuStyle.pad(list, 0.0, 0.0, 0.0, 2.0)  # a little room under the last row
	settings_scroll.add_child(list)
	settings = _SettingsScene.instantiate()  # shared with the in-match menu
	settings.save = save
	settings.extra_fields = _menu_fields
	list.add_child(settings)


func _button(parent: Node, text: String, handler: Callable, icon: String = "") -> Button:
	var b := Button.new()
	b.text = text
	b.mouse_filter = Control.MOUSE_FILTER_PASS  # STOP would swallow touch drags before the ScrollContainer
	if handler.is_valid():
		b.pressed.connect(handler)
	if not icon.is_empty():
		MenuStyle.add_icon(b, icon)
	parent.add_child(b)
	return b


## Shows the settings page over the home page.
func open_settings() -> void:
	home.hide()
	settings_page.show()
	MenuStyle.fade_in(_settings_content)  # content only: the dimmed backdrop cuts in, so no hero art shows through


## Back to the home page; the settings list starts at the top next time.
func close_settings() -> void:
	settings_page.hide()
	settings_scroll.scroll_vertical = 0
	home.show()
	MenuStyle.fade_in(home)


func toggle_gyro() -> void:
	settings.toggle_gyro()


func _menu_fields() -> Dictionary:
	return {"gamertag": name_edit.text.strip_edges(), "last_ip": ip_edit.text.strip_edges()}


func _save_profile() -> void:
	settings.persist()


## W0: Host and Join enabled only where LAN works (not in the browser); the note shows where it does not.
## Re-run by tests after flipping PlatformServices.simulate_web.
func apply_lan_availability() -> void:
	var lan := PlatformServices.new().can_lan()
	host_button.disabled = not lan
	join_button.disabled = not lan
	ip_edit.editable = lan
	lan_note.visible = not lan


## W0: Play solo. Sets the solo flag and opens the same lobby screen, which goes offline (no ENet peer).
func _on_solo() -> void:
	_save_profile()
	if AppFlow.session != null and is_instance_valid(AppFlow.session):
		AppFlow.end_session()  # a stale LAN session must not carry into solo
	AppFlow.solo = true
	if go_scene.is_valid():
		go_scene.call(AppFlow.LOBBY_SCENE)
	else:
		AppFlow.go(get_tree(), AppFlow.LOBBY_SCENE)


func _on_host() -> void:
	AppFlow.solo = false
	if not PlatformServices.new().can_lan():
		status_label.text = LAN_LATER_NOTE
		return
	_save_profile()
	var session := AppFlow.ensure_session(get_tree())
	var err := session.host_game()
	if err != OK:
		status_label.text = "Could not host (error %d)" % err
		AppFlow.end_session()
		return
	AppFlow.go(get_tree(), AppFlow.LOBBY_SCENE)


func _on_join() -> void:
	AppFlow.solo = false
	if not PlatformServices.new().can_lan():
		status_label.text = LAN_LATER_NOTE
		return
	_save_profile()
	var address := str(AppFlow.profile["last_ip"])
	if address.is_empty():
		status_label.text = "Enter the host IP"
		return
	var session := AppFlow.ensure_session(get_tree())
	session.connected.connect(_on_joined, CONNECT_ONE_SHOT)
	session.failed.connect(_on_join_failed, CONNECT_ONE_SHOT)
	var err := session.join_game(address)
	if err != OK:
		status_label.text = "Could not connect (error %d)" % err
		AppFlow.end_session()
		return
	status_label.text = "Connecting..."


func _on_joined() -> void:
	AppFlow.go(get_tree(), AppFlow.LOBBY_SCENE)


func _on_join_failed() -> void:
	status_label.text = "Connection failed"
	AppFlow.end_session()
