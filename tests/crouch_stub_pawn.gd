extends "res://scripts/classes/pawn.gd"
## M2 AN3 stage C: a stand-in for the parallel slice H1c's Pawn.crouch_amount() (0..1), so the soldier model's free
## crouch can be tested and captured before H1c lands. Swapped onto a pawn.tscn instance with set_script() before it
## enters the tree (the scene's root sets nothing but its script). Lowering the Head node (the head hitbox), as H1c
## will, is left to the caller: tests and tools set Head.position.y themselves. Not a test file (no test_ prefix).

var crouch_value := 0.0


func crouch_amount() -> float:
	return crouch_value
