class_name MainMenu
extends Control
## Main menu: Host, Join (manual IP, OQ-41), gamertag (OQ-39). Later-milestone entries are shown disabled.
## Two pages (docs/UI_STYLE.md 5): HOME (logo left, action card right) and SETTINGS (the shared panel in a
## centred column under a Back header). Both pages sit on the code-drawn backdrop.

const _Theme := preload("res://scenes/ui/menu_theme.tres")
const LATER_ENTRIES: Array[String] = ["Loadout", "Profile", "Shop", "Tutorials"]

const _SettingsScene := preload("res://scenes/ui/settings_panel.tscn")

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
var host_button: Button
var join_button: Button
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


## Left: the logo at the top-left; the space below it shows the backdrop art. Nothing interactive.
func _build_hero(parent: Control) -> void:
	var hero := VBoxContainer.new()
	hero.name = "Hero"
	hero.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hero.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hero.size_flags_stretch_ratio = 1.3
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
	card.size_flags_stretch_ratio = 1.0
	parent.add_child(card)
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
	host_button = _button(box, "Host", _on_host)
	MenuStyle.primary(host_button)  # the screen's one crimson control; before add_icon (picks the Icon twin)
	MenuStyle.add_icon(host_button, "standard")
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
	box.add_child(HSeparator.new())
	settings_button = _button(box, "Settings", open_settings, "gear")
	var later_row := HFlowContainer.new()
	MenuStyle.gap(later_row, 1.5)
	box.add_child(later_row)
	for entry in LATER_ENTRIES:
		var b := _button(later_row, "%s (later)" % entry, Callable(), "lock")
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.disabled = true
		later_buttons.append(b)
	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.theme_type_variation = &"WarnLabel"
	box.add_child(status_label)


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


func _on_host() -> void:
	_save_profile()
	var session := AppFlow.ensure_session(get_tree())
	var err := session.host_game()
	if err != OK:
		status_label.text = "Could not host (error %d)" % err
		AppFlow.end_session()
		return
	AppFlow.go(get_tree(), AppFlow.LOBBY_SCENE)


func _on_join() -> void:
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
