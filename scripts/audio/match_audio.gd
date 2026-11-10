class_name MatchAudio
extends Node3D
## S5: the match-wide sounds. A child of the match's WorldEnvironment (GreyboxArt adds it) that listens to the
## MatchDirector's signals and reads its public state: match start and end horns, the zone (the horn when it
## starts to close, the wall's hum at the nearest point of the circle, the burn while outside), the carrier,
## revives, eliminations, loot pickups (the loot field's item nodes leaving the tree), ambience by look variant,
## thunder after lightning, braziers and banners. It writes nothing to gameplay. Data: data/audio.json.

var director: MatchDirector
var hooks: Dictionary = {}
var ambience: Dictionary = {}
var _ambient_loops: Array[Node] = []
var _zone_loop: AudioStreamPlayer3D
var _burn_loop: AudioStreamPlayer
var _carrier_loop: AudioStreamPlayer3D
var _revive_loops := {}  # reviver player id -> AudioStreamPlayer3D
var _was_running := false
var _zone_state := ""
var _loot: Node
var _thunder_in := -1.0
var _banner_in := 3.0
var _fires_bound := false
var _rng := RandomNumberGenerator.new()


func _sfx() -> Node:
	return get_node_or_null("/root/Sfx")


func _match() -> Node:
	return get_parent().get_parent() if get_parent() != null else null


func _ready() -> void:
	var sfx := _sfx()
	if sfx == null:
		set_process(false)
		return
	hooks = sfx.cfg["hooks"]
	ambience = sfx.cfg["ambience"]
	_rng.seed = 11
	var root := _match()
	director = root.get_node_or_null("Director") as MatchDirector if root != null else null
	if director != null:
		director.player_revived.connect(_on_player_revived)
		director.player_eliminated.connect(_on_player_eliminated)
		director.match_over.connect(_on_match_over)


## Called by MatchLook when a variant is shown: the ambience bed follows the look.
func show_look(look: Dictionary, match_look: MatchLook) -> void:
	var sfx := _sfx()
	if sfx == null:
		return
	for loop in _ambient_loops:
		if is_instance_valid(loop):
			loop.queue_free()
	_ambient_loops.clear()
	var ids: Array[String] = [String(ambience["base_loop"])]
	var by_weather: Dictionary = ambience["by_weather"]
	var by_variant: Dictionary = ambience["by_variant"]
	if by_weather.has(look.get("weather", "")):
		ids.append(String(by_weather[look["weather"]]))
	if by_variant.has(look.get("id", "")):
		ids.append(String(by_variant[look["id"]]))
	for id in ids:
		var loop: Node = sfx.make_loop(id, self, false)
		if loop != null:
			_ambient_loops.append(loop)
	if match_look != null and not match_look.lightning_struck.is_connected(_on_lightning):
		match_look.lightning_struck.connect(_on_lightning)


func _on_lightning() -> void:
	var delay: Array = ambience["thunder_delay_s"]
	_thunder_in = _rng.randf_range(float(delay[0]), float(delay[1]))


func _pawn_at(player_id: int) -> Vector3:
	var pawn := director.player(player_id) if director != null else null
	return pawn.global_position + Vector3.UP if pawn != null else Vector3.ZERO


func _is_local(player_id: int) -> bool:
	var pawn := director.player(player_id) if director != null else null
	return pawn != null and pawn.get_node_or_null("CameraRig") != null


func _on_player_revived(player_id: int) -> void:
	_sfx().play_at(String(hooks["revived"]), _pawn_at(player_id))


func _on_player_eliminated(player_id: int, killer_id: int, _cause: String) -> void:
	var sfx := _sfx()
	sfx.play_at(String(hooks["eliminated"]), _pawn_at(player_id))
	if killer_id != player_id and _is_local(killer_id):
		sfx.play_ui(String(hooks["local_kill"]))


func _on_match_over(_result: Dictionary) -> void:
	_sfx().play_ui(String(hooks["match_over"]))


func _on_loot_node_exiting(node: Node) -> void:
	# A loot item's node leaves the tree when it is taken (LootField.take frees it). Its name is "Loot_<item id>".
	var sfx := _sfx()
	if sfx == null or _loot == null or not (node is Node3D) or not director.running:
		return
	# Only a real pickup: LootField.take queue_frees the item's own node. Leaving the match takes every node out
	# without marking it, both through AppFlow.go (change_scene: remove, then free) and through queue_free of the match.
	if not node.is_queued_for_deletion() or _loot.is_queued_for_deletion():
		return
	# Godot renames a second sibling of the same name ("@Loot_ammo@3"): take the longest item id the name holds.
	var best := ""
	var items: Dictionary = _loot.cfg.get("items", {})
	for id: String in items:
		if String(node.name).contains("Loot_" + id) and id.length() > best.length():
			best = id
	var kind := String(items[best].get("kind", "")) if best != "" else ""
	var by_kind: Dictionary = hooks["pickup_by_kind"]
	if by_kind.has(kind):
		sfx.play_at(String(by_kind[kind]), (node as Node3D).global_position)


func _set_loop(current: Node, wanted: bool, hook: String, positional: bool) -> Node:
	if wanted and current == null:
		return _sfx().make_loop(String(hooks[hook]), self, positional)
	if not wanted and current != null:
		current.queue_free()
		return null
	return current


func _process(delta: float) -> void:
	var sfx := _sfx()
	if sfx == null or director == null:
		return
	var root := _match()
	if director.running and not _was_running:
		sfx.play_ui(String(hooks["match_started"]))
		sfx.announce("match_start")
	_was_running = director.running
	var listener: Vector3 = sfx._listener_position()
	# Loot pickups: bind once to the loot field's child list.
	if _loot == null and root != null and root.get("loot") != null:
		_loot = root.loot
		_loot.child_exiting_tree.connect(_on_loot_node_exiting)
	# Braziers: one fire loop each, once the map exists.
	if not _fires_bound and root != null and root.get("map") != null:
		_fires_bound = true
		var ambient := (root.map as Node).get_node_or_null("ArtBuilder/Ambient")
		if ambient != null:
			for light: Node in ambient.get("lights"):
				sfx.make_loop(String(ambience["brazier_loop"]), light.get_parent(), true)
	# The zone.
	var rules: BrRules = director.rules
	var zone_live := rules != null and director.running
	if zone_live:
		var state := rules.zone_state()
		if state != _zone_state:
			if state == "shrinking":
				sfx.play_ui(String(hooks["zone_shrinking"]))
				sfx.announce("zone_closing")
			_zone_state = state
	_zone_loop = _set_loop(_zone_loop, zone_live, "zone_wall_loop", true) as AudioStreamPlayer3D
	var outside := false
	if zone_live:
		var centre := Vector3(rules.zone_center().x, listener.y, rules.zone_center().y)
		var out := listener - centre
		out.y = 0.0
		if out.length() < 0.01:
			out = Vector3.FORWARD
		if _zone_loop != null:
			_zone_loop.global_position = centre + out.normalized() * rules.zone_radius()
		var local := root.get("local_player") as Pawn if root != null else null
		if local != null and local.is_alive() and local.drop_state == Pawn.Drop.NONE:
			outside = rules.is_outside(Vector2(local.global_position.x, local.global_position.z))
	_burn_loop = _set_loop(_burn_loop, outside, "zone_outside_loop", false) as AudioStreamPlayer
	# The carrier.
	_carrier_loop = _set_loop(_carrier_loop, director.drop_active, "carrier_loop", true) as AudioStreamPlayer3D
	if _carrier_loop != null:
		_carrier_loop.global_position = director.carrier_position()
	# Revives in progress: a loop on each reviver.
	var players := director.all_players()
	for id: int in players:
		var reviving := director.running and director.is_reviving(id)
		var loop: Node = _revive_loops.get(id)
		if reviving and loop == null:
			_revive_loops[id] = sfx.make_loop(String(hooks["reviving_loop"]), players[id], true)
		elif not reviving and loop != null:
			if is_instance_valid(loop):
				loop.queue_free()
			_revive_loops.erase(id)
	# Thunder follows lightning; banners snap near the listener now and then.
	if _thunder_in >= 0.0:
		_thunder_in -= delta
		if _thunder_in < 0.0:
			var list: Array = ambience["thunder"]
			sfx.play_ui(String(list[_rng.randi() % list.size()]))
	_banner_in -= delta
	if _banner_in <= 0.0:
		var every: Array = ambience["banner_every_s"]
		_banner_in = _rng.randf_range(float(every[0]), float(every[1]))
		var ambient := (root.map as Node).get_node_or_null("ArtBuilder/Ambient") if root != null and root.get("map") != null else null
		if ambient != null:
			var best := Vector3.ZERO
			var best_d := float(ambience["banner_within_m"])
			for child in ambient.get_children():
				if String(child.name).begins_with("Banner") and (child as Node3D).global_position.distance_to(listener) < best_d:
					best_d = (child as Node3D).global_position.distance_to(listener)
					best = (child as Node3D).global_position + Vector3.UP * 2.5
			if best != Vector3.ZERO:
				sfx.play_at(String(ambience["banner"]), best)
