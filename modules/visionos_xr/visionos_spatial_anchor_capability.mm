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

#include "core/object/callable_mp.h"
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
	ClassDB::bind_method(D_METHOD("get_world_anchor_status"), &VisionOSSpatialAnchorCapability::get_world_anchor_status);
	ClassDB::bind_method(D_METHOD("request_create_anchor", "transform"), &VisionOSSpatialAnchorCapability::request_create_anchor);
	ClassDB::bind_method(D_METHOD("request_remove_anchor", "uuid"), &VisionOSSpatialAnchorCapability::request_remove_anchor);
	ClassDB::bind_method(D_METHOD("request_anchor_enumeration"), &VisionOSSpatialAnchorCapability::request_anchor_enumeration);
	ClassDB::bind_method(D_METHOD("cancel_request", "request_id"), &VisionOSSpatialAnchorCapability::cancel_request);
	ClassDB::bind_method(D_METHOD("get_anchor", "uuid"), &VisionOSSpatialAnchorCapability::get_anchor);
	ClassDB::bind_method(D_METHOD("get_anchors"), &VisionOSSpatialAnchorCapability::get_anchors);
	ClassDB::bind_method(D_METHOD("take_completed_requests"), &VisionOSSpatialAnchorCapability::take_completed_requests);
	ClassDB::bind_method(D_METHOD("get_last_error"), &VisionOSSpatialAnchorCapability::get_last_error);
	ADD_SIGNAL(MethodInfo("operation_failed", PropertyInfo(Variant::STRING, "operation"), PropertyInfo(Variant::STRING, "uuid"), PropertyInfo(Variant::INT, "error"), PropertyInfo(Variant::STRING, "message")));
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
	return scene_understanding != nullptr && scene_understanding->is_world_anchor_supported();
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
	if (scene_understanding == nullptr || p_anchor_tracker.is_null() || p_anchor_tracker->get_shared_with_nearby_participants() || legacy_requests.size() >= (int)VisionOSWorldAnchorStore::MAX_REQUESTS) {
		emit_signal(SNAME("operation_failed"), "persist", p_anchor_tracker.is_valid() ? p_anchor_tracker->get_anchor_uuid() : String(), ERR_UNAVAILABLE, "Cannot persist an unavailable, shared or excess anchor request.");
		return;
	}
	LegacyRequest request;
	request.generation = scene_understanding->get_anchor_store()->get_status().generation;
	request.tracker = p_anchor_tracker;
	request.callback = p_user_callback;
	legacy_requests.push_back(request);
}

void VisionOSSpatialAnchorCapability::unpersist_anchor(Ref<VisionOSAnchorTracker> p_anchor_tracker, const Callable &p_user_callback) {
	// On visionOS, unpersisting means removing the anchor entirely.
	ERR_FAIL_NULL(scene_understanding);
	ERR_FAIL_COND(p_anchor_tracker.is_null());

	uint64_t request = scene_understanding->request_remove_anchor(p_anchor_tracker->get_anchor_uuid());
	if (request) {
		track_legacy_request(request, p_anchor_tracker, p_user_callback);
	} else {
		emit_signal(SNAME("operation_failed"), "remove", p_anchor_tracker->get_anchor_uuid(), ERR_UNAVAILABLE, get_last_error());
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

Dictionary VisionOSSpatialAnchorCapability::get_world_anchor_status() const {
	Dictionary result;
	auto status = scene_understanding ? scene_understanding->get_anchor_store()->get_status() : VisionOSWorldAnchorStore::Status();
	result["supported"] = scene_understanding && scene_understanding->is_world_anchor_supported();
	result["enabled"] = scene_understanding && scene_understanding->is_world_anchors_enabled();
	result["running"] = status.running;
	result["generation"] = status.generation;
	result["enumeration_state"] = String::utf8(status.enumeration.c_str());
	result["error"] = status.error;
	result["error_message"] = String::utf8(status.message.c_str());
	return result;
}

int64_t VisionOSSpatialAnchorCapability::request_create_anchor(const Transform3D &p_transform) {
	return scene_understanding ? scene_understanding->request_create_anchor(p_transform) : 0;
}

int64_t VisionOSSpatialAnchorCapability::request_remove_anchor(const String &p_uuid) {
	return scene_understanding ? scene_understanding->request_remove_anchor(p_uuid) : 0;
}

int64_t VisionOSSpatialAnchorCapability::request_anchor_enumeration() {
	return scene_understanding ? scene_understanding->request_anchor_enumeration() : 0;
}

bool VisionOSSpatialAnchorCapability::cancel_request(int64_t p_request) {
	return scene_understanding && scene_understanding->get_anchor_store()->cancel(p_request);
}

TypedArray<Dictionary> VisionOSSpatialAnchorCapability::get_anchors() const {
	TypedArray<Dictionary> result;
	if (!scene_understanding) {
		return result;
	}
	for (const auto &anchor : scene_understanding->get_anchor_store()->get_anchors()) {
		Dictionary value;
		value["uuid"] = String::utf8(anchor.uuid.c_str());
		value["transform"] = anchor.transform;
		value["tracked"] = anchor.tracked;
		value["persisted"] = anchor.persisted;
		value["removed"] = anchor.removed;
		value["present"] = anchor.present;
		value["shared"] = anchor.shared;
		value["generation"] = anchor.generation;
		value["revision"] = anchor.revision;
		result.push_back(value);
	}
	return result;
}

Dictionary VisionOSSpatialAnchorCapability::get_anchor(const String &p_uuid) const {
	TypedArray<Dictionary> anchors = get_anchors();
	for (int i = 0; i < anchors.size(); i++) {
		Dictionary anchor = anchors[i];
		if ((String)anchor["uuid"] == p_uuid.to_lower()) {
			return anchor;
		}
	}
	return Dictionary();
}

TypedArray<Dictionary> VisionOSSpatialAnchorCapability::take_completed_requests() {
	TypedArray<Dictionary> result;
	if (!scene_understanding) {
		return result;
	}
	for (const auto &request : scene_understanding->get_anchor_store()->take_completed()) {
		Dictionary value;
		value["request_id"] = request.id;
		value["operation"] = String::utf8(request.operation.c_str());
		value["uuid"] = String::utf8(request.uuid.c_str());
		value["success"] = request.success;
		value["error"] = request.error;
		value["error_message"] = String::utf8(request.message.c_str());
		value["generation"] = request.generation;
		result.push_back(value);
	}
	return result;
}

String VisionOSSpatialAnchorCapability::get_last_error() const {
	return scene_understanding ? String::utf8(scene_understanding->get_anchor_store()->get_last_error().c_str()) : "Native world tracking interface is unavailable.";
}

void VisionOSSpatialAnchorCapability::track_legacy_request(uint64_t p_request, const Ref<VisionOSAnchorTracker> &p_tracker, const Callable &p_callback) {
	scene_understanding->get_anchor_store()->mark_legacy(p_request);
	LegacyRequest request;
	request.id = p_request;
	request.tracker = p_tracker;
	request.callback = p_callback;
	request.generation = scene_understanding->get_anchor_store()->get_status().generation;
	legacy_requests.push_back(request);
}

void VisionOSSpatialAnchorCapability::process() {
	if (!scene_understanding) {
		return;
	}
	const auto store = scene_understanding->get_anchor_store();
	// Remove each pending callback before invoking script, which may enqueue another operation.
	for (int i = legacy_requests.size() - 1; i >= 0; i--) {
		LegacyRequest request = legacy_requests[i];
		auto status = store->get_status();
		auto completion = store->get_request(request.id);
		bool ready = false;
		bool success = false;
		int error = ERR_UNAVAILABLE;
		String message = "World anchor persistence is unavailable.";
		String operation = "persist";
		if (request.id) {
			if (completion.id == 0) {
				legacy_requests.remove_at(i);
				continue;
			}
			ready = completion.complete;
			success = completion.complete && completion.success;
			error = completion.error;
			message = String::utf8(completion.message.c_str());
			operation = String::utf8(completion.operation.c_str());
		} else {
			for (const auto &anchor : store->get_anchors()) {
				if (anchor.uuid == request.tracker->get_anchor_uuid().utf8().get_data()) {
					ready = anchor.persisted || anchor.add_failed || anchor.removed;
					success = anchor.persisted && !anchor.shared;
				}
			}
			ready = ready || !status.running || request.generation != status.generation;
			success = success && status.running && request.generation == status.generation;
		}
		if (!ready) {
			continue;
		}
		legacy_requests.remove_at(i);
		if (request.id) {
			store->cancel(request.id);
		}
		callable_mp(this, &VisionOSSpatialAnchorCapability::deliver_legacy_result).call_deferred(request.generation, request.tracker, request.callback, operation, success ? OK : error, message);
	}
}

void VisionOSSpatialAnchorCapability::deliver_legacy_result(uint64_t p_generation, const Ref<VisionOSAnchorTracker> &p_tracker, const Callable &p_callback, const String &p_operation, int p_error, const String &p_message) {
	if (!scene_understanding) {
		return;
	}
	auto status = scene_understanding->get_anchor_store()->get_status();
	if (p_error == OK && (!status.running || status.generation != p_generation)) {
		emit_signal(SNAME("operation_failed"), p_operation, p_tracker->get_anchor_uuid(), ERR_UNAVAILABLE, "World tracking changed before completion delivery.");
	} else if (p_error != OK) {
		emit_signal(SNAME("operation_failed"), p_operation, p_tracker->get_anchor_uuid(), p_error, p_message);
	} else if (p_callback.is_valid()) {
		p_callback.call(p_tracker);
	}
}

#endif // VISIONOS_ENABLED
