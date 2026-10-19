/**************************************************************************/
/*  visionos_image_tracking_store.h                                       */
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

#include "core/error/error_list.h"
#include "core/math/transform_3d.h"
#include "core/math/vector2.h"

#include <atomic>
#include <map>
#include <mutex>
#include <string>
#include <vector>

// Callback-owned values only. In-flight ARKit blocks may outlive the interface.
class VisionOSImageTrackingStore {
public:
	static bool marker_transform(const Transform3D &p_arkit_transform, Transform3D &r_marker_transform) {
		r_marker_transform = p_arkit_transform;
		if (!p_arkit_transform.is_finite() || p_arkit_transform.basis.determinant() <= CMP_EPSILON) {
			return false;
		}
		// ARKit: XZ image plane, +Y normal, -Z printed-top. Marker: XY plane, +Z normal.
		const Basis image_to_marker(Vector3(1, 0, 0), -Math::PI / 2.0);
		r_marker_transform.basis = p_arkit_transform.basis.orthonormalized() * image_to_marker;
		return r_marker_transform.basis.is_rotation();
	}

	enum class ProviderState { ABSENT,
		INITIALIZED,
		RUNNING,
		PAUSED,
		STOPPED,
		FAILED };

	struct ReferenceResult {
		std::string name;
		int error = OK;
		std::string message;
	};

	struct Status {
		bool supported = false;
		bool enabled = false;
		bool session_active = true;
		std::string authorization = "not_determined";
		int authorization_error = OK;
		std::string authorization_error_message;
		ProviderState provider_state = ProviderState::ABSENT;
		bool running = false;
		uint64_t provider_token = 0;
		uint64_t state_revision = 0;
		uint64_t generation = 0;
		uint64_t reference_revision = 0;
		uint64_t superseded_reference_revision = 0;
		std::string registration_state = "cleared";
		std::vector<ReferenceResult> references;
		int error = OK;
		std::string message;
	};

	struct Observation {
		std::string name;
		std::string uuid;
		Transform3D transform;
		Vector2 physical_size;
		float estimated_scale_factor = 1.0;
		bool tracked = false;
		bool removed = false;
		uint64_t reference_revision = 0;
		uint64_t generation = 0;
		uint64_t sequence = 0;
		double observation_time = 0;
		uint64_t received_ticks_usec = 0;
	};

private:
	mutable std::mutex mutex;
	Status status;
	inline static std::atomic<uint64_t> generation_counter{ 0 };
	uint64_t sequence = 0;
	std::map<std::string, Observation> observations;

	void invalidate_locked() {
		status.generation = ++generation_counter;
		status.state_revision++;
		status.running = false;
	}

	void refresh_running_locked() {
		status.running = status.supported && status.enabled && status.session_active && status.authorization == "allowed" &&
				status.authorization_error == OK && status.registration_state == "registered" &&
				status.provider_state == ProviderState::RUNNING;
	}

public:
	void set_session_active(bool p_active) {
		std::lock_guard<std::mutex> lock(mutex);
		if (status.session_active != p_active) {
			invalidate_locked();
			status.session_active = p_active;
		}
		refresh_running_locked();
	}

	void configure(bool p_supported, bool p_enabled) {
		std::lock_guard<std::mutex> lock(mutex);
		if (status.supported != p_supported || status.enabled != p_enabled) {
			invalidate_locked();
		}
		status.supported = p_supported;
		status.enabled = p_enabled;
		refresh_running_locked();
	}

	void set_authorization(const std::string &p_authorization, int p_error = OK, const std::string &p_message = "") {
		std::lock_guard<std::mutex> lock(mutex);
		if (status.authorization != p_authorization || status.authorization_error != p_error) {
			invalidate_locked();
		}
		status.authorization = p_authorization;
		status.authorization_error = p_error;
		status.authorization_error_message = p_message;
		refresh_running_locked();
	}

	// Called only after every candidate reference (and, when active, its provider) was built.
	uint64_t replace(const std::vector<ReferenceResult> &p_references, bool p_registered) {
		std::lock_guard<std::mutex> lock(mutex);
		status.superseded_reference_revision = status.registration_state == "staged" ? status.reference_revision : 0;
		status.reference_revision++;
		status.provider_token++;
		invalidate_locked();
		status.references = p_references;
		status.registration_state = p_references.empty() ? "cleared" : (p_registered ? "registered" : "staged");
		status.provider_state = p_registered && !p_references.empty() ? ProviderState::INITIALIZED : ProviderState::ABSENT;
		status.error = OK;
		status.message.clear();
		observations.clear();
		return status.provider_token;
	}

	// Activating a staged set keeps its reference identity, but gets a new callback fence.
	uint64_t activate() {
		std::lock_guard<std::mutex> lock(mutex);
		status.provider_token++;
		invalidate_locked();
		status.registration_state = "registered";
		status.provider_state = ProviderState::INITIALIZED;
		for (auto &reference : status.references) {
			reference.error = OK;
			reference.message.clear();
		}
		status.error = OK;
		status.message.clear();
		observations.clear();
		return status.provider_token;
	}

	void registration_failed(const std::vector<ReferenceResult> &p_references, int p_error, const std::string &p_message) {
		std::lock_guard<std::mutex> lock(mutex);
		status.provider_token++;
		invalidate_locked();
		status.references = p_references;
		status.registration_state = "failed";
		status.provider_state = ProviderState::FAILED;
		status.error = p_error;
		status.message = p_message;
		observations.clear();
	}

	void stop() {
		std::lock_guard<std::mutex> lock(mutex);
		status.provider_token++;
		invalidate_locked();
		status.provider_state = ProviderState::ABSENT;
		status.registration_state = status.references.empty() ? "cleared" : "staged";
		status.authorization = "not_determined";
		status.authorization_error = OK;
		status.authorization_error_message.clear();
		status.error = OK;
		status.message.clear();
		observations.clear();
	}

	// p_revision fences a state query racing a callback; callbacks omit it.
	void provider_changed(uint64_t p_token, ProviderState p_state, int p_error = OK, const std::string &p_message = "", uint64_t p_revision = UINT64_MAX) {
		std::lock_guard<std::mutex> lock(mutex);
		if (p_token != status.provider_token || (p_revision != UINT64_MAX && p_revision != status.state_revision)) {
			return;
		}
		// A stopped-state poll must not erase an asynchronous failure.
		if (p_revision != UINT64_MAX && status.provider_state == ProviderState::FAILED) {
			return;
		}
		if (p_error != OK) {
			p_state = ProviderState::FAILED;
		}
		if (status.provider_state != p_state || status.error != p_error) {
			invalidate_locked();
			status.provider_state = p_state;
			status.error = p_error;
			status.message = p_message;
		}
		refresh_running_locked();
	}

	Status get_status() const {
		std::lock_guard<std::mutex> lock(mutex);
		return status;
	}

	bool update(uint64_t p_token, uint64_t p_generation, Observation p_observation) {
		std::lock_guard<std::mutex> lock(mutex);
		if (p_token != status.provider_token || p_generation != status.generation || !status.running) {
			return false;
		}
		if (!Math::is_finite(p_observation.observation_time) || p_observation.observation_time <= 0) {
			return false;
		}
		auto existing = observations.find(p_observation.uuid);
		if (existing != observations.end()) {
			const Observation &previous = existing->second;
			if (previous.removed || p_observation.observation_time < previous.observation_time ||
					(p_observation.observation_time == previous.observation_time && !p_observation.removed &&
							(p_observation.tracked || !previous.tracked))) {
				return false;
			}
			if (p_observation.removed) {
				p_observation.name = previous.name;
			}
		}
		bool registered = false;
		for (const ReferenceResult &reference : status.references) {
			registered |= reference.name == p_observation.name && reference.error == OK;
		}
		// Native removals have only a UUID, including when their add callback has
		// not arrived yet. Keep a provider-scoped tombstone to fence late adds.
		if (!registered && !p_observation.removed) {
			return false;
		}
		p_observation.tracked = p_observation.tracked && !p_observation.removed &&
				p_observation.transform.is_finite() && p_observation.transform.basis.is_rotation() &&
				p_observation.physical_size.is_finite() && p_observation.physical_size.x > 0 && p_observation.physical_size.y > 0 &&
				Math::is_finite(p_observation.estimated_scale_factor) && p_observation.estimated_scale_factor > 0;
		p_observation.generation = status.generation;
		p_observation.reference_revision = status.reference_revision;
		p_observation.sequence = ++sequence;
		observations[p_observation.uuid] = p_observation;
		return true;
	}

	std::vector<Observation> get_observations() const {
		std::lock_guard<std::mutex> lock(mutex);
		std::vector<Observation> result;
		for (const auto &entry : observations) {
			Observation value = entry.second;
			value.tracked &= status.running && value.generation == status.generation;
			result.push_back(value);
		}
		return result;
	}

	Observation get_observation(const std::string &p_uuid, uint64_t p_generation) const {
		std::lock_guard<std::mutex> lock(mutex);
		auto found = observations.find(p_uuid);
		if (found == observations.end() || found->second.generation != p_generation) {
			Observation missing;
			missing.uuid = p_uuid;
			missing.generation = p_generation;
			missing.removed = true;
			return missing;
		}
		Observation result = found->second;
		result.tracked &= status.running && result.generation == status.generation;
		return result;
	}
};
