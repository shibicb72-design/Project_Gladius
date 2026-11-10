shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, world_vertex_coords, fog_disabled;
// A sun shaft: one quad per place, stretched along the sun's direction from the instance's origin and turned
// around that axis to face the camera. Additive, soft at the edges, brighter when the view looks towards the
// sun, faded out close to the camera. No depth or screen read (cheap; overdraw is its only cost).
uniform vec4 tint : source_color = vec4(1.0, 0.66, 0.4, 1.0);
uniform float strength = 0.13;
uniform float length_m = 34.0;
uniform float width_m = 5.0;
uniform vec3 axis = vec3(0.0, -1.0, 0.0);
uniform sampler2D noise_pack : filter_linear_mipmap, repeat_enable;
varying float v_fade;
varying vec2 v_noise_uv;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 dir = normalize(axis);
	vec3 on_axis = origin + dir * (UV.y * length_m);
	vec3 to_camera = CAMERA_POSITION_WORLD - on_axis;
	vec3 side = normalize(cross(dir, to_camera));
	VERTEX = on_axis + side * ((UV.x - 0.5) * width_m);
	NORMAL = normalize(to_camera);
	float along_view = dot(normalize(-to_camera), -dir);  // 1 = looking straight up the shaft at the sun
	float facing = clamp(along_view * 0.5 + 0.5, 0.0, 1.0);
	// Seen end-on a quad is a wedge, not a shaft: fade it out there, and close to the camera.
	float side_on = 1.0 - smoothstep(0.75, 0.97, abs(along_view));
	v_fade = (0.35 + 0.65 * facing * facing) * side_on * smoothstep(6.0, 18.0, length(to_camera));
	v_noise_uv = vec2(origin.x * 0.07 + UV.x * 0.6, origin.z * 0.05);
}

void fragment() {
	float across = sin(UV.x * PI);
	float along = smoothstep(0.0, 0.08, UV.y) * (1.0 - smoothstep(0.55, 1.0, UV.y));
	float streaks = 0.55 + 0.45 * texture(noise_pack, v_noise_uv).g;
	ALBEDO = tint.rgb;
	ALPHA = across * across * along * streaks * strength * v_fade;
}
