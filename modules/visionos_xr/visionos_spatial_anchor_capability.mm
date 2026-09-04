/**************************************************************************/
/*  visionos_spatial_anchor_capability.mm                                 */
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

#include "visionos_spatial_anchor_capability.h"

#include "visionos_scene_understanding.h"

#include "core/object/class_db.h"

VisionOSSpatialAnchorCapability *VisionOSSpatialAnchorCapability::singleton = nullptr;

VisionOSSpatialAnchorCapability *VisionOSSpatialAnchorCapability::get_singleton() {
	return singleton;
}

VisionOSSpatialAnchorCapability::VisionOSSpatialAnchorCapability() {
	singleton = this;
}

VisionOSSpatialAnchorCapability::~VisionOSSpatialAnchorCapability() {
	singleton = nullptr;
}

void VisionOSSpatialAnchorCapability::set_scene_understanding(VisionOSSceneUnderstanding *p_scene_understanding) {
	scene_understanding = p_scene_understanding;
}

void VisionOSSpatialAnchorCapability::_bind_methods() {
	// Matches OpenXRSpatialAnchorCapability method signatures
	ClassDB::bind_method(D_METHOD("is_spatial_anchor_supported"), &VisionOSSpatialAnchorCapability::is_spatial_anchor_supported);
	ClassDB::bind_method(D_METHOD("is_spatial_persistence_supported"), &VisionOSSpatialAnchorCapability::is_spatial_persistence_supported);

	ClassDB::bind_method(D_METHOD("create_new_anchor", "transform"), &VisionOSSpatialAnchorCapability::create_new_anchor);
	ClassDB::bind_method(D_METHOD("remove_anchor", "anchor_tracker"), &VisionOSSpatialAnchorCapability::remove_anchor);
	ClassDB::bind_method(D_METHOD("persist_anchor", "anchor_tracker", "user_callback"), &VisionOSSpatialAnchorCapability::persist_anchor, DEFVAL(Callable()));
	ClassDB::bind_method(D_METHOD("unpersist_anchor", "anchor_tracker", "user_callback"), &VisionOSSpatialAnchorCapability::unpersist_anchor, DEFVAL(Callable()));

	// visionOS-specific sharing
	ClassDB::bind_method(D_METHOD("is_sharing_available"), &VisionOSSpatialAnchorCapability::is_sharing_available);
	ClassDB::bind_method(D_METHOD("create_shared_anchor", "transform"), &VisionOSSpatialAnchorCapability::create_shared_anchor);
}

bool VisionOSSpatialAnchorCapability::is_spatial_anchor_supported() {
	return scene_understanding != nullptr && scene_understanding->is_world_anchors_enabled();
}

bool VisionOSSpatialAnchorCapability::is_spatial_persistence_supported() {
	// visionOS world anchors are automatically persistent across app restarts.
	return is_spatial_anchor_supported();
}

Ref<VisionOSAnchorTracker> VisionOSSpatialAnchorCapability::create_new_anchor(const Transform3D &p_transform) {
	ERR_FAIL_NULL_V(scene_understanding, Ref<VisionOSAnchorTracker>());
	return scene_understanding->create_anchor(p_transform, false);
}

void VisionOSSpatialAnchorCapability::remove_anchor(Ref<VisionOSAnchorTracker> p_anchor_tracker) {
	ERR_FAIL_NULL(scene_understanding);
	ERR_FAIL_COND(p_anchor_tracker.is_null());
	scene_understanding->remove_anchor(p_anchor_tracker);
}

void VisionOSSpatialAnchorCapability::persist_anchor(Ref<VisionOSAnchorTracker> p_anchor_tracker, const Callable &p_user_callback) {
	// visionOS world anchors are automatically persistent.
	// Fire the callback immediately to match the OpenXR async pattern.
	if (p_user_callback.is_valid()) {
		p_user_callback.call(p_anchor_tracker);
	}
}

void VisionOSSpatialAnchorCapability::unpersist_anchor(Ref<VisionOSAnchorTracker> p_anchor_tracker, const Callable &p_user_callback) {
	// On visionOS, unpersisting means removing the anchor entirely.
	ERR_FAIL_NULL(scene_understanding);
	ERR_FAIL_COND(p_anchor_tracker.is_null());

	scene_understanding->remove_anchor(p_anchor_tracker);

	if (p_user_callback.is_valid()) {
		p_user_callback.call(p_anchor_tracker);
	}
}

bool VisionOSSpatialAnchorCapability::is_sharing_available() {
	if (scene_understanding == nullptr) {
		return false;
	}
	return scene_understanding->is_anchor_sharing_available();
}

Ref<VisionOSAnchorTracker> VisionOSSpatialAnchorCapability::create_shared_anchor(const Transform3D &p_transform) {
	ERR_FAIL_NULL_V(scene_understanding, Ref<VisionOSAnchorTracker>());
	return scene_understanding->create_anchor(p_transform, true);
}

#endif // VISIONOS_ENABLED
