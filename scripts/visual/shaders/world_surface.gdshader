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

varying flat int v_surface;
varying vec3 v_world;
varying vec3 v_world_normal;

// The sRGB to linear step StandardMaterial3D applies with vertex_color_is_srgb.
vec3 to_linear(vec3 c) {
	return mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
}

void vertex() {
	v_surface = int(UV2.x + 0.5);
	COLOR.rgb = to_linear(mix(vec3(1.0), COLOR.rgb, paint_mix)) * (1.0 + (UV2.y - 0.5) * 2.0 * part_shade);
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	vec4 a = surf_a[v_surface];
	vec4 b = surf_b[v_surface];
	vec4 t = texture(surfaces, vec3(UV * a.y, a.x));
	float up = v_world_normal.y;
	vec3 paint = COLOR.rgb * tint.rgb * (1.0 + a.z * (t.r * 2.0 - 1.0));
	// Dirt creeps up from the ground on faces that do not look up.
	float foot = (1.0 - smoothstep(0.0, grime_height, v_world.y)) * (1.0 - max(up, 0.0));
	paint *= mix(1.0, grime_dark, foot * (0.6 + 0.4 * t.r));
	float rough = clamp(t.g * b.x + b.y, 0.04, 1.0);
	float soaked = wet * smoothstep(0.2, 0.9, up) * (1.0 - b.z);
	paint *= mix(1.0, wet_dark, wet * (1.0 - b.z) * 0.6);
	ALBEDO = paint;
	ROUGHNESS = mix(rough, wet_roughness, soaked);
	METALLIC = b.z;
	vec2 n = (t.ba * 2.0 - 1.0) * a.w * (1.0 - soaked * 0.7);
	NORMAL = normalize(NORMAL + TANGENT * n.x + BINORMAL * n.y);
	// Ambient is one colour (Environment), so shape it here: faces that look down keep less of it.
	AO = mix(ambient_down, 1.0, up * 0.5 + 0.5);
	AO_LIGHT_AFFECT = 0.0;
	float pulse = 1.0 + glow_pulse * sin(TIME * glow_pulse_speed + v_world.x * 0.35 + v_world.z * 0.35);
	EMISSION = paint * (b.w * pulse) + paint * bounce_color * (bounce * (0.5 - 0.5 * up));
}
