extends "res://tests/test_case.gd"

const ShaderText := preload("res://tests/w1b_mobile_shader_text.gd")


func test_mobile_shader_text_matches_base() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(ShaderText.FIXTURE))
	assert_true(parsed is Dictionary and parsed.size() == 13, "fixture covers all 13 base shaders")
	if not parsed is Dictionary:
		return
	var current := ShaderText.snapshot()
	for file: String in parsed:
		assert_true(current.get(file) == parsed[file], "%s Mobile source matches base" % file)
	# Shaders added after the base belong to other slices and have no base text to keep.
	# A new include could change a base shader's Mobile build, so it must stay Mobile-empty.
	for file: String in current:
		if not parsed.has(file) and file.ends_with(".gdshaderinc"):
			assert_true(current[file].is_empty(), "%s adds no Mobile source" % file)


func test_mobile_shader_normalizer_keeps_else_and_expands_nested_identity_calls() -> void:
	var source := """
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
#if SOME_DEFINE
void compatibility_only() {}
#endif
#else
#ifndef W1B_TRIM
#define W1B_TRIM(a) (a)
#endif
vec3 trim = W1B_TRIM(W1A_OUT(vec3(
	a, b, c)));
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
void nested_compatibility_only() {}
#endif
#endif
"""
	assert_eq(ShaderText.normalize(source), "vec3 trim = vec3( a, b, c);", "balanced calls and Mobile branch")
	assert_eq(ShaderText.normalize("#define W1B_TRIM(a) scale(a)"), "#define W1B_TRIM(a) scale(a)",
		"non-identity defines survive to fail comparison")
