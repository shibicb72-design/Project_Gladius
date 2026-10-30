class_name InputRouter
extends Node
## Merges all providers into one InputFrame per physics tick. Later an autoload.

var providers: Array[InputProvider] = []
var _frame: InputFrame = InputFrame.new()
var _prev_pressed: Dictionary = {}
## ADS pure tap toggle (data/stats.json aim.aim_toggle_enabled, default on; false = hold-to-aim). OQ-AIM.
var aim_toggle: AimToggle = AimToggle.new()
var _aim_toggle_configured: bool = false


const _LookMath := preload("res://scripts/input/look_math.gd")

## The player's sensitivity tables (G2d); match_root replaces it with the profile's.
var sens := SensitivitySettings.new()
## Look state comes from the active weapon's optional scope field while aiming (default "no_scope").
## aim_state is a data/input.json sensitivity_tables.states key; ads is true while pawn aim_blend > 0.
var aim_state: String = "no_scope"
var ads: bool = false
## Free Look row (tpp_character or fpp_character), "" while there is no free look in the game.
var free_look_row: String = ""


## Picks the table row for the current scope. Unknown states fall back to no_scope.
func set_aim_state(state: String) -> void:
	aim_state = state if sens.row_for_state(state) != "" else "no_scope"


## Aiming (aim_blend > 0) selects the ADS tables. Leaving ADS puts the state back to no_scope.
func set_ads(active: bool) -> void:
	ads = active
	if not active:
		aim_state = "no_scope"


func set_free_look_row(row: String) -> void:
	free_look_row = row if sens.rows_of(SensitivitySettings.FREE_LOOK).has(row) else ""


## Percent of the table entry that scales this provider's look right now.
func look_percent(source: String) -> float:
	var row := sens.row_for_state(aim_state)
	if source == "gyro":
		return sens.percent("ads_gyro" if ads else "gyro", row)
	var pct := sens.percent("ads" if ads else "camera", row)
	if free_look_row != "":
		pct *= sens.multiplier(SensitivitySettings.FREE_LOOK, free_look_row)
	return pct


func _scaled_look(p: InputProvider) -> Vector2:
	var v := p.get_look()
	if p.look_source == "gyro":
		if sens.gyro_invert_x:
			v.x = -v.x
		if sens.gyro_invert_y:
			v.y = -v.y
	return _LookMath.apply_percent(v, look_percent(p.look_source))


func add_provider(p: InputProvider) -> void:
	providers.append(p)


func remove_provider(p: InputProvider) -> void:
	providers.erase(p)


func get_frame() -> InputFrame:
	return _frame


## Rebuilds the frame from the providers. Called every physics tick; callable directly in tests.
func update_frame(delta: float = 1.0 / float(Engine.physics_ticks_per_second)) -> InputFrame:
	_ensure_aim_toggle()
	var f := InputFrame.new()
	for p in providers:
		p.tick(delta)
		p.set_look_context(ads, sens.row_for_state(aim_state))
		f.move += p.get_move()
		f.sprint = f.sprint or p.is_sprinting()
		f.look += _scaled_look(p)
	if f.move.length() > 1.0:
		f.move = f.move.normalized()
	for action in InputFrame.BUTTONS + InputFrame.LOCAL_BUTTONS:
		var down := false
		for p in providers:
			if p.is_pressed(action):
				down = true
				break
		f.set_button(action, down, down and not _prev_pressed.get(action, false))
		_prev_pressed[action] = down
	# The Aim tap toggle remaps aim_pressed to the latched ADS state (aim_just_pressed stays the raw edge).
	f.aim_pressed = aim_toggle.resolve(f.aim_pressed)
	_frame = f
	return f


func _ensure_aim_toggle() -> void:
	if _aim_toggle_configured:
		return
	aim_toggle.configure(DataRegistry.new().get_aim_cfg())
	_aim_toggle_configured = true


func _physics_process(delta: float) -> void:
	update_frame(delta)


func _input(event: InputEvent) -> void:
	for p in providers:
		p.handle_event(event)
