shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
// S3: the zone wall as an energy field you can read from both sides. A lattice of thin lines climbs the wall,
// a hot line marks where it meets the ground, and the field thins with height and with distance so the world
// behind it stays visible: near the wall you see the lattice, far away only the foot line and a faint veil.
// The mesh is a unit cylinder scaled to the circle (ZoneWall), so the pattern is laid out in metres from the
// model matrix. Additive, no depth or screen read; its cost is overdraw.
uniform vec4 field_color : source_color = vec4(0.1, 0.35, 1.0, 1.0);
uniform vec4 line_color : source_color = vec4(0.4, 0.85, 1.0, 1.0);
uniform vec4 foot_color : source_color = vec4(0.7, 0.92, 1.0, 1.0);
uniform float field_alpha = 0.1;
uniform float line_alpha = 0.3;
uniform float foot_alpha = 0.9;
uniform float foot_height_m = 0.25;
uniform float cell_m = 2.6;
uniform float line_width_m = 0.05;
uniform float climb_mps = 0.6;
uniform float fade_height_m = 12.0;
uniform float near_m = 45.0;
uniform float far_alpha = 0.12;
uniform float wall_height_m = 40.0;
uniform sampler2D noise_pack : filter_linear_mipmap, repeat_enable;
varying vec2 v_wall;  // metres along the circle, metres above the ground
varying float v_distance;

void vertex() {
	float radius = length(MODEL_MATRIX[0].xyz);
	float angle = atan(VERTEX.z, VERTEX.x);
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wall = vec2(angle * radius, world.y);
	v_distance = length(world - CAMERA_POSITION_WORLD);
}

// Distance (in cells) to the nearest line of a net of triangles: two diagonal families and one level family.
float lattice(vec2 p) {
	float a = abs(fract(p.x + p.y * 0.5) - 0.5);
	float b = abs(fract(p.x - p.y * 0.5) - 0.5);
	float c = abs(fract(p.y) - 0.5);
	return min(min(a, b), c);
}

void fragment() {
	vec2 p = vec2(v_wall.x, v_wall.y - TIME * climb_mps) / cell_m;
	float d = lattice(p);
	float soft = fwidth(d) * 1.5 + 0.0005;
	float half_width = line_width_m / cell_m * 0.5;
	float line = 1.0 - smoothstep(half_width, half_width + soft, d);
	float halo = (1.0 - smoothstep(0.0, 0.07, d)) * 0.16;
	float shimmer = texture(noise_pack, vec2(v_wall.x * 0.03, v_wall.y * 0.05 - TIME * 0.04)).r;
	float height_fade = exp(-max(v_wall.y, 0.0) / fade_height_m);
	float near = 1.0 - smoothstep(near_m * 0.25, near_m, v_distance);
	float veil = mix(far_alpha, 1.0, near);
	float foot = (1.0 - smoothstep(0.0, foot_height_m, v_wall.y)) * foot_alpha;
	float low_glow = exp(-max(v_wall.y, 0.0) / 2.0) * 0.25;
	vec3 color = field_color.rgb * (field_alpha * (0.5 + shimmer) + low_glow) * veil;
	color += line_color.rgb * (line + halo) * line_alpha * (0.4 + 1.2 * shimmer) * near;
	color = color * height_fade + foot_color.rgb * foot * mix(0.45, 1.0, near);
	ALBEDO = color;
	ALPHA = 1.0;
}
