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
	float halo = pow(max(towards, 0.0), 48.0) * sun_halo + pow(max(towards, 0.0), 6.0) * sun_halo * 0.18;
	color += sun_color * halo;
	float cloud = 0.0;
	if (up > 0.0) {
		vec2 uv = dir.xz / (up + 0.16) * cloud_scale + cloud_offset;
		float n = texture(noise_pack, uv * 0.35).r * 0.62 + texture(noise_pack, uv * 0.93 + 0.37).r * 0.28 + texture(noise_pack, uv * 2.9).g * 0.1;
		cloud = smoothstep(1.0 - cloud_cover - cloud_soft, 1.0 - cloud_cover + cloud_soft, n) * smoothstep(0.0, 0.1, up);
		// Thick cores are dark; thin edges and the side towards the sun catch its colour.
		float core = smoothstep(1.0 - cloud_cover, 1.0 - cloud_cover + 0.35, n);
		float lit = clamp((1.0 - core * 0.85) * (0.35 + 0.65 * side) + pow(max(towards, 0.0), 10.0) * 0.6, 0.0, 1.5);
		vec3 cloud_color = mix(cloud_dark_color, cloud_lit_color, lit);
		cloud_color = mix(cloud_color, horizon, low * 0.75);
		color = mix(color, cloud_color, cloud);
	}
	if (!AT_CUBEMAP_PASS) {
		float edge = cos(radians(sun_size_deg));
		float disc = smoothstep(edge, mix(edge, 1.0, 0.3), towards);
		color += sun_color * sun_energy * disc * (1.0 - cloud * 0.85);
	}
	color = mix(color, ground_color, smoothstep(0.0, -0.12, up));
	COLOR = color;
}
