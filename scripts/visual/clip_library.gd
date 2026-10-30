class_name ClipLibrary
extends RefCounted
## Explicit candidates only. Resolve at tree construction, never per frame.
const ORDER: Array[String] = ["actionforge", "ual", "mixamo_local"]
static var _clips: Dictionary = {}
static var _reported: Dictionary = {}
var sources: Dictionary
var resolved_sources: Dictionary = {}

func _init(table: Variant = null) -> void:
	sources = DataRegistry.new().load_file("res://data/anim_sources.json") if table == null else table

func resolve(logical: String, procedural: Animation = null, target: Skeleton3D = null) -> Animation:
	var slots: Dictionary = sources.get("clips", {})
	var slot: Dictionary = slots.get(logical, {})
	for source in ORDER:
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
				var resource := load(path)
				var clip: Animation
				if resource is Animation:
					clip = resource
				elif resource is AnimationLibrary:
					var name: StringName = candidate.get("clip", logical)
					if resource.has_animation(name):
						clip = resource.get_animation(name)
				elif resource is PackedScene and target != null:
					clip = _scene_clip(resource, candidate, target, key)
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

static func _scene_clip(scene: PackedScene, candidate: Dictionary, target: Skeleton3D, key: String) -> Animation:
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
			if player.has_animation(name):
				result = AnimRetarget.bake(player.get_animation(name), rigs[0], target, key)
				break
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
