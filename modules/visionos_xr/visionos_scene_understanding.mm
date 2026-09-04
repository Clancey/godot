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

#include "core/config/project_settings.h"
#include "core/object/class_db.h"
#include "servers/xr/xr_server.h"

#import <ARKit/plane_detection.h>
#import <ARKit/scene_reconstruction.h>
#import <ARKit/world_tracking.h>
#import <Metal/Metal.h>

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
}

void VisionOSSceneUnderstanding::initialize(ar_session_t p_session, ar_world_tracking_provider_t p_world_tracking_provider) {
	ar_session = p_session;
	world_tracking_provider = p_world_tracking_provider;

	if (plane_detection_enabled) {
		setup_plane_detection();
	}
	if (scene_reconstruction_enabled) {
		setup_scene_reconstruction();
	}
	if (world_anchors_enabled) {
		setup_world_anchors();
	}
}

void VisionOSSceneUnderstanding::uninitialize() {
	XRServer *xr_server = XRServer::get_singleton();

	// Teardown providers (clears update handlers).
	teardown_plane_detection();
	teardown_scene_reconstruction();
	teardown_world_anchors();

	// Remove all trackers from XR server.
	if (xr_server) {
		for (const KeyValue<uint64_t, Ref<VisionOSPlaneTracker>> &kv : plane_trackers) {
			xr_server->remove_tracker(kv.value);
		}
		for (const KeyValue<uint64_t, Ref<VisionOSMeshTracker>> &kv : mesh_trackers) {
			xr_server->remove_tracker(kv.value);
		}
		for (const KeyValue<uint64_t, Ref<VisionOSAnchorTracker>> &kv : anchor_trackers) {
			xr_server->remove_tracker(kv.value);
		}
	}

	plane_trackers.clear();
	mesh_trackers.clear();
	anchor_trackers.clear();
	created_anchor_uuids.clear();

	{
		MutexLock lock(plane_mutex);
		pending_plane_updates.clear();
	}
	{
		MutexLock lock(mesh_mutex);
		pending_mesh_updates.clear();
	}
	{
		MutexLock lock(anchor_mutex);
		pending_anchor_updates.clear();
	}

	ar_session = nullptr;
	world_tracking_provider = nullptr;
	plane_detection_provider = nullptr;
	scene_reconstruction_provider = nullptr;
}

void VisionOSSceneUnderstanding::add_providers_to(ar_data_providers_t p_data_providers) {
	if (plane_detection_enabled && plane_detection_provider != nullptr) {
		ar_data_providers_add_data_provider(p_data_providers, plane_detection_provider);
	}
	if (scene_reconstruction_enabled && scene_reconstruction_provider != nullptr) {
		ar_data_providers_add_data_provider(p_data_providers, scene_reconstruction_provider);
	}
	// World anchors use the existing world_tracking_provider, no additional provider needed.
}

void VisionOSSceneUnderstanding::process() {
	process_plane_updates();
	process_mesh_updates();
	process_anchor_updates();
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

void VisionOSSceneUnderstanding::setup_world_anchors() {
	ERR_FAIL_NULL(world_tracking_provider);

	ar_world_tracking_provider_set_anchor_update_handler(world_tracking_provider,
			dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
			^(ar_world_anchors_t added, ar_world_anchors_t updated, ar_world_anchors_t removed) {
				__block LocalVector<AnchorUpdate> updates;

				ar_world_anchors_enumerate_anchors(added, ^bool(ar_world_anchor_t anchor) {
					AnchorUpdate upd;
					upd.type = AnchorUpdate::ADDED;

					uuid_t uuid;
					ar_world_anchor_get_identifier(anchor, uuid);
					upd.anchor_id_hash = uuid_to_hash(uuid);
					upd.anchor_uuid_str = uuid_to_string(uuid);
					upd.transform = _simd4x4_to_transform3d(ar_world_anchor_get_origin_from_anchor_transform(anchor));
					upd.is_tracked = ar_world_anchor_is_tracked(anchor);
					upd.is_shared = ar_world_anchor_is_shared_with_nearby_participants(anchor);

					updates.push_back(upd);
					return true;
				});

				ar_world_anchors_enumerate_anchors(updated, ^bool(ar_world_anchor_t anchor) {
					AnchorUpdate upd;
					upd.type = AnchorUpdate::UPDATED;

					uuid_t uuid;
					ar_world_anchor_get_identifier(anchor, uuid);
					upd.anchor_id_hash = uuid_to_hash(uuid);
					upd.anchor_uuid_str = uuid_to_string(uuid);
					upd.transform = _simd4x4_to_transform3d(ar_world_anchor_get_origin_from_anchor_transform(anchor));
					upd.is_tracked = ar_world_anchor_is_tracked(anchor);
					upd.is_shared = ar_world_anchor_is_shared_with_nearby_participants(anchor);

					updates.push_back(upd);
					return true;
				});

				ar_world_anchors_enumerate_anchors(removed, ^bool(ar_world_anchor_t anchor) {
					AnchorUpdate upd;
					upd.type = AnchorUpdate::REMOVED;

					uuid_t uuid;
					ar_world_anchor_get_identifier(anchor, uuid);
					upd.anchor_id_hash = uuid_to_hash(uuid);
					upd.anchor_uuid_str = uuid_to_string(uuid);
					upd.is_tracked = false;

					updates.push_back(upd);
					return true;
				});

				if (updates.size() > 0) {
					MutexLock lock(anchor_mutex);
					for (uint32_t i = 0; i < updates.size(); i++) {
						pending_anchor_updates.push_back(updates[i]);
					}
				}
			});

	// Monitor anchor sharing availability (SharePlay with nearby participants).
	ar_world_tracking_provider_set_world_anchor_sharing_availability_update_handler(world_tracking_provider,
			dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0),
			^(ar_world_anchor_sharing_availability_t sharing_availability) {
				if (sharing_availability == ar_world_anchor_sharing_availability_available) {
					anchor_sharing_available.set();
					print_verbose("visionOS: World anchor sharing is now available (SharePlay session active).");
				} else {
					anchor_sharing_available.clear();
					print_verbose("visionOS: World anchor sharing is no longer available.");
				}
			});

	print_verbose("visionOS: World anchor tracking initialized.");
}

void VisionOSSceneUnderstanding::teardown_world_anchors() {
	if (world_tracking_provider != nullptr) {
		ar_world_tracking_provider_set_anchor_update_handler(world_tracking_provider, nullptr, nullptr);
		ar_world_tracking_provider_set_world_anchor_sharing_availability_update_handler(world_tracking_provider, nullptr, nullptr);
	}
	anchor_sharing_available.clear();
}

void VisionOSSceneUnderstanding::process_anchor_updates() {
	LocalVector<AnchorUpdate> updates;
	{
		MutexLock lock(anchor_mutex);
		updates = pending_anchor_updates;
		pending_anchor_updates.clear();
	}

	if (updates.size() == 0) {
		return;
	}

	XRServer *xr_server = XRServer::get_singleton();
	ERR_FAIL_NULL(xr_server);

	for (uint32_t i = 0; i < updates.size(); i++) {
		const AnchorUpdate &upd = updates[i];

		switch (upd.type) {
			case AnchorUpdate::ADDED: {
				// Check if we already have a tracker for this anchor (created via create_anchor).
				Ref<VisionOSAnchorTracker> *existing_ptr = anchor_trackers.getptr(upd.anchor_id_hash);
				if (existing_ptr != nullptr) {
					// Update the existing tracker with confirmed data from ARKit.
					Ref<VisionOSAnchorTracker> tracker = *existing_ptr;
					tracker->set_pose(SNAME("default"), upd.transform, Vector3(), Vector3());
					tracker->set_anchor_tracked(upd.is_tracked);
					tracker->set_shared_with_nearby_participants(upd.is_shared);
				} else {
					// New anchor discovered (e.g. persisted anchor from a previous session, or shared from another device).
					Ref<VisionOSAnchorTracker> tracker;
					tracker.instantiate();
					tracker->set_tracker_name("visionos/anchor/" + upd.anchor_uuid_str);
					tracker->set_tracker_desc(upd.is_shared ? "Shared world anchor" : "World anchor");
					tracker->set_anchor_uuid(upd.anchor_uuid_str);

					tracker->set_pose(SNAME("default"), upd.transform, Vector3(), Vector3());
					tracker->set_anchor_tracked(upd.is_tracked);
					tracker->set_shared_with_nearby_participants(upd.is_shared);

					anchor_trackers[upd.anchor_id_hash] = tracker;
					xr_server->add_tracker(tracker);
				}
			} break;

			case AnchorUpdate::UPDATED: {
				Ref<VisionOSAnchorTracker> *tracker_ptr = anchor_trackers.getptr(upd.anchor_id_hash);
				if (tracker_ptr == nullptr) {
					break;
				}
				Ref<VisionOSAnchorTracker> tracker = *tracker_ptr;

				tracker->set_pose(SNAME("default"), upd.transform, Vector3(), Vector3());
				tracker->set_anchor_tracked(upd.is_tracked);
				tracker->set_shared_with_nearby_participants(upd.is_shared);
			} break;

			case AnchorUpdate::REMOVED: {
				Ref<VisionOSAnchorTracker> *tracker_ptr = anchor_trackers.getptr(upd.anchor_id_hash);
				if (tracker_ptr == nullptr) {
					break;
				}
				Ref<VisionOSAnchorTracker> tracker = *tracker_ptr;

				tracker->invalidate_pose(SNAME("default"));
				tracker->set_anchor_tracked(false);
				xr_server->remove_tracker(tracker);
				anchor_trackers.erase(upd.anchor_id_hash);

				created_anchor_uuids.erase(upd.anchor_uuid_str);
			} break;
		}
	}
}

// ============================================================================
// World Anchor Public API
// ============================================================================

Ref<VisionOSAnchorTracker> VisionOSSceneUnderstanding::create_anchor(const Transform3D &p_transform, bool p_shared_with_nearby_participants) {
	ERR_FAIL_NULL_V(world_tracking_provider, Ref<VisionOSAnchorTracker>());

	if (!world_anchors_enabled) {
		ERR_PRINT("visionOS: World anchors are not enabled. Set xr/visionos/scene_understanding/enable_world_anchors to true.");
		return Ref<VisionOSAnchorTracker>();
	}

	if (p_shared_with_nearby_participants && !anchor_sharing_available.is_set()) {
		WARN_PRINT("visionOS: Anchor sharing requested but not available (no active SharePlay session with nearby participants). Creating local anchor instead.");
		p_shared_with_nearby_participants = false;
	}

	// Convert Transform3D to simd_float4x4.
	Basis b = p_transform.basis;
	Vector3 o = p_transform.origin;

	simd_float4x4 mat = {
		(simd_float4){ (float)b[0][0], (float)b[1][0], (float)b[2][0], 0.0f },
		(simd_float4){ (float)b[0][1], (float)b[1][1], (float)b[2][1], 0.0f },
		(simd_float4){ (float)b[0][2], (float)b[1][2], (float)b[2][2], 0.0f },
		(simd_float4){ (float)o.x, (float)o.y, (float)o.z, 1.0f }
	};

	ar_world_anchor_t anchor;
	if (p_shared_with_nearby_participants) {
		anchor = ar_world_anchor_shared_with_nearby_participants_create(mat);
	} else {
		anchor = ar_world_anchor_create_with_origin_from_anchor_transform(mat);
	}

	ar_world_tracking_provider_add_anchor(world_tracking_provider, anchor, ^(ar_world_anchor_t p_anchor, bool successful, ar_error_t error) {
		if (!successful) {
			print_verbose("visionOS: Failed to add world anchor.");
		}
	});

	// The anchor will appear via the update handler when ARKit confirms it.
	// We return a placeholder tracker here. The real tracking data will arrive
	// through the update handler and be matched by UUID.
	uuid_t uuid;
	ar_world_anchor_get_identifier(anchor, uuid);
	String uuid_str = uuid_to_string(uuid);

	created_anchor_uuids.insert(uuid_str);

	// Create a temporary tracker that will be updated when ARKit confirms.
	Ref<VisionOSAnchorTracker> tracker;
	tracker.instantiate();
	tracker->set_tracker_name("visionos/anchor/" + uuid_str);
	tracker->set_tracker_desc(p_shared_with_nearby_participants ? "Shared world anchor" : "World anchor");
	tracker->set_anchor_uuid(uuid_str);
	tracker->set_pose(SNAME("default"), p_transform, Vector3(), Vector3());
	tracker->set_anchor_tracked(false); // Not confirmed yet.
	tracker->set_shared_with_nearby_participants(p_shared_with_nearby_participants);

	uint64_t hash = uuid_to_hash(uuid);
	anchor_trackers[hash] = tracker;

	XRServer *xr_server = XRServer::get_singleton();
	if (xr_server) {
		xr_server->add_tracker(tracker);
	}

	return tracker;
}

void VisionOSSceneUnderstanding::remove_anchor(Ref<VisionOSAnchorTracker> p_anchor) {
	ERR_FAIL_NULL(world_tracking_provider);
	ERR_FAIL_COND(p_anchor.is_null());

	String uuid_str = p_anchor->get_anchor_uuid();

	// Remove by identifier - avoids storing ObjC anchor objects in C++ containers.
	uuid_t uuid;
	CharString uuid_utf8 = uuid_str.utf8();
	if (uuid_parse(uuid_utf8.get_data(), uuid) == 0) {
		ar_world_tracking_provider_remove_anchor_with_identifier(world_tracking_provider, uuid, ^(ar_world_anchor_t p_removed_anchor, bool successful, ar_error_t error) {
			if (!successful) {
				print_verbose("visionOS: Failed to remove world anchor.");
			}
		});
	}

	created_anchor_uuids.erase(uuid_str);

	// The removal confirmation will come via the update handler.
}

bool VisionOSSceneUnderstanding::is_anchor_sharing_available() const {
	return anchor_sharing_available.is_set();
}

#endif // VISIONOS_ENABLED
