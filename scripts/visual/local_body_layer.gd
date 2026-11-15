class_name LocalBodyLayer
extends RefCounted
## M2 C1a stage 4 (spec item 3, fixes 1, 3, 10): moves the local player's own third-person body from the default render
## layer (1) to data/camera.json first_person.body_layer. The local CameraRig camera leaves that layer out of its cull
## mask while in first person; every other camera (SpectatorCamera, other machines) keeps the default all-layers mask
## and draws the full soldier. Render layers only: collision layers, hitboxes, the muzzle, the shot and the host aim
## check never see it.
## Covered: Body, Head/HeadMesh, every VisualInstance3D under SoldierModel (including ones it adds or moves in later:
## each tracked node's child_entered_tree is followed), the ShotFx weapon_mesh subtree, ShotFx tracer and flash, and
## the SwingVisual bars the melee swing adds under the pawn (the view model plays its own swing). NOT the ShotFx
## impact, sparks and dust: the hit must be seen in first person. Only bit 1 moves, so a node with layers 0 (the ShotFx
## weapon box, SoldierModel.add_rifle) stays drawn by no camera, as today.
## Owner: Pawn.ensure_local_body_layer, called by the pawn's CameraRig every physics frame; there is one per local pawn.

const DEFAULT_BIT := 1

var pawn: Pawn
var bit := 0
var _fx: ShotFx


func _init(owner_pawn: Pawn, layer: int) -> void:
	pawn = owner_pawn
	bit = 1 << (layer - 1)
	track(pawn.get_node_or_null("Body"))
	track(pawn.get_node_or_null("Head/HeadMesh"))
	track(pawn.get_node_or_null("SoldierModel"))
	for child in pawn.get_children():
		if child is SwingVisual:
			track(child)
	pawn.child_entered_tree.connect(_on_pawn_child)
	refresh()


## Cheap per-frame check: follows pawn.shot_fx when it appears or is replaced (its meshes exist after its _ready).
func refresh() -> void:
	var fx := pawn.shot_fx
	if fx == _fx or fx == null or not is_instance_valid(fx) or fx.tracer == null:
		return
	_fx = fx
	track(fx.weapon_mesh)
	move(fx.tracer)
	move(fx.flash)


## Moves `node` and its whole subtree to the body layer, now and for children added later.
func track(node: Node) -> void:
	if node == null:
		return
	move(node)
	if not node.child_entered_tree.is_connected(track):
		node.child_entered_tree.connect(track)
	for child in node.get_children():
		track(child)


## Bit 1 (the default layer) becomes the body bit; other bits and layers 0 stay as they are.
func move(node: Node) -> void:
	var vi := node as VisualInstance3D
	if vi != null and (vi.layers & DEFAULT_BIT) != 0:
		vi.layers = (vi.layers & ~DEFAULT_BIT) | bit


func _on_pawn_child(node: Node) -> void:
	if node is SwingVisual:
		track(node)


## True iff `node` draws on the body layer and not on the default one.
static func is_on_layer(node: Node, layer: int) -> bool:
	var vi := node as VisualInstance3D
	return vi != null and (vi.layers & (1 << (layer - 1))) != 0 and (vi.layers & DEFAULT_BIT) == 0
