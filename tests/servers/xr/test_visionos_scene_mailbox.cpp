/**************************************************************************/
/*  test_visionos_scene_mailbox.cpp                                       */
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

#include "tests/test_macros.h"

#include "modules/visionos_xr/visionos_engine_thread.h"
#include "modules/visionos_xr/visionos_frame_lifecycle.h"
#include "modules/visionos_xr/visionos_presentation_thread.h"
#include "modules/visionos_xr/visionos_scene_mailbox.h"
#include "modules/visionos_xr/visionos_startup_diagnostics.h"
#include "modules/visionos_xr/visionos_tracking.h"

#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
// doctest only forward-declares std::ostream; stringifying std::shared_ptr and std::thread::id needs the full definition.
#include <ostream>
#include <thread>
#include <utility>

TEST_FORCE_LINK(test_visionos_scene_mailbox)

#ifndef _3D_DISABLED

namespace TestVisionOSSceneMailbox {

using namespace std::chrono_literals;

TEST_CASE("[visionOS] Full Mixed Full restores only interface-owned viewport transparency") {
	VisionOSViewportTransparency state;
	bool transparent = false;
	transparent = state.update(1, false, transparent);
	CHECK_FALSE(transparent);
	transparent = state.update(1, true, transparent);
	CHECK(transparent);
	transparent = state.update(1, true, transparent);
	CHECK(transparent);
	transparent = state.update(1, false, transparent);
	CHECK_FALSE(transparent);
	CHECK_FALSE(state.update(1, false, transparent));

	VisionOSViewportTransparency configured;
	CHECK(configured.update(2, true, true));
	CHECK(configured.update(2, false, true));

	CHECK(state.update(1, true, false));
	CHECK(state.update(3, false, true));
	CHECK_FALSE(state.update(3, false, false));
	CHECK(state.update(3, true, false));
	CHECK_FALSE(state.update(3, false, true));
}

TEST_CASE("[visionOS] Optical hand aim points anatomically forward without changing the palm") {
	for (auto side : { XRPositionalTracker::TRACKER_HAND_LEFT, XRPositionalTracker::TRACKER_HAND_RIGHT }) {
		Ref<XRHandTracker> hand;
		hand.instantiate();
		hand->set_tracker_hand(side);
		hand->set_has_tracking_data(true);
		const bool left = side == XRPositionalTracker::TRACKER_HAND_LEFT;
		// Palms down, middle metacarpals toward world -Z. Raw ARKit longitudinal
		// axes have opposite signs; the production conversion normalizes both.
		const real_t sign = left ? 1 : -1;
		const Basis raw_joint(Vector3(0, 0, -sign), Vector3(0, -sign, 0), Vector3(-1, 0, 0));
		const Basis normalized_joint = raw_joint * Basis(visionos_hand_joint_axis_adjustment(left));
		CHECK(normalized_joint.get_column(1).is_equal_approx(Vector3(0, 0, -1)));
		CHECK((-normalized_joint.get_column(2)).is_equal_approx(Vector3(0, 1, 0)));

		for (real_t angle : { real_t(0), real_t(0.8), real_t(2.2) }) {
			const Transform3D anchor(Basis(Vector3(1, 2, -3).normalized(), angle), Vector3(sign * 0.2, 1.2 + angle, -0.4));
			const Transform3D wrist(anchor.basis * normalized_joint, anchor.origin);
			const Transform3D metacarpal(anchor.basis * normalized_joint, anchor.xform(Vector3(0, 0, -0.015)));
			const Vector3 knuckle = anchor.xform(Vector3(0, 0, -0.085));
			const Transform3D palm(metacarpal.basis, (metacarpal.origin + knuckle) * 0.5);
			hand->set_hand_joint_transform(XRHandTracker::HAND_JOINT_WRIST, wrist);
			hand->set_hand_joint_transform(XRHandTracker::HAND_JOINT_MIDDLE_FINGER_METACARPAL, metacarpal);
			hand->set_hand_joint_transform(XRHandTracker::HAND_JOINT_PALM, palm);
			const Transform3D stable_aim = visionos_hand_aim_pose(hand);
			const Vector3 forward = (knuckle - metacarpal.origin).normalized();
			const Vector3 dorsal = anchor.basis.xform(Vector3(0, 1, 0));
			CHECK((-stable_aim.basis.get_column(2)).is_equal_approx(forward));
			CHECK((-stable_aim.basis.get_column(2)).dot((knuckle - wrist.origin).normalized()) == doctest::Approx(1));
			CHECK(stable_aim.basis.get_column(1).is_equal_approx(dorsal));
			CHECK(stable_aim.basis.get_column(0).is_equal_approx(forward.cross(dorsal)));
			CHECK(stable_aim.basis.determinant() == doctest::Approx(1));
			CHECK(stable_aim.basis.is_equal_approx(anchor.basis));
			CHECK(stable_aim.origin.is_equal_approx(anchor.xform(Vector3(0, 0, -0.05))));
			CHECK(stable_aim.origin == palm.origin);
			CHECK(Math::abs((-palm.basis.get_column(2)).dot(forward)) < 0.00001);

			const Transform3D grip = visionos_hand_grip_pose(hand);
			const Vector3 thumb_side = anchor.basis.xform(Vector3(left ? 1 : -1, 0, 0));
			CHECK((-grip.basis.get_column(2)).is_equal_approx(forward));
			CHECK(grip.basis.get_column(1).is_equal_approx(thumb_side));
			CHECK(grip.basis.get_column(0).is_equal_approx(left ? -dorsal : dorsal));
			CHECK(grip.basis.determinant() == doctest::Approx(1));
			CHECK(grip.origin == palm.origin);

			for (int articulation = 0; articulation < 3; articulation++) {
				const Transform3D proximal(anchor.basis * Basis(Vector3(1, 0, 0), articulation * 0.7), knuckle);
				const Transform3D tip(proximal.basis, anchor.xform(Vector3(0.02, -articulation * 0.03, -0.14 + articulation * 0.035)));
				Transform3D thumb = tip;
				thumb.origin += anchor.basis.xform(Vector3(articulation == 1 ? 0 : 0.06, 0, 0));
				hand->set_hand_joint_transform(XRHandTracker::HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL, proximal);
				hand->set_hand_joint_transform(XRHandTracker::HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL, proximal);
				hand->set_hand_joint_transform(XRHandTracker::HAND_JOINT_INDEX_FINGER_TIP, tip);
				hand->set_hand_joint_transform(XRHandTracker::HAND_JOINT_THUMB_TIP, thumb);
				CHECK(visionos_hand_aim_pose(hand) == stable_aim);
				CHECK(hand->get_hand_joint_transform(XRHandTracker::HAND_JOINT_PALM) == palm);
				CHECK(hand->get_hand_joint_transform(XRHandTracker::HAND_JOINT_WRIST) == wrist);
				CHECK(hand->get_hand_joint_transform(XRHandTracker::HAND_JOINT_MIDDLE_FINGER_METACARPAL) == metacarpal);
				CHECK(hand->get_hand_joint_transform(XRHandTracker::HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL) == proximal);
				CHECK(hand->get_hand_joint_transform(XRHandTracker::HAND_JOINT_INDEX_FINGER_TIP) == tip);
				CHECK(hand->get_hand_joint_transform(XRHandTracker::HAND_JOINT_THUMB_TIP) == thumb);
			}
		}
	}
}

TEST_CASE("[visionOS] Native startup status requires a current successful scene presentation") {
	VisionOSStartupStatus status;
	CHECK(status.get_state() == VisionOSStartupStatus::LOADING);
	status.set_preparing(true);
	const uint64_t first_generation = status.get_generation();
	CHECK(status.get_state() == VisionOSStartupStatus::PREPARING_PIPELINES);
	status.complete(first_generation, false, true);
	CHECK(status.get_state() == VisionOSStartupStatus::PREPARING_PIPELINES);
	status.set_preparing(false);
	CHECK(status.get_state() == VisionOSStartupStatus::LOADING);
	status.set_frame_state(VisionOSStartupStatus::TRACKING_UNAVAILABLE);
	status.complete(first_generation, true, true);
	CHECK(status.get_state() == VisionOSStartupStatus::TRACKING_UNAVAILABLE);
	status.set_frame_state(VisionOSStartupStatus::FRAME_UNAVAILABLE);
	CHECK(status.get_state() == VisionOSStartupStatus::FRAME_UNAVAILABLE);
	status.complete(status.get_generation(), true, false);
	CHECK(status.get_state() == VisionOSStartupStatus::FRAME_UNAVAILABLE);
	status.complete(status.get_generation(), false, true);
	CHECK(status.get_state() == VisionOSStartupStatus::FRAME_UNAVAILABLE);
	status.set_frame_state(VisionOSStartupStatus::LOADING);
	CHECK(status.get_state() == VisionOSStartupStatus::FRAME_UNAVAILABLE);
	status.complete(status.get_generation(), true, true);
	CHECK(status.get_state() == VisionOSStartupStatus::READY);
	status.invalidate();
	CHECK(status.get_state() == VisionOSStartupStatus::LOADING);
	status.complete(first_generation, true, true);
	CHECK(status.get_state() == VisionOSStartupStatus::LOADING);
	status.complete(status.get_generation(), true, true);
	CHECK(status.get_state() == VisionOSStartupStatus::READY);
	status.invalidate(true);
	status.complete(status.get_generation(), true, true);
	CHECK(status.get_state() == VisionOSStartupStatus::CLOSED);
	status.set_preparing(true);
	CHECK(status.get_state() == VisionOSStartupStatus::CLOSED);

	VisionOSStartupStatus replacement;
	status.complete(first_generation, true, true);
	CHECK(replacement.get_state() == VisionOSStartupStatus::LOADING);
	replacement.fail();
	replacement.invalidate(true);
	replacement.complete(replacement.get_generation(), true, true);
	CHECK(replacement.get_state() == VisionOSStartupStatus::FAILED);
}

TEST_CASE("[visionOS] Startup diagnostics require explicit matching bundle opt-in") {
	CHECK_FALSE(visionos_startup_diagnostics_opt_in(false, "com.example.game", "com.example.game"));
	CHECK_FALSE(visionos_startup_diagnostics_opt_in(true, "com.example.game", ""));
	CHECK_FALSE(visionos_startup_diagnostics_opt_in(true, "", ""));
	CHECK_FALSE(visionos_startup_diagnostics_opt_in(true, "com.example.other", "com.example.game"));
	CHECK(visionos_startup_diagnostics_opt_in(true, "com.example.game", "com.example.game"));
}

TEST_CASE("[visionOS] Startup diagnostics distinguish source reuse rejection and producer latency") {
	using Diagnostics = VisionOSStartupDiagnostics;
	Diagnostics diagnostics(100);
	Diagnostics::Source source{ 1, 1, 10, 20 };
	diagnostics.sample(100.1, Diagnostics::SCENE, source);
	diagnostics.sample(100.2, Diagnostics::SCENE, source);
	source.age_ms = 300;
	diagnostics.sample(100.3, Diagnostics::SOURCE_EXPIRED, source);
	diagnostics.iteration_begin(100.2);
	diagnostics.iteration_end(100.8);
	diagnostics.iteration_begin(101.5);
	diagnostics.producer_complete(source, true, true, 260, 90, 20);
	diagnostics.presenter_complete(true, 4, 2);
	diagnostics.presenter_complete(false, 3, 0);
	source.sequence = 11;
	source.age_ms = 10;
	diagnostics.sample(101, Diagnostics::EYE_MISMATCH, source);
	diagnostics.producer_complete(source, false, false, 10, 5, 0);
	CHECK_FALSE(diagnostics.take_report(101.99));
	auto report = diagnostics.take_report(102);
	REQUIRE(report);
	CHECK(report->new_sources_observed == 2);
	CHECK(report->reasons[Diagnostics::SCENE] == 2);
	CHECK(report->reasons[Diagnostics::SOURCE_EXPIRED] == 1);
	CHECK(report->reasons[Diagnostics::EYE_MISMATCH] == 1);
	CHECK(report->max_source_age_ms[Diagnostics::SOURCE_EXPIRED] == 300);
	CHECK(report->producer_completed == 1);
	CHECK(report->producer_failed == 1);
	CHECK(report->producer_invalid_projection == 1);
	CHECK(report->gpu_timed_samples == 1);
	CHECK(report->gpu_max_ms == 20);
	CHECK(report->acquire_to_encode_max_ms == 260);
	CHECK(report->encode_to_complete_max_ms == 90);
	CHECK(report->source_to_complete_max_ms == 300);
	CHECK(report->iterations_started == 2);
	CHECK(report->iterations_completed == 1);
	CHECK(report->iterations_over_250ms == 1);
	CHECK(report->iteration_max_ms == doctest::Approx(600));
	CHECK(report->active_iteration_ms == doctest::Approx(500));
	CHECK(report->transition_count == 3);
	CHECK(report->presenter_completed == 1);
	CHECK(report->presenter_failed == 1);
	CHECK(report->presenter_gpu_max_ms == 2);
	CHECK(report->presenter_encode_to_complete_max_ms == 4);

	// Sequence identities also include the layer and mailbox generation.
	source.generation = 2;
	diagnostics.sample(102.1, Diagnostics::SCENE, source);
	source.layer = 2;
	diagnostics.sample(102.2, Diagnostics::SCENE, source);
	auto next = diagnostics.take_report(104);
	REQUIRE(next);
	CHECK(next->new_sources_observed == 4);
	CHECK(next->producer_completed == 1);
	CHECK(next->gpu_max_ms == 0);
	CHECK(next->iteration_max_ms == 0);
	CHECK(next->max_source_age_ms[Diagnostics::SOURCE_EXPIRED] == 0);
	CHECK(next->presenter_completed == 1);
	CHECK(next->presenter_failed == 1);
	CHECK(next->presenter_gpu_max_ms == 0);
	CHECK(next->presenter_encode_to_complete_max_ms == 0);
}

TEST_CASE("[visionOS] Startup diagnostics bound transitions report rate and capture lifetime") {
	using Diagnostics = VisionOSStartupDiagnostics;
	Diagnostics diagnostics(0);
	for (int i = 0; i < 30; i++) {
		diagnostics.sample(i * 0.05, i % 2 ? Diagnostics::SCENE : Diagnostics::NO_OUTPUT, {});
	}
	CHECK_FALSE(diagnostics.take_report(1.99));
	auto first = diagnostics.take_report(2);
	REQUIRE(first);
	CHECK(first->transition_count == 8);
	CHECK(first->transitions_omitted == 22);
	CHECK(first->reasons[Diagnostics::SCENE] == 15);
	CHECK(first->reasons[Diagnostics::NO_OUTPUT] == 15);
	for (int i = 2; i <= 90; i++) {
		CHECK_FALSE(diagnostics.take_report(i * 2.0 - 0.001));
		auto report = diagnostics.take_report(i * 2.0);
		REQUIRE(report);
		CHECK(report->index == uint64_t(i));
		CHECK(report->transition_count == 0);
	}
	CHECK_FALSE(diagnostics.is_active());
	diagnostics.sample(181, Diagnostics::SCENE, {});
	CHECK_FALSE(diagnostics.take_report(182));
}

TEST_CASE("[visionOS] Eye diagnostics retain per-eye rejection components and bounded source-correlated evidence") {
	using Diagnostics = VisionOSStartupDiagnostics;
	using Eye = VisionOSEyeTransformComparison;
	Diagnostics diagnostics(0);
	std::array<Eye, 2> eyes{};
	eyes[0].compared = eyes[1].compared = true;
	eyes[0].original_mismatch = eyes[1].original_mismatch = true;
	eyes[0].rotation_degrees = 2;
	eyes[0].positional_reprojection = true;
	eyes[0].basis_max_delta = 0.03;
	eyes[1].rotation_degrees = 3;
	eyes[1].translation_m = { -0.00003, 0.00004, 0.00002 };
	eyes[1].anchor_assignment_translation_m = { 0.00001, 0, 0 };
	eyes[1].anchor_assignment_basis_max_delta = 0.002;
	eyes[1].rejection = Eye::TRANSLATION;
	Diagnostics::Source source{ 7, 2, 30, 11 };
	for (uint32_t sample = 0; sample < 20; sample++) {
		source.sequence++;
		diagnostics.sample(sample * 0.05, sample % 2 ? Diagnostics::EYE_MISMATCH : Diagnostics::SCENE, source, eyes);
	}
	diagnostics.sample(1.5, Diagnostics::NO_OUTPUT, {});
	auto report = diagnostics.take_report(2);
	REQUIRE(report);
	CHECK(report->transition_count == 8);
	CHECK(report->transitions_omitted == 13);
	CHECK(report->latest_eye_source.sequence == 50);
	CHECK(report->latest_eye_source.age_ms == 11);
	CHECK(report->eye_windows[0].samples == 20);
	CHECK(report->eye_windows[0].original_mismatches == 20);
	CHECK(report->eye_windows[0].positional_mappings == 20);
	CHECK(report->eye_windows[0].rejections[Eye::NONE] == 20);
	CHECK(report->eye_windows[0].rotation_max_degrees == 2);
	CHECK(report->eye_windows[0].basis_max_delta == 0.03);
	CHECK(report->eye_windows[1].rejections[Eye::TRANSLATION] == 20);
	CHECK(report->eye_windows[1].translation_max_abs_m[0] == 0.00003);
	CHECK(report->eye_windows[1].translation_max_abs_m[1] == 0.00004);
	CHECK(report->eye_windows[1].translation_max_abs_m[2] == 0.00002);
	CHECK(report->eye_windows[1].anchor_assignment_translation_max_abs_m[0] == 0.00001);
	CHECK(report->eye_windows[1].anchor_assignment_basis_max_delta == 0.002);
	CHECK(report->transitions[0].source.sequence == 31);
	CHECK(report->transitions[0].eyes[0].rejection == Eye::NONE);
	CHECK(report->transitions[0].eyes[1].rejection == Eye::TRANSLATION);
	CHECK(report->transitions[0].eyes[1].translation_m[0] == -0.00003);
	auto next = diagnostics.take_report(4);
	REQUIRE(next);
	CHECK(next->eye_windows[0].samples == 20);
	CHECK(next->eye_windows[0].rotation_max_degrees == 0);
	CHECK(next->eye_windows[1].translation_max_abs_m[0] == 0);
	CHECK(next->eye_windows[1].anchor_assignment_basis_max_delta == 0);
	CHECK(next->eye_windows[1].anchor_assignment_translation_max_abs_m[0] == 0);
	CHECK(next->latest_eyes[1].translation_m[0] == -0.00003);
	CHECK(next->latest_eye_source.sequence == 50);
	CHECK(next->transition_count == 0);
}

TEST_CASE("[visionOS] Startup diagnostic completion state survives owner release") {
	using Diagnostics = VisionOSStartupDiagnostics;
	auto owner = std::make_shared<Diagnostics>(0);
	std::weak_ptr<Diagnostics> weak = owner;
	std::function<void()> completion = [state = owner] {
		state->producer_complete({ 1, 1, 1, 30 }, true, true, 10, 20, 5);
	};
	owner.reset();
	CHECK_FALSE(weak.expired());
	completion();
	auto state = weak.lock();
	auto report = state->take_report(2);
	REQUIRE(report);
	CHECK(report->producer_completed == 1);
	completion = {};
	state.reset();
	CHECK(weak.expired());
}

struct HeadGeometry {
	double presentation_time = 0;
	double trackable_time = 0;
	Transform3D origin_from_head;
};

TEST_CASE("[visionOS] Head tracking consumes one immutable pose and timestamp snapshot") {
	Ref<XRPositionalTracker> tracker;
	tracker.instantiate();
	double presentation_time = -1;
	double trackable_time = -1;
	std::shared_ptr<const HeadGeometry> missing;
	CHECK_FALSE(visionos_apply_head_pose(missing, tracker, presentation_time, trackable_time));
	CHECK(presentation_time == 0);
	CHECK(trackable_time == 0);

	auto first = std::make_shared<HeadGeometry>();
	first->presentation_time = 120.125;
	first->trackable_time = 120.12;
	first->origin_from_head.origin = Vector3(1, 2, 3);
	std::shared_ptr<const HeadGeometry> snapshot = first;
	CHECK(visionos_apply_head_pose(snapshot, tracker, presentation_time, trackable_time));
	CHECK(presentation_time == first->presentation_time);
	CHECK(trackable_time == first->trackable_time);
	CHECK(tracker->get_pose("default")->get_transform() == first->origin_from_head);
	CHECK(tracker->get_pose("default")->get_has_tracking_data());

	// A replacement or tracking loss clears the published snapshot. A retained
	// old snapshot remains valid for its already encoded scene, not live input.
	CHECK_FALSE(visionos_apply_head_pose(missing, tracker, presentation_time, trackable_time));
	CHECK_FALSE(tracker->get_pose("default")->get_has_tracking_data());
	CHECK(presentation_time == 0);
	CHECK(trackable_time == 0);
	CHECK(snapshot->presentation_time == 120.125);

	auto replacement = std::make_shared<HeadGeometry>();
	replacement->presentation_time = 121.5;
	replacement->trackable_time = 121.49;
	replacement->origin_from_head.origin = Vector3(-3, 1, 2);
	std::shared_ptr<const HeadGeometry> next = replacement;
	CHECK(visionos_apply_head_pose(next, tracker, presentation_time, trackable_time));
	CHECK(tracker->get_pose("default")->get_transform() == replacement->origin_from_head);
	CHECK(presentation_time == replacement->presentation_time);
	CHECK(trackable_time == replacement->trackable_time);
	CHECK(snapshot->origin_from_head == first->origin_from_head);
}

TEST_CASE("[visionOS] Shared tracking access serializes retiring presenters and session reconfiguration") {
	VisionOSTrackingAccess access;
	std::atomic<int> ready{ 0 };
	std::atomic<bool> begin{ false };
	std::atomic<int> active{ 0 };
	std::atomic<int> overlaps{ 0 };
	std::atomic<int> mismatches{ 0 };
	std::atomic<int> queries{ 0 };
	std::atomic<int> configurations{ 0 };
	std::atomic<double> predictor_timestamp{ 0 };
	auto wait_for_start = [&] {
		ready.fetch_add(1);
		while (!begin.load()) {
			std::this_thread::yield();
		}
	};
	auto predict = [&](double p_base) {
		wait_for_start();
		for (int i = 0; i < 128; i++) {
			double timestamp = p_base + i * 0.01;
			double result = access.perform([&] {
				overlaps.fetch_add(active.fetch_add(1) != 0);
				predictor_timestamp.store(timestamp);
				std::this_thread::sleep_for(50us);
				double response = predictor_timestamp.load();
				active.fetch_sub(1);
				queries.fetch_add(1);
				return response;
			});
			mismatches.fetch_add(result != timestamp);
		}
	};
	std::thread retiring([&] { predict(100); });
	std::thread replacement([&] { predict(200); });
	std::thread authorization([&] {
		wait_for_start();
		for (int i = 0; i < 128; i++) {
			access.perform([&] {
				overlaps.fetch_add(active.fetch_add(1) != 0);
				predictor_timestamp.store(0);
				std::this_thread::yield();
				configurations.fetch_add(1);
				active.fetch_sub(1);
			});
		}
	});
	while (ready.load() != 3) {
		std::this_thread::yield();
	}
	begin.store(true);
	retiring.join();
	replacement.join();
	authorization.join();
	CHECK(overlaps.load() == 0);
	CHECK(mismatches.load() == 0);
	CHECK(queries.load() == 256);
	CHECK(configurations.load() == 128);
	CHECK(active.load() == 0);
}

struct LostInputHands {
	enum HandIndex { HAND_LEFT,
		HAND_RIGHT };
	bool enabled = true;
	Ref<XRPositionalTracker> left_hand_tracker;
	Ref<XRPositionalTracker> right_hand_tracker;
	Ref<XRPositionalTracker> left_hand_controller_tracker;
	Ref<XRPositionalTracker> right_hand_controller_tracker;
	bool pressed[2] = { true, true };
	int resets = 0;
	int publications = 0;

	void reset_hand_tracker_data(const Ref<XRPositionalTracker> &p_tracker) {
		p_tracker->invalidate_pose("default");
		resets++;
	}
	void reset_gestures(HandIndex p_hand, const Ref<XRPositionalTracker> &p_tracker) {
		pressed[p_hand] = false;
		p_tracker->set_input("pinch_click", false);
		p_tracker->set_input("grasp_click", false);
	}
	void publish_gestures(HandIndex p_hand, const Ref<XRPositionalTracker> &p_tracker) {
		p_tracker->set_input("trigger_click", pressed[p_hand]);
		p_tracker->set_input("grip_click", pressed[p_hand]);
		p_tracker->invalidate_pose("default");
		publications++;
	}
};

struct LostInputControllers {
	bool enabled = false;
	Ref<XRPositionalTracker> left_controller_tracker;
	Ref<XRPositionalTracker> right_controller_tracker;
	int resets = 0;

	void reset_controller_tracker_data(const Ref<XRPositionalTracker> &p_tracker) {
		p_tracker->invalidate_pose("default");
		p_tracker->set_input("trigger_click", false);
		p_tracker->set_input("grip_click", false);
		resets++;
	}
};

TEST_CASE("[visionOS] Missing head geometry releases hand gestures and controller input before returning") {
	LostInputHands hands;
	LostInputControllers controllers;
	SUBCASE("Hand-only controller mirrors") {}
	SUBCASE("Accessory-capable controller trackers including optical mirrors") {
		controllers.enabled = true;
	}
	SUBCASE("Controllers without hand tracking") {
		hands.enabled = false;
		controllers.enabled = true;
	}
	Ref<XRPositionalTracker> *trackers[] = {
		&hands.left_hand_tracker, &hands.right_hand_tracker,
		&hands.left_hand_controller_tracker, &hands.right_hand_controller_tracker,
		&controllers.left_controller_tracker, &controllers.right_controller_tracker
	};
	for (auto *tracker : trackers) {
		tracker->instantiate();
		(*tracker)->set_pose("default", Transform3D(), Vector3(), Vector3());
		(*tracker)->set_input("pinch_click", true);
		(*tracker)->set_input("grasp_click", true);
		(*tracker)->set_input("trigger_click", true);
		(*tracker)->set_input("grip_click", true);
	}
	visionos_reset_input_tracking(hands, controllers);
	CHECK(hands.resets == (hands.enabled ? 2 : 0));
	CHECK(hands.publications == (hands.enabled && !controllers.enabled ? 2 : 0));
	CHECK(controllers.resets == (controllers.enabled ? 2 : 0));
	if (hands.enabled) {
		CHECK_FALSE(hands.pressed[0]);
		CHECK_FALSE(hands.pressed[1]);
		for (const auto &tracker : { hands.left_hand_tracker, hands.right_hand_tracker }) {
			CHECK_FALSE(tracker->get_pose("default")->get_has_tracking_data());
			CHECK_FALSE(bool(tracker->get_input("pinch_click")));
			CHECK_FALSE(bool(tracker->get_input("grasp_click")));
		}
	}
	for (const auto &tracker : {
				 controllers.enabled ? controllers.left_controller_tracker : hands.left_hand_controller_tracker,
				 controllers.enabled ? controllers.right_controller_tracker : hands.right_hand_controller_tracker }) {
		CHECK_FALSE(tracker->get_pose("default")->get_has_tracking_data());
		CHECK_FALSE(bool(tracker->get_input("trigger_click")));
		CHECK_FALSE(bool(tracker->get_input("grip_click")));
	}
}

struct Output {
	int value = 0;
	std::shared_ptr<int> texture;
	std::shared_ptr<int> depth_pyramid;
};

using Mailbox = VisionOSSceneMailbox<Output>;

TEST_CASE("[visionOS] Depth hierarchy stays with the producer and consumer lease across invalidation") {
	auto mailbox = std::make_shared<Mailbox>();
	auto output = mailbox->acquire();
	output.output->texture = std::make_shared<int>(10);
	output.output->depth_pyramid = std::make_shared<int>(20);
	std::weak_ptr<int> texture = output.output->texture;
	std::weak_ptr<int> pyramid = output.output->depth_pyramid;
	std::function<void(bool)> complete = [mailbox, lease = std::move(output)](bool p_encoded_hierarchy) {
		mailbox->complete(lease, p_encoded_hierarchy);
	};
	auto second = mailbox->acquire();
	auto third = mailbox->acquire();
	CHECK_FALSE(mailbox->acquire().output);
	CHECK_FALSE(mailbox->latest());
	mailbox->invalidate();
	complete(true);
	CHECK_FALSE(mailbox->latest());
	CHECK_FALSE(mailbox->acquire().output);
	mailbox.reset();
	second = {};
	third = {};
	CHECK_FALSE(texture.expired());
	CHECK_FALSE(pyramid.expired());
	complete = {};
	CHECK(texture.expired());
	CHECK(pyramid.expired());

	mailbox = std::make_shared<Mailbox>();
	output = mailbox->acquire();
	output.output->depth_pyramid = std::make_shared<int>(30);
	pyramid = output.output->depth_pyramid;
	mailbox->complete(output, true);
	auto consumer = mailbox->latest();
	REQUIRE(consumer);
	CHECK(*consumer->depth_pyramid == 30);
	output = {};
	mailbox->close();
	mailbox.reset();
	CHECK_FALSE(pyramid.expired());
	consumer.reset();
	CHECK(pyramid.expired());
}

struct CountedOutput {
	static int constructed;
	static int destroyed;

	CountedOutput() { ++constructed; }
	~CountedOutput() { ++destroyed; }
};

int CountedOutput::constructed = 0;
int CountedOutput::destroyed = 0;

TEST_CASE("[visionOS] Scene mailbox allocates at most three outputs and never waits for a busy slot") {
	const int constructed_before = CountedOutput::constructed;
	const int destroyed_before = CountedOutput::destroyed;
	{
		VisionOSSceneMailbox<CountedOutput> mailbox;
		auto first = mailbox.acquire();
		auto second = mailbox.acquire();
		auto third = mailbox.acquire();
		REQUIRE(first.output);
		REQUIRE(second.output);
		REQUIRE(third.output);
		CHECK(first.output != second.output);
		CHECK(first.output != third.output);
		CHECK(second.output != third.output);
		CHECK(first.generation == mailbox.generation());
		CHECK(first.sequence < second.sequence);
		CHECK(second.sequence < third.sequence);
		CHECK_FALSE(mailbox.acquire().output);
		CHECK(CountedOutput::constructed - constructed_before == 3);

		CountedOutput *released = second.output.get();
		second = {};
		for (int i = 0; i < 64; ++i) {
			auto reused = mailbox.acquire();
			REQUIRE(reused.output);
			CHECK(reused.output.get() == released);
			CHECK(reused.sequence > third.sequence);
			CHECK_FALSE(mailbox.acquire().output);
			mailbox.complete(std::move(reused), false);
		}
		CHECK(CountedOutput::constructed - constructed_before == 3);
		CHECK(CountedOutput::destroyed == destroyed_before);
	}
	CHECK(CountedOutput::destroyed - destroyed_before == 3);
}

TEST_CASE("[visionOS] Only successful producer GPU completion makes an output visible") {
	Mailbox mailbox;
	auto unfinished = mailbox.acquire();
	REQUIRE(unfinished.output);
	unfinished.output->value = 10;
	std::function<void(bool)> gpu_completed = [&mailbox, lease = std::move(unfinished)](bool p_success) mutable {
		mailbox.complete(std::move(lease), p_success);
	};
	CHECK_FALSE(mailbox.latest());
	gpu_completed(false);
	CHECK_FALSE(mailbox.latest());

	auto successful = mailbox.acquire();
	REQUIRE(successful.output);
	successful.output->value = 20;
	gpu_completed = [&mailbox, lease = std::move(successful)](bool p_success) mutable {
		mailbox.complete(std::move(lease), p_success);
	};
	CHECK_FALSE(mailbox.latest());
	gpu_completed(true);
	REQUIRE(mailbox.latest());
	CHECK(mailbox.latest()->value == 20);

	auto failed = mailbox.acquire();
	REQUIRE(failed.output);
	failed.output->value = 30;
	CHECK(mailbox.latest()->value == 20);
	mailbox.complete(std::move(failed), false);
	CHECK(mailbox.latest()->value == 20);
	mailbox.complete({}, true);
	CHECK(mailbox.latest()->value == 20);
}

TEST_CASE("[visionOS] Reordered producer GPU callbacks never regress the published sequence") {
	Mailbox mailbox;
	auto first = mailbox.acquire();
	auto second = mailbox.acquire();
	auto third = mailbox.acquire();
	REQUIRE(first.output);
	REQUIRE(second.output);
	REQUIRE(third.output);
	first.output->value = 1;
	second.output->value = 2;
	third.output->value = 3;
	mailbox.complete(std::move(third), true);
	REQUIRE(mailbox.latest());
	CHECK(mailbox.latest()->value == 3);
	mailbox.complete(std::move(first), true);
	CHECK(mailbox.latest()->value == 3);
	mailbox.complete(std::move(second), true);
	CHECK(mailbox.latest()->value == 3);

	auto older = mailbox.acquire();
	auto newer = mailbox.acquire();
	REQUIRE(older.output);
	REQUIRE(newer.output);
	older.output->value = 4;
	mailbox.complete(std::move(newer), false);
	mailbox.complete(std::move(older), true);
	CHECK(mailbox.latest()->value == 4);
}

TEST_CASE("[visionOS] Layer replacement rejects stale callbacks without reopening retained slots") {
	Mailbox mailbox;
	auto old = mailbox.acquire();
	auto stale = mailbox.acquire();
	REQUIRE(old.output);
	REQUIRE(stale.output);
	old.output->value = 1;
	stale.output->value = 2;
	mailbox.complete(std::move(old), true);
	auto old_presenter = mailbox.latest();
	REQUIRE(old_presenter);
	const uint64_t old_generation = mailbox.generation();
	mailbox.invalidate();
	CHECK(mailbox.generation() == old_generation + 1);
	CHECK_FALSE(mailbox.latest());
	auto replacement = mailbox.acquire();
	REQUIRE(replacement.output);
	CHECK(replacement.generation == mailbox.generation());
	CHECK(replacement.output.get() != old_presenter.get());
	CHECK(replacement.output != stale.output);
	CHECK_FALSE(mailbox.acquire().output);
	replacement.output->value = 3;
	auto late_stale_callback = stale;
	mailbox.complete(std::move(stale), true);
	CHECK_FALSE(mailbox.latest());
	mailbox.complete(std::move(replacement), true);
	REQUIRE(mailbox.latest());
	CHECK(mailbox.latest()->value == 3);
	mailbox.complete(std::move(late_stale_callback), true);
	CHECK(mailbox.latest()->value == 3);
	CHECK(old_presenter->value == 1);
}

TEST_CASE("[visionOS] A presenter GPU callback retains its immutable output through replacement") {
	Mailbox mailbox;
	auto first = mailbox.acquire();
	REQUIRE(first.output);
	first.output->value = 1;
	mailbox.complete(std::move(first), true);
	auto presenter = mailbox.latest();
	REQUIRE(presenter);
	const Output *presented_slot = presenter.get();
	int completed_value = 0;
	std::function<void()> presenter_gpu_completed = [snapshot = std::move(presenter), &completed_value]() mutable {
		completed_value = snapshot->value;
		snapshot.reset();
	};

	auto second = mailbox.acquire();
	REQUIRE(second.output);
	second.output->value = 2;
	mailbox.complete(std::move(second), true);
	auto producer_in_flight = mailbox.acquire();
	REQUIRE(producer_in_flight.output);
	CHECK(producer_in_flight.output.get() != presented_slot);
	CHECK_FALSE(mailbox.acquire().output);
	presenter_gpu_completed();
	CHECK(completed_value == 1);
	auto recycled = mailbox.acquire();
	REQUIRE(recycled.output);
	CHECK(recycled.output.get() == presented_slot);
	CHECK(mailbox.latest()->value == 2);
}

TEST_CASE("[visionOS] Close rejects in-flight publication while GPU callbacks keep resources alive") {
	auto mailbox = std::make_shared<Mailbox>();
	auto published = mailbox->acquire();
	REQUIRE(published.output);
	published.output->texture = std::make_shared<int>(42);
	std::weak_ptr<int> texture = published.output->texture;
	mailbox->complete(std::move(published), true);
	auto presenter = mailbox->latest();
	REQUIRE(presenter);
	int completed_texture = 0;
	std::function<void()> presenter_gpu_completed = [snapshot = std::move(presenter), &completed_texture]() mutable {
		completed_texture = *snapshot->texture;
		snapshot.reset();
	};

	auto in_flight = mailbox->acquire();
	REQUIRE(in_flight.output);
	std::weak_ptr<Output> pending = in_flight.output;
	std::function<void()> producer_gpu_completed = [owner = mailbox, lease = std::move(in_flight)]() mutable {
		owner->complete(std::move(lease), true);
	};
	mailbox->close();
	mailbox->close();
	CHECK_FALSE(mailbox->latest());
	CHECK_FALSE(mailbox->acquire().output);
	producer_gpu_completed();
	CHECK_FALSE(mailbox->latest());
	mailbox->invalidate();
	CHECK_FALSE(mailbox->acquire().output);
	CHECK_FALSE(mailbox->latest());
	mailbox.reset();
	CHECK_FALSE(pending.expired());
	producer_gpu_completed = {};
	CHECK(pending.expired());
	CHECK_FALSE(texture.expired());
	presenter_gpu_completed();
	CHECK(completed_texture == 42);
	CHECK(texture.expired());
}

TEST_CASE("[visionOS] A completion from another scene mailbox cannot replace its output") {
	Mailbox first;
	Mailbox second;
	auto foreign = first.acquire();
	REQUIRE(foreign.output);
	CHECK(foreign.generation == second.generation());
	second.complete(std::move(foreign), true);
	CHECK_FALSE(first.latest());
	CHECK_FALSE(second.latest());
}

struct CompositorFrame {
	std::thread::id owner;
	int phase = 0;
	bool valid = true;
	uint32_t calls = 0;

	void record(bool p_valid) {
		valid = valid && p_valid && owner == std::this_thread::get_id();
		++calls;
	}
};

// No assertions run on the compositor thread. The lifecycle's calls accumulate
// evidence on a stack-owned frame which never enters a producer output.
struct CompositorAPI {
	using Frame = CompositorFrame *;
	using Timing = CompositorFrame *;
	using Drawable = CompositorFrame *;

	static Timing predict_timing(Frame p_frame) {
		p_frame->record(p_frame->phase == 0 || p_frame->phase == 2);
		return p_frame;
	}
	static void start_update(Frame p_frame) {
		p_frame->record(p_frame->phase == 0);
		p_frame->phase = 1;
	}
	static void end_update(Frame p_frame) {
		p_frame->record(p_frame->phase == 1);
		p_frame->phase = 2;
	}
	static void wait_until_input(Timing p_timing) {
		p_timing->record(p_timing->phase == 2);
	}
	static void start_submission(Frame p_frame) {
		p_frame->record(p_frame->phase == 2);
		p_frame->phase = 3;
	}
	static Drawable query_drawable(Frame p_frame, bool &r_frame_valid) {
		p_frame->record(p_frame->phase == 3);
		r_frame_valid = true;
		return p_frame;
	}
	static void end_submission(Frame p_frame) {
		p_frame->record(p_frame->phase == 3);
		p_frame->phase = 4;
	}
};

struct StageProgress {
	uint64_t ticks = 0;
	uint64_t wrong_output = 0;
	std::array<uint64_t, 3> intervals = {};
};

TEST_CASE("[visionOS] Independent compositor progresses through 30s initialization and 18s first and late pipeline waits") {
	using Clock = std::chrono::steady_clock;
	using Lifecycle = VisionOSFrameLifecycle<CompositorAPI>;
	const std::array<std::chrono::seconds, 3> delays = { 30s, 18s, 18s };
	Mailbox mailbox;
	std::mutex state_mutex;
	std::condition_variable owner_wait;
	int stage = 0;
	auto stage_started = Clock::now();
	std::array<StageProgress, 3> progress;
	std::array<Clock::duration, 3> elapsed = {};
	std::array<bool, 3> timed_out = {};
	std::mutex tick_mutex;
	std::condition_variable tick_wait;
	std::atomic<bool> stop{ false };
	const std::thread::id test_owner = std::this_thread::get_id();
	std::thread::id engine_owner;
	std::thread::id compositor_owner;
	bool balanced_frames = true;
	uint64_t completed_frames = 0;
	Clock::duration longest_frame = Clock::duration::zero();
	Clock::duration longest_tick_gap = Clock::duration::zero();

	std::thread compositor([&] {
		compositor_owner = std::this_thread::get_id();
		auto previous_tick = Clock::now();
		while (!stop.load()) {
			int frame_stage;
			Clock::time_point frame_stage_started;
			std::shared_ptr<const Output> snapshot;
			{
				std::lock_guard<std::mutex> lock(state_mutex);
				frame_stage = stage;
				frame_stage_started = stage_started;
				snapshot = mailbox.latest();
			}
			const auto started = Clock::now();
			const auto tick_gap = started - previous_tick;
			if (tick_gap > longest_tick_gap) {
				longest_tick_gap = tick_gap;
			}
			previous_tick = started;
			{
				CompositorFrame frame{ std::this_thread::get_id() };
				Lifecycle lifecycle;
				const bool began = lifecycle.begin(&frame);
				const bool ready = lifecycle.prepare() == Lifecycle::Result::READY;
				const bool drawable = lifecycle.can_draw() && lifecycle.get_drawable() == &frame;
				// An empty mailbox submits the fallback, not an engine wait.
				auto &result = progress[frame_stage];
				++result.ticks;
				const bool expected = frame_stage < 2 ? !snapshot : snapshot && snapshot->value == 1;
				result.wrong_output += expected ? 0 : 1;
				const auto seconds = std::chrono::duration_cast<std::chrono::seconds>(started - frame_stage_started).count();
				const auto interval = seconds / (delays[frame_stage].count() / 3);
				++result.intervals[interval < 2 ? interval : 2];
				lifecycle.consume_drawable();
				lifecycle.finish();
				balanced_frames = balanced_frames && began && ready && drawable && frame.valid && frame.phase == 4 && frame.calls == 8;
				balanced_frames = balanced_frames && !lifecycle.get_frame() && !lifecycle.get_timing() && !lifecycle.get_drawable() && !lifecycle.can_draw();
				++completed_frames;
			}
			// Frame and drawable equivalents have ended before the next tick.
			snapshot.reset();
			const auto frame_duration = Clock::now() - started;
			if (frame_duration > longest_frame) {
				longest_frame = frame_duration;
			}
			std::unique_lock<std::mutex> lock(tick_mutex);
			tick_wait.wait_for(lock, 5ms, [&] { return stop.load(); });
		}
	});

	Mailbox::Lease pending;
	bool first_acquired = false;
	bool late_acquired = false;
	// Exercise the production engine owner and frame lifecycle on the host.
	// The frame API models ownership; this does not exercise CompositorServices.
	VisionOSEngineThread owner;
	owner.start();
	const bool posted = owner.post([&] {
		engine_owner = std::this_thread::get_id();
		for (int i = 0; i < 3; ++i) {
			std::unique_lock<std::mutex> lock(state_mutex);
			if (i == 1) {
				pending = mailbox.acquire();
				first_acquired = bool(pending.output);
				if (pending.output) {
					pending.output->value = 1;
				}
			} else if (i == 2) {
				mailbox.complete(std::move(pending), true);
				pending = mailbox.acquire();
				late_acquired = bool(pending.output);
				if (pending.output) {
					pending.output->value = 2;
				}
			}
			stage = i;
			stage_started = Clock::now();
			const auto deadline = stage_started + delays[i];
			// This is an actual engine-owner stall, including spurious-wakeup handling.
			timed_out[i] = !owner_wait.wait_until(lock, deadline, [] { return false; });
			elapsed[i] = Clock::now() - stage_started;
		}
	});
	owner.finish([] {});
	owner.wait_to_finish();
	stop.store(true);
	tick_wait.notify_one();
	compositor.join();
	mailbox.complete(std::move(pending), true);

	CHECK(posted);
	CHECK(engine_owner != test_owner);
	CHECK(compositor_owner != test_owner);
	CHECK(compositor_owner != engine_owner);
	CHECK(first_acquired);
	CHECK(late_acquired);
	CHECK(balanced_frames);
	CHECK(longest_frame < 5s);
	CHECK(longest_tick_gap < 5s);
	uint64_t ticks = 0;
	for (int i = 0; i < 3; ++i) {
		CAPTURE(i);
		CHECK(timed_out[i]);
		CHECK(elapsed[i] >= delays[i]);
		CHECK(progress[i].ticks >= uint64_t(delays[i].count() * 10));
		CHECK(progress[i].wrong_output == 0);
		for (const auto count : progress[i].intervals) {
			CHECK(count >= 10);
		}
		ticks += progress[i].ticks;
	}
	CHECK(completed_frames == ticks);
	REQUIRE(mailbox.latest());
	CHECK(mailbox.latest()->value == 2);
}

} // namespace TestVisionOSSceneMailbox

#endif // _3D_DISABLED
