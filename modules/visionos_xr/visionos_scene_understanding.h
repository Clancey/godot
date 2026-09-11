/**************************************************************************/
/*  visionos_scene_understanding.h                                        */
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

#pragma once

#ifdef VISIONOS_ENABLED

#include "visionos_anchor_tracker.h"
#include "visionos_definitions.h"
#include "visionos_mesh_tracker.h"
#include "visionos_plane_tracker.h"
#include "visionos_world_anchor_store.h"

#include "core/os/mutex.h"
#include "core/templates/hash_map.h"
#include "core/templates/hash_set.h"
#include "core/templates/local_vector.h"
#include "core/templates/safe_refcount.h"

#include <uuid/uuid.h>

#include <memory>

class VisionOSSceneUnderstanding {
public:
	// Reads the project settings. Call before initialize().
	void configure_from_project_settings();

	void initialize(ar_session_t p_session, ar_world_tracking_provider_t p_world_tracking_provider);
	void uninitialize();
	void add_providers_to(ar_data_providers_t p_data_providers);
	void process();

	// Local world anchors do not require world-sensing authorization.
	VisionOSAuthorizationStatus authorization = VisionOSAuthorizationStatus::NOT_DETERMINED;

	bool enabled() const { return plane_detection_enabled || scene_reconstruction_enabled || world_anchors_enabled; }
	bool active() const { return enabled() && authorization == VisionOSAuthorizationStatus::ALLOWED; }
	bool requires_world_sensing() const { return plane_detection_enabled || scene_reconstruction_enabled; }

	bool is_plane_detection_enabled() const { return plane_detection_enabled; }
	bool is_scene_reconstruction_enabled() const { return scene_reconstruction_enabled; }
	bool is_world_anchors_enabled() const { return world_anchors_enabled; }
	bool is_world_anchor_supported() const;
	std::shared_ptr<VisionOSWorldAnchorStore> get_anchor_store() const { return anchor_store; }
	uint64_t request_create_anchor(const Transform3D &p_transform, bool p_shared = false);
	uint64_t request_remove_anchor(const String &p_uuid);
	uint64_t request_anchor_enumeration();

	// World anchor public API
	Ref<VisionOSAnchorTracker> create_anchor(const Transform3D &p_transform, bool p_shared_with_nearby_participants = false);
	void remove_anchor(Ref<VisionOSAnchorTracker> p_anchor);
	bool is_anchor_sharing_available() const;

private:
	// Configuration
	bool plane_detection_enabled = false;
	bool scene_reconstruction_enabled = false;
	bool world_anchors_enabled = false;
	uint64_t lifecycle_revision = 0;
	bool uninitializing = false;

	// ARKit providers
	ar_session_t ar_session = nullptr;
	ar_world_tracking_provider_t world_tracking_provider = nullptr;
	ar_plane_detection_provider_t plane_detection_provider = nullptr;
	ar_scene_reconstruction_provider_t scene_reconstruction_provider = nullptr;

	// UUID helper
	static String uuid_to_string(const uuid_t p_uuid);
	static uint64_t uuid_to_hash(const uuid_t p_uuid);

	// ---- Plane detection ----
	struct PlaneUpdate {
		enum Type { ADDED,
			UPDATED,
			REMOVED };
		Type type;
		uint64_t anchor_id_hash;
		String anchor_uuid_str;
		Transform3D transform;
		Vector2 bounds_size;
		VisionOSPlaneTracker::PlaneAlignment alignment;
		String classification_label;
		PackedVector2Array vertices;
		PackedInt32Array indices;
	};

	Mutex plane_mutex;
	LocalVector<PlaneUpdate> pending_plane_updates;
	HashMap<uint64_t, Ref<VisionOSPlaneTracker>> plane_trackers;

	void setup_plane_detection();
	void teardown_plane_detection();
	void process_plane_updates();

	// ---- Scene reconstruction ----
	struct MeshUpdate {
		enum Type { ADDED,
			UPDATED,
			REMOVED };
		Type type;
		uint64_t anchor_id_hash;
		String anchor_uuid_str;
		Transform3D transform;
		PackedVector3Array vertices;
		PackedVector3Array normals;
		PackedInt32Array indices;
	};

	Mutex mesh_mutex;
	LocalVector<MeshUpdate> pending_mesh_updates;
	HashMap<uint64_t, Ref<VisionOSMeshTracker>> mesh_trackers;

	void setup_scene_reconstruction();
	void teardown_scene_reconstruction();
	void process_mesh_updates();

	// ---- World anchors ----
	std::shared_ptr<VisionOSWorldAnchorStore> anchor_store = std::make_shared<VisionOSWorldAnchorStore>();
	std::shared_ptr<SafeFlag> anchor_sharing_available = std::make_shared<SafeFlag>();
	HashMap<String, Ref<VisionOSAnchorTracker>> anchor_trackers;
	bool anchor_provider_running = false;
	bool anchor_handlers_installed = false;
	std::string last_created_uuid;
	uint64_t initial_enumeration_request = 0;
	bool enumeration_for_caller = false;
	bool anchor_lifecycle_installed = false;
	uint64_t anchor_provider_revision = 0;
	void setup_anchor_lifecycle();
	uint64_t submit_anchor_enumeration(bool p_internal);
	bool activate_world_anchors();

	void setup_world_anchors();
	void teardown_world_anchors();
	void process_anchor_updates();
};

#endif // VISIONOS_ENABLED
