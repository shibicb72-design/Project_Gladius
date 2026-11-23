extends SceneTree
## With the W1b test tools present, run on the untouched shader base:
## godot --headless --path . --script res://tests/record_w1b_mobile_shader_text.gd

const ShaderText := preload("res://tests/w1b_mobile_shader_text.gd")


func _initialize() -> void:
	var snapshot := ShaderText.snapshot()
	if snapshot.size() != 13:
		push_error("Expected the 13 W1b base shaders")
		quit(1)
		return
	var fixture := FileAccess.open(ShaderText.FIXTURE, FileAccess.WRITE)
	if fixture == null:
		push_error("Could not write the W1b Mobile shader fixture")
		quit(1)
		return
	fixture.store_string(JSON.stringify(snapshot, "\t") + "\n")
	print("Recorded %d Mobile shader sources" % snapshot.size())
	quit(0)
