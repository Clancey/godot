/**************************************************************************/
/*  visionos_frame_lifecycle.h                                             */
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

// Kept independent of CompositorServices so the same lifecycle can be exercised
// with unavailable frames and cancellation in the host test runner.
template <typename API>
class VisionOSFrameLifecycle {
public:
	using Frame = typename API::Frame;
	using Timing = typename API::Timing;
	using Drawable = typename API::Drawable;

	enum class Result {
		NO_FRAME,
		NO_TIMING,
		CANCELLED,
		NO_DRAWABLE,
		READY,
	};

private:
	enum class Phase {
		IDLE,
		UPDATING,
		SUBMITTING,
	};

	Frame frame = {};
	Timing timing = {};
	Drawable drawable = {};
	Phase phase = Phase::IDLE;
	Result result = Result::NO_FRAME;

	void discard() {
		drawable = {};
		timing = {};
		frame = {};
		phase = Phase::IDLE;
	}

public:
	bool begin(Frame p_frame) {
		finish();
		result = Result::NO_FRAME;
		frame = p_frame;
		if (!frame) {
			return false;
		}
		timing = API::predict_timing(frame);
		if (!timing) {
			result = Result::NO_TIMING;
			discard();
			return false;
		}
		API::start_update(frame);
		phase = Phase::UPDATING;
		return true;
	}

	Result prepare() {
		// Initialization can occur in scene processing, after XRServer::_process.
		// No compositor frame exists until the next engine iteration.
		if (phase != Phase::UPDATING) {
			return result;
		}
		API::end_update(frame);
		phase = Phase::IDLE;
		timing = API::predict_timing(frame);
		if (!timing) {
			result = Result::NO_TIMING;
			discard();
			return result;
		}
		API::wait_until_input(timing);
		API::start_submission(frame);
		phase = Phase::SUBMITTING;
		bool frame_valid = true;
		drawable = API::query_drawable(frame, frame_valid);
		if (!frame_valid) {
			// An empty drawable array cancels the frame. The SDK forbids further
			// access, including end_submission, once this happens.
			result = Result::CANCELLED;
			discard();
		} else if (!drawable) {
			finish();
			result = Result::NO_DRAWABLE;
		} else {
			result = Result::READY;
		}
		return result;
	}

	bool can_draw() const { return phase == Phase::SUBMITTING && drawable; }
	Frame get_frame() const { return frame; }
	Timing get_timing() const { return timing; }
	Drawable get_drawable() const { return drawable; }
	void consume_drawable() { drawable = {}; }

	void finish() {
		if (phase == Phase::UPDATING) {
			API::end_update(frame);
		} else if (phase == Phase::SUBMITTING) {
			API::end_submission(frame);
		}
		discard();
		result = Result::NO_FRAME;
	}
};
