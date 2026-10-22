extends Control
## Boot: applies the default graphics preset and the saved profile, then routes to the main menu.


func _ready() -> void:
	PlatformServices.new().log_display_info()
	GraphicsPresets.new().apply("", get_viewport())
	AppFlow.profile = SaveService.new().load_profile()
	AppFlow.go(get_tree(), AppFlow.MENU_SCENE)
