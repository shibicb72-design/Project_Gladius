shader_type spatial;

instance uniform vec3 squad_paint = vec3(0.0, 1.0, 0.0);
instance uniform vec4 tier_paint = vec4(0.0, 0.0, 0.0, -1.0);
instance uniform float cape_lift = 0.0; // The Murmillo has no cloth driven by this value.
uniform sampler2D albedo_atlas : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D normal_atlas : hint_normal, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D orm_atlas : filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D mask_atlas : filter_linear_mipmap, repeat_disable;
uniform float wet;
uniform float wet_dark;
uniform float wet_roughness;
uniform float glow_pulse;
uniform float glow_pulse_speed;
uniform vec3 rim_color : source_color;
uniform float rim;
uniform float rim_power;

varying vec3 world_normal;

vec3 to_linear(vec3 c) {
	return mix(pow((c + vec3(0.055)) / 1.055, vec3(2.4)), c / 12.92, lessThan(c, vec3(0.04045)));
}

#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
vec3 to_srgb(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, c * 12.92, lessThan(c, vec3(0.0031308)));
}
#define W1A_LIN(c) to_linear(c)
#define W1A_OUT(c) to_srgb(c)
#else
#define W1A_LIN(c) (c)
#define W1A_OUT(c) (c)
#endif

void vertex() {
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	vec3 paint = W1A_LIN(texture(albedo_atlas, UV).rgb);
	vec3 orm = texture(orm_atlas, UV).rgb;
	vec2 mask = texture(mask_atlas, UV).rg;
	paint = mix(paint, to_linear(squad_paint), mask.r);
	float tier_glow = 0.0;
	if (tier_paint.a >= 0.0) {
		paint = mix(paint, to_linear(tier_paint.rgb), mask.g);
		tier_glow = tier_paint.a * mask.g;
	}
	float up = normalize(world_normal).y;
	float wetness = wet * (1.0 - orm.b);
	paint *= mix(1.0, wet_dark, wetness * 0.5);
	ALBEDO = W1A_OUT(paint);
	AO = orm.r;
	ROUGHNESS = mix(orm.g, wet_roughness, wetness * smoothstep(0.2, 0.9, up));
	METALLIC = orm.b;
	// A3 item 3: the normal atlas imports VRAM-compressed with compress/normal_map (two-channel RGTC/BC5 on desktop and
	// in the web build), whose blue channel reads 0, so z is rebuilt from xy. The source map is unit length with z >= 0
	// (z from xy matches its blue channel within 0.005), so the uncompressed result is unchanged.
	vec3 normal = vec3(texture(normal_atlas, UV).xy * 2.0 - 1.0, 0.0);
	normal.z = sqrt(max(0.0, 1.0 - dot(normal.xy, normal.xy)));
	NORMAL = normalize(TANGENT * normal.x + BINORMAL * normal.y + NORMAL * normal.z);
	float pulse = 1.0 + glow_pulse * sin(TIME * glow_pulse_speed);
	float edge = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), rim_power);
	EMISSION = W1A_OUT(paint * tier_glow * pulse + W1A_LIN(rim_color) * (edge * rim * (0.4 + 0.6 * clamp(up + 0.5, 0.0, 1.0))));
}
