extends SceneTree
## M2 AN1: lists the bones and animation clips of a glTF file without importing it (reads the file directly):
##   godot --headless --path . --script res://tools/glb_inspect.gd -- --file=res://assets/third_party/quaternius_ual/UAL1_Standard.glb
## Prints GLB BONE <index> <name> <parent> lines and GLB CLIP <name> <length s> <tracks> lines. Read-only.


func _initialize() -> void:
	var path := "res://assets/third_party/quaternius_ual/UAL1_Standard.glb"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--file="):
			path = arg.substr(7)
		elif arg.begins_with("--rel="):  # a project-relative path without the res:// prefix
			path = "res://" + arg.substr(6)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(ProjectSettings.globalize_path(path), state)
	if err != OK:
		print("GLB failed to read %s err=%d" % [path, err])
		quit(1)
		return
	var scene := doc.generate_scene(state)
	var skeletons := scene.find_children("*", "Skeleton3D", true, false)
	for s in skeletons:
		var sk := s as Skeleton3D
		print("GLB SKELETON %s bones=%d" % [sk.name, sk.get_bone_count()])
		for i in sk.get_bone_count():
			var rest := sk.get_bone_global_rest(i)
			print("GLB BONE %d %s parent=%d at=(%.3f, %.3f, %.3f)" % [i, sk.get_bone_name(i), sk.get_bone_parent(i), rest.origin.x, rest.origin.y, rest.origin.z])
	for p in scene.find_children("*", "AnimationPlayer", true, false):
		var player := p as AnimationPlayer
		var names := player.get_animation_list()
		print("GLB PLAYER %s clips=%d" % [player.name, names.size()])
		for n in names:
			var a := player.get_animation(n)
			print("GLB CLIP %s length=%.3f tracks=%d" % [n, a.length, a.get_track_count()])
	for m in scene.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var tris := 0
		for i in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(i)
			var idx: Variant = arrays[Mesh.ARRAY_INDEX]
			tris += (idx.size() if idx != null else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
		print("GLB MESH %s surfaces=%d triangles=%d" % [mi.name, mi.mesh.get_surface_count(), tris])
	scene.free()
	quit(0)
