shader_type spatial;
// One material for every soldier (C3, decision D2). The vertex colour is the paint, authored as sRGB.
// Where the vertex alpha is 0 the paint is the squad colour: a per-instance value, so squads differ
// without a second material. Alpha 1 keeps the vertex colour.
// squad_paint is plain sRGB numbers (a vec3 without a colour hint), so nothing converts it on the way in
// and the one conversion below treats both paints the same.
// The default below is never meant to be seen: SoldierSquadColour sets it from data. Pure green marks an
// instance nobody painted (not magenta: that is the Fold diagnostic clear colour the device harness counts).
// S4: the paint sits on a textured surface like the world's (UV2.x = surface id, one array fetch: R albedo
// modulation, G roughness, B / A normal), with a rim light so a soldier reads against a dark wall, and a
// second per-instance value for the armor tier: vertices of the tier surface take tier_paint.rgb, and
// tier_paint.a makes them glow.
const int SURFACES = 32;
instance uniform vec3 squad_paint = vec3(0.0, 1.0, 0.0);
instance uniform vec4 tier_paint = vec4(0.0, 0.0, 0.0, -1.0);  // a < 0: no tier, keep the vertex paint
uniform sampler2DArray surfaces : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 surf_a[SURFACES];  // layer, tiles per metre, contrast, bump
uniform vec4 surf_b[SURFACES];  // roughness scale, roughness bias, metallic, glow
uniform int tier_surface = -1;
instance uniform float cape_lift = 0.0;
uniform int sway_surface = -1;  // parts with "sway": true must use this surface (their UV2.y is the hang, not a shade)
uniform float sway_m = 0.04;
uniform float sway_lift_m = 0.3;
uniform float sway_speed = 2.6;
uniform float part_shade = 0.05;
uniform float ambient_down = 0.45;
uniform vec3 rim_color : source_color = vec3(0.55, 0.7, 1.0);
uniform float rim = 0.35;
uniform float rim_power = 3.0;
uniform float glow_pulse = 0.12;
uniform float glow_pulse_speed = 1.7;
uniform float wet = 0.0;
uniform float wet_dark = 0.62;
uniform float wet_roughness = 0.12;

varying flat int v_surface;
varying vec3 v_world_normal;
varying float v_tier_glow;

// The sRGB to linear step StandardMaterial3D applies with vertex_color_is_srgb.
vec3 to_linear(vec3 c) {
	return mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
}

void vertex() {
	v_surface = int(UV2.x + 0.5);
	vec3 paint = mix(squad_paint, COLOR.rgb, COLOR.a);
	v_tier_glow = 0.0;
	if (v_surface == tier_surface && tier_paint.a >= 0.0) {
		paint = tier_paint.rgb;
		v_tier_glow = tier_paint.a;
	}
	float shade = UV2.y;
	if (v_surface == sway_surface) {
		// The cape: UV2.y is how far the vertex hangs below the cape's top edge (0..1). It ripples, and
		// swings back (the soldier's +Z) and up with cape_lift, the soldier's speed as a fraction.
		float hang = UV2.y * UV2.y;
		float ripple = sin(TIME * sway_speed + UV2.y * 4.0 + squad_paint.r * 9.0) * sway_m;
		VERTEX.z += (ripple + cape_lift * sway_lift_m) * hang;
		VERTEX.x += cos(TIME * sway_speed * 0.7 + UV2.y * 3.0) * sway_m * 0.4 * hang;
		VERTEX.y += cape_lift * sway_lift_m * 0.45 * hang;
		shade = 0.5;
	}
	COLOR.rgb = to_linear(paint) * (1.0 + (shade - 0.5) * 2.0 * part_shade);
	v_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	vec4 a = surf_a[v_surface];
	vec4 b = surf_b[v_surface];
	vec4 t = texture(surfaces, vec3(UV * a.y, a.x));
	float up = v_world_normal.y;
	vec3 paint = COLOR.rgb * (1.0 + a.z * (t.r * 2.0 - 1.0));
	float rough = clamp(t.g * b.x + b.y, 0.04, 1.0);
	float soaked = wet * smoothstep(0.2, 0.9, up) * (1.0 - b.z);
	paint *= mix(1.0, wet_dark, wet * (1.0 - b.z) * 0.5);
	ALBEDO = paint;
	ROUGHNESS = mix(rough, wet_roughness, soaked);
	METALLIC = b.z;
	vec2 n = (t.ba * 2.0 - 1.0) * a.w;
	vec3 normal = normalize(NORMAL + TANGENT * n.x + BINORMAL * n.y);
	NORMAL = normal;
	AO = mix(ambient_down, 1.0, up * 0.5 + 0.5);
	AO_LIGHT_AFFECT = 0.0;
	float pulse = 1.0 + glow_pulse * sin(TIME * glow_pulse_speed);
	float edge = pow(1.0 - clamp(dot(normal, VIEW), 0.0, 1.0), rim_power);
	EMISSION = paint * ((b.w + v_tier_glow) * pulse) + rim_color * (edge * rim * (0.4 + 0.6 * clamp(up + 0.5, 0.0, 1.0)));
}
