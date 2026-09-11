/**************************************************************************/
/*  visionos_presentation.mm                                              */
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

#include "visionos_presentation.h"

#include "visionos_frame_lifecycle.h"
#include "visionos_scene_transfer.h"
#include "visionos_simd_helpers.h"
#include "visionos_tracking.h"

#import <QuartzCore/QuartzCore.h>

#include <algorithm>

std::shared_ptr<VisionOSStartupDiagnostics> visionos_get_startup_diagnostics() {
	static std::shared_ptr<VisionOSStartupDiagnostics> diagnostics = [] {
		id enabled = NSBundle.mainBundle.infoDictionary[@"GodotVisionOSStartupDiagnostics"];
		id expected = NSBundle.mainBundle.infoDictionary[@"GodotVisionOSStartupDiagnosticsBundleIdentifier"];
		NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
		if (![enabled isKindOfClass:NSNumber.class] || ![expected isKindOfClass:NSString.class] || !bundle ||
				!visionos_startup_diagnostics_opt_in([enabled boolValue], bundle.UTF8String, [expected UTF8String])) {
			return std::shared_ptr<VisionOSStartupDiagnostics>();
		}
		return std::make_shared<VisionOSStartupDiagnostics>(CACurrentMediaTime());
	}();
	return diagnostics;
}

namespace {

NSString *startup_reason(VisionOSStartupDiagnostics::Reason p_reason) {
	switch (p_reason) {
		case VisionOSStartupDiagnostics::SCENE:
			return @"scene";
		case VisionOSStartupDiagnostics::NO_OUTPUT:
			return @"no_output";
		case VisionOSStartupDiagnostics::TRACKING_UNAVAILABLE:
			return @"tracking_unavailable";
		case VisionOSStartupDiagnostics::SOURCE_EXPIRED:
			return @"source_expired";
		case VisionOSStartupDiagnostics::PIPELINE_PENDING:
			return @"pipeline_pending";
		case VisionOSStartupDiagnostics::SOURCE_ANCHOR_MISSING:
			return @"source_anchor_missing";
		case VisionOSStartupDiagnostics::EYE_MISMATCH:
			return @"eye_mismatch";
		case VisionOSStartupDiagnostics::ENCODING_FAILED:
			return @"encoding_failed";
		default:
			return @"unknown";
	}
}

NSDictionary *startup_source(const VisionOSStartupDiagnostics::Source &p_source) {
	return @{@"layer" : @(p_source.layer),
		@"generation" : @(p_source.generation),
		@"sequence" : @(p_source.sequence),
		@"age_ms" : @(p_source.age_ms)};
}

NSString *startup_eye_rejection(VisionOSEyeTransformComparison::Rejection p_rejection) {
	switch (p_rejection) {
		case VisionOSEyeTransformComparison::NONE:
			return @"none";
		case VisionOSEyeTransformComparison::TRANSLATION:
			return @"translation";
		case VisionOSEyeTransformComparison::INVALID_TRANSFORM:
			return @"invalid_transform";
		case VisionOSEyeTransformComparison::INVALID_PROJECTION:
			return @"invalid_projection";
		default:
			return @"unknown";
	}
}

NSArray *startup_vector(const std::array<double, 3> &p_vector) {
	return @[ @(p_vector[0]), @(p_vector[1]), @(p_vector[2]) ];
}

NSArray *startup_eyes(const std::array<VisionOSEyeTransformComparison, 2> &p_eyes) {
	NSMutableArray *eyes = [NSMutableArray array];
	for (const auto &eye : p_eyes) {
		[eyes addObject:@{@"compared" : @(eye.compared),
			@"original_mismatch" : @(eye.original_mismatch),
			@"positional_reprojection" : @(eye.positional_reprojection),
			@"rejected_component" : startup_eye_rejection(eye.rejection),
			@"rotation_degrees" : @(eye.rotation_degrees),
			@"basis_max_delta" : @(eye.basis_max_delta),
			@"translation_m" : startup_vector(eye.translation_m),
			@"source_origin_m" : startup_vector(eye.source_origin_m),
			@"destination_origin_m" : startup_vector(eye.destination_origin_m),
			@"anchor_assignment_basis_max_delta" : @(eye.anchor_assignment_basis_max_delta),
			@"anchor_assignment_translation_m" : startup_vector(eye.anchor_assignment_translation_m)}];
	}
	return eyes;
}

void log_startup_diagnostics(const std::shared_ptr<VisionOSStartupDiagnostics> &p_diagnostics) {
	if (!p_diagnostics) {
		return;
	}
	auto report = p_diagnostics->take_report(CACurrentMediaTime());
	if (!report) {
		return;
	}
	const auto &r = *report;
	NSMutableDictionary *reasons = [NSMutableDictionary dictionary];
	NSMutableDictionary *ages = [NSMutableDictionary dictionary];
	for (int i = 0; i < VisionOSStartupDiagnostics::REASON_COUNT; i++) {
		NSString *name = startup_reason(static_cast<VisionOSStartupDiagnostics::Reason>(i));
		reasons[name] = @(r.reasons[i]);
		ages[name] = @(r.max_source_age_ms[i]);
	}
	NSMutableArray *transitions = [NSMutableArray array];
	NSMutableArray *eye_windows = [NSMutableArray array];
	for (const auto &eye : r.eye_windows) {
		NSMutableDictionary *outcomes = [NSMutableDictionary dictionary];
		for (int i = 0; i < VisionOSEyeTransformComparison::REJECTION_COUNT; i++) {
			outcomes[startup_eye_rejection(static_cast<VisionOSEyeTransformComparison::Rejection>(i))] = @(eye.rejections[i]);
		}
		[eye_windows addObject:@{@"samples" : @(eye.samples),
			@"original_mismatches" : @(eye.original_mismatches),
			@"positional_mappings" : @(eye.positional_mappings),
			@"mapping_outcomes" : outcomes,
			@"window_rotation_max_degrees" : @(eye.rotation_max_degrees),
			@"window_basis_max_delta" : @(eye.basis_max_delta),
			@"window_translation_max_abs_m" : startup_vector(eye.translation_max_abs_m),
			@"window_anchor_assignment_basis_max_delta" : @(eye.anchor_assignment_basis_max_delta),
			@"window_anchor_assignment_translation_max_abs_m" : startup_vector(eye.anchor_assignment_translation_max_abs_m)}];
	}
	for (uint32_t i = 0; i < r.transition_count; i++) {
		const auto &t = r.transitions[i];
		[transitions addObject:@{@"elapsed" : @(t.elapsed),
			@"from" : startup_reason(t.from),
			@"to" : startup_reason(t.to),
			@"source" : startup_source(t.source),
			@"eyes" : startup_eyes(t.eyes)}];
	}
	NSDictionary *record = @{
		@"schema" : @2,
		@"purpose" : @"startup evidence, not a flicker fix",
		@"bundle" : NSBundle.mainBundle.bundleIdentifier,
		@"report" : @(r.index),
		@"elapsed" : @(r.elapsed),
		@"reason_counts" : reasons,
		@"window_max_source_age_ms" : ages,
		@"new_sources_observed" : @(r.new_sources_observed),
		@"latest_source" : startup_source(r.latest_source),
		@"latest_eye_source" : startup_source(r.latest_eye_source),
		@"latest_eyes" : startup_eyes(r.latest_eyes),
		@"eye_windows" : eye_windows,
		@"last_reason" : startup_reason(r.last_reason),
		@"transitions" : transitions,
		@"transitions_omitted" : @(r.transitions_omitted),
		@"iterations_started" : @(r.iterations_started),
		@"iterations_completed" : @(r.iterations_completed),
		@"iterations_over_250ms" : @(r.iterations_over_250ms),
		@"window_iteration_max_ms" : @(r.iteration_max_ms),
		@"active_iteration_ms" : @(r.active_iteration_ms),
		@"producer_gpu_successes" : @(r.producer_completed),
		@"producer_gpu_failures" : @(r.producer_failed),
		@"producer_invalid_projection" : @(r.producer_invalid_projection),
		@"last_completed_source" : @[ @(r.last_completed_layer), @(r.last_completed_generation), @(r.last_completed_sequence) ],
		@"window_acquire_to_encode_max_ms" : @(r.acquire_to_encode_max_ms),
		@"window_encode_to_complete_max_ms" : @(r.encode_to_complete_max_ms),
		@"gpu_timed_samples" : @(r.gpu_timed_samples),
		@"window_gpu_max_ms" : @(r.gpu_max_ms),
		@"window_source_to_complete_max_ms" : @(r.source_to_complete_max_ms),
		@"presenter_gpu_successes" : @(r.presenter_completed),
		@"presenter_gpu_failures" : @(r.presenter_failed),
		@"window_presenter_gpu_max_ms" : @(r.presenter_gpu_max_ms),
		@"window_presenter_encode_to_complete_max_ms" : @(r.presenter_encode_to_complete_max_ms),
	};
	NSError *error = nil;
	NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:&error];
	if (!data) {
		NSLog(@"visionOS startup diagnostic serialization failed: %@", error);
		return;
	}
	NSLog(@"visionOS startup diagnostic %@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
}

struct CompositorFrameAPI {
	using Frame = cp_frame_t;
	using Timing = cp_frame_timing_t;
	using Drawable = cp_drawable_t;
	static Timing predict_timing(Frame p_frame) { return cp_frame_predict_timing(p_frame); }
	static void start_update(Frame p_frame) { cp_frame_start_update(p_frame); }
	static void end_update(Frame p_frame) { cp_frame_end_update(p_frame); }
	static void wait_until_input(Timing p_timing) { cp_time_wait_until(cp_frame_timing_get_optimal_input_time(p_timing)); }
	static void start_submission(Frame p_frame) { cp_frame_start_submission(p_frame); }
	static void end_submission(Frame p_frame) { cp_frame_end_submission(p_frame); }
	static Drawable query_drawable(Frame p_frame, bool &r_valid) {
		cp_drawable_array_t drawables = cp_frame_query_drawables(p_frame);
		size_t count = cp_drawable_array_get_count(drawables);
		r_valid = count != 0;
		for (size_t i = 0; i < count; i++) {
			Drawable drawable = cp_drawable_array_get_drawable(drawables, i);
			if (cp_drawable_get_target(drawable) == cp_drawable_target_built_in) {
				return drawable;
			}
		}
		return nullptr;
	}
};

struct TrackingSession {
	VisionOSTrackingAccess access;
	ar_session_t session = ar_session_create();
	ar_world_tracking_provider_t provider = ar_world_tracking_provider_create(ar_world_tracking_configuration_create());
	TrackingSession() {
		ar_data_providers_t providers = ar_data_providers_create();
		ar_data_providers_add_data_provider(providers, provider);
		ar_session_run(session, providers);
	}
};

TrackingSession &tracking_session() {
	static TrackingSession tracking;
	return tracking;
}

id<MTLTexture> make_target(id<MTLDevice> p_device, NSUInteger p_width, NSUInteger p_height, MTLPixelFormat p_format) {
	MTLTextureDescriptor *descriptor = [MTLTextureDescriptor new];
	descriptor.textureType = MTLTextureType2DArray;
	descriptor.pixelFormat = p_format;
	descriptor.width = p_width;
	descriptor.height = p_height;
	descriptor.arrayLength = 2;
	descriptor.storageMode = MTLStorageModePrivate;
	descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	return [p_device newTextureWithDescriptor:descriptor];
}

} // namespace

VisionOSTrackingAccess &visionos_tracking_access() {
	return tracking_session().access;
}

void visionos_run_tracking_session(ar_data_providers_t p_providers) {
	auto &tracking = tracking_session();
	tracking.access.perform([&] {
		ar_session_run(tracking.session, p_providers);
	});
}

VisionOSPresentation::VisionOSPresentation(cp_layer_renderer_t p_layer, cp_layer_renderer_capabilities_t p_capabilities, bool p_alpha_blend) :
		layer(p_layer), capabilities(p_capabilities), requested_alpha_blend(p_alpha_blend), alpha_blend(p_alpha_blend) {
	device = cp_layer_renderer_get_device(layer);
	queue = [device newCommandQueueWithMaxCommandBufferCount:3];
	queue.label = @"Godot compositor presentation";
	session = tracking_session().session;
	world_tracking = tracking_session().provider;
	startup_diagnostics = visionos_get_startup_diagnostics();
	if (startup_diagnostics) {
		static std::atomic<uint64_t> next_layer{ 1 };
		diagnostic_layer = next_layer.fetch_add(1);
	}
	float near_plane = cp_layer_renderer_capabilities_supported_minimum_near_plane_distance(capabilities);
	requested_depth_range = simd_make_float2(4000.0f, fmaxf(near_plane, 0.11f));
}

VisionOSPresentation::~VisionOSPresentation() {
	stop();
	presenter.join();
}

void VisionOSPresentation::start() {
	prepare_transfer();
	presenter.start([this] {
		pthread_setname_np("GodotCompositor");
		run();
	});
}

void VisionOSPresentation::stop() {
	presenter.get_completions()->startup.invalidate(true);
	presenter.request_stop();
	mailbox->close();
	std::lock_guard<std::mutex> lock(geometry_mutex);
	geometry.reset();
}

void VisionOSPresentation::request_depth_range(simd_float2 p_range) {
	std::lock_guard<std::mutex> lock(geometry_mutex);
	requested_depth_range = p_range;
}

std::shared_ptr<const VisionOSSceneGeometry> VisionOSPresentation::get_geometry() {
	std::lock_guard<std::mutex> lock(geometry_mutex);
	return geometry;
}

VisionOSPresentation::Lease VisionOSPresentation::acquire() {
	auto snapshot = get_geometry();
	if (!snapshot || presenter.is_stopping()) {
		return {};
	}
	auto lease = mailbox->acquire();
	if (!lease.output || lease.generation != snapshot->generation) {
		return {};
	}
	auto &output = *lease.output;
	output.geometry = snapshot;
	output.projection_valid = true;
	output.transparent_background = false;
	output.color_is_srgb = true;
	if (startup_diagnostics && startup_diagnostics->is_active()) {
		output.diagnostic_source = { diagnostic_layer, lease.generation, lease.sequence, 0 };
		output.diagnostic_acquired_at = CACurrentMediaTime();
	}
	if (!output.color || output.color.width != snapshot->width || output.color.height != snapshot->height ||
			output.color.pixelFormat != snapshot->color_format || output.depth.pixelFormat != snapshot->depth_format) {
		output.color = make_target(device, snapshot->width, snapshot->height, snapshot->color_format);
		output.depth = make_target(device, snapshot->width, snapshot->height, snapshot->depth_format);
	}
	if (!output.color || !output.depth) {
		NSLog(@"visionOS scene target allocation failed (%lux%lu).", snapshot->width, snapshot->height);
		return {};
	}
	auto pyramid_shape = visionos_scene_depth_pyramid_shape(snapshot->width, snapshot->height);
	if (!output.depth_pyramid || output.depth_pyramid.width != pyramid_shape.width || output.depth_pyramid.height != pyramid_shape.height || output.depth_pyramid_views.count != pyramid_shape.levels) {
		MTLTextureDescriptor *descriptor = [MTLTextureDescriptor new];
		descriptor.textureType = MTLTextureType2DArray;
		descriptor.pixelFormat = MTLPixelFormatR32Float;
		descriptor.width = pyramid_shape.width;
		descriptor.height = pyramid_shape.height;
		descriptor.mipmapLevelCount = pyramid_shape.levels;
		descriptor.arrayLength = 2;
		descriptor.storageMode = MTLStorageModePrivate;
		descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsagePixelFormatView;
		output.depth_pyramid = [device newTextureWithDescriptor:descriptor];
		NSMutableArray<id<MTLTexture>> *views = [NSMutableArray array];
		for (uint32_t level = 0; level < pyramid_shape.levels; level++) {
			id<MTLTexture> view = [output.depth_pyramid newTextureViewWithPixelFormat:MTLPixelFormatR32Float textureType:MTLTextureType2DArray levels:NSMakeRange(level, 1) slices:NSMakeRange(0, 2)];
			if (!view) {
				break;
			}
			[views addObject:view];
		}
		output.depth_pyramid_views = [views copy];
	}
	if (!output.depth_pyramid || output.depth_pyramid_views.count != pyramid_shape.levels) {
		NSLog(@"visionOS scene depth hierarchy allocation failed.");
		return {};
	}
	if (snapshot->rate_map) {
		MTLSizeAndAlign size = snapshot->rate_map.parameterBufferSizeAndAlign;
		if (!output.rate_parameters || output.rate_parameters.length < size.size) {
			output.rate_parameters = [device newBufferWithLength:size.size options:MTLResourceStorageModeShared];
		}
		if (!output.rate_parameters) {
			NSLog(@"visionOS scene rate-map parameter allocation failed.");
			return {};
		}
		[snapshot->rate_map copyParameterDataToBuffer:output.rate_parameters offset:0];
	}
	return lease;
}

void VisionOSPresentation::complete(const Lease &p_lease, id<MTLCommandBuffer> p_command) {
	auto outputs = mailbox;
	Lease lease = p_lease;
	bool projection_valid = lease.output->projection_valid;
	bool compositing_valid = !lease.output->geometry->alpha_blend || lease.output->transparent_background;
	bool valid = projection_valid && compositing_valid && pipeline_ready.load(std::memory_order_acquire) && encode_depth_pyramid(*lease.output, p_command);
	auto diagnostics = startup_diagnostics && startup_diagnostics->is_active() ? startup_diagnostics : nullptr;
	auto source = lease.output->diagnostic_source;
	double acquired_at = lease.output->diagnostic_acquired_at;
	double encoded_at = diagnostics ? CACurrentMediaTime() : 0;
	double source_time = lease.output->geometry->presentation_time;
	[p_command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
		bool success = completed.status == MTLCommandBufferStatusCompleted;
		if (!success) {
			NSLog(@"visionOS scene command failed: %@", completed.error);
		}
		outputs->complete(lease, success && valid);
		if (diagnostics) {
			double completed_at = CACurrentMediaTime();
			auto completed_source = source;
			completed_source.age_ms = (completed_at - source_time) * 1000.0;
			double gpu_ms = completed.GPUStartTime > 0 && completed.GPUEndTime >= completed.GPUStartTime ? (completed.GPUEndTime - completed.GPUStartTime) * 1000.0 : 0;
			diagnostics->producer_complete(completed_source, success, projection_valid, (encoded_at - acquired_at) * 1000.0, (completed_at - encoded_at) * 1000.0, gpu_ms);
		}
	}];
}

bool VisionOSPresentation::encode_depth_pyramid(const VisionOSSceneOutput &p_output, id<MTLCommandBuffer> p_command) {
	for (NSUInteger level = 0; level < p_output.depth_pyramid_views.count; level++) {
		id<MTLComputeCommandEncoder> encoder = [p_command computeCommandEncoder];
		if (!encoder) {
			NSLog(@"visionOS scene depth hierarchy could not encode level %lu.", level);
			return false;
		}
		id<MTLTexture> target = p_output.depth_pyramid_views[level];
		if (level == 0) {
			[encoder setComputePipelineState:depth_tiles_pipeline];
			[encoder setTexture:p_output.depth atIndex:0];
			[encoder setBytes:p_output.geometry->physical_bounds length:sizeof(p_output.geometry->physical_bounds) atIndex:0];
			[encoder setTexture:target atIndex:1];
			[encoder dispatchThreadgroups:MTLSizeMake(target.width, target.height, 2) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		} else {
			[encoder setComputePipelineState:depth_mip_pipeline];
			[encoder setTexture:p_output.depth_pyramid_views[level - 1] atIndex:0];
			[encoder setTexture:target atIndex:1];
			[encoder dispatchThreadgroups:MTLSizeMake((target.width + 7) / 8, (target.height + 7) / 8, 2) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
		}
		[encoder endEncoding];
	}
	return true;
}

void VisionOSPresentation::pipeline_prepared() {
	if (prepared_pipelines.fetch_add(1, std::memory_order_acq_rel) == 2) {
		pipeline_ready.store(true, std::memory_order_release);
		presenter.get_completions()->startup.set_preparing(false);
	}
}

void VisionOSPresentation::run() {
	bool paused = false;
	while (!presenter.is_stopping()) {
		@autoreleasepool {
			// Serialization and logging happen outside any acquired CP frame.
			log_startup_diagnostics(startup_diagnostics);
			cp_layer_renderer_state state = cp_layer_renderer_get_state(layer);
			if (state == cp_layer_renderer_state_invalidated) {
				stop();
				break;
			}
			if (state == cp_layer_renderer_state_paused) {
				if (!paused) {
					mailbox->invalidate();
					presenter.get_completions()->startup.invalidate();
					std::lock_guard<std::mutex> lock(geometry_mutex);
					geometry.reset();
				}
				paused = true;
				std::this_thread::sleep_for(std::chrono::milliseconds(2));
				continue;
			}
			paused = false;
			if (presenter.get_completions()->in_flight.load() < 3) {
				present();
			} else {
				std::this_thread::sleep_for(std::chrono::milliseconds(1));
			}
		}
	}
}

void VisionOSPresentation::present() {
	bool requested = requested_alpha_blend.load(std::memory_order_acquire);
	if (requested != alpha_blend) {
		// Old in-flight leases retain their GPU resources, but cannot publish
		// an opaque render into the new mixed-immersion generation.
		mailbox->invalidate();
		presenter.get_completions()->startup.invalidate();
		std::lock_guard<std::mutex> lock(geometry_mutex);
		geometry.reset();
		alpha_blend = requested;
	}
	VisionOSFrameLifecycle<CompositorFrameAPI> frame;
	if (!frame.begin(cp_layer_renderer_query_next_frame(layer))) {
		std::this_thread::sleep_for(std::chrono::milliseconds(1));
		return;
	}
	frame.prepare();
	if (!frame.can_draw()) {
		frame.finish();
		return;
	}
	cp_drawable_t drawable = frame.get_drawable();
	if (presenter.is_stopping()) {
		frame.finish();
		return;
	}
	id<MTLTexture> color = cp_drawable_get_color_texture(drawable, 0);
	id<MTLTexture> depth = cp_drawable_get_depth_texture(drawable, 0);
	if (!color || !depth || color.textureType != MTLTextureType2DArray || color.arrayLength != 2 ||
			cp_drawable_get_view_count(drawable) != 2) {
		NSLog(@"visionOS compositor requires complete layered stereo targets.");
		presenter.get_completions()->startup.fail();
		frame.finish();
		stop();
		return;
	}
	double presentation_time = cp_time_to_cf_time_interval(cp_frame_timing_get_presentation_time(cp_drawable_get_frame_timing(drawable)));
	ar_device_anchor_t anchor = ar_device_anchor_create();
	std::array<simd_float4x4, 2> acquired_eyes{};
	bool tracked = tracking_session().access.perform([&] {
		return ar_world_tracking_provider_query_device_anchor_at_timestamp(world_tracking, presentation_time, anchor) == ar_device_anchor_query_status_success;
	});
	if (tracked) {
		cp_drawable_set_device_anchor(drawable, anchor);
		auto snapshot = std::make_shared<VisionOSSceneGeometry>();
		snapshot->generation = mailbox->generation();
		snapshot->alpha_blend = alpha_blend;
		snapshot->presentation_time = presentation_time;
		snapshot->trackable_time = cp_time_to_cf_time_interval(cp_frame_timing_get_trackable_anchor_time(frame.get_timing()));
		snapshot->origin_from_head = MTL::simd_to_transform3D(ar_anchor_get_origin_from_anchor_transform(anchor));
		snapshot->width = color.width;
		snapshot->height = color.height;
		snapshot->color_format = color.pixelFormat;
		snapshot->depth_format = depth.pixelFormat;
		snapshot->rate_map = cp_drawable_get_rasterization_rate_map_count(drawable) ? cp_drawable_get_rasterization_rate_map(drawable, 0) : nil;
		{
			std::lock_guard<std::mutex> lock(geometry_mutex);
			snapshot->depth_range = requested_depth_range;
		}
		cp_drawable_set_depth_range(drawable, snapshot->depth_range);
		for (uint32_t eye = 0; eye < 2; eye++) {
			cp_view_t view = cp_drawable_get_view(drawable, eye);
			cp_view_texture_map_t map = cp_view_get_view_texture_map(view);
			snapshot->viewport[eye] = cp_view_texture_map_get_viewport(map);
			const MTLViewport &viewport = snapshot->viewport[eye];
			MTLCoordinate2D low = { float(viewport.originX), float(viewport.originY) };
			MTLCoordinate2D high = { float(viewport.originX + viewport.width), float(viewport.originY + viewport.height) };
			if (snapshot->rate_map) {
				low = [snapshot->rate_map mapScreenToPhysicalCoordinates:low forLayer:eye];
				high = [snapshot->rate_map mapScreenToPhysicalCoordinates:high forLayer:eye];
			}
			snapshot->physical_bounds[eye] = visionos_scene_physical_bounds(simd_make_float2(low.x, low.y), simd_make_float2(high.x, high.y), snapshot->width, snapshot->height);
			snapshot->head_from_eye[eye] = cp_view_get_transform(view);
			acquired_eyes[eye] = snapshot->head_from_eye[eye];
			snapshot->projection[eye] = cp_drawable_compute_projection(drawable, cp_axis_direction_convention_right_up_forward, eye);
			if (cp_view_texture_map_get_texture_index(map) != 0 || cp_view_texture_map_get_slice_index(map) != eye) {
				NSLog(@"visionOS compositor returned an unsupported stereo texture mapping.");
				presenter.get_completions()->startup.fail();
				frame.finish();
				stop();
				return;
			}
		}
		{
			std::lock_guard<std::mutex> lock(geometry_mutex);
			if (!presenter.is_stopping()) {
				geometry = snapshot;
			}
		}
		source_anchors.erase(std::remove_if(source_anchors.begin(), source_anchors.end(), [](const SourceAnchor &p_anchor) {
			return p_anchor.geometry.expired();
		}),
				source_anchors.end());
		source_anchors.push_back({ snapshot, anchor });
	} else {
		std::lock_guard<std::mutex> lock(geometry_mutex);
		geometry.reset();
	}
	auto output = mailbox->latest();
	VisionOSStartupDiagnostics::Reason reason = VisionOSStartupDiagnostics::SCENE;
	VisionOSStartupDiagnostics::Source diagnostic_source;
	if (startup_diagnostics && output) {
		diagnostic_source = output->diagnostic_source;
		diagnostic_source.age_ms = (presentation_time - output->geometry->presentation_time) * 1000.0;
	}
	if (!tracked) {
		reason = VisionOSStartupDiagnostics::TRACKING_UNAVAILABLE;
	} else if (!output) {
		reason = VisionOSStartupDiagnostics::NO_OUTPUT;
	} else if (presentation_time - output->geometry->presentation_time > 0.25) {
		reason = VisionOSStartupDiagnostics::SOURCE_EXPIRED;
	} else if (!pipeline_ready.load(std::memory_order_acquire)) {
		reason = VisionOSStartupDiagnostics::PIPELINE_PENDING;
	}
	if (reason != VisionOSStartupDiagnostics::SCENE) {
		output.reset();
	}
	if (output) {
		// Compositor reprojection must use the pose that actually rendered this
		// output, never the newer pose used to acquire its destination.
		ar_device_anchor_t source_anchor = nil;
		for (const auto &entry : source_anchors) {
			if (entry.geometry.lock() == output->geometry) {
				source_anchor = entry.anchor;
				break;
			}
		}
		if (source_anchor) {
			cp_drawable_set_device_anchor(drawable, source_anchor);
			cp_drawable_set_depth_range(drawable, output->geometry->depth_range);
		} else {
			reason = VisionOSStartupDiagnostics::SOURCE_ANCHOR_MISSING;
			output.reset();
		}
	}
	id<MTLCommandBuffer> command = [queue commandBuffer];
	bool transferred_scene = false;
	std::array<VisionOSEyeTransformComparison, 2> eye_comparisons{};
	if (!command || !transfer(drawable, command, output, acquired_eyes, transferred_scene, eye_comparisons)) {
		NSLog(@"visionOS compositor could not encode its bounded presentation pass.");
		frame.finish();
		presenter.get_completions()->startup.set_frame_state(VisionOSStartupStatus::FRAME_UNAVAILABLE);
		if (startup_diagnostics) {
			startup_diagnostics->sample(CACurrentMediaTime(), VisionOSStartupDiagnostics::ENCODING_FAILED, diagnostic_source, eye_comparisons);
		}
		return;
	}
	auto completions = presenter.get_completions();
	const uint64_t startup_generation = completions->startup.get_generation();
	completions->in_flight.fetch_add(1);
	auto diagnostics = startup_diagnostics && startup_diagnostics->is_active() ? startup_diagnostics : nullptr;
	double encoded_at = diagnostics ? CACurrentMediaTime() : 0;
	[command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
		// Retain scene textures until this queue has finished reading them.
		(void)output;
		if (completed.status != MTLCommandBufferStatusCompleted) {
			NSLog(@"visionOS compositor command failed: %@", completed.error);
		} else {
			completions->completed.fetch_add(1);
		}
		completions->startup.complete(startup_generation, transferred_scene, completed.status == MTLCommandBufferStatusCompleted);
		if (diagnostics) {
			double gpu_ms = completed.GPUStartTime > 0 && completed.GPUEndTime >= completed.GPUStartTime ? (completed.GPUEndTime - completed.GPUStartTime) * 1000.0 : 0;
			diagnostics->presenter_complete(completed.status == MTLCommandBufferStatusCompleted, (CACurrentMediaTime() - encoded_at) * 1000.0, gpu_ms);
		}
		completions->in_flight.fetch_sub(1);
	}];
	cp_drawable_encode_present(drawable, command);
	[command commit];
	frame.consume_drawable();
	frame.finish();
	if (output && !transferred_scene) {
		reason = VisionOSStartupDiagnostics::EYE_MISMATCH;
	}
	if (reason == VisionOSStartupDiagnostics::TRACKING_UNAVAILABLE) {
		completions->startup.set_frame_state(VisionOSStartupStatus::TRACKING_UNAVAILABLE);
	} else if (reason == VisionOSStartupDiagnostics::SOURCE_EXPIRED || reason == VisionOSStartupDiagnostics::SOURCE_ANCHOR_MISSING || reason == VisionOSStartupDiagnostics::EYE_MISMATCH) {
		completions->startup.set_frame_state(VisionOSStartupStatus::FRAME_UNAVAILABLE);
	} else {
		completions->startup.set_frame_state(VisionOSStartupStatus::LOADING);
	}
	if (startup_diagnostics) {
		startup_diagnostics->sample(CACurrentMediaTime(), reason, diagnostic_source, eye_comparisons);
	}
	encoded_presentations++;
	encoded_scenes += transferred_scene ? 1 : 0;
	if (encoded_presentations <= 3 || encoded_presentations % 300 == 0) {
		NSLog(@"visionOS independent compositor: encoded=%llu completed=%llu scene=%llu margin_ms=%.2f",
				(unsigned long long)encoded_presentations, (unsigned long long)completions->completed.load(),
				(unsigned long long)encoded_scenes, (presentation_time - CACurrentMediaTime()) * 1000.0);
	}
}

void VisionOSPresentation::prepare_transfer() {
	presenter.get_completions()->startup.set_preparing(true);
	auto self = shared_from_this();
	MTLCompileOptions *options = [MTLCompileOptions new];
	[device newLibraryWithSource:[NSString stringWithUTF8String:VISIONOS_SCENE_TRANSFER_SHADER]
						 options:options
			   completionHandler:^(id<MTLLibrary> library, NSError *error) {
				   if (!library) {
					   NSLog(@"visionOS scene transfer shader failed: %@", error);
					   self->presenter.get_completions()->startup.fail();
					   self->stop();
					   return;
				   }
				   [self->device newComputePipelineStateWithFunction:[library newFunctionWithName:@"scene_depth_tiles"]
												   completionHandler:^(id<MTLComputePipelineState> pipeline, NSError *pipeline_error) {
													   if (!pipeline) {
														   NSLog(@"visionOS depth tile pipeline failed: %@", pipeline_error);
														   self->presenter.get_completions()->startup.fail();
														   self->stop();
														   return;
													   }
													   self->depth_tiles_pipeline = pipeline;
													   self->pipeline_prepared();
												   }];
				   [self->device newComputePipelineStateWithFunction:[library newFunctionWithName:@"scene_depth_mip"]
												   completionHandler:^(id<MTLComputePipelineState> pipeline, NSError *pipeline_error) {
													   if (!pipeline) {
														   NSLog(@"visionOS depth mip pipeline failed: %@", pipeline_error);
														   self->presenter.get_completions()->startup.fail();
														   self->stop();
														   return;
													   }
													   self->depth_mip_pipeline = pipeline;
													   self->pipeline_prepared();
												   }];
				   MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
				   descriptor.label = @"Godot completed scene transfer";
				   descriptor.vertexFunction = [library newFunctionWithName:@"scene_transfer_vertex"];
				   descriptor.fragmentFunction = [library newFunctionWithName:@"scene_transfer_fragment"];
				   descriptor.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
				   descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
				   descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
				   [self->device newRenderPipelineStateWithDescriptor:descriptor
													completionHandler:^(id<MTLRenderPipelineState> pipeline, NSError *pipeline_error) {
														if (!pipeline) {
															NSLog(@"visionOS scene transfer pipeline failed: %@", pipeline_error);
															self->presenter.get_completions()->startup.fail();
															self->stop();
															return;
														}
														MTLDepthStencilDescriptor *depth = [MTLDepthStencilDescriptor new];
														depth.depthCompareFunction = MTLCompareFunctionAlways;
														depth.depthWriteEnabled = YES;
														self->transfer_depth = [self->device newDepthStencilStateWithDescriptor:depth];
														if (!self->transfer_depth) {
															NSLog(@"visionOS scene transfer depth state allocation failed.");
															self->presenter.get_completions()->startup.fail();
															self->stop();
															return;
														}
														self->transfer_pipeline = pipeline;
														self->pipeline_prepared();
													}];
			   }];
}

bool VisionOSPresentation::transfer(cp_drawable_t p_drawable, id<MTLCommandBuffer> p_command, const std::shared_ptr<const VisionOSSceneOutput> &p_output, const std::array<simd_float4x4, 2> &p_acquired_eyes, bool &r_scene, std::array<VisionOSEyeTransformComparison, 2> &r_eyes) {
	VisionOSSceneTransferParameters parameters[2] = {};
	MTLViewport viewports[2] = {};
	bool compatible = p_output != nullptr;
	for (uint32_t eye = 0; eye < 2; eye++) {
		cp_view_t view = cp_drawable_get_view(p_drawable, eye);
		viewports[eye] = cp_view_texture_map_get_viewport(cp_view_get_view_texture_map(view));
		if (p_output) {
			const auto &source = *p_output->geometry;
			simd_float4x4 eye_transform = cp_view_get_transform(view);
			simd_float4x4 projection = cp_drawable_compute_projection(p_drawable, cp_axis_direction_convention_right_up_forward, eye);
			r_eyes[eye] = visionos_scene_transfer_eye_mapping(source.head_from_eye[eye], eye_transform, source.projection[eye], projection, parameters[eye]);
			compatible &= r_eyes[eye].rejection == VisionOSEyeTransformComparison::NONE;
			if (startup_diagnostics && startup_diagnostics->is_active() && visionos_scene_transfer_matrix_finite(eye_transform) && visionos_scene_transfer_matrix_finite(p_acquired_eyes[eye])) {
				for (uint32_t axis = 0; axis < 3; axis++) {
					r_eyes[eye].anchor_assignment_translation_m[axis] = eye_transform.columns[3][axis] - p_acquired_eyes[eye].columns[3][axis];
					for (uint32_t column = 0; column < 3; column++) {
						r_eyes[eye].anchor_assignment_basis_max_delta = std::max(r_eyes[eye].anchor_assignment_basis_max_delta, double(std::abs(eye_transform.columns[column][axis] - p_acquired_eyes[eye].columns[column][axis])));
					}
				}
			}
			MTLViewport source_viewport = source.viewport[eye];
			parameters[eye].source_viewport = simd_make_float4(source_viewport.originX, source_viewport.originY, source_viewport.width, source_viewport.height);
			parameters[eye].destination_viewport = simd_make_float4(viewports[eye].originX, viewports[eye].originY, viewports[eye].width, viewports[eye].height);
			parameters[eye].has_rate_map = source.rate_map != nil;
			parameters[eye].source_physical_bounds = source.physical_bounds[eye];
			parameters[eye].alpha_blend = source.alpha_blend;
			parameters[eye].source_is_srgb = p_output->color_is_srgb;
		}
	}
	cp_drawable_render_context_t context = cp_drawable_add_render_context(p_drawable, p_command);
	if (!context) {
		return false;
	}
	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture = cp_drawable_get_color_texture(p_drawable, 0);
	pass.colorAttachments[0].loadAction = MTLLoadActionClear;
	simd_double4 loading = visionos_scene_loading_color(alpha_blend, CACurrentMediaTime());
	pass.colorAttachments[0].clearColor = MTLClearColorMake(loading.x, loading.y, loading.z, loading.w);
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	pass.depthAttachment.texture = cp_drawable_get_depth_texture(p_drawable, 0);
	pass.depthAttachment.loadAction = MTLLoadActionClear;
	pass.depthAttachment.clearDepth = 0;
	pass.depthAttachment.storeAction = MTLStoreActionStore;
	pass.renderTargetArrayLength = 2;
	if (cp_drawable_get_rasterization_rate_map_count(p_drawable)) {
		pass.rasterizationRateMap = cp_drawable_get_rasterization_rate_map(p_drawable, 0);
		pass.renderTargetWidth = pass.rasterizationRateMap.screenSize.width;
		pass.renderTargetHeight = pass.rasterizationRateMap.screenSize.height;
	}
	id<MTLRenderCommandEncoder> encoder = [p_command renderCommandEncoderWithDescriptor:pass];
	if (!encoder) {
		return false;
	}
	if (compatible) {
		[encoder setRenderPipelineState:transfer_pipeline];
		[encoder setDepthStencilState:transfer_depth];
		[encoder setViewports:viewports count:2];
		[encoder setFragmentBytes:parameters length:sizeof(parameters) atIndex:0];
		// The shader does not dereference the rate-data argument when VRS is off.
		if (p_output->rate_parameters) {
			[encoder setFragmentBuffer:p_output->rate_parameters offset:0 atIndex:1];
		} else {
			uint32_t unused[4] = {};
			[encoder setFragmentBytes:unused length:sizeof(unused) atIndex:1];
		}
		[encoder setFragmentTexture:p_output->color atIndex:0];
		[encoder setFragmentTexture:p_output->depth atIndex:1];
		[encoder setFragmentTexture:p_output->depth_pyramid atIndex:2];
		[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3 instanceCount:2];
		r_scene = true;
	}
	cp_drawable_render_context_end_encoding(context, encoder);
	return true;
}
