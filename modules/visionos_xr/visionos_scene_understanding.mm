/**************************************************************************/
/*  visionos_scene_understanding.mm                                       */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#ifdef VISIONOS_ENABLED

#include "visionos_scene_understanding.h"

#include "visionos_simd_helpers.h"
#include "visionos_spatial_anchor_capability.h"
#include "visionos_tracking.h"

#include "core/config/project_settings.h"
#include "core/object/class_db.h"
#include "servers/xr/xr_server.h"

#import <ARKit/image_tracking.h>
#import <ARKit/plane_detection.h>
#import <ARKit/scene_reconstruction.h>
#import <ARKit/world_tracking.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

static Transform3D _simd4x4_to_transform3d(const simd_float4x4 &p_matrix) {
	return MTL::simd_to_transform3D(p_matrix);
}

String VisionOSSceneUnderstanding::uuid_to_string(const uuid_t p_uuid) {
	char buf[37];
	snprintf(buf, sizeof(buf),
			"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
			p_uuid[0], p_uuid[1], p_uuid[2], p_uuid[3],
			p_uuid[4], p_uuid[5], p_uuid[6], p_uuid[7],
			p_uuid[8], p_uuid[9], p_uuid[10], p_uuid[11],
			p_uuid[12], p_uuid[13], p_uuid[14], p_uuid[15]);
	return String(buf);
}

uint64_t VisionOSSceneUnderstanding::uuid_to_hash(const uuid_t p_uuid) {
	uint64_t h = 0;
	for (int i = 0; i < 16; i++) {
		h = h * 31 + p_uuid[i];
	}
	return h;
}

// ============================================================================
// Lifecycle
// ============================================================================

void VisionOSSceneUnderstanding::configure_from_project_settings() {
	plane_detection_enabled = GLOBAL_GET("xr/visionos/scene_understanding/enable_plane_detection");
	scene_reconstruction_enabled = GLOBAL_GET("xr/visionos/scene_understanding/enable_scene_reconstruction");
	world_anchors_enabled = GLOBAL_GET("xr/visionos/scene_understanding/enable_world_anchors");
	image_tracking_enabled = GLOBAL_GET("xr/visionos/scene_understanding/enable_image_tracking");
}

void VisionOSSceneUnderstanding::initialize(ar_session_t p_session, ar_world_tracking_provider_t p_world_tracking_provider) {
	lifecycle_revision++;
	ar_session = p_session;
	world_tracking_provider = p_world_tracking_provider;

	if (plane_detection_enabled) {
		setup_plane_detection();
	}
	if (scene_reconstruction_enabled) {
		setup_scene_reconstruction();
	}
	if (image_tracking_enabled) {
		setup_image_tracking();
	}
	// Install anchor handlers only once the presenter's existing provider is running.
	if (world_anchors_enabled && is_world_anchor_supported()) {
		setup_anchor_lifecycle();
	}
}

void VisionOSSceneUnderstanding::uninitialize() {
	if (uninitializing) {
		return;
	}
	uninitializing = true;
	lifecycle_revision++;
	XRServer *xr_server = XRServer::get_singleton();

	// Teardown providers (clears update handlers).
	teardown_plane_detection();
	teardown_scene_reconstruction();
	teardown_image_tracking();
	teardown_world_anchors();
	anchor_store->unwatch_provider();
	if (anchor_lifecycle_installed && ar_session != nullptr) {
		visionos_tracking_access().perform([&] {
			ar_session_set_data_provider_state_change_handler(ar_session, nullptr, nullptr);
		});
	}
	anchor_lifecycle_installed = false;
	if (VisionOSSpatialAnchorCapability::get_singleton()) {
		VisionOSSpatialAnchorCapability::get_singleton()->process();
	}

	// Remove all trackers from XR server.
	if (xr_server) {
		for (const KeyValue<uint64_t, Ref<VisionOSPlaneTracker>> &kv : plane_trackers) {
			xr_server->remove_tracker(kv.value);
		}
		for (const KeyValue<uint64_t, Ref<VisionOSMeshTracker>> &kv : mesh_trackers) {
			xr_server->remove_tracker(kv.value);
		}
		for (const KeyValue<uint64_t, Ref<VisionOSMarkerTracker>> &kv : marker_trackers) {
			kv.value->invalidate_pose(SNAME("default"));
			xr_server->remove_tracker(kv.value);
		}
		const HashMap<String, Ref<VisionOSAnchorTracker>> old_anchor_trackers(anchor_trackers);
		anchor_trackers.clear();
		for (const KeyValue<String, Ref<VisionOSAnchorTracker>> &kv : old_anchor_trackers) {
			kv.value->invalidate_pose(SNAME("default"));
			kv.value->set_anchor_tracked(false);
			xr_server->remove_tracker(kv.value);
		}
	}

	plane_trackers.clear();
	mesh_trackers.clear();
	marker_trackers.clear();
	anchor_trackers.clear();

	{
		MutexLock lock(plane_mutex);
		pending_plane_updates.clear();
	}
	{
		MutexLock lock(mesh_mutex);
		pending_mesh_updates.clear();
	}
	{
		MutexLock lock(marker_mutex);
		pending_marker_updates.clear();
	}

	ar_session = nullptr;
	world_tracking_provider = nullptr;
	plane_detection_provider = nullptr;
	scene_reconstruction_provider = nullptr;
	image_tracking_provider = nullptr;
	providers_changed = false;
	uninitializing = false;
}

void VisionOSSceneUnderstanding::add_providers_to(ar_data_providers_t p_data_providers) {
	if (plane_detection_enabled && plane_detection_provider != nullptr) {
		ar_data_providers_add_data_provider(p_data_providers, plane_detection_provider);
	}
	if (scene_reconstruction_enabled && scene_reconstruction_provider != nullptr) {
		ar_data_providers_add_data_provider(p_data_providers, scene_reconstruction_provider);
	}
	if (image_tracking_enabled && image_tracking_provider != nullptr) {
		ar_data_providers_add_data_provider(p_data_providers, image_tracking_provider);
	}
	// World anchors use the existing world_tracking_provider, no additional provider needed.
}

void VisionOSSceneUnderstanding::process() {
	if (active()) {
		process_plane_updates();
		process_mesh_updates();
		process_marker_updates();
	}
	process_anchor_updates();
	if (VisionOSSpatialAnchorCapability::get_singleton()) {
		VisionOSSpatialAnchorCapability::get_singleton()->process();
	}
}

// ============================================================================
// Image (marker) tracking
// ============================================================================

// ARKit image anchors lie in their XZ plane with +Y out of the image and -Z
// towards its top edge. Rotate into the OpenXR spatial marker convention used
// by every other marker source: +X right, +Y top, +Z out of the face.
static const Basis _arkit_image_to_marker = Basis(Vector3(1, 0, 0), -Math::PI / 2.0);

static ar_reference_image_t _create_reference_image(const Ref<Image> &p_image, float p_physical_width) {
	Ref<Image> gray = p_image->duplicate();
	if (gray->is_compressed()) {
		ERR_FAIL_COND_V_MSG(gray->decompress() != OK, nullptr, "Cannot decompress marker reference image.");
	}
	gray->convert(Image::FORMAT_L8);
	const int width = gray->get_width();
	const int height = gray->get_height();
	PackedByteArray pixels = gray->get_data();

	CFDataRef data = CFDataCreate(kCFAllocatorDefault, pixels.ptr(), pixels.size());
	CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
	CGColorSpaceRef color_space = CGColorSpaceCreateDeviceGray();
	CGImageRef cg_image = CGImageCreate(width, height, 8, 8, width, color_space, kCGImageAlphaNone, provider, nullptr, false, kCGRenderingIntentDefault);
	CGColorSpaceRelease(color_space);
	CGDataProviderRelease(provider);
	CFRelease(data);
	ERR_FAIL_NULL_V_MSG(cg_image, nullptr, "Cannot create a CGImage for a marker reference image.");

	ar_reference_image_t reference = ar_reference_image_create_from_cgimage(cg_image, kCGImagePropertyOrientationUp, p_physical_width);
	CGImageRelease(cg_image);
	return reference;
}

bool VisionOSSceneUnderstanding::is_image_tracking_supported() const {
	return ar_image_tracking_provider_is_supported();
}

bool VisionOSSceneUnderstanding::add_marker_reference_image(const String &p_name, const Ref<Image> &p_image, float p_physical_width) {
	ERR_FAIL_COND_V_MSG(p_image.is_null() || p_image->is_empty(), false, "Marker reference image is empty.");
	ERR_FAIL_COND_V_MSG(p_physical_width <= 0, false, "Marker reference image needs a positive physical width in meters.");
	ERR_FAIL_COND_V_MSG(p_name.is_empty(), false, "Marker reference image needs a name; it is reported as the tracker's marker_data.");
	for (const ReferenceImage &existing : reference_images) {
		ERR_FAIL_COND_V_MSG(existing.name == p_name, false, "Marker reference image \"" + p_name + "\" is already registered.");
	}
	reference_images.push_back({ p_name, p_image, p_physical_width });
	if (image_tracking_enabled && ar_session != nullptr) {
		setup_image_tracking();
	}
	return true;
}

void VisionOSSceneUnderstanding::clear_marker_reference_images() {
	reference_images.clear();
	if (image_tracking_enabled && ar_session != nullptr) {
		setup_image_tracking();
	}
}

bool VisionOSSceneUnderstanding::consume_providers_changed() {
	bool changed = providers_changed;
	providers_changed = false;
	return changed;
}

void VisionOSSceneUnderstanding::setup_image_tracking() {
	teardown_image_tracking();
	providers_changed = true;

	if (!ar_image_tracking_provider_is_supported()) {
		print_verbose("visionOS: Image tracking is not supported on this device.");
		return;
	}
	if (reference_images.is_empty()) {
		// ARKit rejects a provider without reference images; wait for registration.
		return;
	}

	ar_reference_images_t references = ar_reference_images_create();
	for (const ReferenceImage &reference_image : reference_images) {
		ar_reference_image_t reference = _create_reference_image(reference_image.image, reference_image.physical_width);
		if (reference == nullptr) {
			continue;
		}
		ar_reference_image_set_name(reference, reference_image.name.utf8().get_data());
		ar_reference_images_add_image(references, reference);
	}
	if (ar_reference_images_get_count(references) == 0) {
		return;
	}

	ar_image_tracking_configuration_t config = ar_image_tracking_configuration_create();
	ar_image_tracking_configuration_add_reference_images(config, references);
	image_tracking_provider = ar_image_tracking_provider_create(config);

	uint64_t revision = image_tracking_revision;
	ar_image_tracking_provider_set_update_handler(image_tracking_provider,
			dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
			^(ar_image_anchors_t added, ar_image_anchors_t updated, ar_image_anchors_t removed) {
				__block LocalVector<MarkerUpdate> updates;
				auto collect = ^(ar_image_anchors_t p_anchors, MarkerUpdate::Type p_type) {
					ar_image_anchors_enumerate_anchors(p_anchors, ^bool(ar_image_anchor_t anchor) {
						MarkerUpdate upd;
						upd.type = p_type;
						uuid_t uuid;
						ar_image_anchor_get_identifier(anchor, uuid);
						upd.anchor_id_hash = uuid_to_hash(uuid);
						upd.anchor_uuid_str = uuid_to_string(uuid);
						if (p_type != MarkerUpdate::REMOVED) {
							ar_reference_image_t reference = ar_image_anchor_get_reference_image(anchor);
							const char *name = ar_reference_image_get_name(reference);
							upd.name = name ? String::utf8(name) : String();
							upd.physical_size = Vector2(ar_reference_image_get_physical_width(reference), ar_reference_image_get_physical_height(reference));
							upd.estimated_scale_factor = ar_image_anchor_get_estimated_scale_factor(anchor);
							upd.tracked = ar_image_anchor_is_tracked(anchor);
							Transform3D anchor_transform = _simd4x4_to_transform3d(ar_image_anchor_get_origin_from_anchor_transform(anchor));
							upd.transform = Transform3D(anchor_transform.basis.orthonormalized() * _arkit_image_to_marker, anchor_transform.origin);
						}
						updates.push_back(upd);
						return true;
					});
				};
				collect(added, MarkerUpdate::ADDED);
				collect(updated, MarkerUpdate::UPDATED);
				collect(removed, MarkerUpdate::REMOVED);

				if (updates.size() > 0) {
					MutexLock lock(marker_mutex);
					if (revision != image_tracking_revision) {
						return;
					}
					for (uint32_t i = 0; i < updates.size(); i++) {
						pending_marker_updates.push_back(updates[i]);
					}
				}
			});

	print_verbose(vformat("visionOS: Image tracking provider initialized with %d reference images.", (int)ar_reference_images_get_count(references)));
}

void VisionOSSceneUnderstanding::teardown_image_tracking() {
	{
		MutexLock lock(marker_mutex);
		image_tracking_revision++;
		pending_marker_updates.clear();
	}
	if (image_tracking_provider != nullptr) {
		ar_image_tracking_provider_set_update_handler(image_tracking_provider, nullptr, nullptr);
		image_tracking_provider = nullptr;
	}
	XRServer *xr_server = XRServer::get_singleton();
	for (const KeyValue<uint64_t, Ref<VisionOSMarkerTracker>> &kv : marker_trackers) {
		kv.value->set_marker_tracked(false);
		kv.value->invalidate_pose(SNAME("default"));
		if (xr_server) {
			xr_server->remove_tracker(kv.value);
		}
	}
	marker_trackers.clear();
}

void VisionOSSceneUnderstanding::process_marker_updates() {
	LocalVector<MarkerUpdate> updates;
	{
		MutexLock lock(marker_mutex);
		updates = pending_marker_updates;
		pending_marker_updates.clear();
	}
	if (updates.size() == 0) {
		return;
	}

	XRServer *xr_server = XRServer::get_singleton();
	ERR_FAIL_NULL(xr_server);

	for (const MarkerUpdate &upd : updates) {
		Ref<VisionOSMarkerTracker> *tracker_ptr = marker_trackers.getptr(upd.anchor_id_hash);
		if (upd.type == MarkerUpdate::REMOVED) {
			if (tracker_ptr != nullptr) {
				Ref<VisionOSMarkerTracker> tracker = *tracker_ptr;
				tracker->set_marker_tracked(false);
				tracker->invalidate_pose(SNAME("default"));
				xr_server->remove_tracker(tracker);
				marker_trackers.erase(upd.anchor_id_hash);
			}
			continue;
		}

		Ref<VisionOSMarkerTracker> tracker;
		bool is_new = tracker_ptr == nullptr;
		if (is_new) {
			tracker.instantiate();
			tracker->set_tracker_name("visionos/marker/" + upd.anchor_uuid_str);
			tracker->set_tracker_desc(upd.name);
			tracker->set_marker_uuid(upd.anchor_uuid_str);
			tracker->set_marker_data(upd.name);
		} else {
			tracker = *tracker_ptr;
		}
		tracker->set_physical_size(upd.physical_size);
		tracker->set_estimated_scale_factor(upd.estimated_scale_factor);
		if (upd.tracked) {
			tracker->set_pose(SNAME("default"), upd.transform, Vector3(), Vector3(), XRPose::XR_TRACKING_CONFIDENCE_HIGH);
		} else {
			// Keep the last pose but flag it; an untracked image anchor is a stale estimate.
			tracker->set_pose(SNAME("default"), upd.transform, Vector3(), Vector3(), XRPose::XR_TRACKING_CONFIDENCE_LOW);
		}
		tracker->set_marker_tracked(upd.tracked);
		if (is_new) {
			marker_trackers[upd.anchor_id_hash] = tracker;
			xr_server->add_tracker(tracker);
		}
	}
}

// ============================================================================
// Plane Detection
// ============================================================================

static String _plane_classification_to_label(ar_plane_anchor_t p_anchor) {
#if defined(__VISION_OS_VERSION_MAX_ALLOWED) && __VISION_OS_VERSION_MAX_ALLOWED >= 260000
	ar_surface_classification_t classification = ar_plane_anchor_get_surface_classification(p_anchor);
	switch (classification) {
		case ar_surface_classification_wall:
			return "Wall plane";
		case ar_surface_classification_floor:
			return "Floor plane";
		case ar_surface_classification_ceiling:
			return "Ceiling plane";
		case ar_surface_classification_table:
			return "Table plane";
		case ar_surface_classification_seat:
			return "Seat";
		case ar_surface_classification_window:
			return "Window";
		case ar_surface_classification_door:
			return "Door";
		default:
			return "Uncategorized plane";
	}
#else
	ar_plane_classification_t classification = ar_plane_anchor_get_plane_classification(p_anchor);
	switch (classification) {
		case ar_plane_classification_wall:
			return "Wall plane";
		case ar_plane_classification_floor:
			return "Floor plane";
		case ar_plane_classification_ceiling:
			return "Ceiling plane";
		case ar_plane_classification_table:
			return "Table plane";
		case ar_plane_classification_seat:
			return "Seat";
		case ar_plane_classification_window:
			return "Window";
		case ar_plane_classification_door:
			return "Door";
		default:
			return "Uncategorized plane";
	}
#endif
}

static VisionOSPlaneTracker::PlaneAlignment _arkit_alignment_to_plane_alignment(ar_plane_alignment_t p_alignment) {
	if (p_alignment & ar_plane_alignment_horizontal) {
		return VisionOSPlaneTracker::PLANE_ALIGNMENT_HORIZONTAL_UPWARD;
	} else if (p_alignment & ar_plane_alignment_vertical) {
		return VisionOSPlaneTracker::PLANE_ALIGNMENT_VERTICAL;
	}
	return VisionOSPlaneTracker::PLANE_ALIGNMENT_ARBITRARY;
}

static void _extract_plane_geometry(ar_plane_anchor_t p_anchor, PackedVector2Array &r_vertices, PackedInt32Array &r_indices, Vector2 &r_bounds_size) {
	ar_plane_geometry_t geometry = ar_plane_anchor_get_geometry(p_anchor);
	if (geometry == nullptr) {
		return;
	}

	// Extract extent for bounds.
	ar_plane_extent_t extent = ar_plane_geometry_get_plane_extent(geometry);
	if (extent != nullptr) {
		r_bounds_size.x = ar_plane_extent_get_width(extent);
		r_bounds_size.y = ar_plane_extent_get_height(extent);
	}

	// Extract vertices from Metal buffer.
	ar_geometry_source_t vertex_source = ar_plane_geometry_get_mesh_vertices(geometry);
	if (vertex_source == nullptr) {
		return;
	}

	size_t vertex_count = ar_geometry_source_get_count(vertex_source);
	if (vertex_count == 0) {
		return;
	}

	id<MTLBuffer> vertex_buffer = ar_geometry_source_get_buffer(vertex_source);
	if (vertex_buffer == nil) {
		return;
	}

	size_t vertex_offset = ar_geometry_source_get_offset(vertex_source);
	size_t vertex_stride = ar_geometry_source_get_stride(vertex_source);
	const uint8_t *vertex_data = (const uint8_t *)[vertex_buffer contents] + vertex_offset;

	// ARKit plane vertices are 3-component floats on the XZ plane in anchor-local space.
	// We store as 2D (x, z) to match the OpenXR plane tracker convention.
	r_vertices.resize(vertex_count);
	Vector2 *vert_write = r_vertices.ptrw();
	for (size_t i = 0; i < vertex_count; i++) {
		const float *v = (const float *)(vertex_data + i * vertex_stride);
		vert_write[i] = Vector2(v[0], v[2]); // x, z (ARKit plane coords)
	}

	// Extract indices.
	ar_geometry_element_t face_element = ar_plane_geometry_get_mesh_faces(geometry);
	if (face_element == nullptr) {
		return;
	}

	size_t face_count = ar_geometry_element_get_count(face_element);
	size_t indices_per_face = ar_geometry_element_get_index_count_per_primitive(face_element);
	size_t bytes_per_index = ar_geometry_element_get_bytes_per_index(face_element);

	id<MTLBuffer> index_buffer = ar_geometry_element_get_buffer(face_element);
	if (index_buffer == nil) {
		return;
	}

	const uint8_t *index_data = (const uint8_t *)[index_buffer contents];
	size_t total_indices = face_count * indices_per_face;

	r_indices.resize(total_indices);
	int32_t *idx_write = r_indices.ptrw();

	if (bytes_per_index == 2) {
		const uint16_t *src = (const uint16_t *)index_data;
		for (size_t i = 0; i < total_indices; i++) {
			idx_write[i] = (int32_t)src[i];
		}
	} else if (bytes_per_index == 4) {
		const uint32_t *src = (const uint32_t *)index_data;
		for (size_t i = 0; i < total_indices; i++) {
			idx_write[i] = (int32_t)src[i];
		}
	}
}

void VisionOSSceneUnderstanding::setup_plane_detection() {
	if (!ar_plane_detection_provider_is_supported()) {
		print_verbose("visionOS: Plane detection is not supported on this device.");
		plane_detection_enabled = false;
		return;
	}

	ar_plane_detection_configuration_t config = ar_plane_detection_configuration_create();
	// Detect both horizontal and vertical planes by default.
	ar_plane_detection_configuration_set_alignment(config, ar_plane_alignment_t(ar_plane_alignment_horizontal | ar_plane_alignment_vertical));

	plane_detection_provider = ar_plane_detection_provider_create(config);

	ar_plane_detection_provider_set_update_handler(plane_detection_provider,
			dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
			^(ar_plane_anchors_t added, ar_plane_anchors_t updated, ar_plane_anchors_t removed) {
				__block LocalVector<PlaneUpdate> updates;

				// Process added planes.
				ar_plane_anchors_enumerate_anchors(added, ^bool(ar_plane_anchor_t anchor) {
					PlaneUpdate upd;
					upd.type = PlaneUpdate::ADDED;

					uuid_t uuid;
					ar_plane_anchor_get_identifier(anchor, uuid);
					upd.anchor_id_hash = uuid_to_hash(uuid);
					upd.anchor_uuid_str = uuid_to_string(uuid);

					upd.transform = _simd4x4_to_transform3d(ar_plane_anchor_get_origin_from_anchor_transform(anchor));
					upd.alignment = _arkit_alignment_to_plane_alignment(ar_plane_anchor_get_alignment(anchor));
					upd.classification_label = _plane_classification_to_label(anchor);

					_extract_plane_geometry(anchor, upd.vertices, upd.indices, upd.bounds_size);

					updates.push_back(upd);
					return true;
				});

				// Process updated planes.
				ar_plane_anchors_enumerate_anchors(updated, ^bool(ar_plane_anchor_t anchor) {
					PlaneUpdate upd;
					upd.type = PlaneUpdate::UPDATED;

					uuid_t uuid;
					ar_plane_anchor_get_identifier(anchor, uuid);
					upd.anchor_id_hash = uuid_to_hash(uuid);
					upd.anchor_uuid_str = uuid_to_string(uuid);

					upd.transform = _simd4x4_to_transform3d(ar_plane_anchor_get_origin_from_anchor_transform(anchor));
					upd.alignment = _arkit_alignment_to_plane_alignment(ar_plane_anchor_get_alignment(anchor));
					upd.classification_label = _plane_classification_to_label(anchor);

					_extract_plane_geometry(anchor, upd.vertices, upd.indices, upd.bounds_size);

					updates.push_back(upd);
					return true;
				});

				// Process removed planes.
				ar_plane_anchors_enumerate_anchors(removed, ^bool(ar_plane_anchor_t anchor) {
					PlaneUpdate upd;
					upd.type = PlaneUpdate::REMOVED;

					uuid_t uuid;
					ar_plane_anchor_get_identifier(anchor, uuid);
					upd.anchor_id_hash = uuid_to_hash(uuid);
					upd.anchor_uuid_str = uuid_to_string(uuid);

					updates.push_back(upd);
					return true;
				});

				if (updates.size() > 0) {
					MutexLock lock(plane_mutex);
					for (uint32_t i = 0; i < updates.size(); i++) {
						pending_plane_updates.push_back(updates[i]);
					}
				}
			});

	print_verbose("visionOS: Plane detection provider initialized.");
}

void VisionOSSceneUnderstanding::teardown_plane_detection() {
	if (plane_detection_provider != nullptr) {
		ar_plane_detection_provider_set_update_handler(plane_detection_provider, nullptr, nullptr);
		plane_detection_provider = nullptr;
	}
}

void VisionOSSceneUnderstanding::process_plane_updates() {
	LocalVector<PlaneUpdate> updates;
	{
		MutexLock lock(plane_mutex);
		updates = pending_plane_updates;
		pending_plane_updates.clear();
	}

	if (updates.size() == 0) {
		return;
	}

	XRServer *xr_server = XRServer::get_singleton();
	ERR_FAIL_NULL(xr_server);

	for (uint32_t i = 0; i < updates.size(); i++) {
		const PlaneUpdate &upd = updates[i];

		switch (upd.type) {
			case PlaneUpdate::ADDED: {
				Ref<VisionOSPlaneTracker> tracker;
				tracker.instantiate();
				tracker->set_tracker_name("visionos/plane/" + upd.anchor_uuid_str);
				tracker->set_tracker_desc(upd.classification_label);

				tracker->set_pose(SNAME("default"), upd.transform, Vector3(), Vector3());
				tracker->set_bounds_size(upd.bounds_size);
				tracker->set_plane_alignment(upd.alignment);
				tracker->set_plane_label(upd.classification_label);

				if (upd.vertices.size() >= 3) {
					tracker->set_mesh_data(upd.transform, upd.vertices, upd.indices);
				}

				plane_trackers[upd.anchor_id_hash] = tracker;
				xr_server->add_tracker(tracker);
			} break;

			case PlaneUpdate::UPDATED: {
				Ref<VisionOSPlaneTracker> *tracker_ptr = plane_trackers.getptr(upd.anchor_id_hash);
				if (tracker_ptr == nullptr) {
					break;
				}
				Ref<VisionOSPlaneTracker> tracker = *tracker_ptr;

				tracker->set_pose(SNAME("default"), upd.transform, Vector3(), Vector3());
				tracker->set_bounds_size(upd.bounds_size);
				tracker->set_plane_alignment(upd.alignment);
				tracker->set_plane_label(upd.classification_label);

				if (upd.vertices.size() >= 3) {
					tracker->set_mesh_data(upd.transform, upd.vertices, upd.indices);
				}
			} break;

			case PlaneUpdate::REMOVED: {
				Ref<VisionOSPlaneTracker> *tracker_ptr = plane_trackers.getptr(upd.anchor_id_hash);
				if (tracker_ptr == nullptr) {
					break;
				}
				Ref<VisionOSPlaneTracker> tracker = *tracker_ptr;

				tracker->invalidate_pose(SNAME("default"));
				xr_server->remove_tracker(tracker);
				plane_trackers.erase(upd.anchor_id_hash);
			} break;
		}
	}
}

// ============================================================================
// Scene Reconstruction
// ============================================================================

static void _extract_mesh_geometry(ar_mesh_anchor_t p_anchor, PackedVector3Array &r_vertices, PackedVector3Array &r_normals, PackedInt32Array &r_indices) {
	ar_mesh_geometry_t geometry = ar_mesh_anchor_get_geometry(p_anchor);
	if (geometry == nullptr) {
		return;
	}

	// Extract vertices.
	ar_geometry_source_t vertex_source = ar_mesh_geometry_get_vertices(geometry);
	if (vertex_source == nullptr) {
		return;
	}

	size_t vertex_count = ar_geometry_source_get_count(vertex_source);
	if (vertex_count == 0) {
		return;
	}

	id<MTLBuffer> vertex_buffer = ar_geometry_source_get_buffer(vertex_source);
	if (vertex_buffer == nil) {
		return;
	}

	size_t vertex_offset = ar_geometry_source_get_offset(vertex_source);
	size_t vertex_stride = ar_geometry_source_get_stride(vertex_source);
	const uint8_t *vertex_data = (const uint8_t *)[vertex_buffer contents] + vertex_offset;

	r_vertices.resize(vertex_count);
	Vector3 *vert_write = r_vertices.ptrw();
	for (size_t i = 0; i < vertex_count; i++) {
		const float *v = (const float *)(vertex_data + i * vertex_stride);
		vert_write[i] = Vector3(v[0], v[1], v[2]);
	}

	// Extract normals.
	ar_geometry_source_t normal_source = ar_mesh_geometry_get_normals(geometry);
	if (normal_source != nullptr) {
		id<MTLBuffer> normal_buffer = ar_geometry_source_get_buffer(normal_source);
		if (normal_buffer != nil) {
			size_t normal_offset = ar_geometry_source_get_offset(normal_source);
			size_t normal_stride = ar_geometry_source_get_stride(normal_source);
			const uint8_t *normal_data = (const uint8_t *)[normal_buffer contents] + normal_offset;

			r_normals.resize(vertex_count);
			Vector3 *norm_write = r_normals.ptrw();
			for (size_t i = 0; i < vertex_count; i++) {
				const float *n = (const float *)(normal_data + i * normal_stride);
				norm_write[i] = Vector3(n[0], n[1], n[2]);
			}
		}
	}

	// Extract indices.
	ar_geometry_element_t face_element = ar_mesh_geometry_get_faces(geometry);
	if (face_element == nullptr) {
		return;
	}

	size_t face_count = ar_geometry_element_get_count(face_element);
	size_t indices_per_face = ar_geometry_element_get_index_count_per_primitive(face_element);
	size_t bytes_per_index = ar_geometry_element_get_bytes_per_index(face_element);

	id<MTLBuffer> index_buffer = ar_geometry_element_get_buffer(face_element);
	if (index_buffer == nil) {
		return;
	}

	const uint8_t *index_data = (const uint8_t *)[index_buffer contents];
	size_t total_indices = face_count * indices_per_face;

	r_indices.resize(total_indices);
	int32_t *idx_write = r_indices.ptrw();

	if (bytes_per_index == 2) {
		const uint16_t *src = (const uint16_t *)index_data;
		for (size_t i = 0; i < total_indices; i++) {
			idx_write[i] = (int32_t)src[i];
		}
	} else if (bytes_per_index == 4) {
		const uint32_t *src = (const uint32_t *)index_data;
		for (size_t i = 0; i < total_indices; i++) {
			idx_write[i] = (int32_t)src[i];
		}
	}
}

void VisionOSSceneUnderstanding::setup_scene_reconstruction() {
	if (!ar_scene_reconstruction_provider_is_supported()) {
		print_verbose("visionOS: Scene reconstruction is not supported on this device.");
		scene_reconstruction_enabled = false;
		return;
	}

	ar_scene_reconstruction_configuration_t config = ar_scene_reconstruction_configuration_create();
	// Enable classification for per-face labels (wall, floor, etc.).
	ar_scene_reconstruction_configuration_set_scene_reconstruction_mode(config, ar_scene_reconstruction_mode_classification);

	scene_reconstruction_provider = ar_scene_reconstruction_provider_create(config);

	ar_scene_reconstruction_provider_set_update_handler(scene_reconstruction_provider,
			dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
			^(ar_mesh_anchors_t added, ar_mesh_anchors_t updated, ar_mesh_anchors_t removed) {
				__block LocalVector<MeshUpdate> updates;

				ar_mesh_anchors_enumerate_anchors(added, ^bool(ar_mesh_anchor_t anchor) {
					MeshUpdate upd;
					upd.type = MeshUpdate::ADDED;

					uuid_t uuid;
					ar_mesh_anchor_get_identifier(anchor, uuid);
					upd.anchor_id_hash = uuid_to_hash(uuid);
					upd.anchor_uuid_str = uuid_to_string(uuid);

					upd.transform = _simd4x4_to_transform3d(ar_mesh_anchor_get_origin_from_anchor_transform(anchor));
					_extract_mesh_geometry(anchor, upd.vertices, upd.normals, upd.indices);

					updates.push_back(upd);
					return true;
				});

				ar_mesh_anchors_enumerate_anchors(updated, ^bool(ar_mesh_anchor_t anchor) {
					MeshUpdate upd;
					upd.type = MeshUpdate::UPDATED;

					uuid_t uuid;
					ar_mesh_anchor_get_identifier(anchor, uuid);
					upd.anchor_id_hash = uuid_to_hash(uuid);
					upd.anchor_uuid_str = uuid_to_string(uuid);

					upd.transform = _simd4x4_to_transform3d(ar_mesh_anchor_get_origin_from_anchor_transform(anchor));
					_extract_mesh_geometry(anchor, upd.vertices, upd.normals, upd.indices);

					updates.push_back(upd);
					return true;
				});

				ar_mesh_anchors_enumerate_anchors(removed, ^bool(ar_mesh_anchor_t anchor) {
					MeshUpdate upd;
					upd.type = MeshUpdate::REMOVED;

					uuid_t uuid;
					ar_mesh_anchor_get_identifier(anchor, uuid);
					upd.anchor_id_hash = uuid_to_hash(uuid);
					upd.anchor_uuid_str = uuid_to_string(uuid);

					updates.push_back(upd);
					return true;
				});

				if (updates.size() > 0) {
					MutexLock lock(mesh_mutex);
					for (uint32_t i = 0; i < updates.size(); i++) {
						pending_mesh_updates.push_back(updates[i]);
					}
				}
			});

	print_verbose("visionOS: Scene reconstruction provider initialized.");
}

void VisionOSSceneUnderstanding::teardown_scene_reconstruction() {
	if (scene_reconstruction_provider != nullptr) {
		ar_scene_reconstruction_provider_set_update_handler(scene_reconstruction_provider, nullptr, nullptr);
		scene_reconstruction_provider = nullptr;
	}
}

void VisionOSSceneUnderstanding::process_mesh_updates() {
	LocalVector<MeshUpdate> updates;
	{
		MutexLock lock(mesh_mutex);
		updates = pending_mesh_updates;
		pending_mesh_updates.clear();
	}

	if (updates.size() == 0) {
		return;
	}

	XRServer *xr_server = XRServer::get_singleton();
	ERR_FAIL_NULL(xr_server);

	for (uint32_t i = 0; i < updates.size(); i++) {
		const MeshUpdate &upd = updates[i];

		switch (upd.type) {
			case MeshUpdate::ADDED: {
				Ref<VisionOSMeshTracker> tracker;
				tracker.instantiate();
				tracker->set_tracker_name("visionos/mesh/" + upd.anchor_uuid_str);
				tracker->set_tracker_desc("Scene mesh");

				tracker->set_pose(SNAME("default"), upd.transform, Vector3(), Vector3());

				if (upd.vertices.size() >= 3) {
					tracker->set_mesh_data_3d(upd.vertices, upd.normals, upd.indices);
				}

				mesh_trackers[upd.anchor_id_hash] = tracker;
				xr_server->add_tracker(tracker);
			} break;

			case MeshUpdate::UPDATED: {
				Ref<VisionOSMeshTracker> *tracker_ptr = mesh_trackers.getptr(upd.anchor_id_hash);
				if (tracker_ptr == nullptr) {
					break;
				}
				Ref<VisionOSMeshTracker> tracker = *tracker_ptr;

				tracker->set_pose(SNAME("default"), upd.transform, Vector3(), Vector3());

				if (upd.vertices.size() >= 3) {
					tracker->set_mesh_data_3d(upd.vertices, upd.normals, upd.indices);
				}
			} break;

			case MeshUpdate::REMOVED: {
				Ref<VisionOSMeshTracker> *tracker_ptr = mesh_trackers.getptr(upd.anchor_id_hash);
				if (tracker_ptr == nullptr) {
					break;
				}
				Ref<VisionOSMeshTracker> tracker = *tracker_ptr;

				tracker->invalidate_pose(SNAME("default"));
				xr_server->remove_tracker(tracker);
				mesh_trackers.erase(upd.anchor_id_hash);
			} break;
		}
	}
}

// ============================================================================
// World Anchors
// ============================================================================

static VisionOSWorldAnchorStore::Anchor world_anchor_record(ar_world_anchor_t p_anchor) {
	VisionOSWorldAnchorStore::Anchor result;
	uuid_t uuid;
	char text[37];
	ar_world_anchor_get_identifier(p_anchor, uuid);
	uuid_unparse_lower(uuid, text);
	result.uuid = text;
	result.transform = MTL::simd_to_transform3D(ar_world_anchor_get_origin_from_anchor_transform(p_anchor));
	result.tracked = ar_world_anchor_is_tracked(p_anchor) && VisionOSWorldAnchorStore::is_valid_transform(result.transform);
	result.shared = ar_world_anchor_is_shared_with_nearby_participants(p_anchor);
	result.observation_time = ar_world_anchor_get_timestamp(p_anchor);
	return result;
}

static std::string world_anchor_error(ar_error_t p_error, bool p_success) {
	if (p_error == nullptr) {
		return p_success ? "" : "ARKit world anchor operation failed without an error description.";
	}
	CFErrorRef error = ar_error_copy_cf_error(p_error);
	CFStringRef description = CFErrorCopyDescription(error);
	char buffer[1024];
	std::string result = CFStringGetCString(description, buffer, sizeof(buffer), kCFStringEncodingUTF8) ? buffer : "ARKit world anchor operation failed.";
	CFRelease(description);
	CFRelease(error);
	return result;
}

void VisionOSSceneUnderstanding::setup_anchor_lifecycle() {
	if (anchor_lifecycle_installed || ar_session == nullptr || world_tracking_provider == nullptr) {
		return;
	}
	const auto store = anchor_store;
	const uint64_t observer = store->watch_provider();
	ar_world_tracking_provider_t provider = world_tracking_provider;
	visionos_tracking_access().perform([&] {
		// Blocks created inside a [&] lambda would capture these by reference to this stack frame, and ARKit invokes them later.
		const auto block_store = store;
		const uint64_t block_observer = observer;
		const ar_world_tracking_provider_t block_provider = provider;
		ar_session_set_data_provider_state_change_handler(ar_session,
				dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
				^(ar_data_providers_t providers, ar_data_provider_state_t state, ar_error_t error, ar_data_provider_t failed_provider) {
					ar_data_providers_enumerate_data_providers(providers, ^bool(ar_data_provider_t changed_provider) {
						if (changed_provider == block_provider) {
							block_store->provider_changed(block_observer);
							return false;
						}
						return true;
					});
				});
	});
	anchor_lifecycle_installed = true;
}

void VisionOSSceneUnderstanding::setup_world_anchors() {
	ERR_FAIL_NULL(world_tracking_provider);
	const auto store = anchor_store;
	const uint64_t generation = store->start(anchor_provider_revision);
	if (!generation) {
		return;
	}
	anchor_sharing_available = std::make_shared<SafeFlag>();
	const auto sharing = anchor_sharing_available;
	anchor_handlers_installed = true;
	visionos_tracking_access().perform([&] {
		// Blocks created inside a [&] lambda would capture these by reference to this stack frame, and ARKit invokes them later.
		const auto block_store = store;
		const uint64_t block_generation = generation;
		const auto block_sharing = sharing;
		ar_world_tracking_provider_set_anchor_update_handler(world_tracking_provider,
				dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
				^(ar_world_anchors_t added, ar_world_anchors_t updated, ar_world_anchors_t removed) {
					for (int kind = 0; kind < 3; kind++) {
						ar_world_anchors_t collection = kind == 0 ? added : (kind == 1 ? updated : removed);
						if (collection == nullptr) {
							continue;
						}
						ar_world_anchors_enumerate_anchors(collection, ^bool(ar_world_anchor_t anchor) {
							block_store->update(block_generation, world_anchor_record(anchor), kind == 2);
							return true;
						});
					}
				});
		ar_world_tracking_provider_set_world_anchor_sharing_availability_update_handler(world_tracking_provider,
				dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0),
				^(ar_world_anchor_sharing_availability_t availability) {
					if (block_store->get_status().generation == block_generation && block_store->get_status().running) {
						block_sharing->set_to(availability == ar_world_anchor_sharing_availability_available);
					}
				});
	});
	initial_enumeration_request = submit_anchor_enumeration(!enumeration_for_caller);
}

void VisionOSSceneUnderstanding::teardown_world_anchors() {
	anchor_store->stop();
	if (anchor_handlers_installed && world_tracking_provider != nullptr) {
		visionos_tracking_access().perform([&] {
			ar_world_tracking_provider_set_anchor_update_handler(world_tracking_provider, nullptr, nullptr);
			ar_world_tracking_provider_set_world_anchor_sharing_availability_update_handler(world_tracking_provider, nullptr, nullptr);
		});
	}
	anchor_handlers_installed = false;
	anchor_provider_running = false;
	anchor_sharing_available->clear();
}

void VisionOSSceneUnderstanding::process_anchor_updates() {
	if (!world_anchors_enabled || uninitializing) {
		return;
	}
	const uint64_t lifecycle = lifecycle_revision;
	const auto provider_state = anchor_store->sample_provider_state([&] {
		return is_world_anchor_supported() && world_tracking_provider != nullptr &&
				visionos_tracking_access().perform([&] { return ar_data_provider_get_state(world_tracking_provider) == ar_data_provider_state_running; });
	});
	const bool running = provider_state.running;
	const uint64_t provider_revision = provider_state.revision;
	if (running != anchor_provider_running || provider_revision != anchor_provider_revision) {
		anchor_provider_revision = provider_revision;
		teardown_world_anchors();
		const HashMap<String, Ref<VisionOSAnchorTracker>> old_anchor_trackers(anchor_trackers);
		anchor_trackers.clear();
		for (const KeyValue<String, Ref<VisionOSAnchorTracker>> &entry : old_anchor_trackers) {
			entry.value->invalidate_pose(SNAME("default"));
			entry.value->set_anchor_tracked(false);
			XRServer::get_singleton()->remove_tracker(entry.value);
			if (lifecycle != lifecycle_revision) {
				return;
			}
		}
		if (running) {
			anchor_provider_running = true;
			setup_world_anchors();
		}
	}
	XRServer *xr_server = XRServer::get_singleton();
	ERR_FAIL_NULL(xr_server);
	// Invalidate old-generation trackers even if the new enumeration has not arrived.
	for (const auto &anchor : anchor_store->get_anchors()) {
		String uuid = String::utf8(anchor.uuid.c_str());
		if (anchor.removed && !anchor_trackers.has(uuid)) {
			continue;
		}
		Ref<VisionOSAnchorTracker> tracker;
		if (anchor_trackers.has(uuid)) {
			tracker = anchor_trackers[uuid];
		} else {
			tracker.instantiate();
			tracker->set_anchor_uuid(uuid);
			tracker->set_tracker_name("visionos/anchor/" + uuid);
			anchor_trackers[uuid] = tracker;
			xr_server->add_tracker(tracker);
			if (lifecycle != lifecycle_revision) {
				return;
			}
		}
		tracker->set_shared_with_nearby_participants(anchor.shared);
		if (anchor.tracked) {
			tracker->set_pose(SNAME("default"), anchor.transform, Vector3(), Vector3());
		} else {
			tracker->invalidate_pose(SNAME("default"));
		}
		tracker->set_anchor_tracked(anchor.tracked);
		if (lifecycle != lifecycle_revision) {
			return;
		}
		if (anchor.removed) {
			anchor_trackers.erase(uuid);
			xr_server->remove_tracker(tracker);
			if (lifecycle != lifecycle_revision) {
				return;
			}
		}
	}
}

// ============================================================================
// World Anchor Public API
// ============================================================================

Ref<VisionOSAnchorTracker> VisionOSSceneUnderstanding::create_anchor(const Transform3D &p_transform, bool p_shared_with_nearby_participants) {
	uint64_t request = request_create_anchor(p_transform, p_shared_with_nearby_participants);
	if (!request) {
		ERR_PRINT(String::utf8(anchor_store->get_last_error().c_str()));
		return Ref<VisionOSAnchorTracker>();
	}
	for (const auto &anchor : anchor_store->get_anchors()) {
		if (anchor.create_request == request || anchor.uuid == last_created_uuid) {
			String uuid = String::utf8(anchor.uuid.c_str());
			Ref<VisionOSAnchorTracker> tracker;
			tracker.instantiate();
			tracker->set_anchor_uuid(uuid);
			tracker->set_tracker_name("visionos/anchor/" + uuid);
			tracker->set_shared_with_nearby_participants(p_shared_with_nearby_participants);
			anchor_trackers[uuid] = tracker;
			XRServer::get_singleton()->add_tracker(tracker);
			VisionOSSpatialAnchorCapability::get_singleton()->track_legacy_request(request, tracker);
			return tracker;
		}
	}
	return Ref<VisionOSAnchorTracker>();
}

uint64_t VisionOSSceneUnderstanding::request_create_anchor(const Transform3D &p_transform, bool p_shared) {
	if (!activate_world_anchors()) {
		return anchor_store->reject("Local world anchors require an enabled, running native world tracking provider.");
	}
	if (!VisionOSWorldAnchorStore::is_valid_transform(p_transform)) {
		return anchor_store->reject("Anchor transform must be a finite rigid transform in raw tracking-origin meters.");
	}
	if (p_shared && !is_anchor_sharing_available()) {
		return anchor_store->reject("Shared anchors are unavailable; local fallback is not permitted.");
	}
	Basis b = p_transform.basis;
	Vector3 o = p_transform.origin;
	simd_float4x4 mat = {
		(simd_float4){ (float)b[0][0], (float)b[1][0], (float)b[2][0], 0.0f },
		(simd_float4){ (float)b[0][1], (float)b[1][1], (float)b[2][1], 0.0f },
		(simd_float4){ (float)b[0][2], (float)b[1][2], (float)b[2][2], 0.0f },
		(simd_float4){ (float)o.x, (float)o.y, (float)o.z, 1.0f }
	};

	ar_world_anchor_t anchor = p_shared ? ar_world_anchor_shared_with_nearby_participants_create(mat) : ar_world_anchor_create_with_origin_from_anchor_transform(mat);
	if (anchor == nullptr) {
		return anchor_store->reject("ARKit could not allocate a world anchor.");
	}
	uuid_t uuid;
	ar_world_anchor_get_identifier(anchor, uuid);
	char text[37];
	uuid_unparse_lower(uuid, text);
	const auto store = anchor_store;
	const uint64_t generation = store->get_status().generation;
	const uint64_t request = store->begin("create", text, p_transform, p_shared);
	if (request) {
		last_created_uuid = text;
		visionos_tracking_access().perform([&] {
			// Blocks created inside a [&] lambda would capture these by reference to this stack frame, and ARKit invokes them later.
			const auto block_store = store;
			const uint64_t block_generation = generation;
			const uint64_t block_request = request;
			ar_world_tracking_provider_add_anchor(world_tracking_provider, anchor, ^(ar_world_anchor_t p_anchor, bool successful, ar_error_t error) {
				block_store->complete(block_generation, block_request, successful && error == nullptr, error ? ar_error_get_error_code(error) : FAILED, world_anchor_error(error, successful));
			});
		});
	}
	return request;
}

void VisionOSSceneUnderstanding::remove_anchor(Ref<VisionOSAnchorTracker> p_anchor) {
	ERR_FAIL_COND(p_anchor.is_null());
	uint64_t request = request_remove_anchor(p_anchor->get_anchor_uuid());
	if (!request) {
		ERR_PRINT(String::utf8(anchor_store->get_last_error().c_str()));
	} else {
		VisionOSSpatialAnchorCapability::get_singleton()->track_legacy_request(request, p_anchor);
	}
}

uint64_t VisionOSSceneUnderstanding::request_remove_anchor(const String &p_uuid) {
	if (!activate_world_anchors()) {
		return anchor_store->reject("World tracking is unavailable.");
	}
	uuid_t uuid;
	if (uuid_parse(p_uuid.utf8().get_data(), uuid) != 0) {
		return anchor_store->reject("Invalid world anchor UUID.");
	}
	char text[37];
	uuid_unparse_lower(uuid, text);
	const auto store = anchor_store;
	const uint64_t generation = store->get_status().generation;
	const uint64_t request = store->begin("remove", text);
	if (request) {
		visionos_tracking_access().perform([&] {
			// Blocks created inside a [&] lambda would capture these by reference to this stack frame, and ARKit invokes them later.
			const auto block_store = store;
			const uint64_t block_generation = generation;
			const uint64_t block_request = request;
			ar_world_tracking_provider_remove_anchor_with_identifier(world_tracking_provider, uuid, ^(ar_world_anchor_t p_removed, bool successful, ar_error_t error) {
				block_store->complete(block_generation, block_request, successful && error == nullptr, error ? ar_error_get_error_code(error) : FAILED, world_anchor_error(error, successful));
			});
		});
	}
	return request;
}

bool VisionOSSceneUnderstanding::is_anchor_sharing_available() const {
	return anchor_store->get_status().running && anchor_sharing_available->is_set();
}

bool VisionOSSceneUnderstanding::is_world_anchor_supported() const {
#if TARGET_OS_SIMULATOR
	return false;
#else
	return ar_world_tracking_provider_is_supported();
#endif
}

bool VisionOSSceneUnderstanding::activate_world_anchors() {
	if (uninitializing || !is_world_anchor_supported() || world_tracking_provider == nullptr) {
		return false;
	}
	if (!world_anchors_enabled) {
		world_anchors_enabled = true;
		setup_anchor_lifecycle();
		process_anchor_updates();
	}
	return anchor_store->get_status().running;
}

uint64_t VisionOSSceneUnderstanding::request_anchor_enumeration() {
	const bool was_enabled = world_anchors_enabled;
	enumeration_for_caller = true;
	const bool activated = activate_world_anchors();
	enumeration_for_caller = false;
	if (!activated) {
		return anchor_store->reject("World tracking is unavailable; wait for the native provider to run.");
	}
	if (!was_enabled) {
		return initial_enumeration_request;
	}
	return submit_anchor_enumeration(false);
}

uint64_t VisionOSSceneUnderstanding::submit_anchor_enumeration(bool p_internal) {
	if (!is_world_anchor_supported() || !anchor_store->get_status().running) {
		return anchor_store->reject("World tracking is unavailable.");
	}
	const auto store = anchor_store;
	const uint64_t generation = store->get_status().generation;
	const uint64_t request = store->begin("enumerate", "", Transform3D(), false, p_internal);
	if (request) {
		visionos_tracking_access().perform([&] {
			// Blocks created inside a [&] lambda would capture these by reference to this stack frame, and ARKit invokes them later.
			const auto block_store = store;
			const uint64_t block_generation = generation;
			const uint64_t block_request = request;
			ar_world_tracking_provider_copy_all_world_anchors(world_tracking_provider, ^(ar_world_anchors_t anchors) {
				const double observed_at = CACurrentMediaTime();
				__block std::vector<VisionOSWorldAnchorStore::Anchor> records;
				if (anchors != nullptr) {
					ar_world_anchors_enumerate_anchors(anchors, ^bool(ar_world_anchor_t anchor) {
						records.push_back(world_anchor_record(anchor));
						return records.size() <= VisionOSWorldAnchorStore::MAX_ANCHORS;
					});
				}
				block_store->enumerated(block_generation, block_request, records, anchors != nullptr, observed_at);
			});
		});
	}
	return request;
}

#endif // VISIONOS_ENABLED
