/**************************************************************************/
/*  visionos_pose_latency.h                                               */
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

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>

// The presenter acquires a head pose for its drawable, but the engine output
// rendered from that pose reaches the display several frames later. Apple's
// compositor reprojects the difference, and the disocclusions it uncovers
// behind near objects smear. This estimates that pipeline latency so the
// engine renders a pose predicted for when its frame is actually shown.
// Kept free of CompositorServices so it runs in the host test runner.
class VisionOSPoseLatency {
public:
	enum Mode {
		AUTO,
		OFF,
		FIXED,
	};

	// A lead beyond a few display frames extrapolates head motion further
	// than ARKit predicts reliably; the compositor reprojects the remainder.
	static constexpr double MAX_LEAD = 0.1;
	// Samples from frames older than the presenter's expiry are not latency.
	static constexpr double MAX_SAMPLE = 0.25;
	static constexpr double SMOOTHING = 0.125;

	// `p_value` is the VISIONOS_POSE_LEAD environment value: unset or "auto"
	// measures the latency, "off" or "0" disables prediction, and a positive
	// number is a fixed lead in milliseconds.
	void configure(const char *p_value) {
		mode = AUTO;
		fixed_lead = 0;
		if (!p_value || !*p_value || std::strcmp(p_value, "auto") == 0) {
			return;
		}
		if (std::strcmp(p_value, "off") == 0) {
			mode = OFF;
			return;
		}
		char *end = nullptr;
		double milliseconds = std::strtod(p_value, &end);
		if (end == p_value || *end != '\0' || !std::isfinite(milliseconds)) {
			return;
		}
		if (milliseconds <= 0) {
			mode = OFF;
			return;
		}
		mode = FIXED;
		fixed_lead = std::min(milliseconds / 1000.0, MAX_LEAD);
	}

	// Call once per engine output, when the presenter first shows it.
	// `p_acquired_time` is the presentation time of the drawable whose pose
	// the output was rendered from; `p_shown_time` is the presentation time of
	// the drawable now showing it.
	void observe(double p_acquired_time, double p_shown_time) {
		double sample = p_shown_time - p_acquired_time;
		if (!std::isfinite(sample) || sample < 0 || sample > MAX_SAMPLE) {
			return;
		}
		sample = std::min(sample, MAX_LEAD);
		measured = has_sample ? measured + (sample - measured) * SMOOTHING : sample;
		has_sample = true;
	}

	double get_lead() const {
		switch (mode) {
			case OFF:
				return 0;
			case FIXED:
				return fixed_lead;
			case AUTO:
			default:
				return has_sample ? measured : 0;
		}
	}

	Mode get_mode() const { return mode; }

	void reset() {
		measured = 0;
		has_sample = false;
	}

private:
	Mode mode = AUTO;
	double fixed_lead = 0;
	double measured = 0;
	bool has_sample = false;
};
