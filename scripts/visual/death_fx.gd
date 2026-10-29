extends Node
## Presentation only. Death visibility transition; corpse belongs to the match, never the hidden pawn.
var _pawn: Pawn
var _was_visible := true
var _cfg: Dictionary

func _ready() -> void:
	_pawn = get_parent() as Pawn
	_cfg = LowpolyKit.config()["death"]
	_was_visible = _pawn.visible
	_pawn.visibility_changed.connect(_on_visibility_changed)

func _on_visibility_changed() -> void:
	var now := _pawn.visible
	var dying := _was_visible and not now
	_was_visible = now
	if not dying or not _pawn.is_inside_tree():
		return
	var model := _pawn.get_node("SoldierModel") as SoldierModel
	var corpse := model.make_corpse()
	_pawn.get_parent().add_child(corpse)
	corpse.global_transform = _pawn.global_transform
	var tween := corpse.create_tween()
	tween.set_parallel(true)
	tween.tween_property(corpse, "rotation_degrees:x", corpse.rotation_degrees.x + float(_cfg["topple_degrees"]), float(_cfg["topple_s"])).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(corpse, "position:y", corpse.position.y + float(_cfg["drop_m"]), float(_cfg["topple_s"]))
	tween.chain().tween_interval(maxf(0.0, float(_cfg["lifetime_s"]) - float(_cfg["topple_s"])))
	tween.chain().tween_callback(corpse.queue_free)
