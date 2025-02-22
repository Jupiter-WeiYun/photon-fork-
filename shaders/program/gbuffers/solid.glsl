/*
--------------------------------------------------------------------------------

  Photon Shaders by SixthSurge

  program/gbuffers/solid.glsl:
  Handle terrain, entities, the hand, beacon beams and spider eyes

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

varying vec2 uv;
varying vec2 light_levels;

flat varying uint material_mask;
flat varying vec4 tint;
flat varying mat3 tbn;

#if defined POM
varying vec2 atlas_tile_coord;
varying vec3 tangent_pos;
flat varying vec2 atlas_tile_offset;
flat varying vec2 atlas_tile_scale;
#endif

#if defined PROGRAM_GBUFFERS_TERRAIN
varying float vanilla_ao;
#endif

// ------------
//   uniforms
// ------------

uniform sampler2D noisetex;

uniform sampler2D gtexture;

#if defined NORMAL_MAPPING || defined POM
uniform sampler2D normals;
#endif

#if defined SPECULAR_MAPPING
uniform sampler2D specular;
#endif

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;

uniform vec3 cameraPosition;

uniform float near;
uniform float far;

uniform ivec2 atlasSize;

uniform int frameCounter;
uniform float frameTimeCounter;
uniform float rainStrength;

uniform vec2 view_res;
uniform vec2 view_pixel_size;
uniform vec2 taa_offset;

uniform vec3 light_dir;

#if defined PROGRAM_GBUFFERS_BLOCK
uniform int blockEntityId;
#endif

#if defined PROGRAM_GBUFFERS_ENTITIES
uniform int entityId;
uniform vec4 entityColor;
#endif


//----------------------------------------------------------------------------//
#if defined STAGE_VERTEX

attribute vec4 at_tangent;
attribute vec3 mc_Entity;
attribute vec2 mc_midTexCoord;

#include "/include/utility/space_conversion.glsl"
#include "/include/vertex/wind_animation.glsl"

void main()
{
	uv           = gl_MultiTexCoord0.xy;
	light_levels = clamp01(gl_MultiTexCoord1.xy * rcp(240.0));
	tint         = gl_Color;

	tbn[0] = mat3(gbufferModelViewInverse) * normalize(gl_NormalMatrix * at_tangent.xyz);
	tbn[2] = mat3(gbufferModelViewInverse) * normalize(gl_NormalMatrix * gl_Normal);
	tbn[1] = cross(tbn[0], tbn[2]) * sign(at_tangent.w);

#if   defined PROGRAM_GBUFFERS_TERRAIN
	material_mask = uint(max0(mc_Entity.x - 10000.0));
#elif defined PROGRAM_GBUFFERS_ENTITIES
	material_mask = uint(max(entityId - 10000, 0));
#elif defined PROGRAM_GBUFFERS_BLOCK
	material_mask = uint(max(blockEntityId - 10000, 0));
#endif

#if defined PROGRAM_GBUFFERS_TERRAIN
	vanilla_ao = gl_Color.a < 0.1 ? 1.0 : gl_Color.a; // fixes models where vanilla ao breaks (eg lecterns)
	tint.a = 1.0;

	#ifdef POM
	// from fayer3
	vec2 uv_minus_mid = uv - mc_midTexCoord;
	atlas_tile_offset = min(uv, mc_midTexCoord - uv_minus_mid);
	atlas_tile_scale = abs(uv_minus_mid) * 2.0;
	atlas_tile_coord = sign(uv_minus_mid) * 0.5 + 0.5;
	#endif
#endif

#if defined PROGRAM_SPIDEREYES
	material_mask = 2; // full emissive
	light_levels.x = 1.0;
#endif

#if defined PROGRAM_GBUFFERS_BEACONBEAM
	material_mask = 2;
#endif

	vec3 view_pos = transform(gl_ModelViewMatrix, gl_Vertex.xyz);
#if defined PROGRAM_GBUFFERS_TERRAIN
	bool is_top_vertex = uv.y < mc_midTexCoord.y;
	vec3 scene_pos = view_to_scene_space(view_pos);
	scene_pos += animate_vertex(scene_pos + cameraPosition, is_top_vertex, light_levels.y, material_mask);
    view_pos = scene_to_view_space(scene_pos);

	#ifdef POM
	tangent_pos = (scene_pos - gbufferModelViewInverse[3].xyz) * tbn;
	#endif
#endif

	vec4 clip_pos = project(gl_ProjectionMatrix, view_pos);

#if   defined TAA && defined TAAU
	clip_pos.xy  = clip_pos.xy * taau_render_scale + clip_pos.w * (taau_render_scale - 1.0);
	clip_pos.xy += taa_offset * clip_pos.w;
#elif defined TAA
	clip_pos.xy += taa_offset * clip_pos.w * 0.66;
#endif

	gl_Position = clip_pos;
}

#endif
//----------------------------------------------------------------------------//



//----------------------------------------------------------------------------//
#if defined STAGE_FRAGMENT

layout (location = 0) out vec4 gbuffer_data_0; // albedo, block ID, flat normal, light levels
layout (location = 1) out vec4 gbuffer_data_1; // detailed normal, specular map (optional)

/* DRAWBUFFERS:1 */

#ifdef NORMAL_MAPPING
/* DRAWBUFFERS:12 */
#endif

#ifdef SPECULAR_MAPPING
/* DRAWBUFFERS:12 */
#endif

#if defined PROGRAM_GBUFFERS_TERRAIN && defined POM
#include "/include/misc/parallax.glsl"
#endif

#include "/include/utility/dithering.glsl"
#include "/include/utility/encoding.glsl"
#include "/include/utility/fast_math.glsl"
#include "/include/utility/random.glsl"
#include "/include/utility/space_conversion.glsl"

#if   TEXTURE_FORMAT == TEXTURE_FORMAT_LAB
void decode_normal_map(vec3 normal_map, out vec3 normal, out float ao)
{
	normal.xy = normal_map.xy * 2.0 - 1.0;
	normal.z  = sqrt(clamp01(1.0 - dot(normal.xy, normal.xy)));
	ao        = normal_map.z;
}
#elif TEXTURE_FORMAT == TEXTURE_FORMAT_OLD
void decode_normal_map(vec3 normal_map, out vec3 normal, out float ao)
{
	normal  = normal_map * 2.0 - 1.0;
	ao      = length(normal);
	normal *= rcp(ao);
}
#endif

#if defined PROGRAM_GBUFFERS_BLOCK
vec3 draw_end_portal()
{
	const int   layer_count = 8;       // Number of layers
	const float depth_scale = 0.33;    // Apparent distance between layers
	const float depth_fade = 0.5;      // How quickly the layers fade to black
	const float threshold = 0.99;      // Threshold for the "stars". Lower values mean more stars appear
	const float twinkle_speed = 0.4;   // How fast the stars appear to twinkle
	const float twinkle_amount = 0.04; // How many twinkling stars appear
	const vec3  color0 = pow(vec3(0.80, 0.90, 0.99), vec3(2.2));
	const vec3  color1 = pow(vec3(0.75, 0.40, 0.93), vec3(2.2));
	const vec3  color2 = pow(vec3(0.20, 0.70, 0.90), vec3(2.2));

	vec3 screen_pos = vec3(gl_FragCoord.xy * view_pixel_size * rcp(taau_render_scale), gl_FragCoord.z);
	vec3 view_pos = screen_to_view_space(screen_pos, true);
	vec3 scene_pos = view_to_scene_space(view_pos);

	vec3 world_pos = scene_pos + cameraPosition;
	vec3 world_dir = normalize(scene_pos - gbufferModelViewInverse[3].xyz);

	// Get tangent-space position/direction without tangent/bitangent

	vec2 tangent_pos, tangent_dir;
	if (abs(tbn[2].x) > 0.5) {
		tangent_pos = world_pos.yz;
		tangent_dir = world_dir.yz / abs(world_dir.x + eps);
	} else if (abs(tbn[2].y) > 0.5) {
		tangent_pos = world_pos.xz;
		tangent_dir = world_dir.xz / abs(world_dir.y + eps);
	} else {
		tangent_pos = world_pos.xy;
		tangent_dir = world_dir.xy / abs(world_dir.z + eps);
	}

	vec3 result = vec3(0.0);

	for (int i = 0; i < layer_count; ++i) {
		// Random layer offset
		vec2 layer_offset = r2(i) * 512.0;

		// Make layers drift over time
		float angle = i * golden_angle;
		vec2 drift = 0.033 * vec2(cos(angle), sin(angle)) * frameTimeCounter * r1(i);

		// Snap tangent_pos to a grid and calculate a seed for the RNG
		ivec2 grid_pos = ivec2((tangent_pos + drift) * 32.0 + layer_offset);
		uint seed = uint(80000 * grid_pos.y + grid_pos.x);

		// 4 random numbers for this grid cell
		vec4 random = rand_next_vec4(seed);

		// Twinkling animation
		float twinkle_offset = tau * random.w;
		random.x *= 1.0 - twinkle_amount * cos(frameTimeCounter * twinkle_speed + twinkle_offset);

		// Stomp all values below threshold to zero
		float intensity = pow8(linear_step(threshold, 1.0, random.x));

		// Blend between the 3 colors
		vec3 color = mix(color0, color1, random.y);
		     color = mix(color, color2, random.z);

		// Fade away with depth
		float fade = exp2(-depth_fade * float(i));

		result += color * intensity * exp2(-3.0 * (1.0 - fade) * (1.0 - color)) * fade;

		// Step along the view ray
		tangent_pos += tangent_dir * depth_scale * gbufferProjection[1][1] * rcp(1.37);

		if (random.x > threshold) break;
	}

	result *= 0.8;
	result  = sqrt(result);
	result *= sqrt(result);

	return result;
}
#endif

const float lod_bias = log2(taau_render_scale);

#if defined PROGRAM_GBUFFERS_TERRAIN && defined POM
	#define read_tex(x) textureGrad(x, parallax_uv, uv_gradient[0], uv_gradient[1])
#else
	#define read_tex(x) texture(x, uv, lod_bias)
#endif

void main()
{
#if defined TAA && defined TAAU
	vec2 coord = gl_FragCoord.xy * view_pixel_size * rcp(taau_render_scale);
	if (clamp01(coord) != coord) discard;
#endif

	bool parallax_shadow = false;
	float dither = interleaved_gradient_noise(gl_FragCoord.xy, frameCounter);

#if defined PROGRAM_GBUFFERS_TERRAIN && defined POM
	float view_distance = length(tangent_pos);

	bool has_pom = view_distance < POM_DISTANCE; // Only calculate POM for close terrain
	     has_pom = has_pom && material_mask != 1 && material_mask != 8; // Do not calculate POM for water or lava

	vec3 tangent_dir = -normalize(tangent_pos);
	mat2 uv_gradient = mat2(dFdx(uv), dFdy(uv));

	vec2 parallax_uv;

	if (has_pom) {
		float pom_depth;
		vec3 shadow_trace_pos;

		parallax_uv = get_parallax_uv(tangent_dir, uv_gradient, view_distance, dither, shadow_trace_pos, pom_depth);
	#ifdef POM_SHADOW
		parallax_shadow = get_parallax_shadow(shadow_trace_pos, uv_gradient, view_distance, dither);
	#endif
	} else {
		parallax_uv = uv;
		parallax_shadow = false;
	}
#endif

	vec4 base_color   = read_tex(gtexture) * tint;
#ifdef NORMAL_MAPPING
	vec3 normal_map   = read_tex(normals).xyz;
#endif
#ifdef SPECULAR_MAPPING
	vec4 specular_map = read_tex(specular);
#endif

#if defined PROGRAM_GBUFFERS_ENTITIES
	if (base_color.a < 0.1 && material_mask != 101) discard; // Save transparent quad in boats, which material_masks out water
#else
	if (base_color.a < 0.1) discard;
#endif

#ifdef WHITE_WORLD
	base_color.rgb = vec3(1.0);
#endif

#if defined PROGRAM_GBUFFERS_TERRAIN && defined VANILLA_AO
	const float vanilla_ao_strength = 0.9;
	const float vanilla_ao_lift     = 0.5;
	base_color.rgb *= lift(vanilla_ao, vanilla_ao_lift) * vanilla_ao_strength + (1.0 - vanilla_ao_strength);
#endif

#if defined PROGRAM_GBUFFERS_ENTITIES
	base_color.rgb = mix(base_color.rgb, entityColor.rgb, entityColor.a);
#endif

#if defined PROGRAM_GBUFFERS_BLOCK
	// parallax end portal
	if (material_mask == 250) base_color.rgb = draw_end_portal();
#endif

#if defined PROGRAM_GBUFFERS_BEACONBEAM
	// Discard the translucent edge part of the beam
	if (base_color.a < 0.99) discard;
#endif

#ifdef NORMAL_MAPPING
	vec3 normal; float material_ao;
	decode_normal_map(normal_map, normal, material_ao);

#if defined PROGRAM_GBUFFERS_TERRAIN && defined POM && defined POM_SLOPE_NORMALS
#endif

	normal = tbn * normal;
#else
	const float material_ao = 1.0;
#endif

	gbuffer_data_0.x  = pack_unorm_2x8(base_color.rg);
	gbuffer_data_0.y  = pack_unorm_2x8(base_color.b, clamp01(float(material_mask) * rcp(255.0)));
	gbuffer_data_0.z  = pack_unorm_2x8(encode_unit_vector(tbn[2]));
	gbuffer_data_0.w  = pack_unorm_2x8(dither_8bit(light_levels * mix(0.7, 1.0, material_ao), dither));

#ifdef NORMAL_MAPPING
	gbuffer_data_1.xy = encode_unit_vector(normal);
#endif

#ifdef SPECULAR_MAPPING
#if defined POM && defined POM_SHADOW
	// Pack parallax shadow in alpha component of specular map
	// Specular map alpha >= 0.5 => parallax shadow
	specular_map.a *= step(specular_map.a, 0.999);
	specular_map.a  = clamp01(specular_map.a * 0.5 + 0.5 * float(parallax_shadow));
#endif

	gbuffer_data_1.z  = pack_unorm_2x8(specular_map.xy);
	gbuffer_data_1.w  = pack_unorm_2x8(specular_map.zw);
#endif
}

#endif
//----------------------------------------------------------------------------//
