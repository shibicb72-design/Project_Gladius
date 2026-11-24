extends "res://tests/test_case.gd"
## A3 item 3: the Murmillo's 8 atlas textures (slice A2, scripts/visual/shaders/soldier_textured.gdshader). Albedo and
## ORM import VRAM-compressed with mipmaps; the normal map VRAM-compressed with mipmaps and the normal-map flag (the
## shader rebuilds z from xy: two-channel RGTC/BC5 on desktop and in the web build); the mask (squad / tier paint
## fields) stays lossless. Reads each .import file and the imported texture's format.

const DIR := "res://assets/generated/characters/gladiator_%s_%s.png"
const MODE_LOSSLESS := 0
const MODE_VRAM := 2


func _params(path: String) -> ConfigFile:
	var cfg := ConfigFile.new()
	assert_eq(cfg.load(path + ".import"), OK, "%s.import reads" % path)
	return cfg


func test_albedo_orm_normal_are_vram_compressed_with_mipmaps_and_the_mask_is_lossless() -> void:
	for lod in ["near", "far"]:
		for kind in ["albedo", "orm", "normal", "mask"]:
			var path := DIR % [lod, kind]
			var cfg := _params(path)
			var mode := int(cfg.get_value("params", "compress/mode", -1))
			var normal_flag := int(cfg.get_value("params", "compress/normal_map", -1))
			var img := (load(path) as Texture2D).get_image()
			print("A3_TEXTURES %s_%s mode=%d normal_map=%d mipmaps=%s format=%d compressed=%s" % [lod, kind, mode, normal_flag,
					cfg.get_value("params", "mipmaps/generate"), img.get_format(), img.is_compressed()])
			assert_eq(bool(cfg.get_value("params", "mipmaps/generate", false)), true, "%s_%s: mipmaps" % [lod, kind])
			assert_true(img.has_mipmaps(), "%s_%s: the imported texture has mipmaps" % [lod, kind])
			if kind == "mask":
				assert_eq(mode, MODE_LOSSLESS, "%s mask: lossless" % lod)
				assert_true(not img.is_compressed(), "%s mask: the imported texture is uncompressed" % lod)
				continue
			assert_eq(mode, MODE_VRAM, "%s_%s: VRAM compressed" % [lod, kind])
			assert_true(img.is_compressed(), "%s_%s: the imported texture is block-compressed" % [lod, kind])
			assert_true(bool(cfg.get_value("remap", "metadata", {}).get("vram_texture", false)), "%s_%s: vram_texture" % [lod, kind])
			if kind == "normal":
				assert_eq(normal_flag, 1, "%s normal: compress/normal_map enabled" % lod)
				assert_eq(img.get_format(), Image.FORMAT_RGTC_RG, "%s normal: two-channel RGTC (BC5) on desktop" % lod)
			else:
				assert_true(normal_flag != 1, "%s_%s: not flagged as a normal map" % [lod, kind])


func test_the_shader_rebuilds_the_normal_z_from_xy() -> void:
	var code := (load("res://scripts/visual/shaders/soldier_textured.gdshader") as Shader).code
	assert_true(code.contains("texture(normal_atlas, UV).xy"), "the normal atlas is read as xy only")
	assert_true(code.contains("sqrt(max(0.0, 1.0 - dot(normal.xy, normal.xy)))"), "z is rebuilt from xy")
	assert_true(not code.contains("texture(normal_atlas, UV).xyz"), "the blue channel (0 in RGTC) is never read")
