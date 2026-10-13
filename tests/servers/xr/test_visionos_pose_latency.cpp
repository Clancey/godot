/**************************************************************************/
/*  test_visionos_pose_latency.cpp                                        */
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

#include "modules/visionos_xr/visionos_pose_latency.h"

TEST_FORCE_LINK(test_visionos_pose_latency)

namespace TestVisionOSPoseLatency {

TEST_CASE("[VisionOS] Pose latency predicts nothing until an output has been shown") {
	VisionOSPoseLatency latency;
	CHECK(latency.get_mode() == VisionOSPoseLatency::AUTO);
	CHECK(latency.get_lead() == 0);
}

TEST_CASE("[VisionOS] Pose latency converges on the engine-to-display delay") {
	VisionOSPoseLatency latency;
	const double frame = 1.0 / 90.0;
	// Device sweeps showed outputs first shown three display frames after
	// the drawable that acquired their pose.
	double acquired = 100.0;
	for (int i = 0; i < 64; i++) {
		latency.observe(acquired, acquired + 3 * frame);
		acquired += frame;
	}
	CHECK(latency.get_lead() == doctest::Approx(3 * frame).epsilon(0.001));
}

TEST_CASE("[VisionOS] Pose latency smooths a single slow frame") {
	VisionOSPoseLatency latency;
	const double frame = 1.0 / 90.0;
	for (int i = 0; i < 32; i++) {
		latency.observe(i * frame, (i + 2) * frame);
	}
	latency.observe(1.0, 1.0 + 0.09);
	CHECK(latency.get_lead() < 4 * frame);
	CHECK(latency.get_lead() > 2 * frame);
}

TEST_CASE("[VisionOS] Pose latency ignores impossible samples and clamps its lead") {
	VisionOSPoseLatency latency;
	latency.observe(10.0, 9.99);
	latency.observe(10.0, 10.3);
	latency.observe(10.0, NAN);
	CHECK(latency.get_lead() == 0);
	for (int i = 0; i < 64; i++) {
		latency.observe(10.0, 10.2);
	}
	CHECK(latency.get_lead() == VisionOSPoseLatency::MAX_LEAD);
	latency.reset();
	CHECK(latency.get_lead() == 0);
}

TEST_CASE("[VisionOS] Pose latency honours the VISIONOS_POSE_LEAD override") {
	VisionOSPoseLatency latency;
	latency.observe(0.0, 0.03);

	latency.configure("off");
	CHECK(latency.get_mode() == VisionOSPoseLatency::OFF);
	CHECK(latency.get_lead() == 0);

	latency.configure("0");
	CHECK(latency.get_mode() == VisionOSPoseLatency::OFF);

	latency.configure("22");
	CHECK(latency.get_mode() == VisionOSPoseLatency::FIXED);
	CHECK(latency.get_lead() == doctest::Approx(0.022));

	latency.configure("500");
	CHECK(latency.get_lead() == VisionOSPoseLatency::MAX_LEAD);

	latency.configure("auto");
	CHECK(latency.get_mode() == VisionOSPoseLatency::AUTO);
	CHECK(latency.get_lead() == doctest::Approx(0.03));

	latency.configure("fast");
	CHECK(latency.get_mode() == VisionOSPoseLatency::AUTO);
	latency.configure(nullptr);
	CHECK(latency.get_mode() == VisionOSPoseLatency::AUTO);
}

} // namespace TestVisionOSPoseLatency
