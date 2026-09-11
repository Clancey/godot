/**************************************************************************/
/*  test_visionos_frame_lifecycle.cpp                                      */
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

#include "tests/test_macros.h"

#include "modules/visionos_xr/visionos_frame_lifecycle.h"
#include "modules/visionos_xr/visionos_render_probe.h"

TEST_FORCE_LINK(test_visionos_frame_lifecycle)

namespace TestVisionOSFrameLifecycle {

struct TestFrame {
	String calls;
	int phase = 0;
	bool timing_available = true;
	bool cancelled = false;
	bool built_in = true;
};

struct FrameAPI {
	using Frame = TestFrame *;
	using Timing = TestFrame *;
	using Drawable = TestFrame *;

	static Timing predict_timing(Frame p_frame) {
		REQUIRE(p_frame != nullptr);
		CHECK((p_frame->phase == 0 || p_frame->phase == 2));
		p_frame->calls += "predict ";
		return p_frame->timing_available ? p_frame : nullptr;
	}
	static void start_update(Frame p_frame) {
		REQUIRE(p_frame != nullptr);
		CHECK(p_frame->phase == 0);
		p_frame->phase = 1;
		p_frame->calls += "start_update ";
	}
	static void end_update(Frame p_frame) {
		REQUIRE(p_frame != nullptr);
		CHECK(p_frame->phase == 1);
		p_frame->phase = 2;
		p_frame->calls += "end_update ";
	}
	static void wait_until_input(Timing p_timing) {
		REQUIRE(p_timing != nullptr);
		CHECK(p_timing->phase == 2);
		p_timing->calls += "wait ";
	}
	static void start_submission(Frame p_frame) {
		REQUIRE(p_frame != nullptr);
		CHECK(p_frame->phase == 2);
		p_frame->phase = 3;
		p_frame->calls += "start_submission ";
	}
	static Drawable query_drawable(Frame p_frame, bool &r_frame_valid) {
		REQUIRE(p_frame != nullptr);
		CHECK(p_frame->phase == 3);
		p_frame->calls += "drawables ";
		r_frame_valid = !p_frame->cancelled;
		if (p_frame->cancelled) {
			p_frame->phase = 4;
			return nullptr;
		}
		return p_frame->built_in ? p_frame : nullptr;
	}
	static void end_submission(Frame p_frame) {
		REQUIRE(p_frame != nullptr);
		CHECK(p_frame->phase == 3);
		p_frame->phase = 5;
		p_frame->calls += "end_submission ";
	}
};

using Lifecycle = VisionOSFrameLifecycle<FrameAPI>;
using Result = Lifecycle::Result;

TEST_CASE("[visionOS] Initialization after XR process skips rendering until a frame arrives") {
	Lifecycle frame;
	CHECK(frame.prepare() == Result::NO_FRAME);
	CHECK_FALSE(frame.can_draw());
	CHECK(frame.get_frame() == nullptr);
	CHECK(frame.get_drawable() == nullptr);
	frame.finish();
	CHECK_FALSE(frame.begin(nullptr));
	CHECK(frame.prepare() == Result::NO_FRAME);
	frame.finish();

	TestFrame recovered;
	REQUIRE(frame.begin(&recovered));
	CHECK(frame.get_timing() == &recovered);
	CHECK_FALSE(frame.can_draw());
	CHECK(frame.prepare() == Result::READY);
	CHECK(frame.can_draw());
	CHECK(frame.get_drawable() == &recovered);
	String before_duplicate = recovered.calls;
	CHECK(frame.prepare() == Result::READY);
	CHECK(recovered.calls == before_duplicate);
	frame.consume_drawable();
	CHECK_FALSE(frame.can_draw());
	CHECK(frame.get_drawable() == nullptr);
	CHECK(frame.get_frame() == &recovered);
	frame.finish();
	CHECK(recovered.calls == "predict start_update end_update predict wait start_submission drawables end_submission ");
	CHECK(frame.get_frame() == nullptr);
	CHECK(frame.get_timing() == nullptr);
	CHECK(frame.prepare() == Result::NO_FRAME);
	String finished_calls = recovered.calls;
	frame.finish();
	CHECK(recovered.calls == finished_calls);
}

TEST_CASE("[visionOS] Missing timing before and after update never reaches submission") {
	Lifecycle frame;
	TestFrame paused;
	paused.timing_available = false;
	CHECK_FALSE(frame.begin(&paused));
	CHECK(frame.prepare() == Result::NO_TIMING);
	CHECK(paused.calls == "predict ");
	CHECK_FALSE(frame.can_draw());
	frame.finish();
	CHECK(paused.calls == "predict ");

	TestFrame interrupted;
	REQUIRE(frame.begin(&interrupted));
	interrupted.timing_available = false;
	CHECK(frame.prepare() == Result::NO_TIMING);
	CHECK(interrupted.calls == "predict start_update end_update predict ");
	CHECK(frame.get_frame() == nullptr);
	CHECK(frame.get_timing() == nullptr);
	frame.finish();
	CHECK(interrupted.calls == "predict start_update end_update predict ");

	TestFrame resumed;
	REQUIRE(frame.begin(&resumed));
	CHECK(frame.prepare() == Result::READY);
	CHECK(frame.can_draw());
	frame.finish();
	CHECK(resumed.phase == 5);
}

TEST_CASE("[visionOS] Empty drawables cancel without touching the invalid frame") {
	Lifecycle frame;
	TestFrame cancelled;
	cancelled.cancelled = true;
	REQUIRE(frame.begin(&cancelled));
	CHECK(frame.prepare() == Result::CANCELLED);
	CHECK_FALSE(frame.can_draw());
	CHECK(frame.get_frame() == nullptr);
	CHECK(frame.get_timing() == nullptr);
	CHECK(frame.get_drawable() == nullptr);
	String cancelled_calls = cancelled.calls;
	frame.finish();
	CHECK(cancelled.calls == cancelled_calls);
	CHECK(cancelled.phase == 4);

	TestFrame recovered;
	REQUIRE(frame.begin(&recovered));
	CHECK(frame.prepare() == Result::READY);
	CHECK(frame.get_drawable() == &recovered);
	frame.finish();
	CHECK(cancelled.calls == cancelled_calls);
}

TEST_CASE("[visionOS] Missing built-in drawable closes submission and never reuses an old drawable") {
	Lifecycle frame;
	TestFrame first;
	REQUIRE(frame.begin(&first));
	CHECK(frame.prepare() == Result::READY);
	frame.finish();

	TestFrame capture_only;
	capture_only.built_in = false;
	REQUIRE(frame.begin(&capture_only));
	CHECK(frame.prepare() == Result::NO_DRAWABLE);
	CHECK_FALSE(frame.can_draw());
	CHECK(frame.get_drawable() == nullptr);
	CHECK(frame.get_frame() == nullptr);
	CHECK(capture_only.phase == 5);
	String calls = capture_only.calls;
	frame.finish();
	CHECK(capture_only.calls == calls);
	CHECK_FALSE(frame.begin(nullptr));
	CHECK(frame.prepare() == Result::NO_FRAME);
}

TEST_CASE("[visionOS] Teardown and layer replacement balance only phases that started") {
	Lifecycle frame;
	TestFrame updating;
	REQUIRE(frame.begin(&updating));
	frame.finish();
	CHECK(updating.calls == "predict start_update end_update ");

	TestFrame submitted;
	REQUIRE(frame.begin(&submitted));
	CHECK(frame.prepare() == Result::READY);
	TestFrame replacement;
	REQUIRE(frame.begin(&replacement));
	CHECK(submitted.phase == 5);
	CHECK(frame.get_drawable() == nullptr);
	CHECK_FALSE(frame.can_draw());
	CHECK(frame.prepare() == Result::READY);
	frame.finish();
	CHECK(replacement.phase == 5);
}

TEST_CASE("[visionOS] Output probe samples and visible intervention are strictly bounded") {
	uint32_t samples = 0;
	for (uint64_t frame = 0; frame < 100000; frame++) {
		samples += VisionOSRenderProbe::sample(frame) ? 1 : 0;
	}
	CHECK(samples == 8);
	CHECK_FALSE(VisionOSRenderProbe::sample(0));
	CHECK_FALSE(VisionOSRenderProbe::sample(601));
	CHECK_FALSE(VisionOSRenderProbe::clear_output(-0.001, 0));
	CHECK(VisionOSRenderProbe::clear_output(0.0, 0));
	CHECK(VisionOSRenderProbe::clear_output(1.999, 179));
	CHECK_FALSE(VisionOSRenderProbe::clear_output(2.0, 0));
	CHECK_FALSE(VisionOSRenderProbe::clear_output(0.5, 180));
	CHECK_FALSE(VisionOSRenderProbe::clear_output(30.0, 1));
}

} // namespace TestVisionOSFrameLifecycle
