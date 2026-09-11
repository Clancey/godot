/**************************************************************************/
/*  visionos_spatial_anchor_capability.h                                  */
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

#include "core/object/ref_counted.h"
#include "core/variant/typed_array.h"

class VisionOSSceneUnderstanding;

class VisionOSSpatialAnchorCapability : public Object {
	GDCLASS(VisionOSSpatialAnchorCapability, Object);

public:
	static VisionOSSpatialAnchorCapability *get_singleton();

	VisionOSSpatialAnchorCapability();
	~VisionOSSpatialAnchorCapability();

	void set_scene_understanding(VisionOSSceneUnderstanding *p_scene_understanding);
	Dictionary get_world_anchor_status() const;
	int64_t request_create_anchor(const Transform3D &p_transform);
	int64_t request_remove_anchor(const String &p_uuid);
	int64_t request_anchor_enumeration();
	bool cancel_request(int64_t p_request);
	Dictionary get_anchor(const String &p_uuid) const;
	TypedArray<Dictionary> get_anchors() const;
	TypedArray<Dictionary> take_completed_requests();
	String get_last_error() const;
	void process();
	void track_legacy_request(uint64_t p_request, const Ref<VisionOSAnchorTracker> &p_tracker, const Callable &p_callback = Callable());

	// Mirrors OpenXRSpatialAnchorCapability API
	bool is_spatial_anchor_supported();
	bool is_spatial_persistence_supported();

	Ref<VisionOSAnchorTracker> create_new_anchor(const Transform3D &p_transform);
	void remove_anchor(Ref<VisionOSAnchorTracker> p_anchor_tracker);

	// Legacy callbacks run on the engine thread only after actual operation success.
	void persist_anchor(Ref<VisionOSAnchorTracker> p_anchor_tracker, const Callable &p_user_callback = Callable());
	void unpersist_anchor(Ref<VisionOSAnchorTracker> p_anchor_tracker, const Callable &p_user_callback = Callable());

	// visionOS-specific: SharePlay shared anchors
	bool is_sharing_available();
	Ref<VisionOSAnchorTracker> create_shared_anchor(const Transform3D &p_transform);

protected:
	static void _bind_methods();

private:
	static VisionOSSpatialAnchorCapability *singleton;
	VisionOSSceneUnderstanding *scene_understanding = nullptr;
	struct LegacyRequest {
		uint64_t id = 0;
		uint64_t generation = 0;
		Ref<VisionOSAnchorTracker> tracker;
		Callable callback;
	};
	Vector<LegacyRequest> legacy_requests;
	void deliver_legacy_result(uint64_t p_generation, const Ref<VisionOSAnchorTracker> &p_tracker, const Callable &p_callback, const String &p_operation, int p_error, const String &p_message);
};

#endif // VISIONOS_ENABLED
