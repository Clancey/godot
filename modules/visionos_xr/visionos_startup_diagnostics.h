/**************************************************************************/
/*  visionos_startup_diagnostics.h                                         */
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

#include "visionos_eye_transform.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string_view>

inline bool visionos_startup_diagnostics_opt_in(bool p_enabled, std::string_view p_bundle, std::string_view p_expected_bundle) {
	return p_enabled && !p_bundle.empty() && p_bundle == p_expected_bundle;
}

class VisionOSStartupDiagnostics {
public:
	enum Reason {
		SCENE,
		NO_OUTPUT,
		TRACKING_UNAVAILABLE,
		SOURCE_EXPIRED,
		PIPELINE_PENDING,
		SOURCE_ANCHOR_MISSING,
		EYE_MISMATCH,
		ENCODING_FAILED,
		REASON_COUNT
	};

	struct Source {
		uint64_t layer = 0;
		uint64_t generation = 0;
		uint64_t sequence = 0;
		double age_ms = 0;
	};

	struct Transition {
		double elapsed = 0;
		Reason from = NO_OUTPUT;
		Reason to = NO_OUTPUT;
		Source source;
		std::array<VisionOSEyeTransformComparison, 2> eyes{};
	};

	struct EyeWindow {
		uint64_t samples = 0;
		uint64_t original_mismatches = 0;
		uint64_t positional_mappings = 0;
		std::array<uint64_t, VisionOSEyeTransformComparison::REJECTION_COUNT> rejections{};
		double rotation_max_degrees = 0;
		double basis_max_delta = 0;
		std::array<double, 3> translation_max_abs_m{};
		double anchor_assignment_basis_max_delta = 0;
		std::array<double, 3> anchor_assignment_translation_max_abs_m{};
	};

	struct Report {
		uint64_t index = 0;
		double elapsed = 0;
		std::array<uint64_t, REASON_COUNT> reasons{};
		std::array<double, REASON_COUNT> max_source_age_ms{};
		uint64_t new_sources_observed = 0;
		Source latest_source;
		Source latest_eye_source;
		std::array<VisionOSEyeTransformComparison, 2> latest_eyes{};
		std::array<EyeWindow, 2> eye_windows{};
		Reason last_reason = NO_OUTPUT;
		std::array<Transition, 8> transitions{};
		uint32_t transition_count = 0;
		uint64_t transitions_omitted = 0;
		uint64_t iterations_started = 0;
		uint64_t iterations_completed = 0;
		uint64_t iterations_over_250ms = 0;
		double iteration_max_ms = 0;
		double active_iteration_ms = 0;
		uint64_t producer_completed = 0;
		uint64_t producer_failed = 0;
		uint64_t producer_invalid_projection = 0;
		uint64_t gpu_timed_samples = 0;
		double acquire_to_encode_max_ms = 0;
		double encode_to_complete_max_ms = 0;
		double gpu_max_ms = 0;
		double source_to_complete_max_ms = 0;
		uint64_t last_completed_sequence = 0;
		uint64_t last_completed_layer = 0;
		uint64_t last_completed_generation = 0;
		uint64_t presenter_completed = 0;
		uint64_t presenter_failed = 0;
		double presenter_gpu_max_ms = 0;
		double presenter_encode_to_complete_max_ms = 0;
	};

private:
	std::mutex mutex;
	std::atomic<bool> finished{ false };
	const double started_at;
	double next_report_at;
	double iteration_started_at = 0;
	bool saw_reason = false;
	Report totals;

public:
	explicit VisionOSStartupDiagnostics(double p_now) :
			started_at(p_now), next_report_at(p_now + 2.0) {}

	bool is_active() const { return !finished.load(std::memory_order_relaxed); }

	void sample(double p_now, Reason p_reason, const Source &p_source, const std::array<VisionOSEyeTransformComparison, 2> &p_eyes = {}) {
		if (!is_active()) {
			return;
		}
		std::lock_guard<std::mutex> lock(mutex);
		totals.reasons[p_reason]++;
		for (uint32_t eye = 0; eye < p_eyes.size(); eye++) {
			const auto &comparison = p_eyes[eye];
			if (!comparison.compared) {
				continue;
			}
			totals.latest_eyes[eye] = comparison;
			totals.latest_eye_source = p_source;
			auto &window = totals.eye_windows[eye];
			window.samples++;
			window.original_mismatches += comparison.original_mismatch;
			window.positional_mappings += comparison.positional_reprojection;
			window.rejections[comparison.rejection]++;
			window.rotation_max_degrees = std::max(window.rotation_max_degrees, comparison.rotation_degrees);
			window.basis_max_delta = std::max(window.basis_max_delta, comparison.basis_max_delta);
			window.anchor_assignment_basis_max_delta = std::max(window.anchor_assignment_basis_max_delta, comparison.anchor_assignment_basis_max_delta);
			for (uint32_t axis = 0; axis < 3; axis++) {
				window.translation_max_abs_m[axis] = std::max(window.translation_max_abs_m[axis], std::abs(comparison.translation_m[axis]));
				window.anchor_assignment_translation_max_abs_m[axis] = std::max(window.anchor_assignment_translation_max_abs_m[axis], std::abs(comparison.anchor_assignment_translation_m[axis]));
			}
		}
		if (p_source.sequence) {
			totals.max_source_age_ms[p_reason] = std::max(totals.max_source_age_ms[p_reason], p_source.age_ms);
			if (p_source.layer != totals.latest_source.layer || p_source.generation != totals.latest_source.generation || p_source.sequence != totals.latest_source.sequence) {
				totals.new_sources_observed++;
			}
			totals.latest_source = p_source;
		}
		if (!saw_reason || p_reason != totals.last_reason) {
			if (totals.transition_count < totals.transitions.size()) {
				totals.transitions[totals.transition_count++] = { p_now - started_at, totals.last_reason, p_reason, p_source, p_eyes };
			} else {
				totals.transitions_omitted++;
			}
		}
		saw_reason = true;
		totals.last_reason = p_reason;
	}

	void iteration_begin(double p_now) {
		if (!is_active()) {
			return;
		}
		std::lock_guard<std::mutex> lock(mutex);
		totals.iterations_started++;
		iteration_started_at = p_now;
	}

	void iteration_end(double p_now) {
		if (!is_active()) {
			return;
		}
		std::lock_guard<std::mutex> lock(mutex);
		double elapsed_ms = (p_now - iteration_started_at) * 1000.0;
		totals.iterations_completed++;
		totals.iterations_over_250ms += elapsed_ms > 250.0;
		totals.iteration_max_ms = std::max(totals.iteration_max_ms, elapsed_ms);
	}

	void producer_complete(const Source &p_source, bool p_success, bool p_projection_valid, double p_acquire_to_encode_ms, double p_encode_to_complete_ms, double p_gpu_ms) {
		if (!is_active()) {
			return;
		}
		std::lock_guard<std::mutex> lock(mutex);
		if (p_success) {
			totals.producer_completed++;
		} else {
			totals.producer_failed++;
		}
		totals.producer_invalid_projection += !p_projection_valid;
		totals.last_completed_sequence = p_source.sequence;
		totals.last_completed_layer = p_source.layer;
		totals.last_completed_generation = p_source.generation;
		totals.acquire_to_encode_max_ms = std::max(totals.acquire_to_encode_max_ms, p_acquire_to_encode_ms);
		totals.encode_to_complete_max_ms = std::max(totals.encode_to_complete_max_ms, p_encode_to_complete_ms);
		totals.source_to_complete_max_ms = std::max(totals.source_to_complete_max_ms, p_source.age_ms);
		if (p_gpu_ms > 0) {
			totals.gpu_timed_samples++;
			totals.gpu_max_ms = std::max(totals.gpu_max_ms, p_gpu_ms);
		}
	}

	void presenter_complete(bool p_success, double p_encode_to_complete_ms, double p_gpu_ms) {
		if (!is_active()) {
			return;
		}
		std::lock_guard<std::mutex> lock(mutex);
		totals.presenter_completed += p_success;
		totals.presenter_failed += !p_success;
		totals.presenter_gpu_max_ms = std::max(totals.presenter_gpu_max_ms, p_gpu_ms);
		totals.presenter_encode_to_complete_max_ms = std::max(totals.presenter_encode_to_complete_max_ms, p_encode_to_complete_ms);
	}

	// At most one compact report every two seconds for three minutes. Only
	// counters are cumulative; maxima and transition records cover each window.
	std::optional<Report> take_report(double p_now) {
		if (!is_active()) {
			return {};
		}
		std::lock_guard<std::mutex> lock(mutex);
		if (p_now < next_report_at) {
			return {};
		}
		totals.index++;
		totals.elapsed = p_now - started_at;
		totals.active_iteration_ms = totals.iterations_started > totals.iterations_completed ? (p_now - iteration_started_at) * 1000.0 : 0;
		Report result = totals;
		totals.transition_count = 0;
		totals.max_source_age_ms.fill(0);
		for (auto &window : totals.eye_windows) {
			window.rotation_max_degrees = 0;
			window.basis_max_delta = 0;
			window.translation_max_abs_m.fill(0);
			window.anchor_assignment_basis_max_delta = 0;
			window.anchor_assignment_translation_max_abs_m.fill(0);
		}
		totals.iteration_max_ms = 0;
		totals.acquire_to_encode_max_ms = 0;
		totals.encode_to_complete_max_ms = 0;
		totals.gpu_max_ms = 0;
		totals.source_to_complete_max_ms = 0;
		totals.presenter_gpu_max_ms = 0;
		totals.presenter_encode_to_complete_max_ms = 0;
		next_report_at = p_now + 2.0;
		if (totals.elapsed >= 180.0 || totals.index >= 90) {
			finished.store(true, std::memory_order_relaxed);
		}
		return result;
	}
};

std::shared_ptr<VisionOSStartupDiagnostics> visionos_get_startup_diagnostics();
