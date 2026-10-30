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

func resolve(logical: String, procedural: Animation = null) -> Animation:
	var slots: Dictionary = sources.get("clips", {})
	var slot: Dictionary = slots.get(logical, {})
	for source in ORDER:
		for candidate: Dictionary in slot.get(source, []):
			var path: String = candidate.get("path", "")
			if path.is_empty() or not ResourceLoader.exists(path):
				_report_once("skip " + source + " " + logical + " " + path)
				continue
			var key := JSON.stringify(candidate)
			if not _clips.has(key):
				var resource := load(path)
				var clip: Animation
				if resource is Animation:
					clip = resource
				elif resource is AnimationLibrary:
					var name: StringName = candidate.get("clip", logical)
					if resource.has_animation(name):
						clip = resource.get_animation(name)
				# Imported scenes require the L2 skeleton-aware bake before use.
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

static func _report_once(message: String) -> void:
	if not _reported.has(message):
		_reported[message] = true
		print("[clip_library] " + message)
