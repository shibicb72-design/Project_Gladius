class_name ClipLibrary
extends RefCounted
## Explicit candidates only. Resolve at tree construction, never per frame.
## M2 AN2 item 2: "blender" = clips baked onto the soldier's own rig in Blender (soldier_clips.glb), first; the UAL
## runtime retarget stays as the fallback behind it.
const ORDER: Array[String] = ["blender", "actionforge", "ual", "mixamo_local"]
static var _clips: Dictionary = {}
static var _reported: Dictionary = {}
static var _held: Dictionary = {}
## Tools and tests only (before/after captures and the foot-slide baseline): sources listed here are passed over.
static var skip_sources: Array[String] = []
var sources: Dictionary
var resolved_sources: Dictionary = {}

func _init(table: Variant = null) -> void:
	sources = DataRegistry.new().load_file("res://data/anim_sources.json") if table == null else table

func resolve(logical: String, procedural: Animation = null, target: Skeleton3D = null) -> Animation:
	var slots: Dictionary = sources.get("clips", {})
	var slot: Dictionary = slots.get(logical, {})
	for source in ORDER:
		if skip_sources.has(source):
			continue
		for candidate: Dictionary in slot.get(source, []):
			var path: String = candidate.get("path", "")
			if path.is_empty() or not ResourceLoader.exists(path):
				_report_once("skip " + source + " " + logical + " " + path)
				continue
			var key := JSON.stringify(candidate)
			if target != null:
				for bone in target.get_bone_count():
					key += String(target.get_bone_name(bone)) + str(target.get_bone_global_rest(bone))
			if not _clips.has(key):
				var resource: Resource = _held.get(path, null)
				if resource == null:
					resource = load(path)
					_held[path] = resource
				var clip: Animation
				if resource is Animation:
					clip = resource
				elif resource is AnimationLibrary:
					var name: StringName = candidate.get("clip", logical)
					if resource.has_animation(name):
						clip = resource.get_animation(name)
				elif resource is PackedScene and target != null:
					var rig: Dictionary = sources.get("rigs", {}).get(String(candidate.get("rig", "")), {})
					clip = _scene_clip(resource, candidate, target, key, rig.get("bones", {}), bool(rig.get("same_rig", false)))
				_clips[key] = clip
			var clip: Animation = _clips[key]
			if clip != null:
				resolved_sources[logical] = source
				return clip
			_report_once("unsupported candidate " + source + " " + logical + " " + path)
	resolved_sources[logical] = "procedural" if procedural != null else "none"
	return procedural

func source_for(logical: String) -> String:
	return resolved_sources.get(logical, "none")

## M2 AN1: drops the held source files (the UAL scene: skeleton and its 43 source clips, no mesh: the import skips
## it). The baked soldier clips stay in _clips, shared by every soldier; a later cache miss loads the file again.
static func release_sources() -> void:
	_held.clear()

## M2 AN1: every shared clip resolved so far (tests: one instance per slot across soldiers).
static func cached_count() -> int:
	return _clips.size()

## A rig row with "same_rig": the source skeleton is the soldier's own (checked: names and rests); its clips are
## copied as authored (AnimRetarget.same_rig_clip). A source that fails the check is retargeted like any other.
static func _scene_clip(scene: PackedScene, candidate: Dictionary, target: Skeleton3D, key: String, source_map: Dictionary = {}, same: bool = false) -> Animation:
	var instance := scene.instantiate()
	var rigs := instance.find_children("*", "Skeleton3D", true, false)
	if instance is Skeleton3D:
		rigs.push_front(instance)
	var players := instance.find_children("*", "AnimationPlayer", true, false)
	if instance is AnimationPlayer:
		players.push_front(instance)
	var result: Animation
	# Ambiguous rigs are not guessed. A later source table must identify the source.
	if rigs.size() == 1:
		var name: StringName = candidate.get("clip", "")
		for player: AnimationPlayer in players:
			if player.has_animation(name) and same and AnimRetarget.same_rig(rigs[0], target):
				result = AnimRetarget.same_rig_clip(player.get_animation(name), rigs[0], target, key)
				break
			if player.has_animation(name):
				result = AnimRetarget.bake(player.get_animation(name), rigs[0], target, key, source_map, bool(candidate.get("root_motion", false)))
				break
		if result != null and candidate.has("loop"):
			result.loop_mode = Animation.LOOP_LINEAR if bool(candidate["loop"]) else Animation.LOOP_NONE
	instance.free()
	return result

static func _report_once(message: String) -> void:
	if not _reported.has(message):
		_reported[message] = true
		print("[clip_library] " + message)

## Clone shared clips before slot-specific timing or additive conversion.
static func fit(clip: Animation, duration: float, loop: Animation.LoopMode, additive: bool = false) -> Animation:
	var result := clip.duplicate_deep() as Animation
	var factor := duration / clip.length if clip.length > 0.0 else 1.0
	for track in result.get_track_count():
		var count := result.track_get_key_count(track)
		if count == 0:
			continue
		if additive:
			if result.track_get_type(track) == Animation.TYPE_ROTATION_3D:
				var first: Quaternion = clip.rotation_track_interpolate(track, 0.0)
				for key in count:
					var value: Quaternion = result.track_get_key_value(track, key)
					result.track_set_key_value(track, key, value * first.inverse())
			elif result.track_get_type(track) == Animation.TYPE_POSITION_3D:
				var first: Vector3 = clip.position_track_interpolate(track, 0.0)
				for key in count:
					var value: Vector3 = result.track_get_key_value(track, key)
					result.track_set_key_value(track, key, value - first)
		var keys := range(count - 1, -1, -1) if factor >= 1.0 else range(count)
		for key in keys:
			result.track_set_key_time(track, key, clip.track_get_key_time(track, key) * factor)
	result.length = duration
	result.loop_mode = loop
	return result
