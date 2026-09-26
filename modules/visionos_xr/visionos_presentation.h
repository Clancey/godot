/**************************************************************************/
/*  visionos_presentation.h                                               */
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

#include "visionos_presentation_thread.h"
#include "visionos_scene_mailbox.h"
#include "visionos_startup_diagnostics.h"

#include "core/math/transform_3d.h"

#import <ARKit/ARKit.h>
#import <CompositorServices/CompositorServices.h>
#import <Metal/Metal.h>
#include <TargetConditionals.h>

#include <atomic>
#include <memory>
#include <mutex>

// Views Godot renders. The simulator's compositor presents one view and its GPU
// (Apple2 family) has no layered rendering, so it renders mono.
#if TARGET_OS_SIMULATOR
static constexpr uint32_t VISIONOS_RENDER_VIEW_COUNT = 1;
#else
static constexpr uint32_t VISIONOS_RENDER_VIEW_COUNT = 2;
#endif
#include <thread>
#include <vector>

// No frame, drawable, view or compositor-owned texture crosses to the engine.
struct VisionOSSceneGeometry {
	uint64_t generation = 0;
	bool alpha_blend = false;
	double presentation_time = 0;
	double trackable_time = 0;
	Transform3D origin_from_head;
	simd_float4x4 head_from_eye[2];
	simd_float4x4 projection[2];
	simd_float2 depth_range;
	MTLViewport viewport[2];
	simd_float4 physical_bounds[2];
	NSUInteger width = 0;
	NSUInteger height = 0;
	MTLPixelFormat color_format = MTLPixelFormatInvalid;
	MTLPixelFormat depth_format = MTLPixelFormatInvalid;
	id<MTLRasterizationRateMap> rate_map = nil;
};

struct VisionOSSceneOutput {
	std::shared_ptr<const VisionOSSceneGeometry> geometry;
	id<MTLTexture> color = nil;
	id<MTLTexture> depth = nil;
	id<MTLBuffer> rate_parameters = nil;
	id<MTLTexture> depth_pyramid = nil;
	NSArray<id<MTLTexture>> *depth_pyramid_views = nil;
	bool projection_valid = false;
	bool transparent_background = false;
	bool color_is_srgb = true;
	VisionOSStartupDiagnostics::Source diagnostic_source;
	double diagnostic_acquired_at = 0;
};

// Compositor API calls and the submission queue belong exclusively to this
// owner. The scene renderer only acquires independent output slots.
class VisionOSPresentation : public std::enable_shared_from_this<VisionOSPresentation> {
public:
	using Mailbox = VisionOSSceneMailbox<VisionOSSceneOutput>;
	using Lease = Mailbox::Lease;

private:
	cp_layer_renderer_t layer;
	cp_layer_renderer_capabilities_t capabilities;
	id<MTLDevice> device;
	id<MTLCommandQueue> queue;
	ar_session_t session;
	ar_world_tracking_provider_t world_tracking;
	std::shared_ptr<Mailbox> mailbox = std::make_shared<Mailbox>();
	std::shared_ptr<VisionOSStartupDiagnostics> startup_diagnostics;
	uint64_t diagnostic_layer = 0;
	std::mutex geometry_mutex;
	std::shared_ptr<const VisionOSSceneGeometry> geometry;
	struct SourceAnchor {
		std::weak_ptr<const VisionOSSceneGeometry> geometry;
		ar_device_anchor_t anchor;
	};
	// SDK anchor objects never cross to the scene/GPU worker threads. Retain
	// exactly the prediction used by each still-owned numeric scene snapshot.
	std::vector<SourceAnchor> source_anchors;
	simd_float2 requested_depth_range;
	std::atomic<bool> requested_alpha_blend{ false };
	bool alpha_blend = false;
	uint64_t encoded_presentations = 0;
	uint64_t encoded_scenes = 0;
	VisionOSPresentationThread presenter;
	id<MTLRenderPipelineState> transfer_pipeline = nil;
	id<MTLDepthStencilState> transfer_depth = nil;
	id<MTLComputePipelineState> depth_tiles_pipeline = nil;
	id<MTLComputePipelineState> depth_mip_pipeline = nil;
	std::atomic<uint32_t> prepared_pipelines{ 0 };
	std::atomic<bool> pipeline_ready{ false };

	void run();
	void present();
	void prepare_transfer();
	void pipeline_prepared();
	bool encode_depth_pyramid(const VisionOSSceneOutput &p_output, id<MTLCommandBuffer> p_command);
	bool transfer(cp_drawable_t p_drawable, id<MTLCommandBuffer> p_command, const std::shared_ptr<const VisionOSSceneOutput> &p_output, const std::array<simd_float4x4, 2> &p_acquired_eyes, bool &r_scene, std::array<VisionOSEyeTransformComparison, 2> &r_eyes);

public:
	VisionOSPresentation(cp_layer_renderer_t p_layer, cp_layer_renderer_capabilities_t p_capabilities, bool p_alpha_blend);
	~VisionOSPresentation();
	void start();
	void stop();
	bool is_stopped() const { return presenter.is_stopping(); }
	VisionOSStartupStatus::State get_startup_state() const { return presenter.get_completions()->startup.get_state(); }
	void request_depth_range(simd_float2 p_range);
	void request_alpha_blend(bool p_enabled) { requested_alpha_blend.store(p_enabled, std::memory_order_release); }
	bool is_alpha_blend_requested() const { return requested_alpha_blend.load(std::memory_order_acquire); }
	std::shared_ptr<const VisionOSSceneGeometry> get_geometry();
	// Leases an output for p_geometry, the prediction the engine posed its camera
	// with. Falls back to the latest prediction when none is given.
	Lease acquire(const std::shared_ptr<const VisionOSSceneGeometry> &p_geometry = nullptr);
	void complete(const Lease &p_lease, id<MTLCommandBuffer> p_command);
	ar_session_t get_session() const { return session; }
	ar_world_tracking_provider_t get_world_tracking() const { return world_tracking; }
};

std::shared_ptr<VisionOSPresentation> visionos_get_presentation();
void visionos_run_tracking_session(ar_data_providers_t p_providers);
