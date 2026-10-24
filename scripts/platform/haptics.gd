class_name Haptics
extends RefCounted
## Static entry point for gameplay: Haptics.play("weapon_fire"). Holds the shared HapticsService, built lazily
## from the profile. Tests replace `service` with one that has a fake backend.

static var service: HapticsService


static func get_service() -> HapticsService:
	if service == null:
		service = HapticsService.new()
		service.apply_settings(_profile().get("haptics", null))
	return service


static func play(event_id: String) -> bool:
	return get_service().play(event_id)


## Re-reads the saved settings (after the settings screen or a profile change).
static func reload_from_profile() -> void:
	get_service().apply_settings(_profile().get("haptics", null))


static func _profile() -> Dictionary:
	return AppFlow.profile if not AppFlow.profile.is_empty() else SaveService.new().load_profile()
