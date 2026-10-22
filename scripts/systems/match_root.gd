class_name MatchRoot
extends Node3D
## Offline match scene glue: loads the map from data, wires the director, the local player
## and a debug label (the real HUD is S10).

const END_SCREEN_DELAY_S := 3.0  # presentation pause, not a design value
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

var _client_bridge: NetMatchBridge
var _input_accum_s: float = 0.0
var _spawn_synced: bool = false

@onready var director: MatchDirector = $Director
@onready var hud: GameHud = $Hud/GameHud
@onready var _touch_hud: Control = $Hud/TouchHud


func _ready() -> void:
	router = InputRouter.new()
	add_child(router)
	router.add_provider(KeyboardMouseProvider.new())
	router.add_provider(GamepadProvider.new())
	if _touch_hud != null and "provider" in _touch_hud:
		router.add_provider(_touch_hud.provider)
	director.match_over.connect(_on_match_over)
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
	else:
		# Offline / standalone: the local player is the only human in squad 0.
		local_player = _PawnScene.instantiate()
		local_player.class_id = "hastati"
		local_player.squad_id = 0
		add_child(local_player)
		director.add_player(0, local_player)
		if fill_bots:
			bots = BotSpawner.spawn_bots(self, director, {0: 1}, center, radius)
	if local_player != null:
		hud.bind(director, local_player)
		var rig := _RigScene.instantiate()
		rig.name = "CameraRig"
		local_player.add_child(rig)
	var seed_value := seed_override if seed_override != 0 else AppFlow.match_seed
	if seed_value == 0:
		seed_value = randi()
	return director.start(squads, xforms, zone, seed_value)


func _exit_tree() -> void:
	if roster != null:
		roster.detach_bridge()


func _physics_process(delta: float) -> void:
	if local_player == null or router == null:
		return
	var frame := router.get_frame()
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
		local_player.shot.connect(bridge.send_fire)
		local_player.reload_started.connect(bridge.send_reload)
		local_player.weapon_switched.connect(bridge.send_weapon_slot)
	bridge.snapshot_received.connect(_on_snapshot)
	bridge.respawn_event.connect(_on_local_respawn_event)


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


## Started from the menu flow: show the end screen after a short pause. Standalone runs stay put.
func _on_match_over(result: Dictionary) -> void:
	AppFlow.last_result = result
	if AppFlow.lobby != null and lobby_override == null and is_inside_tree():
		await get_tree().create_timer(END_SCREEN_DELAY_S).timeout
		if is_inside_tree():
			AppFlow.go(get_tree(), AppFlow.END_SCENE)
