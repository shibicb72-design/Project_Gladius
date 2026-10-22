class_name InputRouter
extends Node
## Merges all providers into one InputFrame per physics tick. Later an autoload.

var providers: Array[InputProvider] = []
var _frame: InputFrame = InputFrame.new()
var _prev_pressed: Dictionary = {}


func add_provider(p: InputProvider) -> void:
	providers.append(p)


func remove_provider(p: InputProvider) -> void:
	providers.erase(p)


func get_frame() -> InputFrame:
	return _frame


## Rebuilds the frame from the providers. Called every physics tick; callable directly in tests.
func update_frame() -> InputFrame:
	var f := InputFrame.new()
	for p in providers:
		f.move += p.get_move()
		f.look += p.get_look()
	if f.move.length() > 1.0:
		f.move = f.move.normalized()
	for action in InputFrame.BUTTONS:
		var down := false
		for p in providers:
			if p.is_pressed(action):
				down = true
				break
		f.set_button(action, down, down and not _prev_pressed.get(action, false))
		_prev_pressed[action] = down
	_frame = f
	return f


func _physics_process(_delta: float) -> void:
	update_frame()


func _input(event: InputEvent) -> void:
	for p in providers:
		p.handle_event(event)
