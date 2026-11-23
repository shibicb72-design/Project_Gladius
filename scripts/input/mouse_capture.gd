class_name MouseCapture
extends RefCounted
## W0 (PC browser, keyboard and mouse): the mouse capture state machine. Owned and driven by PauseMenu (which runs
## with PROCESS_MODE_ALWAYS, so it works while the tree is paused) on devices without a touchscreen only.
##
## States: FREE (cursor visible, the match is running; the next click in the match asks for capture), CAPTURED (the
## pointer is locked; mouse look reads it), MENU (the pause menu is open; the cursor is visible).
## - FREE + click            -> ask for capture. Becomes CAPTURED only once the mode reads captured (a browser grants
##                              pointer lock asynchronously, or refuses it: then it stays FREE and the next click asks
##                              again, so a refused request is never a stuck state).
## - CAPTURED + Esc          -> release the mouse and open the menu (desktop: the key event arrives).
## - CAPTURED + capture lost -> open the menu (the browser eats the Esc keydown that ends pointer lock, so the only
##                              sign is the mode changing away from captured with no key event; tab switch too).
## - any + menu opened       -> MENU (the gear, or the two lines above); the mouse is released.
## - MENU + menu closed      -> FREE. Never recaptures by itself: the NEXT click does (Chrome refuses an immediate
##                              re-lock after Esc, and a lock outside a click is refused anyway).
##
## Mouse mode seam (binding fix 13): every read and write of the mouse mode goes through get_mode / set_mode, which
## default to Input.mouse_mode. Headless Godot ignores mouse mode changes, so tests replace both with a fake.

signal pause_requested

enum State { FREE, CAPTURED, MENU }

var state: State = State.FREE
## () -> int (an Input.MouseMode). Default: the real Input.mouse_mode.
var get_mode: Callable = func() -> int: return Input.mouse_mode
## (int) -> void. Default: sets the real Input.mouse_mode.
var set_mode: Callable = func(m: int) -> void: Input.mouse_mode = m


func mode() -> int:
	return int(get_mode.call())


func is_captured() -> bool:
	return mode() == Input.MOUSE_MODE_CAPTURED


## A left click in the match (not on the gear, menu closed). Asks for capture unless already captured.
func on_click() -> void:
	if state == State.MENU:
		return
	if is_captured():
		state = State.CAPTURED
		return
	set_mode.call(Input.MOUSE_MODE_CAPTURED)
	poll()


## Esc (the "pause" action) with the menu closed: release and ask for the menu.
func on_escape() -> void:
	if state == State.MENU:
		return
	_release()
	state = State.MENU
	pause_requested.emit()


## The pause menu opened (any way): release the mouse.
func on_menu_opened() -> void:
	_release()
	state = State.MENU


## The pause menu closed: back to FREE. The cursor stays visible until the next click.
func on_menu_closed() -> void:
	state = State.FREE


## Once per frame. Picks up a granted capture, and turns a lost capture (no key event) into a pause request.
func poll() -> void:
	var captured := is_captured()
	match state:
		State.FREE:
			if captured:
				state = State.CAPTURED
		State.CAPTURED:
			if not captured:
				state = State.MENU
				pause_requested.emit()
		State.MENU:
			if captured:
				_release()  # something else captured while the menu is up: keep the cursor for the menu


## Leaving the match (or the scene): give the cursor back.
func release() -> void:
	_release()
	state = State.FREE


func _release() -> void:
	if is_captured():
		set_mode.call(Input.MOUSE_MODE_VISIBLE)
