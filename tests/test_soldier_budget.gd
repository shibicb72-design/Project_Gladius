extends "res://tests/test_case.gd"
## M2 AN1 commit 6: the third-person soldier's cost per LOD stays inside data/art_soldier.json soldier.budgets.
## A soldier's cost at a camera distance is what Godot would draw of it there: every visible GeometryInstance3D of its
## SoldierModel (layers != 0) whose visibility range holds that distance (begin <= d < end, end 0 = no end), measured
## from the instance's AABB centre as Godot does. Triangles from the meshes, one draw per surface.
const Perf := preload("res://tests/test_astra_perf.gd")


func _budgets() -> Dictionary:
	return SoldierLook.config()["budgets"]


func _pawn(at: Vector3 = Vector3.ZERO) -> Pawn:
	var pawn: Pawn = load("res://scenes/player/pawn.tscn").instantiate()
	(Engine.get_main_loop() as SceneTree).root.add_child(pawn)
	pawn.set_physics_process(false)
	pawn.global_position = at
	(pawn.get_node("SoldierModel") as SoldierModel).set_process(false)
	return pawn


static func _instances(node: Node, out: Array[GeometryInstance3D]) -> void:
	if node is GeometryInstance3D:
		out.append(node)
	for child in node.get_children():
		_instances(child, out)


## [triangles, draw calls] of `model` seen from `eye`; a distance < 0 measures every instance at that distance instead.
static func cost(model: SoldierModel, eye: Vector3, distance: float = -1.0) -> Vector2i:
	var all: Array[GeometryInstance3D] = []
	_instances(model, all)
	var result := Vector2i.ZERO
	for gi in all:
		if not gi.is_visible_in_tree() or gi.layers == 0 or not (gi is MeshInstance3D) or (gi as MeshInstance3D).mesh == null:
			continue
		var d := distance
		if d < 0.0:
			d = eye.distance_to(gi.global_transform * gi.get_aabb().get_center())
		if d < gi.visibility_range_begin or (gi.visibility_range_end > 0.0 and d >= gi.visibility_range_end):
			continue
		var mesh := (gi as MeshInstance3D).mesh
		result += Vector2i(Perf.triangles(mesh), mesh.get_surface_count())
	return result


func test_each_lod_of_one_soldier_within_its_budget() -> void:
	var b := _budgets()
	assert_true(String(b["_note"]).length() > 40, "every budget carries its reason")
	var far_m := float(SoldierLook.config()["gun"]["far_m"])
	var pawn := _pawn()
	var model := pawn.get_node("SoldierModel") as SoldierModel
	assert_true(model.rifle.visibility_range_end > 0.0 and is_equal_approx(model.rifle.visibility_range_end, model.rifle_far.visibility_range_begin),
			"near gun hands over to the far gun at one distance")
	# M2 AN2 item 1: the body has two LODs too; each LOD's cost below counts the body instance its range shows.
	assert_true(model.armor_far != null and model.armor.visibility_range_end > 0.0 and is_equal_approx(model.armor.visibility_range_end, model.armor_far.visibility_range_begin)
			and is_equal_approx(model.armor.visibility_range_end, far_m), "near body hands over to the far body at the gun's distance")
	for gun: String in ["pilum_br", "sagittarii_rifle"]:
		model.show_gun(gun)
		var near := cost(model, Vector3.ZERO, far_m * 0.5)
		var far := cost(model, Vector3.ZERO, far_m + 1.0)
		print("SOLDIER_BUDGET gun=", gun, " near triangles=", near.x, " draws=", near.y, " far triangles=", far.x, " draws=", far.y,
				" armor=", Perf.triangles(model.armor.mesh), " gun_near=", Perf.triangles(model.rifle.mesh), " gun_far=", Perf.triangles(model.rifle_far.mesh))
		assert_true(near.x > 0 and near.x <= int(b["near"]["max_triangles"]) and near.y <= int(b["near"]["max_draw_calls"]),
				"%s near LOD within budget: %s" % [gun, near])
		assert_true(far.x > 0 and far.x <= int(b["far"]["max_triangles"]) and far.y <= int(b["far"]["max_draw_calls"]),
				"%s far LOD within budget: %s" % [gun, far])
		assert_true(far.x < near.x, "%s: the far LOD is cheaper than the near one" % gun)
		assert_true(Perf.triangles(model.rifle.mesh) <= 500 and model.rifle.mesh.get_surface_count() == 1, "%s: a third-person gun is at most 500 triangles in one draw" % gun)
	pawn.free()


## 18 soldiers in a line from 4 m to 106 m: every one past the data distance costs no more than the far budget, and
## every nearer one no more than the near budget (what the visibility ranges actually select, not a formula).
func test_distant_soldiers_cost_no_more_than_the_far_budget() -> void:
	var b := _budgets()
	var past := float(b["far_test_m"])
	assert_true(past >= float(SoldierLook.config()["gun"]["far_m"]), "the test distance is at or past the gun's far distance")
	var pawns: Array[Pawn] = []
	for i in 18:
		pawns.append(_pawn(Vector3(0.0, 0.0, -4.0 - 6.0 * i)))
	var eye := Vector3(0.0, 1.6, 0.0)
	var distant := 0
	var distant_total := Vector2i.ZERO
	var near_total := Vector2i.ZERO
	for pawn in pawns:
		var model := pawn.get_node("SoldierModel") as SoldierModel
		var c := cost(model, eye)
		var d := eye.distance_to(pawn.global_position)
		if d >= past:
			distant += 1
			distant_total += c
			assert_true(c.x <= int(b["far"]["max_triangles"]) and c.y <= int(b["far"]["max_draw_calls"]), "soldier at %.0f m within the far budget: %s" % [d, c])
		else:
			near_total += c
			assert_true(c.x <= int(b["near"]["max_triangles"]) and c.y <= int(b["near"]["max_draw_calls"]), "soldier at %.0f m within the near budget: %s" % [d, c])
	assert_true(distant >= 10, "nonvacuous: most of the line is past %s m (%d soldiers)" % [past, distant])
	assert_true(distant_total.x <= distant * int(b["far"]["max_triangles"]), "the distant soldiers together stay under count x far budget")
	print("SOLDIER_BUDGET 18 soldiers: distant=", distant, " distant_triangles=", distant_total.x, " distant_draws=", distant_total.y,
			" near_triangles=", near_total.x, " near_draws=", near_total.y)
	for pawn in pawns:
		pawn.free()
