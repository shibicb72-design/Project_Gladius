class_name MatchRoot
extends Node3D
## Offline match scene glue: loads the map from data, wires the director, the local player
## and a debug label (the real HUD is S10).

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
var _remaining_s: float = 0.0

@onready var director: MatchDirector = $Director
@onready var _label: Label = $Hud/DebugLabel
@onready var _touch_hud: Control = $Hud/TouchHud


func _ready() -> void:
	router = InputRouter.new()
	add_child(router)
	router.add_provider(KeyboardMouseProvider.new())
	router.add_provider(GamepadProvider.new())
	if _touch_hud != null and "provider" in _touch_hud:
		router.add_provider(_touch_hud.provider)
	director.score_changed.connect(_on_score_changed)
	director.time_changed.connect(_on_time_changed)
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

	local_player = _PawnScene.instantiate()
	local_player.class_id = "hastati"
	local_player.squad_id = 0
	add_child(local_player)
	var rig := _RigScene.instantiate()
	rig.name = "CameraRig"
	local_player.add_child(rig)
	director.add_player(0, local_player)
	if fill_bots:
		# Host-only: the local player is the only human in squad 0.
		bots = BotSpawner.spawn_bots(self, director, {0: 1}, center, float(hill.get("radius_m", 8.0)))

	var squads: Array = range(int(director.match_cfg.get("offline_squads", 2)))
	return director.start(squads, xforms, zone, randi())


func _physics_process(_delta: float) -> void:
	if local_player != null and router != null:
		local_player.set_frame(router.get_frame())


static func _vec(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func _on_score_changed(_scores: Dictionary) -> void:
	_refresh_label()


func _on_time_changed(remaining_s: float) -> void:
	_remaining_s = remaining_s
	_refresh_label()


func _on_match_over(result: Dictionary) -> void:
	_label.text = "MATCH OVER  winner: %s  draw: %s" % [result["winner"], result["draw"]]


func _refresh_label() -> void:
	if not director.running or director.rules == null:
		return
	var parts: Array[String] = []
	for squad in director.rules.scores:
		parts.append("Squad %s: %d" % [squad, int(director.rules.scores[squad])])
	var t := int(_remaining_s)
	_label.text = "%s   %d:%02d" % ["  ".join(parts), t / 60, t % 60]
