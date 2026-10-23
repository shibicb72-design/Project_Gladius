class_name MatchRoot
extends Node3D
## Offline match scene glue: loads the map from data, wires the director, the local player
## and a debug label (the real HUD is S10).

const UI_PATH := "res://data/ui.json"
const MAP_PATH := "res://data/maps/alesia_section.json"
const _PawnScene := preload("res://scenes/player/pawn.tscn")
const _RigScene := preload("res://scenes/player/camera_rig.tscn")

## Tests turn this off to override director config before calling begin().
@export var auto_start: bool = true
@export var bake_navmesh: bool = true
## Fill empty squad slots with bots (data/bots.json match_fill). Existing tests turn it off.
@export var fill_bots: bool = true

var map_def: Dictionary = {}
var map: Node3D
var router: InputRouter
var local_player: Pawn
var bots: Array[Pawn] = []
var zone: HillZone
var roster: MatchRoster
## Tests running two peers in one process inject these instead of the AppFlow globals.
var session_override: NetSession
var lobby_override: LobbyState
var seed_override: int = 0
## Set when the host connection was lost during the match (tests read it; the real flow leaves the scene).
var host_lost_handled: bool = false
## Test hook: when valid, a host drop calls go_scene.call(menu_scene_path) instead of the AppFlow change.
var go_scene: Callable

var _client_bridge: NetMatchBridge
var _input_accum_s: float = 0.0
var _spawn_synced: bool = false

@onready var director: MatchDirector = $Director
@onready var hud: GameHud = $Hud/GameHud
@onready var _touch_hud: Control = $Hud/TouchHud
@onready var pause_menu: PauseMenu = $Hud/PauseMenu

## True while the in-match menu is open: the local pawn then gets a zero InputFrame. Offline the tree is
## also paused; online the simulation and networking keep running (you can be shot in the menu).
var menu_open: bool = false
var networked_match: bool = false


func _ready() -> void:
	router = InputRouter.new()
	add_child(router)
	router.add_provider(KeyboardMouseProvider.new())
	var gamepad := GamepadProvider.new()
	gamepad.configure(DataRegistry.new().load_file("res://data/input.json"))
	router.add_provider(gamepad)
	var gyro := GyroProvider.new()
	var profile: Dictionary = AppFlow.profile if not AppFlow.profile.is_empty() else SaveService.new().load_profile()
	var gyro_cfg: Dictionary = DataRegistry.new().load_file("res://data/input.json").get("gyro", {})
	gyro.configure({"gyro_mode": SaveService.gyro_mode(profile), "sensitivity": gyro_cfg.get("sensitivity", 1.0)})
	router.add_provider(gyro)
	if _touch_hud != null and "provider" in _touch_hud:
		router.add_provider(_touch_hud.provider)
	director.match_over.connect(_on_match_over)
	pause_menu.opened.connect(_on_menu_opened)
	pause_menu.closed.connect(_on_menu_closed)
	pause_menu.quit_confirmed.connect(quit_to_menu)
	if auto_start:
		begin()


## Loads the map and starts the match. Returns false if the data is unusable.
func begin() -> bool:
	if director.mode_cfg.is_empty():
		director.load_config()
	map_def = DataRegistry.new().load_file(MAP_PATH)
	var scene: PackedScene = load(str(map_def.get("scene", ""))) as PackedScene
	if scene == null:
		return false
	map = scene.instantiate()
	add_child(map)
	var nav := map.get_node_or_null("Nav") as NavigationRegion3D
	if bake_navmesh and nav != null:
		nav.bake_navigation_mesh(false)

	var hill: Dictionary = map_def.get("hill", {})
	var center := _vec(hill.get("center", [0, 0, 0]))
	zone = HillZone.new()
	add_child(zone)
	zone.configure(center, float(hill.get("radius_m", 8.0)), float(hill.get("height_m", 3.0)))

	var xforms: Dictionary = {}
	var spawns: Dictionary = map_def.get("spawns", {})
	for spot_id in spawns:
		var pos := _vec(spawns[spot_id])
		var to_hill := center - pos
		to_hill.y = 0.0
		xforms[spot_id] = Transform3D(Basis.looking_at(to_hill.normalized()), pos)

	var radius := float(hill.get("radius_m", 8.0))
	var squads: Array = range(int(director.match_cfg.get("squads", 2)))
	var session := session_override
	if session == null and AppFlow.session != null and is_instance_valid(AppFlow.session):
		session = AppFlow.session
	var lobby := lobby_override if lobby_override != null else AppFlow.lobby
	var local_peer := session.get_unique_id() if session != null else 0
	var networked := local_peer != 0
	networked_match = networked
	director.authoritative = not networked or session.is_host
	if lobby != null:
		var slots := lobby.assign()
		squads = range(lobby.squad_count)
		roster = MatchRoster.new()
		roster.build(self, director, slots, local_peer, director.authoritative, fill_bots, center, radius,
				networked)
		local_player = roster.local_pawn
		bots = roster.bots
		if networked:
			roster.attach_bridge(session, slots)
			if not session.is_host:
				_wire_client(roster.bridge)
				session.host_lost.connect(_on_host_lost)
			else:
				# The host's own pawn shoots locally; clients learn about it from the host.
				var host_bridge: NetMatchBridge = roster.bridge
				local_player.shot_resolved.connect(func(o: Vector3, e: Vector3, _h: Dictionary) -> void:
						host_bridge.announce_pawn_shot(local_player, o, e))
				wire_bot_shots(host_bridge, bots)
	else:
		# Offline / standalone: the local player is the only human in squad 0.
		local_player = _PawnScene.instantiate()
		local_player.class_id = offline_class_id(DataRegistry.new(), profile_cfg())
		local_player.squad_id = 0
		add_child(local_player)
		director.add_player(0, local_player)
		if fill_bots:
			bots = BotSpawner.spawn_bots(self, director, {0: 1}, squads.size(), center, radius)
	if local_player != null:
		hud.bind(director, local_player)
		var rig := _RigScene.instantiate()
		rig.name = "CameraRig"
		local_player.add_child(rig)
	var seed_value := seed_override if seed_override != 0 else AppFlow.match_seed
	if seed_value == 0:
		seed_value = randi()
	return director.start(squads, xforms, zone, seed_value)


## Class for the offline / no-lobby player: data/match.json default_class, else the profile's
## last_class, else the first enabled class in stats.json. Only enabled classes qualify.
static func offline_class_id(registry: DataRegistry, profile: Dictionary) -> String:
	var wanted: Array[String] = [str(registry.load_file(DataRegistry.MATCH_PATH).get("default_class", "")),
			str(profile.get("last_class", ""))]
	for cid in wanted:
		var def := registry.get_class_def(cid) if cid != "" else null
		if def != null and def.enabled:
			return cid
	var classes: Dictionary = registry.load_file(DataRegistry.STATS_PATH).get("classes", {})
	for cid in classes:
		if bool(classes[cid].get("enabled", false)):
			return str(cid)
	return ""


func profile_cfg() -> Dictionary:
	return AppFlow.profile if not AppFlow.profile.is_empty() else SaveService.new().load_profile()


func _exit_tree() -> void:
	if roster != null:
		roster.detach_bridge()
	if menu_open and not networked_match and is_inside_tree():
		get_tree().paused = false


func _on_menu_opened() -> void:
	menu_open = true
	_touch_hud.set_suspended(true)
	if not networked_match:
		get_tree().paused = true


func _on_menu_closed() -> void:
	menu_open = false
	_touch_hud.set_suspended(false)
	get_tree().paused = false


## Quit confirmed in the menu: leave the match for the main menu (same exit as a lost host).
func quit_to_menu() -> void:
	if menu_open:
		pause_menu.close()
	get_tree().paused = false
	if go_scene.is_valid():
		go_scene.call(AppFlow.MENU_SCENE)
		return
	if session_override == null and lobby_override == null:
		AppFlow.end_session()
		AppFlow.go(get_tree(), AppFlow.MENU_SCENE)


func _physics_process(delta: float) -> void:
	if local_player == null or router == null:
		return
	var frame := InputFrame.new()  # zero frame while the menu is open: no move, look, fire, jump or sprint
	if not menu_open:
		frame = router.get_frame()
		var rig := local_player.get_node_or_null("CameraRig") as CameraRig
		if rig != null:
			frame.aim_point = rig.get_aim_point(local_player.hitscan_exclude())
			frame.has_aim_point = true
	local_player.set_frame(frame)
	if _client_bridge != null and director.running:
		_input_accum_s += delta
		if _input_accum_s >= _client_bridge.input_interval_s:
			_input_accum_s = 0.0
			_client_bridge.send_input(frame, local_player.global_position, local_player.rotation.y)


## Client only: input and fire go to the host; the host's snapshots and events come back.
func _wire_client(bridge: NetMatchBridge) -> void:
	_client_bridge = bridge
	if local_player != null:
		local_player.shot.connect(func(o: Vector3, d: Vector3, wid: String) -> void:
				bridge.send_fire(o, d, wid, local_player.aiming))
		bridge.shot_event.connect(_on_remote_shot)
		local_player.reload_started.connect(bridge.send_reload)
		local_player.weapon_switched.connect(bridge.send_weapon_slot)
	bridge.snapshot_received.connect(_on_snapshot)
	bridge.respawn_event.connect(_on_local_respawn_event)


## Host: reports every bot pawn's shot to the clients, the same way as the host player's own.
static func wire_bot_shots(host_bridge: NetMatchBridge, bot_pawns: Array) -> void:
	for bot in bot_pawns:
		var b: Pawn = bot
		b.shot_resolved.connect(func(o: Vector3, e: Vector3, _h: Dictionary) -> void:
				host_bridge.announce_pawn_shot(b, o, e))


## Client: draws another player's shot from the host's report (the local pawn drew its own at once).
func _on_remote_shot(player_id: int, origin: Vector3, end: Vector3) -> void:
	var p: Pawn = director.player(player_id)
	if p != null and p != local_player:
		p.show_shot_fx(origin, end)


func _on_snapshot() -> void:
	var id := roster.local_player_id
	if not _spawn_synced and _client_bridge.replica.has(id):
		_spawn_synced = true
		_client_bridge.snap_local_to_replica(id)
	_client_bridge.apply_replica(id)
	_client_bridge.apply_local_vitals(id)


func _on_local_respawn_event(player_id: int) -> void:
	if player_id == roster.local_player_id:
		_client_bridge.snap_local_to_replica(player_id)


static func _vec(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


## OQ-27 placeholder: no 60 s reconnect pause yet; a host drop sends every client back to the menu.
func _on_host_lost() -> void:
	host_lost_handled = true
	if go_scene.is_valid():
		go_scene.call(AppFlow.MENU_SCENE)
		return
	if is_inside_tree() and session_override == null and lobby_override == null:
		AppFlow.end_session()
		AppFlow.go(get_tree(), AppFlow.MENU_SCENE)


## Started from the menu flow: show the end screen after a short pause. Standalone runs stay put.
func _on_match_over(result: Dictionary) -> void:
	AppFlow.last_result = result
	if AppFlow.lobby != null and lobby_override == null and is_inside_tree():
		var delay_s := float(DataRegistry.new().load_file(UI_PATH).get("end_screen_delay_s", 3.0))
		await get_tree().create_timer(delay_s).timeout
		if is_inside_tree():
			AppFlow.go(get_tree(), AppFlow.END_SCENE)
