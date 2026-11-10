shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
// S3: the next circle's markers. mode 0 = the low ring on the ground (a bright foot that fades upward, with
// dashes running round it), mode 1 = the beacon at the circle's centre (a column of light that pulses and
// thins with height). Unit cylinder meshes scaled by ZoneWall. Additive, no depth or screen read.
uniform vec4 tint : source_color = vec4(1.0, 0.85, 0.5, 1.0);
uniform float strength = 1.0;
uniform float mode = 0.0;
uniform float dash_m = 3.0;
uniform float run_mps = 1.5;
uniform float pulse_speed = 2.2;
varying vec2 v_wall;
varying float v_height01;
varying float v_view;

void vertex() {
	float radius = length(MODEL_MATRIX[0].xyz);
	float angle = atan(VERTEX.z, VERTEX.x);
	v_wall = vec2(angle * radius, VERTEX.y);
	v_height01 = UV.y;
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 to_camera = normalize(CAMERA_POSITION_WORLD - world);
	vec3 normal = normalize((MODEL_MATRIX * vec4(VERTEX.x, 0.0, VERTEX.z, 0.0)).xyz);
	v_view = abs(dot(to_camera, normal));
}

void fragment() {
	float up = 1.0 - v_height01;  // CylinderMesh UV.y runs from the top (0) to the bottom (1)
	float alpha;
	if (mode < 0.5) {
		float dash = smoothstep(0.35, 0.5, abs(fract((v_wall.x - TIME * run_mps) / dash_m) - 0.5) * 2.0);
		alpha = pow(1.0 - up, 2.5) * (0.55 + 0.45 * dash);
	} else {
		float pulse = 0.75 + 0.25 * sin(TIME * pulse_speed - up * 14.0);
		// Brightest seen through its middle: a soft-edged column.
		alpha = pow(1.0 - up, 1.6) * pulse * (0.25 + 0.75 * v_view * v_view);
	}
	ALBEDO = tint.rgb * alpha * strength;
	ALPHA = 1.0;
}
