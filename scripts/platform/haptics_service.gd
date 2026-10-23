class_name HapticsService
extends RefCounted
## Haptic feedback by event id. Settings (master switch, per-category toggles, High/Low quality) live in the
## profile under "haptics"; durations and amplitudes live in data/haptics.json (all placeholders, OQ-HAPTICS-VALUES).
## Gameplay never calls Input: it goes through Haptics.play(event) and this service forwards to a HapticsBackend.

const DATA_PATH := "res://data/haptics.json"

var cfg: Dictionary
var backend: HapticsBackend
var enabled: bool = true
var quality: String = "high"
var categories: Dictionary = {}


func _init(config: Dictionary = {}, hw: HapticsBackend = null) -> void:
	cfg = config if not config.is_empty() else DataRegistry.new().load_file(DATA_PATH)
	backend = hw if hw != null else HapticsBackend.new()
	apply_settings(default_settings(cfg))


## data/haptics.json "defaults" as a settings dictionary (enabled, quality, categories).
static func default_settings(config: Dictionary = {}) -> Dictionary:
	var c: Dictionary = config if not config.is_empty() else DataRegistry.new().load_file(DATA_PATH)
	var d: Dictionary = c["defaults"]
	return {"enabled": bool(d["enabled"]), "quality": str(d["quality"]), "categories": (d["categories"] as Dictionary).duplicate()}


## A settings dictionary from a profile or file: unknown quality falls back to the data default, missing or
## non-bool category flags fall back to the data default, unknown categories are dropped.
static func sanitize(value: Variant, config: Dictionary = {}) -> Dictionary:
	var c: Dictionary = config if not config.is_empty() else DataRegistry.new().load_file(DATA_PATH)
	var out := default_settings(c)
	if not (value is Dictionary):
		return out
	var v: Dictionary = value
	if v.get("enabled", null) is bool:
		out["enabled"] = v["enabled"]
	if str(v.get("quality", "")) in (c["qualities"] as Array):
		out["quality"] = str(v["quality"])
	var cats: Variant = v.get("categories", null)
	if cats is Dictionary:
		for cat in out["categories"]:
			if (cats as Dictionary).get(cat, null) is bool:
				out["categories"][cat] = cats[cat]
	return out


func apply_settings(settings: Variant) -> void:
	var s := sanitize(settings, cfg)
	enabled = s["enabled"]
	quality = s["quality"]
	categories = s["categories"]


func to_dict() -> Dictionary:
	return {"enabled": enabled, "quality": quality, "categories": categories.duplicate()}


## True when this device can vibrate. When false the settings screen shows "Not available on this device".
func is_supported() -> bool:
	return backend.is_supported()


## Effective master switch: the stored choice AND device support (unsupported always reads as off).
func is_enabled() -> bool:
	return enabled and is_supported()


func is_category_enabled(category: String) -> bool:
	return bool(categories.get(category, false))


func set_enabled(on: bool) -> void:
	enabled = on


func set_category(category: String, on: bool) -> void:
	if categories.has(category):
		categories[category] = on


func set_quality(q: String) -> void:
	if q in (cfg["qualities"] as Array):
		quality = q


## Plays the event if haptics are effectively on, its category is on and the event is known. Returns whether
## the backend was called.
func play(event_id: String) -> bool:
	if not is_enabled():
		return false
	var events: Dictionary = cfg["events"]
	if not events.has(event_id):
		return false
	var ev: Dictionary = events[event_id]
	if not is_category_enabled(str(ev["category"])):
		return false
	var p: Dictionary = ev[quality]
	backend.vibrate(int(p["duration_ms"]), float(p["amplitude"]))
	return true
