shader_type spatial;
// The map's ground: trodden earth, dry grass and Roman paving blended by a small paint map (GroundPaint,
// R = paving, G = grass, the rest earth) with noisy edges, a large-scale shade so the tiling does not show,
// and puddles where the wet amount reaches. World-space mapping, so it needs no UVs.
// Cost: five texture fetches per pixel (paint map, noise, three surface tiles); flagged in the report.
uniform sampler2DArray surfaces : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D paint_map : filter_linear, repeat_disable;
uniform sampler2D noise_pack : filter_linear_mipmap, repeat_enable;
uniform float map_size_m = 160.0;
uniform vec3 layer_ids = vec3(10.0, 11.0, 12.0);  // earth, grass, paving
uniform vec3 tiles_per_m = vec3(0.333, 0.4, 0.25);
uniform vec3 earth_color : source_color = vec3(0.42, 0.34, 0.26);
uniform vec3 grass_color : source_color = vec3(0.36, 0.4, 0.2);
uniform vec3 grass_dry_color : source_color = vec3(0.5, 0.44, 0.22);
uniform vec3 paving_color : source_color = vec3(0.6, 0.57, 0.52);
uniform float macro_per_m = 0.027;
uniform float macro_strength = 0.3;
uniform float edge_noise = 0.4;
uniform float wet = 0.0;
uniform float wet_dark = 0.62;
uniform float wet_roughness = 0.12;
uniform float puddle_level = 0.62;
uniform float puddle_soft = 0.08;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = v_world.xz;
	vec4 paint = texture(paint_map, p / map_size_m + 0.5);
	vec4 nz = texture(noise_pack, p * macro_per_m);
	float paving = smoothstep(0.42, 0.58, paint.r + (nz.b - 0.5) * edge_noise * 0.6);
	float grass = smoothstep(0.38, 0.62, paint.g + (nz.r - 0.5) * edge_noise) * (1.0 - paving);
	vec4 te = texture(surfaces, vec3(p * tiles_per_m.x, layer_ids.x));
	vec4 tg = texture(surfaces, vec3(p * tiles_per_m.y, layer_ids.y));
	vec4 tp = texture(surfaces, vec3(p * tiles_per_m.z, layer_ids.z));
	vec3 earth = earth_color * (0.2 + 1.6 * te.r);
	// Two tones of grass in broad patches, with the blades' own light and dark on top.
	vec3 green = mix(grass_color, grass_dry_color, smoothstep(0.35, 0.7, nz.g + (nz.b - 0.5) * 0.3)) * (0.05 + 1.9 * tg.r);
	vec3 stone = paving_color * (0.3 + 1.4 * tp.r);
	vec3 albedo = mix(mix(earth, green, grass), stone, paving);
	vec4 t = mix(mix(te, tg, grass), tp, paving);
	albedo *= 1.0 + (nz.g - 0.5) * 2.0 * macro_strength;
	// Water gathers in the low noise first; paving joints hold it, grass hides it.
	float low = 1.0 - nz.r * 0.6 - t.r * 0.25 - nz.g * 0.15;
	float puddle = smoothstep(puddle_level, puddle_level + puddle_soft, low + wet * 0.5 - 0.5) * (1.0 - grass * 0.8) * step(0.001, wet);
	float damp = wet * (1.0 - grass * 0.5);
	albedo *= mix(1.0, wet_dark, max(damp * 0.7, puddle));
	ALBEDO = albedo;
	ROUGHNESS = mix(mix(t.g, wet_roughness + 0.25, damp * 0.6), 0.04, puddle);
	vec2 n = (t.ba * 2.0 - 1.0) * (1.0 - puddle);
	// World-space mapping on a flat top: +u is world +x, +v is world +z.
	vec3 tangent = normalize((VIEW_MATRIX * vec4(1.0, 0.0, 0.0, 0.0)).xyz);
	vec3 bitangent = normalize((VIEW_MATRIX * vec4(0.0, 0.0, 1.0, 0.0)).xyz);
	NORMAL = normalize(NORMAL + tangent * n.x * 1.2 + bitangent * n.y * 1.2);
	SPECULAR = mix(0.5, 0.9, puddle);
}
