#pragma once

#include "visionos_render_probe.h"

#include "scene/3d/camera_3d.h"
#include "scene/3d/mesh_instance_3d.h"
#include "scene/main/scene_tree.h"
#include "scene/main/window.h"
#include "scene/resources/3d/world_3d.h"
#include "scene/resources/camera_attributes.h"
#include "scene/resources/environment.h"
#include "servers/xr/xr_interface.h"
#include "servers/xr/xr_server.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <atomic>
#include <cmath>

namespace VisionOSRenderDiagnostics {

inline bool enabled() {
	static bool value = [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.clancey.vrzombies.vrsdiagnostic"] &&
			[NSBundle.mainBundle.infoDictionary[@"VRZombiesRenderDiagnostic"] boolValue];
	return value;
}

inline std::atomic<uint64_t> &iterations() {
	static std::atomic<uint64_t> value{ 0 };
	return value;
}

inline std::atomic<uint64_t> &gpu_completions() {
	static std::atomic<uint64_t> value{ 0 };
	return value;
}

inline void write(NSString *p_name, NSDictionary *p_data) {
	if (!enabled()) {
		return;
	}
	@autoreleasepool {
		NSError *error = nil;
		NSURL *directory = [[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"visionos_render_diagnostic" isDirectory:YES];
		if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
			NSLog(@"visionOS diagnostic directory error: %@", error);
			return;
		}
		static NSString *run_id = NSUUID.UUID.UUIDString;
		NSMutableDictionary *record = [p_data mutableCopy];
		record[@"run_id"] = run_id;
		NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:&error];
		if (!data || ![data writeToURL:[directory URLByAppendingPathComponent:[p_name stringByAppendingString:@".json"]] options:NSDataWritingAtomic error:&error]) {
			NSLog(@"visionOS diagnostic write error: %@", error);
		}
		NSLog(@"visionOS render diagnostic %@ saved (gpu_status: %@)", p_name, p_data[@"gpu_status"] ?: @"n/a");
	}
}

inline NSNumber *number(double p_value) {
	return @(std::isfinite(p_value) ? p_value : 0.0);
}

inline NSArray *vector(const Vector3 &p_value) {
	return @[ number(p_value.x), number(p_value.y), number(p_value.z) ];
}

inline NSArray *transform(const Transform3D &p_value) {
	return @[ vector(p_value.basis.get_column(0)), vector(p_value.basis.get_column(1)), vector(p_value.basis.get_column(2)), vector(p_value.origin) ];
}

inline NSArray *color(const Color &p_value) {
	return @[ number(p_value.r), number(p_value.g), number(p_value.b), number(p_value.a) ];
}

inline void scene(uint64_t p_iteration, bool p_before = false) {
	if (!enabled() || !VisionOSRenderProbe::sample(p_iteration)) {
		return;
	}
	SceneTree *tree = SceneTree::get_singleton();
	Window *root = tree ? tree->get_root() : nullptr;
	Camera3D *camera = root ? root->get_camera_3d() : nullptr;
	XRServer *xr = XRServer::get_singleton();
	NSMutableDictionary *data = [@{
		@"iteration" : @(p_iteration),
		@"camera_present" : @(camera != nullptr),
		@"paused" : @(tree && tree->is_paused()),
		@"use_xr" : @(root && root->is_using_xr()),
		@"world_scale" : number(xr ? xr->get_world_scale() : 0),
		@"world_origin" : transform(xr ? xr->get_world_origin() : Transform3D()),
		@"reference_frame" : transform(xr ? xr->get_reference_frame() : Transform3D()),
	} mutableCopy];
	if (root) {
		Size2 size = root->get_visible_rect().size;
		data[@"viewport_size"] = @[ number(size.x), number(size.y) ];
		data[@"transparent"] = @(root->has_transparent_background());
		data[@"vrs_mode"] = @(root->get_vrs_mode());
		data[@"msaa_3d"] = @(root->get_msaa_3d());
		data[@"scaling_3d_scale"] = number(root->get_scaling_3d_scale());
		data[@"previous_render_visible_objects_primitives_calls"] = @[
			@(root->get_render_info(Viewport::RENDER_INFO_TYPE_VISIBLE, Viewport::RENDER_INFO_OBJECTS_IN_FRAME)),
			@(root->get_render_info(Viewport::RENDER_INFO_TYPE_VISIBLE, Viewport::RENDER_INFO_PRIMITIVES_IN_FRAME)),
			@(root->get_render_info(Viewport::RENDER_INFO_TYPE_VISIBLE, Viewport::RENDER_INFO_DRAW_CALLS_IN_FRAME)),
		];
	}
	Ref<XRInterface> interface = xr ? xr->get_primary_interface() : Ref<XRInterface>();
	if (interface.is_valid()) {
		data[@"interface"] = @(String(interface->get_name()).utf8().get_data());
		data[@"initialized"] = @(interface->is_initialized());
		data[@"tracking_status"] = @(interface->get_tracking_status());
	}
	if (camera) {
		data[@"camera_path"] = @(String(camera->get_path()).utf8().get_data());
		data[@"camera_class"] = @(String(camera->get_class()).utf8().get_data());
		data[@"camera_transform"] = transform(camera->get_global_transform());
		data[@"near"] = number(camera->get_near());
		data[@"far"] = number(camera->get_far());
		data[@"cull_mask"] = @(camera->get_cull_mask());
		data[@"camera_current"] = @(camera->is_current());
		Ref<CameraAttributes> attributes = camera->get_attributes();
		if (attributes.is_valid()) {
			data[@"exposure_multiplier"] = number(attributes->get_exposure_multiplier());
			data[@"exposure_sensitivity"] = number(attributes->get_exposure_sensitivity());
		}
		Ref<Environment> environment = camera->get_environment();
		Ref<World3D> world = root->find_world_3d();
		if (environment.is_null() && world.is_valid()) {
			environment = world->get_environment();
		}
		if (environment.is_valid()) {
			data[@"environment_background_mode"] = @(environment->get_background());
			data[@"environment_background_color"] = color(environment->get_bg_color());
			data[@"background_energy"] = number(environment->get_bg_energy_multiplier());
			data[@"ambient_energy"] = number(environment->get_ambient_light_energy());
			data[@"tonemap_exposure"] = number(environment->get_tonemap_exposure());
			data[@"glow_enabled"] = @(environment->is_glow_enabled());
			data[@"fog_enabled"] = @(environment->is_fog_enabled());
		}
		LocalVector<Node *> pending;
		pending.push_back(root);
		NSMutableArray *meshes = [NSMutableArray array];
		uint32_t visited = 0, mesh_count = 0, visible_count = 0, layer_matches = 0;
		Transform3D camera_inverse = camera->get_global_transform().affine_inverse();
		while (!pending.is_empty() && visited < 4096) {
			Node *node = pending[pending.size() - 1];
			pending.remove_at(pending.size() - 1);
			visited++;
			MeshInstance3D *mesh = Object::cast_to<MeshInstance3D>(node);
			if (mesh) {
				mesh_count++;
				bool visible = mesh->is_visible_in_tree();
				bool matches = (mesh->get_layer_mask() & camera->get_cull_mask()) != 0;
				AABB bounds = mesh->get_global_transform().xform(mesh->get_aabb());
				visible_count += visible;
				layer_matches += visible && matches;
				if (meshes.count < 32 && visible && matches) {
					[meshes addObject:@{
						@"path" : @(String(mesh->get_path()).utf8().get_data()),
						@"world_aabb_position" : vector(bounds.position), @"world_aabb_size" : vector(bounds.size),
						@"layer_mask" : @(mesh->get_layer_mask()), @"center_camera_space" : vector(camera_inverse.xform(bounds.get_center())),
					}];
				}
			}
			for (int child = 0; child < node->get_child_count() && pending.size() < 4096; child++) {
				pending.push_back(node->get_child(child));
			}
		}
		data[@"geometry_counts_visited_mesh_visible_mask"] = @[ @(visited), @(mesh_count), @(visible_count), @(layer_matches) ];
		data[@"frustum_test"] = @"Unavailable outside the acquired-drawable interval; camera-space centers are not culling results.";
		data[@"geometry_truncated"] = @(!pending.is_empty());
		data[@"geometry"] = meshes;
	}
	data[@"before_iteration"] = @(p_before);
	write([NSString stringWithFormat:p_before ? @"scene-before-%04llu" : @"scene-%04llu", (unsigned long long)p_iteration], data);
}

inline void schedule_watchdogs() {
	if (!enabled()) {
		return;
	}
	write(@"identity", @{
		@"purpose" : @"DIAGNOSTIC: native VRS viewport correction; early cyan control before the first XR scene compile, at most 2 seconds or 180 attempts. Startup termination remains unverified.",
		@"revision" : @2,
		@"bundle" : NSBundle.mainBundle.bundleIdentifier,
		@"captures" : @"25 app-rendered color/depth points per eye before and after presentation pass; no images, passthrough or system content.",
	});
	for (int delay : { 5, 15, 30 }) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
			write([NSString stringWithFormat:@"watchdog-%02d", delay], @{@"seconds" : @(delay),
				@"iterations_begun" : @(iterations().load()),
				@"sampled_gpu_completions" : @(gpu_completions().load()),
				@"uikit_responsive" : @YES,
			});
		});
	}
}

struct Readback {
	id<MTLBuffer> buffer = nil;
};

inline NSDictionary *coordinates(id<MTLTexture> p_color, id<MTLRasterizationRateMap> p_map) {
	NSMutableArray *points = [NSMutableArray array];
	NSMutableArray *sizes = [NSMutableArray array];
	for (NSUInteger eye = 0; eye < 2; eye++) {
		if (p_map && eye < p_map.layerCount) {
			MTLSize physical = [p_map physicalSizeForLayer:eye];
			[sizes addObject:@[ @(physical.width), @(physical.height) ]];
		}
		for (NSUInteger y = 0; y < 5; y++) {
			for (NSUInteger x = 0; x < 5; x++) {
				MTLCoordinate2D physical = { float((p_color.width - 1) * (x + 1) / 6), float((p_color.height - 1) * (y + 1) / 6) };
				MTLCoordinate2D logical = p_map && eye < p_map.layerCount ? [p_map mapPhysicalToScreenCoordinates:physical forLayer:eye] : physical;
				[points addObject:@[ @(eye), @(physical.x), @(physical.y), @(logical.x), @(logical.y) ]];
			}
		}
	}
	return @{ @"physical_layer_sizes" : sizes,
		@"logical_size" : @[ @(p_map ? p_map.screenSize.width : p_color.width), @(p_map ? p_map.screenSize.height : p_color.height) ],
		@"eye_physical_x_y_logical_x_y" : points };
}

inline Readback sample_textures(id<MTLCommandBuffer> p_command_buffer, id<MTLTexture> p_color, id<MTLTexture> p_depth) {
	Readback result;
	if (!p_color || !p_depth || p_color.pixelFormat != MTLPixelFormatRGBA16Float ||
			p_depth.pixelFormat != MTLPixelFormatDepth32Float_Stencil8 ||
			p_color.arrayLength < 2 || p_depth.arrayLength < 2 || p_color.framebufferOnly || p_depth.framebufferOnly ||
			p_color.storageMode == MTLStorageModeMemoryless || p_depth.storageMode == MTLStorageModeMemoryless) {
		return result;
	}
	// Each one-pixel row occupies 256 bytes to satisfy both texture-to-buffer alignments.
	result.buffer = [p_command_buffer.device newBufferWithLength:2 * 2 * 25 * 256 options:MTLResourceStorageModeShared];
	if (!result.buffer) {
		return result;
	}
	id<MTLBlitCommandEncoder> encoder = [p_command_buffer blitCommandEncoder];
	if (!encoder) {
		result.buffer = nil;
		return result;
	}
	for (NSUInteger eye = 0; eye < 2; eye++) {
		for (NSUInteger y = 0; y < 5; y++) {
			for (NSUInteger x = 0; x < 5; x++) {
				NSUInteger point = eye * 25 + y * 5 + x;
				MTLOrigin color_origin = MTLOriginMake((p_color.width - 1) * (x + 1) / 6, (p_color.height - 1) * (y + 1) / 6, 0);
				MTLOrigin depth_origin = MTLOriginMake((p_depth.width - 1) * (x + 1) / 6, (p_depth.height - 1) * (y + 1) / 6, 0);
				[encoder copyFromTexture:p_color
									 sourceSlice:eye
									 sourceLevel:0
									sourceOrigin:color_origin
									  sourceSize:MTLSizeMake(1, 1, 1)
										toBuffer:result.buffer
							   destinationOffset:point * 256
						  destinationBytesPerRow:256
						destinationBytesPerImage:256];
				[encoder copyFromTexture:p_depth
									 sourceSlice:eye
									 sourceLevel:0
									sourceOrigin:depth_origin
									  sourceSize:MTLSizeMake(1, 1, 1)
										toBuffer:result.buffer
							   destinationOffset:(50 + point) * 256
						  destinationBytesPerRow:256
						destinationBytesPerImage:256
										 options:MTLBlitOptionDepthFromDepthStencil];
			}
		}
	}
	[encoder endEncoding];
	return result;
}

inline NSArray *read_samples(id<MTLBuffer> p_buffer) {
	NSMutableArray *points = [NSMutableArray array];
	if (!p_buffer) {
		return points;
	}
	const uint8_t *bytes = static_cast<const uint8_t *>(p_buffer.contents);
	for (NSUInteger point = 0; point < 50; point++) {
		const _Float16 *rgba = reinterpret_cast<const _Float16 *>(bytes + point * 256);
		float depth = *reinterpret_cast<const float *>(bytes + (50 + point) * 256);
		bool finite = std::isfinite(float(rgba[0])) && std::isfinite(float(rgba[1])) && std::isfinite(float(rgba[2])) && std::isfinite(float(rgba[3])) && std::isfinite(depth);
		[points addObject:@[ number(rgba[0]), number(rgba[1]), number(rgba[2]), number(rgba[3]), number(depth), @(finite) ]];
	}
	return points;
}

} // namespace VisionOSRenderDiagnostics
