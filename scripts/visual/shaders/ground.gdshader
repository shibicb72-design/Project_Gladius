shader_type spatial;
// The map's ground: trodden earth, dry grass and Roman paving blended by a small paint map (GroundPaint,
// R = paving, G = grass, the rest earth) with noisy edges, a large-scale shade so the tiling does not show,
// and puddles where the wet amount reaches. World-space mapping, so it needs no UVs.
// Cost: six texture fetches per pixel (paint map, two noise scales, three surface tiles); flagged in the report.
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
// M2W1 ground detail (data/art_ground_detail.json, graphics preset art_ground_detail_enabled). Off = the S2 path
// below the branch, unchanged. On: eight fetches instead of six (paint, two macro noise scales, the near noise,
// earth, grass, paving and rock tiles). The macro scales come from two noise fetches: the 360 m tile's G gives
// ~60 m patches, the 90 m tile's G ~15 m and its B ~2-3 m grain; the near noise (4 m tile) only within ~10 m.
uniform bool detail_enabled = false;
uniform float detail_large_m = 360.0;
uniform float detail_mid_m = 90.0;
uniform float detail_near_m = 4.0;
uniform vec3 earth_ochre : source_color = vec3(0.62, 0.5, 0.34);
uniform vec3 earth_umber : source_color = vec3(0.4, 0.31, 0.22);
uniform vec3 earth_worn : source_color = vec3(0.7, 0.62, 0.48);
uniform float earth_worn_amount = 0.35;
uniform float earth_contrast = 1.3;
uniform vec3 grass_lush : source_color = vec3(0.33, 0.42, 0.18);
uniform vec3 grass_dry : source_color = vec3(0.6, 0.54, 0.3);
uniform float grass_contrast = 1.5;
uniform float bare_amount = 0.6;
uniform float bare_level = 0.62;
uniform float creep_amount = 0.5;
uniform float rock_layer = 8.0;
uniform float rock_tiles_per_m = 0.2;
uniform vec3 rock_color : source_color = vec3(0.56, 0.53, 0.48);
uniform float rock_slope_start = 0.06;  // 1 - normal.y (0.06 ~ 20 degrees)
uniform float rock_slope_end = 0.12;    // (0.12 ~ 28 degrees)
uniform float rock_noise = 0.08;
uniform float rock_over_paving = 0.85;
uniform float rock_contrast = 0.9;
uniform float rock_scree = 0.45;
uniform float earth_bump = 0.5;
uniform float rock_bump = 0.35;
uniform vec3 paving_edge_color : source_color = vec3(0.34, 0.28, 0.21);
uniform float paving_edge = 0.5;
uniform float paving_joint_grass = 0.6;
uniform float slab_tint = 0.25;
uniform float warp_m = 1.5;
uniform float macro_value = 0.22;
uniform float near_detail_m = 10.0;
uniform float near_strength = 0.25;
uniform float near_bump = 0.6;
uniform float fade_start_m = 25.0;
uniform float fade_end_m = 140.0;
uniform float fade_amount = 0.75;

varying vec3 v_world;
varying vec3 v_normal_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_normal_world = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}

void fragment() {
	vec2 p = v_world.xz;
	if (detail_enabled) {
		vec4 paint_d = texture(paint_map, p / map_size_m + 0.5);
		vec4 L = texture(noise_pack, p / detail_large_m + vec2(0.37, 0.11));
		vec4 M = texture(noise_pack, p / detail_mid_m + vec2(0.71, 0.29));
		vec4 Nn = texture(noise_pack, p / detail_near_m + vec2(0.13, 0.53));
		float dist = length(v_world - CAMERA_POSITION_WORLD);
		float far_k = smoothstep(fade_start_m, fade_end_m, dist) * fade_amount;  // tiling detail fades into macro colour
		float near_k = 1.0 - smoothstep(near_detail_m * 0.5, near_detail_m, dist);
		vec2 warp = (M.rg - 0.5) * warp_m;  // bends the tiles' grid a little so the repeat does not line up
		float paving = smoothstep(0.42, 0.58, paint_d.r + (M.b - 0.5) * edge_noise * 0.9 + (M.g - 0.5) * edge_noise * 0.3);
		// Rock and scree on the slopes (the hill's steepest is 29 degrees: planar xz stretches 14% there at most).
		// It also covers most of the paint's paving there (looks only: the paint map and footsteps are unchanged).
		float slope = 1.0 - normalize(v_normal_world).y;
		float rock = smoothstep(rock_slope_start, rock_slope_end, slope + (M.b - 0.5) * rock_noise + (M.g - 0.5) * rock_noise);
		paving *= 1.0 - rock * rock_over_paving;
		float grass_paint = smoothstep(0.38, 0.62, paint_d.g + (M.r - 0.5) * edge_noise + (L.g - 0.5) * 0.25);
		// Bare worn patches and stone scatter inside the grass; sparse dry grass creeping into the earth.
		float bare = smoothstep(bare_level, bare_level + 0.1, M.g * 0.65 + L.r * 0.35 + (M.b - 0.5) * 0.15) * bare_amount;
		float grass = grass_paint * (1.0 - bare) * (1.0 - paving);
		float creep = (1.0 - grass_paint) * smoothstep(0.55, 0.78, L.g * 0.5 + M.g * 0.35 + M.b * 0.15) * creep_amount * (1.0 - paving);
		rock *= 1.0 - paving;
		vec4 te = texture(surfaces, vec3((p + warp) * tiles_per_m.x, layer_ids.x));
		vec4 tg = texture(surfaces, vec3((p - warp) * tiles_per_m.y, layer_ids.y));
		vec4 tp = texture(surfaces, vec3(p * tiles_per_m.z, layer_ids.z));
		vec4 tr = texture(surfaces, vec3((p + warp * 0.5) * rock_tiles_per_m, rock_layer));
		te.ba = mix(vec2(0.5), te.ba, earth_bump);  // the dirt tile's pebble bumps repeat: keep them low
		tr.ba = mix(vec2(0.5), tr.ba, rock_bump);  // grazing sun on a shaded slope: strong bumps light up as flecks
		float er = mix(te.r, 0.5, far_k);
		float gr = mix(tg.r, 0.5, far_k);
		float rr = mix(tr.r, 0.5, far_k * 0.6);
		vec3 earth_col = mix(earth_umber, earth_ochre, smoothstep(0.3, 0.7, L.g * 0.55 + M.r * 0.45));
		earth_col = mix(earth_col, earth_worn, smoothstep(0.55, 0.85, M.b * 0.6 + M.g * 0.4) * earth_worn_amount);
		vec3 earth = earth_col * (1.0 + (er - 0.5) * earth_contrast);
		vec3 green_col = mix(grass_lush, grass_dry, smoothstep(0.3, 0.72, L.r * 0.45 + M.g * 0.4 + M.b * 0.15));
		vec3 green = green_col * (1.0 + (gr - 0.5) * grass_contrast);
		vec3 creep_col = grass_dry * (1.0 + (gr - 0.5) * grass_contrast);
		vec3 rock_c = rock_color * (1.0 + (rr - 0.5) * rock_contrast);
		rock_c = mix(rock_c, earth, smoothstep(0.35, 0.75, M.b) * rock_scree);  // loose earth between the stones
		vec3 stone = paving_color * (0.3 + 1.4 * mix(tp.r, 0.5, far_k * 0.5)) * (1.0 + (M.b - 0.5) * slab_tint);
		// Grass in the paving joints near the grass, a darker dirt band where the paving meets the earth.
		float joint = 1.0 - smoothstep(0.18, 0.32, tp.r);
		stone = mix(stone, green_col * 0.7, joint * grass_paint * paving_joint_grass);
		vec3 albedo_d = mix(earth, creep_col, creep * smoothstep(0.45, 0.6, gr));
		albedo_d = mix(albedo_d, green, grass);
		albedo_d = mix(albedo_d, rock_c, rock);
		float edge = clamp(paving * (1.0 - paving) * 4.0, 0.0, 1.0);
		albedo_d = mix(albedo_d, stone, paving);
		albedo_d = mix(albedo_d, paving_edge_color, edge * paving_edge * (1.0 - grass_paint * 0.5));
		// One value term over all of it at the three scales, then the near grain.
		albedo_d *= 1.0 + (L.g * 0.45 + M.g * 0.35 + M.b * 0.2 - 0.5) * 2.0 * macro_value;
		albedo_d *= 1.0 + (Nn.b - 0.5) * near_strength * near_k;
		vec4 t_d = mix(mix(mix(te, tg, grass), tr, rock), tp, paving);
		float low_d = 1.0 - M.r * 0.6 - t_d.r * 0.25 - M.g * 0.15;
		float puddle_d = smoothstep(puddle_level, puddle_level + puddle_soft, low_d + wet * 0.5 - 0.5) * (1.0 - grass * 0.8) * (1.0 - rock) * step(0.001, wet);
		float damp_d = wet * (1.0 - grass * 0.5) * (1.0 - rock * 0.6);  // rain runs off the slopes
		albedo_d *= mix(1.0, wet_dark, max(damp_d * 0.7, puddle_d));
		ALBEDO = albedo_d;
		ROUGHNESS = mix(mix(t_d.g, wet_roughness + 0.25, damp_d * 0.6), 0.04, puddle_d);
		vec2 n_d = (t_d.ba * 2.0 - 1.0) * (1.0 - puddle_d) * (1.0 - far_k * 0.8) + (Nn.gb - 0.5) * near_bump * near_k;
		vec3 tangent_d = normalize((VIEW_MATRIX * vec4(1.0, 0.0, 0.0, 0.0)).xyz);
		vec3 bitangent_d = normalize((VIEW_MATRIX * vec4(0.0, 0.0, 1.0, 0.0)).xyz);
		NORMAL = normalize(NORMAL + tangent_d * n_d.x * 1.2 + bitangent_d * n_d.y * 1.2);
		SPECULAR = mix(0.5 - rock * 0.25, 0.9, puddle_d);
	} else {
	vec4 paint = texture(paint_map, p / map_size_m + 0.5);
	vec4 nz = texture(noise_pack, p * macro_per_m);
	// A second, much larger sample for the broad patches, so the first one's tiling does not show from the air.
	vec4 wide = texture(noise_pack, p * macro_per_m * 0.27 + vec2(0.37, 0.11));
	float paving = smoothstep(0.42, 0.58, paint.r + (nz.b - 0.5) * edge_noise * 0.6);
	float grass = smoothstep(0.38, 0.62, paint.g + (nz.r - 0.5) * edge_noise) * (1.0 - paving);
	vec4 te = texture(surfaces, vec3(p * tiles_per_m.x, layer_ids.x));
	vec4 tg = texture(surfaces, vec3(p * tiles_per_m.y, layer_ids.y));
	vec4 tp = texture(surfaces, vec3(p * tiles_per_m.z, layer_ids.z));
	vec3 earth = earth_color * (0.2 + 1.6 * te.r);
	// Two tones of grass in broad patches, with the blades' own light and dark on top.
	vec3 green = mix(grass_color, grass_dry_color, smoothstep(0.3, 0.75, wide.r * 0.7 + nz.g * 0.3)) * (0.05 + 1.9 * tg.r);
	vec3 stone = paving_color * (0.3 + 1.4 * tp.r);
	vec3 albedo = mix(mix(earth, green, grass), stone, paving);
	vec4 t = mix(mix(te, tg, grass), tp, paving);
	albedo *= 1.0 + (wide.g * 0.6 + nz.g * 0.4 - 0.5) * 2.0 * macro_strength;
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
}
