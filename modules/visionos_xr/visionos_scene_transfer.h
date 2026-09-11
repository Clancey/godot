/**************************************************************************/
/*  visionos_scene_transfer.h                                             */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md).   */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                     */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining   */
/* a copy of this software and associated documentation files (the         */
/* "Software"), to deal in the Software without restriction, including     */
/* without limitation the rights to use, copy, modify, merge, publish,     */
/* distribute, sublicense, and/or sell copies of the Software, and to      */
/* permit persons to whom the Software is furnished to do so, subject to   */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,         */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,    */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE       */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#pragma once

#include "visionos_eye_transform.h"

#include <simd/simd.h>

#include <algorithm>
#include <cmath>

struct VisionOSSceneTransferParameters {
	simd_float4x4 destination_to_source;
	simd_float4x4 source_to_destination;
	simd_float4x4 destination_to_source_ray;
	simd_float4 source_viewport;
	simd_float4 destination_viewport;
	simd_float4 source_physical_bounds;
	uint32_t has_rate_map;
	uint32_t positional_reprojection;
	uint32_t alpha_blend = 0;
	uint32_t source_is_srgb = 0;
};

inline simd_double4 visionos_scene_loading_color(bool p_alpha_blend, double p_time) {
	if (p_alpha_blend) {
		return simd_make_double4(0, 0, 0, 0);
	}
	double loading = 0.02 + 0.01 * std::sin(p_time * 2.0);
	return simd_make_double4(loading, loading, loading, 1);
}

inline simd_float4 visionos_scene_physical_bounds(simd_float2 p_low, simd_float2 p_high, uint32_t p_width, uint32_t p_height) {
	// Include the physical texels whose centers lie in the logical viewport.
	return simd_make_float4(std::max(0.0f, std::ceil(p_low.x - 0.5f)), std::max(0.0f, std::ceil(p_low.y - 0.5f)),
			std::min(float(p_width), std::ceil(p_high.x - 0.5f)), std::min(float(p_height), std::ceil(p_high.y - 0.5f)));
}

struct VisionOSSceneDepthPyramidShape {
	uint32_t width = 1;
	uint32_t height = 1;
	uint32_t levels = 1;
};

inline VisionOSSceneDepthPyramidShape visionos_scene_depth_pyramid_shape(uint32_t p_width, uint32_t p_height) {
	VisionOSSceneDepthPyramidShape shape;
	while (shape.width < (p_width + 31) / 32) {
		shape.width *= 2;
	}
	while (shape.height < (p_height + 31) / 32) {
		shape.height *= 2;
	}
	for (uint32_t size = std::max(shape.width, shape.height); size > 1; size /= 2) {
		shape.levels++;
	}
	return shape;
}

inline bool visionos_scene_transfer_matrix_finite(const simd_float4x4 &p_matrix) {
	for (uint32_t column = 0; column < 4; column++) {
		for (uint32_t row = 0; row < 4; row++) {
			if (!std::isfinite(p_matrix.columns[column][row])) {
				return false;
			}
		}
	}
	return true;
}

inline VisionOSEyeTransformComparison visionos_scene_transfer_eye_mapping(
		const simd_float4x4 &p_source_eye, const simd_float4x4 &p_destination_eye,
		const simd_float4x4 &p_source_projection, const simd_float4x4 &p_destination_projection,
		VisionOSSceneTransferParameters &r_parameters) {
	VisionOSEyeTransformComparison comparison;
	comparison.compared = true;
	if (!visionos_scene_transfer_matrix_finite(p_source_eye) || !visionos_scene_transfer_matrix_finite(p_destination_eye)) {
		comparison.original_mismatch = true;
		comparison.rejection = VisionOSEyeTransformComparison::INVALID_TRANSFORM;
		return comparison;
	}
	constexpr float original_tolerance = 0.00001f;
	for (uint32_t column = 0; column < 4; column++) {
		for (uint32_t row = 0; row < 4; row++) {
			double delta = std::abs(p_destination_eye.columns[column][row] - p_source_eye.columns[column][row]);
			comparison.original_mismatch |= delta >= original_tolerance;
			if (column < 3 && row < 3) {
				comparison.basis_max_delta = std::max(comparison.basis_max_delta, delta);
			}
		}
		// Eye poses must be affine; a projective eye transform has no single
		// optical center for the depth-independent ray mapping below.
		float expected = column == 3 ? 1.0f : 0.0f;
		if (p_source_eye.columns[column].w != expected || p_destination_eye.columns[column].w != expected) {
			comparison.rejection = VisionOSEyeTransformComparison::INVALID_TRANSFORM;
		}
	}
	for (uint32_t axis = 0; axis < 3; axis++) {
		comparison.source_origin_m[axis] = p_source_eye.columns[3][axis];
		comparison.destination_origin_m[axis] = p_destination_eye.columns[3][axis];
		comparison.translation_m[axis] = p_destination_eye.columns[3][axis] - p_source_eye.columns[3][axis];
		comparison.positional_reprojection |= comparison.translation_m[axis] != 0;
	}
	simd_float4x4 source_basis = p_source_eye;
	simd_float4x4 destination_basis = p_destination_eye;
	source_basis.columns[3] = destination_basis.columns[3] = simd_make_float4(0, 0, 0, 1);
	simd_float4x4 source_from_destination = simd_mul(simd_inverse(source_basis), destination_basis);
	simd_float4x4 destination_from_source = simd_mul(simd_inverse(destination_basis), source_basis);
	if (!visionos_scene_transfer_matrix_finite(source_from_destination) || !visionos_scene_transfer_matrix_finite(destination_from_source)) {
		comparison.rejection = VisionOSEyeTransformComparison::INVALID_TRANSFORM;
	}
	if (comparison.rejection != VisionOSEyeTransformComparison::NONE) {
		return comparison;
	}
	simd_quatf rotation = simd_quaternion(source_from_destination);
	comparison.rotation_degrees = 2.0 * std::atan2(simd_length(rotation.vector.xyz), std::abs(rotation.vector.w)) * (180.0 / 3.14159265358979323846);
	if (!std::isfinite(comparison.rotation_degrees)) {
		comparison.rotation_degrees = 0;
		comparison.rejection = VisionOSEyeTransformComparison::INVALID_TRANSFORM;
		return comparison;
	}
	r_parameters.destination_to_source_ray = simd_mul(simd_mul(p_source_projection, source_from_destination), simd_inverse(p_destination_projection));
	// Subtract origins before rotating, so equal origins remain exactly zero.
	// Both eye poses are relative to the retained source head anchor.
	simd_float4 displacement = p_destination_eye.columns[3] - p_source_eye.columns[3];
	source_from_destination.columns[3] = simd_mul(simd_inverse(source_basis), displacement);
	destination_from_source.columns[3] = simd_mul(simd_inverse(destination_basis), -displacement);
	source_from_destination.columns[3].w = destination_from_source.columns[3].w = 1;
	r_parameters.destination_to_source = simd_mul(simd_mul(p_source_projection, source_from_destination), simd_inverse(p_destination_projection));
	r_parameters.source_to_destination = simd_mul(simd_mul(p_destination_projection, destination_from_source), simd_inverse(p_source_projection));
	r_parameters.positional_reprojection = comparison.positional_reprojection;
	if (!visionos_scene_transfer_matrix_finite(r_parameters.destination_to_source) || !visionos_scene_transfer_matrix_finite(r_parameters.source_to_destination) || !visionos_scene_transfer_matrix_finite(r_parameters.destination_to_source_ray)) {
		comparison.rejection = VisionOSEyeTransformComparison::INVALID_PROJECTION;
	}
	return comparison;
}

static constexpr const char *VISIONOS_SCENE_TRANSFER_SHADER = R"METAL(
#include <metal_stdlib>
#include <metal_graphics>
using namespace metal;
kernel void scene_depth_tiles(texture2d_array<float, access::read> depth [[texture(0)]],
		texture2d_array<float, access::write> tiles [[texture(1)]],
		constant float4 *physical_bounds [[buffer(0)]],
		uint3 group [[threadgroup_position_in_grid]], uint3 local [[thread_position_in_threadgroup]],
		uint index [[thread_index_in_threadgroup]]) {
	threadgroup float values[256];
	float value = 0.0;
	float4 bounds = physical_bounds[group.z];
	for (uint y = 0; y < 2; y++) {
		for (uint x = 0; x < 2; x++) {
			uint2 pixel = group.xy * 32 + local.xy * 2 + uint2(x, y);
			float2 center = float2(pixel) + 0.5;
			if (all(pixel < uint2(depth.get_width(), depth.get_height())) &&
					all(center >= bounds.xy) && all(center < bounds.zw)) {
				float sample = depth.read(pixel, group.z).x;
				value = max(value, isfinite(sample) && sample >= 0.0 && sample <= 1.0 ? sample : 1.0);
			}
		}
	}
	values[index] = value;
	threadgroup_barrier(mem_flags::mem_threadgroup);
	for (uint stride = 128; stride > 0; stride /= 2) {
		if (index < stride) {
			values[index] = max(values[index], values[index + stride]);
		}
		threadgroup_barrier(mem_flags::mem_threadgroup);
	}
	if (index == 0) {
		tiles.write(float4(values[0]), group.xy, group.z);
	}
}
kernel void scene_depth_mip(texture2d_array<float, access::read> source [[texture(0)]],
		texture2d_array<float, access::write> destination [[texture(1)]],
		uint3 pixel [[thread_position_in_grid]]) {
	if (any(pixel.xy >= uint2(destination.get_width(), destination.get_height()))) {
		return;
	}
	float value = 0.0;
	for (uint y = 0; y < 2; y++) {
		for (uint x = 0; x < 2; x++) {
			uint2 child = pixel.xy * 2 + uint2(x, y);
			if (all(child < uint2(source.get_width(), source.get_height()))) {
				value = max(value, source.read(child, pixel.z).x);
			}
		}
	}
	destination.write(float4(value), pixel.xy, pixel.z);
}
struct Parameters {
	float4x4 destination_to_source;
	float4x4 source_to_destination;
	float4x4 destination_to_source_ray;
	float4 source_viewport;
	float4 destination_viewport;
	float4 source_physical_bounds;
	uint has_rate_map;
	uint positional_reprojection;
	uint alpha_blend;
	uint source_is_srgb;
};
struct Vertex {
	float4 position [[position]];
	float2 uv;
	uint layer [[render_target_array_index]];
	uint viewport [[viewport_array_index]];
};
vertex Vertex scene_transfer_vertex(uint vertex_id [[vertex_id]], uint instance_id [[instance_id]]) {
	float2 position = float2((vertex_id << 1) & 2, vertex_id & 2);
	return {float4(position * 2.0 - 1.0, 0.0, 1.0), float2(position.x, 1.0 - position.y), instance_id, instance_id};
}
struct Fragment {
	half4 color [[color(0)]];
	float depth [[depth(any)]];
};
Fragment scene_composite_sample(half4 color, float depth, constant Parameters &p) {
	if (!p.alpha_blend) {
		return {color, depth};
	}
	// Keep transparent occluder depth during visibility traversal, but never
	// submit it (or a zero-depth background) as visible mixed-immersion content.
	if (!all(isfinite(color)) || color.a <= 0.0h || !isfinite(depth) || depth <= 0.0 || depth > 1.0) {
		return {half4(0.0), 0.0};
	}
	float3 rgb = float3(color.rgb);
	if (p.source_is_srgb) {
		rgb = select(pow(max((rgb + 0.055) / 1.055, float3(0.0)), float3(2.4)),
				rgb / 12.92, rgb <= 0.04045);
	}
	// Godot's scene blend already associates RGB with alpha. Decode the
	// tonemapper's optional sRGB encoding, then map linear Rec.709 to Display P3.
	float3 p3 = float3(
			dot(rgb, float3(0.82246197, 0.17753803, 0.0)),
			dot(rgb, float3(0.03319420, 0.96680580, 0.0)),
			dot(rgb, float3(0.01708263, 0.07239744, 0.91051993)));
	return {half4(half3(p3), min(color.a, 1.0h)), depth};
}
float2 scene_screen_to_physical(float2 screen, uint layer, constant Parameters &p,
		constant rasterization_rate_map_data &rate_data) {
	if (p.has_rate_map) {
		rasterization_rate_map_decoder decoder(rate_data);
		return decoder.map_screen_to_physical_coordinates(screen, layer);
	}
	return screen;
}
float2 scene_physical_to_screen(float2 physical, uint layer, constant Parameters &p,
		constant rasterization_rate_map_data &rate_data) {
	if (p.has_rate_map) {
		rasterization_rate_map_decoder decoder(rate_data);
		return decoder.map_physical_to_screen_coordinates(physical, layer);
	}
	return physical;
}
bool scene_clip_plane(float near_value, float far_value, thread float &begin, thread float &end) {
	if (near_value < 0.0 && far_value < 0.0) {
		return false;
	}
	if (near_value < 0.0) {
		begin = max(begin, near_value / (near_value - far_value));
	}
	if (far_value < 0.0) {
		end = min(end, near_value / (near_value - far_value));
	}
	return begin <= end;
}
Fragment scene_background(float2 destination_ndc, uint layer, constant Parameters &p,
		texture2d_array<half> color, depth2d_array<float> depth,
		constant rasterization_rate_map_data &rate_data) {
	float4 source = p.destination_to_source_ray * float4(destination_ndc, 0.5, 1.0);
	float2 uv = float2(source.x / source.w * 0.5 + 0.5, 0.5 - source.y / source.w * 0.5);
	if (source.w <= 0.0 || any(uv < 0.0) || any(uv > 1.0)) {
		return {half4(0.0), 0.0};
	}
	float2 physical = scene_screen_to_physical(uv * p.source_viewport.zw + p.source_viewport.xy, layer, p, rate_data);
	if (any(physical < p.source_physical_bounds.xy) || any(physical >= p.source_physical_bounds.zw)) {
		return {half4(0.0), 0.0};
	}
	float2 texture_uv = physical / float2(color.get_width(), color.get_height());
	constexpr sampler nearest_sampler(coord::normalized, address::clamp_to_edge, filter::nearest);
	if (depth.sample(nearest_sampler, texture_uv, layer) == 0.0) {
		return scene_composite_sample(color.sample(nearest_sampler, texture_uv, layer), 0.0, p);
	}
	// A direction hidden by a source surface contains no known background.
	return {half4(0.0), 0.0};
}
Fragment scene_positional_transfer(float2 destination_ndc, uint layer, constant Parameters &p,
		texture2d_array<half> color, depth2d_array<float> depth,
		texture2d_array<float, access::read> hierarchy,
		constant rasterization_rate_map_data &rate_data) {
	int top_level = int(hierarchy.get_num_mip_levels()) - 1;
	float nearest_depth = hierarchy.read(uint2(0), layer, top_level).x;
	if (nearest_depth == 0.0) {
		return scene_background(destination_ndc, layer, p, color, depth, rate_data);
	}
	float4 near_clip = p.destination_to_source * float4(destination_ndc, 1.0, 1.0);
	float4 far_clip = p.destination_to_source * float4(destination_ndc, 0.0, 1.0);
	float2 known_low = scene_physical_to_screen(p.source_physical_bounds.xy, layer, p, rate_data);
	float2 known_high = scene_physical_to_screen(p.source_physical_bounds.zw, layer, p, rate_data);
	float2 uv_low = (known_low - p.source_viewport.xy) / p.source_viewport.zw;
	float2 uv_high = (known_high - p.source_viewport.xy) / p.source_viewport.zw;
	float3 ndc_low = max(float3(-1.0, -1.0, 0.0), float3(uv_low.x * 2.0 - 1.0, 1.0 - uv_high.y * 2.0, 0.0));
	float3 ndc_high = min(float3(1.0), float3(uv_high.x * 2.0 - 1.0, 1.0 - uv_low.y * 2.0, 1.0));
	float begin = 0.0, end = 1.0;
	if (!scene_clip_plane(near_clip.x - ndc_low.x * near_clip.w, far_clip.x - ndc_low.x * far_clip.w, begin, end) ||
			!scene_clip_plane(ndc_high.x * near_clip.w - near_clip.x, ndc_high.x * far_clip.w - far_clip.x, begin, end) ||
			!scene_clip_plane(near_clip.y - ndc_low.y * near_clip.w, far_clip.y - ndc_low.y * far_clip.w, begin, end) ||
			!scene_clip_plane(ndc_high.y * near_clip.w - near_clip.y, ndc_high.y * far_clip.w - far_clip.y, begin, end) ||
			!scene_clip_plane(near_clip.z, far_clip.z, begin, end) ||
			!scene_clip_plane(near_clip.w - near_clip.z, far_clip.w - far_clip.z, begin, end)) {
		return {half4(0.0), 0.0};
	}
	float4 clipped_begin = mix(near_clip, far_clip, begin);
	float4 clipped_end = mix(near_clip, far_clip, end);
	if (clipped_begin.w <= 0.0 || clipped_end.w <= 0.0) {
		return {half4(0.0), 0.0};
	}
	float3 ray_begin = clipped_begin.xyz / clipped_begin.w;
	float3 ray_end = clipped_end.xyz / clipped_end.w;
	if (!all(isfinite(ray_begin)) || !all(isfinite(ray_end))) {
		return {half4(0.0), 0.0};
	}
	// Roundoff at clipped frustum boundaries must not select an outside texel.
	ray_begin = clamp(ray_begin, ndc_low, ndc_high);
	ray_end = clamp(ray_end, ndc_low, ndc_high);
	// No source surface lies in front of this per-eye maximum. Stay one
	// representable depth in front of it when shortening the ray.
	float skip_depth = nextafter(nearest_depth, 1.0);
	if (ray_begin.z > skip_depth && ray_end.z < skip_depth) {
		ray_begin = mix(ray_begin, ray_end, (ray_begin.z - skip_depth) / (ray_begin.z - ray_end.z));
		ray_begin.z = skip_depth;
	}
	float2 screen_begin = (float2(ray_begin.x, -ray_begin.y) * 0.5 + 0.5) * p.source_viewport.zw + p.source_viewport.xy;
	float2 screen_end = (float2(ray_end.x, -ray_end.y) * 0.5 + 0.5) * p.source_viewport.zw + p.source_viewport.xy;
	float2 screen_delta = screen_end - screen_begin;
	float z_delta = ray_end.z - ray_begin.z;
	int2 size = int2(depth.get_width(), depth.get_height());
	int2 valid_low = int2(p.source_physical_bounds.xy);
	int2 valid_high = int2(p.source_physical_bounds.zw);
	int2 cell = clamp(int2(floor(scene_screen_to_physical(screen_begin, layer, p, rate_data))), valid_low, valid_high - 1);
	int2 step = int2(screen_delta.x < 0.0 ? -1 : 1, screen_delta.y < 0.0 ? -1 : 1);
	float entry = 0.0;
	int level = top_level;
	constexpr sampler nearest_sampler(coord::normalized, address::clamp_to_edge, filter::nearest);
	// A max-depth block can only skip empty space or space strictly in front
	// of every source surface. Otherwise descend to individual texel planes.
	#pragma clang loop unroll(disable)
	for (uint visit = 0; visit < 64; visit++) {
		if (any(cell < valid_low) || any(cell >= valid_high)) {
			return {half4(0.0), 0.0};
		}
		int span = level < 0 ? 1 : 32 << level;
		int2 block = cell / span;
		int2 block_low = max(block * span, valid_low);
		int2 block_high = min(block * span + span, valid_high);
		float2 low = scene_physical_to_screen(float2(block_low), layer, p, rate_data);
		float2 high = scene_physical_to_screen(float2(block_high), layer, p, rate_data);
		float2 boundary = float2(step.x > 0 ? high.x : low.x, step.y > 0 ? high.y : low.y);
		float cross_x = screen_delta.x == 0.0 ? 1e30 : (boundary.x - screen_begin.x) / screen_delta.x;
		float cross_y = screen_delta.y == 0.0 ? 1e30 : (boundary.y - screen_begin.y) / screen_delta.y;
		float exit = max(entry, min(1.0, min(cross_x, cross_y)));
		float entry_z = ray_begin.z + entry * z_delta;
		float exit_z = ray_begin.z + exit * z_delta;
		if (level >= 0) {
			float maximum = hierarchy.read(uint2(block), layer, level).x;
			if (maximum != 0.0 && maximum >= min(entry_z, exit_z)) {
				level--;
				continue;
			}
		}
		if (exit > entry) {
			float2 texture_uv = (float2(cell) + 0.5) / float2(size);
			float sample_depth = level < 0 ? depth.sample(nearest_sampler, texture_uv, layer) : 0.0;
			if (!isfinite(sample_depth) || sample_depth < 0.0 || sample_depth > 1.0) {
				return {half4(0.0), 0.0};
			}
			if (sample_depth > 0.0) {
				if (sample_depth > entry_z) {
					// This ray enters space hidden behind a source surface.
					// Its unseen contents cannot be supplied by a farther texel.
					return {half4(0.0), 0.0};
				}
				if (sample_depth >= exit_z && z_delta < 0.0) {
					float hit = clamp((sample_depth - ray_begin.z) / z_delta, entry, exit);
					float3 source_ndc = mix(ray_begin, ray_end, hit);
					float4 destination = p.source_to_destination * float4(source_ndc.xy, sample_depth, 1.0);
					if (destination.w <= 0.0 || destination.z < 0.0 || destination.z > destination.w) {
						return {half4(0.0), 0.0};
					}
					return scene_composite_sample(color.sample(nearest_sampler, texture_uv, layer), destination.z / destination.w, p);
				}
			}
		}
		if (exit >= 1.0) {
			return scene_background(destination_ndc, layer, p, color, depth, rate_data);
		}
		int2 previous_cell = cell;
		if (level >= 0) {
			float2 next_physical = scene_screen_to_physical(screen_begin + screen_delta * exit, layer, p, rate_data);
			cell = clamp(int2(floor(next_physical)), block_low, block_high - 1);
		}
		if (cross_x <= cross_y) {
			cell.x = step.x > 0 ? block_high.x : block_low.x - 1;
		}
		if (cross_y <= cross_x) {
			cell.y = step.y > 0 ? block_high.y : block_low.y - 1;
		}
		if (level >= 0) {
			level = min(level + 1, top_level);
		} else if (any(previous_cell / 32 != cell / 32)) {
			level = 0;
		}
		entry = exit;
	}
	return {half4(0.0), 0.0};
}
fragment Fragment scene_transfer_fragment(Vertex in [[stage_in]],
		texture2d_array<half> color [[texture(0)]],
		depth2d_array<float> depth [[texture(1)]],
		texture2d_array<float, access::read> hierarchy [[texture(2)]],
		constant Parameters *parameters [[buffer(0)]],
		constant rasterization_rate_map_data &rate_data [[buffer(1)]]) {
	constant Parameters &p = parameters[in.layer];
	// Fragment position is physical under VRS; the interpolant retains the
	// destination's logical view coordinates.
	float2 uv = in.uv;
	if (p.positional_reprojection) {
		return scene_positional_transfer(float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0), in.layer, p, color, depth, hierarchy, rate_data);
	}
	float4 source = p.destination_to_source * float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.5, 1.0);
	float2 source_ndc = source.xy / source.w;
	float2 source_uv = float2(source_ndc.x * 0.5 + 0.5, 0.5 - source_ndc.y * 0.5);
	if (source.w <= 0.0 || any(source_uv < 0.0) || any(source_uv > 1.0)) {
		return {half4(0.0), 0.0};
	}
	float2 physical = source_uv * p.source_viewport.zw + p.source_viewport.xy;
	if (p.has_rate_map) {
		rasterization_rate_map_decoder decoder(rate_data);
		physical = decoder.map_screen_to_physical_coordinates(physical, in.layer);
	}
	if (any(physical < p.source_physical_bounds.xy) || any(physical >= p.source_physical_bounds.zw)) {
		return {half4(0.0), 0.0};
	}
	float2 texture_uv = physical / float2(color.get_width(), color.get_height());
	constexpr sampler nearest_sampler(coord::normalized, address::clamp_to_edge, filter::nearest);
	half4 sample_color = color.sample(nearest_sampler, texture_uv, in.layer);
	float sample_depth = depth.sample(nearest_sampler, texture_uv, in.layer);
	// Reverse-Z clear depth has no surface to reproject. Preserve background
	// color without turning it into clipped geometry at a finite far plane.
	if (sample_depth == 0.0) {
		return scene_composite_sample(sample_color, 0.0, p);
	}
	float4 destination = p.source_to_destination * float4(source_ndc, sample_depth, 1.0);
	if (destination.w <= 0.0 || destination.z < 0.0 || destination.z > destination.w) {
		return {half4(0.0), 0.0};
	}
	return scene_composite_sample(sample_color, destination.z / destination.w, p);
}
)METAL";
