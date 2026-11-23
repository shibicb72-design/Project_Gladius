shader_type spatial;
// One material for the built world (kit pieces, cover, walls, props). A vertex carries its paint (COLOR, sRGB),
// the surface id of that paint (UV2.x, data/art_materials.json "surface_order") and a per-part shade (UV2.y).
// UV is in metres on the face's main plane and TANGENT follows +u (LowpolyKit._triangle), so one texture
// fetch gives the surface: R = albedo modulation, G = roughness, B / A = tangent-space normal x / y.
// Cost: one array fetch per pixel, no screen or depth read; runs on the Mobile renderer.
const int SURFACES = 32;
uniform sampler2DArray surfaces : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 surf_a[SURFACES];  // layer, tiles per metre, contrast, bump
uniform vec4 surf_b[SURFACES];  // roughness scale, roughness bias, metallic, glow
uniform vec4 tint : source_color = vec4(1.0);
uniform float paint_mix = 1.0;  // 0 = tint only (pieces without vertex paint), 1 = tint x vertex paint
uniform float part_shade = 0.08;  // how far UV2.y moves a part lighter or darker
uniform float ambient_down = 0.45;
uniform vec3 bounce_color : source_color = vec3(1.0, 0.62, 0.38);
uniform float bounce = 0.07;
uniform float grime_height = 0.9;
uniform float grime_dark = 0.72;
uniform float glow_pulse = 0.12;
uniform float glow_pulse_speed = 1.7;
uniform float wet = 0.0;
uniform float wet_dark = 0.62;
uniform float wet_roughness = 0.12;
// M2W1 astraA: world-kit looks (scripts/visual/world_kit_meshes.gd: glb structures, parts cover) carry CUSTOM0 =
// (variation weight, baked shade range, grime kept, 0); every other mesh has none (reads 0) and takes exactly the
// old path. A look with a shade range reads UV2.y over that range (its shade is baked at load) and keeps CUSTOM0.z
// of the world-height grime; with a weight it takes a per-instance value / warmth from its origin (MODEL_MATRIX:
// the batch instance, so a near and a far mesh of one piece match; cells of variation_cell_m, a broad wave of
// variation_broad_m). The variation uniforms default to 0 (off); WorldKit sets them when the looks are on.
uniform float variation_value = 0.0;
uniform float variation_warm = 0.0;
uniform float variation_broad = 0.0;
uniform float variation_cell_m = 8.0;
uniform float variation_broad_m = 70.0;
// M2W1 astraB: the look variant's "glow_gain" (data/art_look.json; absent = 1.0, the emission as before) scales the
// surfaces' own glow (energy lines, lamps, beacons), not the bounce term.
uniform float glow_gain = 1.0;
// M2W1 astraB: the wet gloss fades out between half this and this camera distance (default: never), so far hills
// in the storm do not flash the light back.
uniform float wet_far_m = 100000.0;

varying flat int v_surface;
varying vec3 v_world;
varying vec3 v_world_normal;
varying float v_grime;

// A sin-free hash (fract / dot only: a large sin argument loses precision on GPUs and gave neighbouring cells
// nearly the same value).
float cell_hash(vec2 c) {
	vec3 p = fract(vec3(c.xyx) * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

// The sRGB to linear step StandardMaterial3D applies with vertex_color_is_srgb.
vec3 to_linear(vec3 c) {
	return mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
}

// W1a: the Compatibility renderer (WebGL 2) shades in sRGB space: OUTPUT_IS_SRGB is true there, source_color
// uniforms (tint, bounce_color) and light colours arrive unconverted, and StandardMaterial3D skips its
// vertex_color_is_srgb step. This shader mixes its paint in linear (to_linear in vertex(), then linear-space shade,
// grime and wet factors), which drew every world-kit face (walls, gates, buildings) far too dark on the web and
// pushed the glow strips (paint x glow_gain) far too hot. There, W1A_LIN() takes a source_color to linear, the paint
// and the emission are worked out exactly as on Mobile, and W1A_OUT() hands them over in sRGB, as a
// StandardMaterial3D albedo is there. Mobile and Forward+ compile W1A_LIN(c) and W1A_OUT(c) as (c), unchanged.
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
vec3 w1a_to_srgb(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(vec3(1.055) * pow(c, vec3(1.0 / 2.4)) - vec3(0.055), c * 12.92, lessThan(c, vec3(0.0031308)));
}
#define W1A_LIN(c) to_linear(c)
#define W1A_OUT(c) w1a_to_srgb(c)
#else
#define W1A_LIN(c) (c)
#define W1A_OUT(c) (c)
#endif

void vertex() {
	v_surface = int(UV2.x + 0.5);
	bool kit = CUSTOM0.y > 0.0;
	COLOR.rgb = to_linear(mix(vec3(1.0), COLOR.rgb, paint_mix)) * (1.0 + (UV2.y - 0.5) * 2.0 * (kit ? CUSTOM0.y : part_shade));
	v_grime = kit ? CUSTOM0.z : 1.0;
	if (CUSTOM0.x > 0.0) {
		vec3 origin = MODEL_MATRIX[3].xyz;
		vec2 cell = floor(origin.xz / variation_cell_m);
		float h0 = cell_hash(cell);
		float h1 = cell_hash(cell + vec2(17.0, 5.0));
		float wave = sin(origin.x * 6.2831853 / variation_broad_m) * cos(origin.z * 6.2831853 / (variation_broad_m * 1.37));
		float value = 1.0 + CUSTOM0.x * ((h0 * 2.0 - 1.0) * variation_value + wave * variation_broad);
		float warm = CUSTOM0.x * (h1 * 2.0 - 1.0) * variation_warm;
		COLOR.rgb *= value * vec3(1.0 + warm, 1.0, 1.0 - warm);	}
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	vec4 a = surf_a[v_surface];
	vec4 b = surf_b[v_surface];
	vec4 t = texture(surfaces, vec3(UV * a.y, a.x));
	float up = v_world_normal.y;
	vec3 paint = COLOR.rgb * W1A_LIN(tint.rgb) * (1.0 + a.z * (t.r * 2.0 - 1.0));
	// Dirt creeps up from the ground on faces that do not look up.
	float foot = (1.0 - smoothstep(0.0, grime_height, v_world.y)) * (1.0 - max(up, 0.0)) * v_grime;
	paint *= mix(1.0, grime_dark, foot * (0.6 + 0.4 * t.r));
	float rough = clamp(t.g * b.x + b.y, 0.04, 1.0);
	float soaked = wet * smoothstep(0.2, 0.9, up) * (1.0 - b.z) * (1.0 - smoothstep(wet_far_m * 0.5, wet_far_m, length(v_world - CAMERA_POSITION_WORLD)));
	paint *= mix(1.0, wet_dark, wet * (1.0 - b.z) * 0.6);
	ALBEDO = W1A_OUT(paint);
	ROUGHNESS = mix(rough, wet_roughness, soaked);
	METALLIC = b.z;
	vec2 n = (t.ba * 2.0 - 1.0) * a.w * (1.0 - soaked * 0.7);
	NORMAL = normalize(NORMAL + TANGENT * n.x + BINORMAL * n.y);
	// Ambient is one colour (Environment), so shape it here: faces that look down keep less of it.
	AO = mix(ambient_down, 1.0, up * 0.5 + 0.5);
	AO_LIGHT_AFFECT = 0.0;
	float pulse = 1.0 + glow_pulse * sin(TIME * glow_pulse_speed + v_world.x * 0.35 + v_world.z * 0.35);
	EMISSION = W1A_OUT(paint * (b.w * pulse * glow_gain) +paint * W1A_LIN(bounce_color) * (bounce * (0.5 - 0.5 * up)));
}
