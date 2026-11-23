extends RefCounted
## W1a: an exact dump of what GreyboxArt._apply_environment sets for one look variant: every stored property of the
## Environment, its Sky and sky ShaderMaterial, the sun (DirectionalLight3D) and the shared world material
## (WorldSurface.material(), the one the walls, gates and kit pieces draw with). Values are var_to_str text, so a
## float that moves by one ulp shows. Resources are written as class + path. Used by test_w1a_renderer_look.gd and,
## once, by tools/w1a_record_golden.gd to record tests/fixtures/w1a_mobile_look_golden.json from the code before
## W1a (the Mobile golden).

const VARIANTS := ["dusk", "night", "storm"]
const SKIP := ["resource_path", "resource_name", "resource_local_to_scene", "resource_scene_unique_id", "script"]


static func value_text(v: Variant) -> String:
	if v is Resource:
		return "<%s %s>" % [(v as Resource).get_class(), (v as Resource).resource_path]
	if v is Object:
		return "<%s>" % (v as Object).get_class()
	return var_to_str(v)


static func props(obj: Object) -> Dictionary:
	var out := {}
	if obj == null:
		return out
	for p: Dictionary in obj.get_property_list():
		if int(p["usage"]) & PROPERTY_USAGE_STORAGE == 0:
			continue
		var prop := String(p["name"])
		if SKIP.has(prop):
			continue
		out[prop] = value_text(obj.get(prop))
	return out


## A stage like the match's (a "Light" sun beside a WorldEnvironment running greybox_art.gd), added to the tree.
static func stage(tree: SceneTree) -> Node3D:
	var s := Node3D.new()
	var light := DirectionalLight3D.new()
	light.name = "Light"
	s.add_child(light)
	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	world.set_script(load("res://scripts/visual/greybox_art.gd"))
	s.add_child(world)
	tree.root.add_child(s)
	return s


## Applies `variant` on the stage and dumps the five objects.
static func dump(s: Node3D, variant: String) -> Dictionary:
	var world := s.get_node("WorldEnvironment") as WorldEnvironment
	world.call("_apply_environment", world, variant)
	var env := world.environment
	var sky: Sky = env.sky
	return {
		"environment": props(env),
		"sky": props(sky),
		"sky_material": props(sky.sky_material if sky != null else null),
		"sun": props(s.get_node("Light")),
		"world_material": props(WorldSurface.material()),
	}


## Every variant of VARIANTS, keyed by id.
static func dump_all(tree: SceneTree) -> Dictionary:
	var s := stage(tree)
	var out := {}
	for id: String in VARIANTS:
		out[id] = dump(s, id)
	s.free()
	return out
