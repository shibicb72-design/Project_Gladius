shader_type sky;
// S1: the Alesia sky. A gradient from the zenith to a horizon that is warm towards the sun and cool away from
// it, a sun (or moon) disc with a halo, one layer of clouds lit from the sun's side, and stars. Everything
// comes from uniforms (data/art_look.json) and one generated noise texture; there is no sky image.
// It does not read TIME, so the radiance map is built once and not every frame (Mobile renderer cost).
uniform vec3 zenith_color : source_color = vec3(0.1, 0.14, 0.32);
uniform vec3 horizon_color : source_color = vec3(0.45, 0.38, 0.5);
uniform vec3 horizon_sun_color : source_color = vec3(0.95, 0.55, 0.32);
uniform vec3 ground_color : source_color = vec3(0.12, 0.1, 0.1);
uniform float horizon_power = 3.0;
uniform float sun_spread = 5.0;
uniform vec3 sun_color : source_color = vec3(1.0, 0.72, 0.45);
uniform float sun_energy = 10.0;
uniform float sun_size_deg = 2.4;
uniform float sun_halo = 0.5;
uniform sampler2D noise_pack : filter_linear_mipmap, repeat_enable;
uniform float cloud_cover = 0.5;
uniform float cloud_soft = 0.18;
uniform float cloud_scale = 0.35;
uniform vec2 cloud_offset = vec2(0.0);
uniform vec3 cloud_lit_color : source_color = vec3(1.0, 0.6, 0.42);
uniform vec3 cloud_dark_color : source_color = vec3(0.2, 0.18, 0.3);
uniform float star_energy = 0.0;
// M2W1 (optional; the defaults draw exactly the S1 sky). Cloud light: one more fetch of the low octave a step
// towards the sun; where the cloud thins towards the sun the edge is lit, where it thickens the side is in shade.
uniform float cloud_light_step = 0.0;
uniform float cloud_light_gain = 3.0;
uniform float cloud_light_mix = 0.0;
uniform vec3 cloud_base_color : source_color = vec3(0.2, 0.18, 0.3);
uniform float cloud_base = 0.0;
// High thin streaks above the cumulus (two fetches; skipped at cloud2_cover 0).
uniform float cloud2_cover = 0.0;
uniform float cloud2_scale = 0.12;
uniform float cloud2_stretch = 3.0;
uniform vec2 cloud2_offset = vec2(0.31, 0.07);
uniform vec3 cloud2_color : source_color = vec3(1.0, 0.95, 0.88);
uniform float cloud2_opacity = 0.5;
// A pale band along the horizon (math only), warmer on the sun's side.
uniform float horizon_haze = 0.0;
uniform float horizon_haze_width = 0.08;
uniform vec3 horizon_haze_color : source_color = vec3(0.8, 0.78, 0.74);
uniform vec3 horizon_haze_sun_color : source_color = vec3(0.95, 0.85, 0.7);
// M2W1 astraB (optional; 0 = the S1 cloud light). The S1 clouds take the sun's side from the azimuth alone, so every
// thin cloud in the sun's compass direction is lit at any height: a vertical glow column through the sun. At 1 the
// clouds take it from the angle to the sun (a round warm area round the sun) and the light is capped at 1.
uniform float cloud_sun_3d = 0.0;
uniform float cloud_sun_spread = 3.0;  // power on (dot(dir, sun) * 0.5 + 0.5) for that round area
// The halo's wide term (S1: 0.18 of sun_halo); lower keeps the sky round the sun deep.
uniform float sun_halo_wide = 0.18;

void sky() {
	vec3 dir = normalize(EYEDIR);
	float up = dir.y;
	vec3 sun_dir = LIGHT0_ENABLED ? LIGHT0_DIRECTION : vec3(0.0, 1.0, 0.0);
	float towards = dot(dir, sun_dir);
	float side = pow(clamp(dot(normalize(dir.xz + vec2(0.0001)), normalize(sun_dir.xz + vec2(0.0001))) * 0.5 + 0.5, 0.0, 1.0), sun_spread);
	float low = pow(1.0 - clamp(up, 0.0, 1.0), horizon_power);
	vec3 horizon = mix(horizon_color, horizon_sun_color, side);
	vec3 color = mix(zenith_color, horizon, low);
	// Stars before the clouds, so clouds cover them.
	if (star_energy > 0.0) {
		vec2 suv = dir.xz / (abs(up) + 0.35) * 1.7;
		float star = texture(noise_pack, suv).a * texture(noise_pack, suv * 0.23 + 0.31).g;
		color += vec3(0.85, 0.9, 1.0) * star * star_energy * smoothstep(0.02, 0.4, up);
	}
	float halo = pow(max(towards, 0.0), 48.0) * sun_halo + pow(max(towards, 0.0), 6.0) * sun_halo * sun_halo_wide;
	color += sun_color * halo;
	float cloud_side = mix(side, pow(clamp(towards * 0.5 + 0.5, 0.0, 1.0), cloud_sun_spread), cloud_sun_3d);
	float cloud = 0.0;
	if (up > 0.0 && cloud2_cover > 0.0) {
		vec2 uv2 = dir.xz / (up + 0.25) * cloud2_scale * vec2(1.0, cloud2_stretch) + cloud2_offset;
		float n2 = texture(noise_pack, uv2).g * 0.7 + texture(noise_pack, uv2 * vec2(3.1, 1.3) + 0.53).r * 0.3;
		float streak = smoothstep(1.0 - cloud2_cover, 1.0 - cloud2_cover + 0.28, n2) * smoothstep(0.03, 0.3, up);
		vec3 streak_color = mix(cloud2_color * 0.82, cloud2_color, cloud_side);
		color = mix(color, mix(streak_color, horizon, low * 0.6), streak * cloud2_opacity);
	}
	if (up > 0.0) {
		vec2 uv = dir.xz / (up + 0.16) * cloud_scale + cloud_offset;
		float n0 = texture(noise_pack, uv * 0.35).r;
		float n = n0 * 0.62 + texture(noise_pack, uv * 0.93 + 0.37).r * 0.28 + texture(noise_pack, uv * 2.9).g * 0.1;
		cloud = smoothstep(1.0 - cloud_cover - cloud_soft, 1.0 - cloud_cover + cloud_soft, n) * smoothstep(0.0, 0.1, up);
		// Thick cores are dark; thin edges and the side towards the sun catch its colour.
		float core = smoothstep(1.0 - cloud_cover, 1.0 - cloud_cover + 0.35, n);
		float lit = clamp((1.0 - core * 0.85) * (0.35 + 0.65 * cloud_side) + pow(max(towards, 0.0), 10.0) * 0.6, 0.0, mix(1.5, 1.0, cloud_sun_3d));
		if (cloud_light_mix > 0.0) {
			vec2 sun_uv = normalize(sun_dir.xz + vec2(0.0001)) * cloud_light_step;
			float n_sun = texture(noise_pack, (uv + sun_uv) * 0.35).r;
			float facing_sun = clamp((n0 - n_sun) * cloud_light_gain + 0.5, 0.0, 1.0);
			lit = mix(lit, lit * (0.35 + 1.3 * facing_sun), cloud_light_mix);
		}
		vec3 cloud_color = mix(cloud_dark_color, cloud_lit_color, lit);
		// Bases: the thick part of a cloud, seen from below, goes to the base colour.
		cloud_color = mix(cloud_color, cloud_base_color, core * cloud_base * (1.0 - 0.5 * cloud_side));
		cloud_color = mix(cloud_color, horizon, low * 0.75);
		color = mix(color, cloud_color, cloud);
	}
	if (!AT_CUBEMAP_PASS) {
		float edge = cos(radians(sun_size_deg));
		float disc = smoothstep(edge, mix(edge, 1.0, 0.3), towards);
		color += sun_color * sun_energy * disc * (1.0 - cloud * 0.85);
	}
	color = mix(color, ground_color, smoothstep(0.0, -0.12, up));
	if (horizon_haze > 0.0) {
		float band = exp(-abs(up) / max(horizon_haze_width, 0.001));
		color = mix(color, mix(horizon_haze_color, horizon_haze_sun_color, side), band * horizon_haze);
	}
	COLOR = color;
}
