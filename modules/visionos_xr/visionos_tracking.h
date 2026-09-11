/**************************************************************************/
/*  visionos_tracking.h                                                   */
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

#include "servers/xr/xr_hand_tracker.h"
#include "servers/xr/xr_positional_tracker.h"

#include <memory>
#include <mutex>

inline Quaternion visionos_hand_joint_axis_adjustment(bool p_left_hand) {
	const real_t angle = (p_left_hand ? -1 : 1) * Math::PI * 0.5;
	return Quaternion(Vector3(1, 0, 0), angle) * Quaternion(Vector3(0, 0, 1), angle);
}

inline Transform3D visionos_hand_aim_pose(const Ref<XRHandTracker> &p_hand) {
	const Transform3D palm = p_hand->get_hand_joint_transform(XRHandTracker::HAND_JOINT_PALM);
	// Normalized humanoid joints point +Y along the bone and -Z out the back
	// of the hand. Aim uses -Z forward and +Y dorsal, without changing grip.
	const Basis aim_basis(-palm.basis.get_column(0), -palm.basis.get_column(2), -palm.basis.get_column(1));
	return Transform3D(aim_basis, palm.origin);
}

// Shared by every presenter using the same tracking session, including a
// retiring layer. Only predictor transactions and session reconfiguration
// take this lock, never engine iteration or rendering work.
class VisionOSTrackingAccess {
	std::mutex mutex;

public:
	template <typename Operation>
	auto perform(Operation p_operation) {
		std::lock_guard<std::mutex> lock(mutex);
		return p_operation();
	}
};

#ifdef VISIONOS_ENABLED
VisionOSTrackingAccess &visionos_tracking_access();
#endif

template <typename Geometry>
bool visionos_apply_head_pose(const std::shared_ptr<const Geometry> &p_geometry, const Ref<XRPositionalTracker> &p_tracker, double &r_presentation_time, double &r_trackable_time) {
	r_presentation_time = p_geometry ? p_geometry->presentation_time : 0;
	r_trackable_time = p_geometry ? p_geometry->trackable_time : 0;
	if (!p_geometry) {
		p_tracker->invalidate_pose("default");
		return false;
	}
	// The pose and its timestamps are one immutable prediction. The engine
	// must not query the presenter's ARKit predictor a second time.
	p_tracker->set_pose("default", p_geometry->origin_from_head, Vector3(), Vector3(), XRPose::XR_TRACKING_CONFIDENCE_HIGH);
	return true;
}

template <typename Hands, typename Controllers>
void visionos_reset_input_tracking(Hands &p_hands, Controllers &p_controllers) {
	if (p_hands.enabled) {
		p_hands.reset_hand_tracker_data(p_hands.left_hand_tracker);
		p_hands.reset_hand_tracker_data(p_hands.right_hand_tracker);
		p_hands.reset_gestures(Hands::HAND_LEFT, p_hands.left_hand_tracker);
		p_hands.reset_gestures(Hands::HAND_RIGHT, p_hands.right_hand_tracker);
		if (!p_controllers.enabled) {
			p_hands.publish_gestures(Hands::HAND_LEFT, p_hands.left_hand_controller_tracker);
			p_hands.publish_gestures(Hands::HAND_RIGHT, p_hands.right_hand_controller_tracker);
		}
	}
	if (p_controllers.enabled) {
		// These trackers may contain either optical gestures or accessory input.
		p_controllers.reset_controller_tracker_data(p_controllers.left_controller_tracker);
		p_controllers.reset_controller_tracker_data(p_controllers.right_controller_tracker);
	}
}
