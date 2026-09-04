/**************************************************************************/
/*  visionos_hand_tracking.mm                                             */
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

#include "visionos_hand_tracking.h"

#include "visionos_simd_helpers.h"

namespace {

_FORCE_INLINE_ XRHandTracker::HandJoint joint_from_arkit(ar_hand_skeleton_joint_name_t p_joint_name) {
	switch (p_joint_name) {
		case ar_hand_skeleton_joint_name_wrist:
			return XRHandTracker::HAND_JOINT_WRIST;
		case ar_hand_skeleton_joint_name_thumb_knuckle:
			return XRHandTracker::HAND_JOINT_THUMB_METACARPAL;
		case ar_hand_skeleton_joint_name_thumb_intermediate_base:
			return XRHandTracker::HAND_JOINT_THUMB_PHALANX_PROXIMAL;
		case ar_hand_skeleton_joint_name_thumb_intermediate_tip:
			return XRHandTracker::HAND_JOINT_THUMB_PHALANX_DISTAL;
		case ar_hand_skeleton_joint_name_thumb_tip:
			return XRHandTracker::HAND_JOINT_THUMB_TIP;
		case ar_hand_skeleton_joint_name_index_finger_metacarpal:
			return XRHandTracker::HAND_JOINT_INDEX_FINGER_METACARPAL;
		case ar_hand_skeleton_joint_name_index_finger_knuckle:
			return XRHandTracker::HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL;
		case ar_hand_skeleton_joint_name_index_finger_intermediate_base:
			return XRHandTracker::HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE;
		case ar_hand_skeleton_joint_name_index_finger_intermediate_tip:
			return XRHandTracker::HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL;
		case ar_hand_skeleton_joint_name_index_finger_tip:
			return XRHandTracker::HAND_JOINT_INDEX_FINGER_TIP;
		case ar_hand_skeleton_joint_name_middle_finger_metacarpal:
			return XRHandTracker::HAND_JOINT_MIDDLE_FINGER_METACARPAL;
		case ar_hand_skeleton_joint_name_middle_finger_knuckle:
			return XRHandTracker::HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL;
		case ar_hand_skeleton_joint_name_middle_finger_intermediate_base:
			return XRHandTracker::HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE;
		case ar_hand_skeleton_joint_name_middle_finger_intermediate_tip:
			return XRHandTracker::HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL;
		case ar_hand_skeleton_joint_name_middle_finger_tip:
			return XRHandTracker::HAND_JOINT_MIDDLE_FINGER_TIP;
		case ar_hand_skeleton_joint_name_ring_finger_metacarpal:
			return XRHandTracker::HAND_JOINT_RING_FINGER_METACARPAL;
		case ar_hand_skeleton_joint_name_ring_finger_knuckle:
			return XRHandTracker::HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL;
		case ar_hand_skeleton_joint_name_ring_finger_intermediate_base:
			return XRHandTracker::HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE;
		case ar_hand_skeleton_joint_name_ring_finger_intermediate_tip:
			return XRHandTracker::HAND_JOINT_RING_FINGER_PHALANX_DISTAL;
		case ar_hand_skeleton_joint_name_ring_finger_tip:
			return XRHandTracker::HAND_JOINT_RING_FINGER_TIP;
		case ar_hand_skeleton_joint_name_little_finger_metacarpal:
			return XRHandTracker::HAND_JOINT_PINKY_FINGER_METACARPAL;
		case ar_hand_skeleton_joint_name_little_finger_knuckle:
			return XRHandTracker::HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL;
		case ar_hand_skeleton_joint_name_little_finger_intermediate_base:
			return XRHandTracker::HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE;
		case ar_hand_skeleton_joint_name_little_finger_intermediate_tip:
			return XRHandTracker::HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL;
		case ar_hand_skeleton_joint_name_little_finger_tip:
			return XRHandTracker::HAND_JOINT_PINKY_FINGER_TIP;
		case ar_hand_skeleton_joint_name_forearm_wrist:
		case ar_hand_skeleton_joint_name_forearm_arm:
		default:
			// These don't have direct equivalents or are invalid
			return XRHandTracker::HAND_JOINT_MAX;
	}
}

// Pinch detection: thumb tip to index tip distance, with hysteresis so the click
// doesn't chatter around the threshold.
constexpr float PINCH_PRESS_DISTANCE_M = 0.025f;
constexpr float PINCH_RELEASE_DISTANCE_M = 0.04f;
constexpr float PINCH_ANALOG_MAX_DISTANCE_M = 0.06f;
constexpr float PINCH_SMOOTHING_FACTOR = 0.35f;

// Grasp (fist) detection: how far each fingertip is curled toward the palm.
constexpr float GRASP_CURL_CLOSE_DISTANCE_M = 0.04f; // Fully curled.
constexpr float GRASP_CURL_OPEN_DISTANCE_M = 0.10f; // Fully open.
constexpr float GRASP_PRESS_THRESHOLD = 0.7f;
constexpr float GRASP_RELEASE_THRESHOLD = 0.5f;
constexpr float GRASP_SMOOTHING_FACTOR = 0.35f;

_FORCE_INLINE_ bool is_joint_tracked(const Ref<XRHandTracker> &p_hand_tracker, XRHandTracker::HandJoint p_joint) {
	return p_hand_tracker->get_hand_joint_flags(p_joint).has_flag(XRHandTracker::HAND_JOINT_FLAG_POSITION_TRACKED);
}
} // namespace

void VisionOSHandTracking::initialize(XRServer *p_xr_server, bool p_accessory_tracking_enabled) {
	// Hand tracking provider (registered with the shared ARKit session)
	ar_hand_tracking_configuration_t hand_tracking_configuration = ar_hand_tracking_configuration_create();
	hand_tracking_provider = ar_hand_tracking_provider_create(hand_tracking_configuration);

	// Hand tracker initialization
	left_hand_tracker.instantiate();
	left_hand_tracker->set_tracker_hand(XRPositionalTracker::TRACKER_HAND_LEFT);
	left_hand_tracker->set_tracker_name("/user/hand_tracker/left");
	p_xr_server->add_tracker(left_hand_tracker);

	right_hand_tracker.instantiate();
	right_hand_tracker->set_tracker_hand(XRPositionalTracker::TRACKER_HAND_RIGHT);
	right_hand_tracker->set_tracker_name("/user/hand_tracker/right");
	p_xr_server->add_tracker(right_hand_tracker);

	// When accessory tracking is enabled, VisionOSControllerTracking registers
	// `left_hand` and `right_hand` itself and gestures are mirrored into those.
	// Otherwise register them here so hand gestures still drive XRController3D.
	if (!p_accessory_tracking_enabled) {
		left_hand_controller_tracker.instantiate();
		left_hand_controller_tracker->set_tracker_hand(XRPositionalTracker::TRACKER_HAND_LEFT);
		left_hand_controller_tracker->set_tracker_name("left_hand");
		left_hand_controller_tracker->set_tracker_desc("visionOS Left Hand");
		p_xr_server->add_tracker(left_hand_controller_tracker);

		right_hand_controller_tracker.instantiate();
		right_hand_controller_tracker->set_tracker_hand(XRPositionalTracker::TRACKER_HAND_RIGHT);
		right_hand_controller_tracker->set_tracker_name("right_hand");
		right_hand_controller_tracker->set_tracker_desc("visionOS Right Hand");
		p_xr_server->add_tracker(right_hand_controller_tracker);
	}

	left_hand_anchor = ar_hand_anchor_create();
	right_hand_anchor = ar_hand_anchor_create();
}

void VisionOSHandTracking::uninitialize(XRServer *p_xr_server) {
	if (p_xr_server == nullptr) {
		return;
	}

	if (left_hand_controller_tracker.is_valid()) {
		p_xr_server->remove_tracker(left_hand_controller_tracker);
		left_hand_controller_tracker.unref();
	}
	if (right_hand_controller_tracker.is_valid()) {
		p_xr_server->remove_tracker(right_hand_controller_tracker);
		right_hand_controller_tracker.unref();
	}
}

void VisionOSHandTracking::update_hand_trackers_from_arkit(CFTimeInterval p_trackable_anchor_time) {
	if (p_trackable_anchor_time != 0) {
		ar_hand_anchor_query_status_t query_anchor_result =
				ar_hand_tracking_provider_query_anchors_at_timestamp(hand_tracking_provider,
						p_trackable_anchor_time,
						left_hand_anchor,
						right_hand_anchor);

		if (query_anchor_result != ar_hand_anchor_query_status_success) {
			reset_hand_tracker_data(left_hand_tracker);
			reset_hand_tracker_data(right_hand_tracker);
			reset_gestures(HAND_LEFT, left_hand_tracker);
			reset_gestures(HAND_RIGHT, right_hand_tracker);
			ERR_FAIL_MSG("Cannot query hand anchors, result: " + itos(query_anchor_result) + ".");
		}
	} else {
		// If we failed to get a trackable_anchor_time, we just get the latest anchors.
		// Tracking will be less precise in this case
		bool result = ar_hand_tracking_provider_get_latest_anchors(hand_tracking_provider, left_hand_anchor, right_hand_anchor);
		if (!result) {
			reset_hand_tracker_data(left_hand_tracker);
			reset_hand_tracker_data(right_hand_tracker);
			reset_gestures(HAND_LEFT, left_hand_tracker);
			reset_gestures(HAND_RIGHT, right_hand_tracker);
			ERR_FAIL_MSG("Cannot query latest anchors, the ARKit session is probably not running.");
		}
	}

	if (ar_hand_anchor_is_tracked(left_hand_anchor)) {
		set_hand_tracker_data_from_arkit(left_hand_tracker, left_hand_anchor);
		update_gestures(HAND_LEFT, left_hand_tracker);
	} else {
		reset_hand_tracker_data(left_hand_tracker);
		reset_gestures(HAND_LEFT, left_hand_tracker);
	}

	if (ar_hand_anchor_is_tracked(right_hand_anchor)) {
		set_hand_tracker_data_from_arkit(right_hand_tracker, right_hand_anchor);
		update_gestures(HAND_RIGHT, right_hand_tracker);
	} else {
		reset_hand_tracker_data(right_hand_tracker);
		reset_gestures(HAND_RIGHT, right_hand_tracker);
	}
}

void VisionOSHandTracking::update_gestures(HandIndex p_hand, const Ref<XRHandTracker> &p_hand_tracker) {
	GestureState &state = gestures[p_hand];

	// Pinch: thumb tip to index tip.
	if (is_joint_tracked(p_hand_tracker, XRHandTracker::HAND_JOINT_THUMB_TIP) &&
			is_joint_tracked(p_hand_tracker, XRHandTracker::HAND_JOINT_INDEX_FINGER_TIP)) {
		const Vector3 thumb_tip = p_hand_tracker->get_hand_joint_transform(XRHandTracker::HAND_JOINT_THUMB_TIP).origin;
		const Vector3 index_tip = p_hand_tracker->get_hand_joint_transform(XRHandTracker::HAND_JOINT_INDEX_FINGER_TIP).origin;

		const float distance = thumb_tip.distance_to(index_tip);
		const float raw_pinch = CLAMP(
				(PINCH_ANALOG_MAX_DISTANCE_M - distance) / (PINCH_ANALOG_MAX_DISTANCE_M - PINCH_PRESS_DISTANCE_M),
				0.0f, 1.0f);

		state.pinch_value = Math::lerp(state.pinch_value, raw_pinch, PINCH_SMOOTHING_FACTOR);
		state.pinch_click = state.pinch_click ? distance < PINCH_RELEASE_DISTANCE_M : distance < PINCH_PRESS_DISTANCE_M;
	} else {
		state.pinch_value = 0.0f;
		state.pinch_click = false;
	}

	// Grasp: average curl of the four non-thumb fingers, measured as the distance
	// from each fingertip to the palm.
	const XRHandTracker::HandJoint curl_joints[] = {
		XRHandTracker::HAND_JOINT_INDEX_FINGER_TIP,
		XRHandTracker::HAND_JOINT_MIDDLE_FINGER_TIP,
		XRHandTracker::HAND_JOINT_RING_FINGER_TIP,
		XRHandTracker::HAND_JOINT_PINKY_FINGER_TIP,
	};

	float curl_sum = 0.0f;
	int tracked_count = 0;

	if (is_joint_tracked(p_hand_tracker, XRHandTracker::HAND_JOINT_PALM)) {
		const Vector3 palm = p_hand_tracker->get_hand_joint_transform(XRHandTracker::HAND_JOINT_PALM).origin;

		for (const XRHandTracker::HandJoint &joint : curl_joints) {
			if (!is_joint_tracked(p_hand_tracker, joint)) {
				continue;
			}

			const float distance = palm.distance_to(p_hand_tracker->get_hand_joint_transform(joint).origin);
			curl_sum += CLAMP(
					(GRASP_CURL_OPEN_DISTANCE_M - distance) / (GRASP_CURL_OPEN_DISTANCE_M - GRASP_CURL_CLOSE_DISTANCE_M),
					0.0f, 1.0f);
			tracked_count++;
		}
	}

	// Fall back to pinch when too few fingers are tracked, which happens when the
	// hand is turned away from the sensors, so grabbing still works.
	float raw_grasp = (tracked_count >= 2) ? (curl_sum / tracked_count) : 0.0f;
	raw_grasp = MAX(raw_grasp, state.pinch_click ? 1.0f : state.pinch_value);

	state.grasp_value = Math::lerp(state.grasp_value, raw_grasp, GRASP_SMOOTHING_FACTOR);
	state.grasp_click = state.grasp_click ? state.grasp_value > GRASP_RELEASE_THRESHOLD : state.grasp_value > GRASP_PRESS_THRESHOLD;

	p_hand_tracker->set_input("pinch", state.pinch_value);
	p_hand_tracker->set_input("pinch_click", state.pinch_click);
	p_hand_tracker->set_input("grasp", state.grasp_value);
	p_hand_tracker->set_input("grasp_click", state.grasp_click);
}

void VisionOSHandTracking::reset_gestures(HandIndex p_hand, const Ref<XRHandTracker> &p_hand_tracker) {
	gestures[p_hand] = GestureState();

	p_hand_tracker->set_input("pinch", 0.0f);
	p_hand_tracker->set_input("pinch_click", false);
	p_hand_tracker->set_input("grasp", 0.0f);
	p_hand_tracker->set_input("grasp_click", false);
}

void VisionOSHandTracking::publish_gestures(HandIndex p_hand, const Ref<XRControllerTracker> &p_controller_tracker) {
	if (p_controller_tracker.is_null()) {
		return;
	}

	const GestureState &state = gestures[p_hand];
	const Ref<XRHandTracker> &hand_tracker = (p_hand == HAND_LEFT) ? left_hand_tracker : right_hand_tracker;

	// Map onto the same action names the accessory controllers use, so gameplay
	// built on XRController3D works with either input source.
	p_controller_tracker->set_input("trigger", state.pinch_value);
	p_controller_tracker->set_input("trigger_click", state.pinch_click);
	p_controller_tracker->set_input("grip", state.grasp_value);
	p_controller_tracker->set_input("grip_click", state.grasp_click);

	if (hand_tracker.is_null() || !hand_tracker->get_has_tracking_data()) {
		p_controller_tracker->invalidate_pose("default");
		p_controller_tracker->invalidate_pose("aim");
		p_controller_tracker->invalidate_pose("grip");
		p_controller_tracker->invalidate_pose("palm");
		return;
	}

	const Transform3D palm = hand_tracker->get_hand_joint_transform(XRHandTracker::HAND_JOINT_PALM);

	// Aim points along the index finger when it is tracked, otherwise it follows
	// the palm.
	Transform3D aim = palm;
	if (is_joint_tracked(hand_tracker, XRHandTracker::HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL) &&
			is_joint_tracked(hand_tracker, XRHandTracker::HAND_JOINT_INDEX_FINGER_TIP)) {
		const Vector3 knuckle = hand_tracker->get_hand_joint_transform(XRHandTracker::HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL).origin;
		const Vector3 tip = hand_tracker->get_hand_joint_transform(XRHandTracker::HAND_JOINT_INDEX_FINGER_TIP).origin;
		const Vector3 direction = tip - knuckle;
		const Vector3 up = palm.basis.get_column(Vector3::AXIS_Y);

		// Skip the degenerate case rather than let looking_at() warn every frame.
		if (!direction.is_zero_approx() && !up.cross(direction).is_zero_approx()) {
			// Godot poses look down -Z.
			aim.basis = Basis::looking_at(direction, up);
			aim.origin = tip;
		}
	}

	p_controller_tracker->set_pose("default", aim, Vector3(), Vector3());
	p_controller_tracker->set_pose("aim", aim, Vector3(), Vector3());
	p_controller_tracker->set_pose("grip", palm, Vector3(), Vector3());
	p_controller_tracker->set_pose("palm", palm, Vector3(), Vector3());
}

void VisionOSHandTracking::reset_hand_tracker_data(Ref<XRHandTracker> p_hand_tracker) {
	p_hand_tracker->set_hand_tracking_source(XRHandTracker::HAND_TRACKING_SOURCE_UNKNOWN);
	p_hand_tracker->set_has_tracking_data(false);
	p_hand_tracker->invalidate_pose("default");
}

void VisionOSHandTracking::set_hand_tracker_data_from_arkit(Ref<XRHandTracker> p_hand_tracker, ar_hand_anchor_t p_hand_anchor) {
	simd_float4x4 origin_from_hand_anchor_simd = ar_hand_anchor_get_origin_from_anchor_transform(p_hand_anchor);

	ar_hand_skeleton_t hand_skeleton = ar_hand_anchor_get_hand_skeleton(p_hand_anchor);
	Transform3D origin_from_hand_anchor = MTL::simd_to_transform3D(origin_from_hand_anchor_simd);

	// Rotate from ARKit coordinates to Godot Humanoid coordinates
	ar_hand_chirality_t chirality = ar_hand_anchor_get_chirality(p_hand_anchor);
	bool is_left_hand = (chirality == ar_hand_chirality_left);
	real_t rotation_angle = (is_left_hand ? -1 : 1) * Math::PI * 0.5;
	const Quaternion rotationX(Vector3(1, 0, 0), rotation_angle);

	BitField<XRHandTracker::HandJointFlags> flags = {};
	flags.set_flag(XRHandTracker::HAND_JOINT_FLAG_ORIENTATION_VALID);
	flags.set_flag(XRHandTracker::HAND_JOINT_FLAG_POSITION_VALID);
	flags.set_flag(XRHandTracker::HAND_JOINT_FLAG_ORIENTATION_TRACKED);
	flags.set_flag(XRHandTracker::HAND_JOINT_FLAG_POSITION_TRACKED);

	// Updating all the hand joints
	const Quaternion rotationZ(Vector3(0, 0, 1), rotation_angle);
	const Quaternion joint_axis_adjustment = rotationX * rotationZ;
	ar_hand_skeleton_enumerate_joints(hand_skeleton, ^bool(ar_skeleton_joint_t joint) {
		uint64_t joint_index = ar_skeleton_joint_get_index(joint);
		XRHandTracker::HandJoint hand_joint = joint_from_arkit((ar_hand_skeleton_joint_name_t)joint_index);
		if (hand_joint == XRHandTracker::HAND_JOINT_MAX) {
			return true;
		}
		simd_float4x4 hand_anchor_from_joint_simd = ar_skeleton_joint_get_anchor_from_joint_transform(joint);
		Transform3D hand_anchor_from_joint = MTL::simd_to_transform3D(hand_anchor_from_joint_simd);
		Transform3D origin_from_joint = origin_from_hand_anchor * hand_anchor_from_joint;
		origin_from_joint.basis = origin_from_joint.basis * joint_axis_adjustment;
		p_hand_tracker->set_hand_joint_transform(hand_joint, origin_from_joint);
		p_hand_tracker->set_hand_joint_flags(hand_joint, flags);
		return true;
	});

	// ARKit hands don't have a palm joint, so computing it the same way WebXR (webxr_interface_js.cpp) does it:
	// finding the middle of the middle-finger's metacarpal bone
	{
		// Start by getting the middle finger metacarpal joint.
		Transform3D palm_transform = p_hand_tracker->get_hand_joint_transform(XRHandTracker::HAND_JOINT_MIDDLE_FINGER_METACARPAL);

		// Get the middle finger phalanx position.
		Vector3 phalanx = p_hand_tracker->get_hand_joint_transform(XRHandTracker::HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL).origin;

		// Offset the palm half-way towards the phalanx joint.
		palm_transform.origin = (palm_transform.origin + phalanx) / 2.0;

		// Set the palm joint and the pose.
		p_hand_tracker->set_hand_joint_transform(XRHandTracker::HAND_JOINT_PALM, palm_transform);
		p_hand_tracker->set_hand_joint_flags(XRHandTracker::HAND_JOINT_PALM, flags);
		// Note: ARKit does not have API for linear/angular velocity; so leaving it at 0
		p_hand_tracker->set_pose("default", palm_transform, Vector3(), Vector3());
	}

	p_hand_tracker->set_hand_tracking_source(XRHandTracker::HAND_TRACKING_SOURCE_UNOBSTRUCTED);
	p_hand_tracker->set_has_tracking_data(true);
}

#endif // VISIONOS_ENABLED
