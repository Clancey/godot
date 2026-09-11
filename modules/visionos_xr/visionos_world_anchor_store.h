/**************************************************************************/
/*  visionos_world_anchor_store.h                                         */
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

#include <map>
#include <mutex>
#include <string>
#include <vector>

// Callback-owned value storage. Never stores Objects, Callables, providers or render resources.
class VisionOSWorldAnchorStore {
public:
	static constexpr size_t MAX_ANCHORS = 256;
	static constexpr size_t MAX_REQUESTS = 64;
	static bool is_valid_transform(const Transform3D &p_transform) {
		return p_transform.is_finite() && p_transform.basis.is_rotation();
	}

	struct Anchor {
		std::string uuid;
		Transform3D transform;
		bool tracked = false;
		bool persisted = false;
		bool removed = false;
		bool present = false;
		bool shared = false;
		bool add_failed = false;
		uint64_t generation = 0;
		uint64_t revision = 0;
		uint64_t create_request = 0;
		double observation_time = 0;
	};

	struct Request {
		uint64_t id = 0;
		uint64_t generation = 0;
		uint64_t revision = 0;
		std::string operation;
		std::string uuid;
		bool complete = false;
		bool success = false;
		bool cancelled = false;
		bool legacy = false;
		bool internal = false;
		int error = OK;
		std::string message;
	};

	struct Status {
		bool running = false;
		uint64_t generation = 0;
		std::string enumeration = "idle";
		uint64_t provider_revision = 0;
		int error = OK;
		std::string message;
	};

	struct ProviderState {
		uint64_t revision;
		bool running;
	};

private:
	mutable std::mutex mutex;
	Status status;
	uint64_t sequence = 0;
	uint64_t next_request = 0;
	std::map<std::string, Anchor> anchors;
	std::map<uint64_t, Request> requests;
	std::string last_error;
	uint64_t provider_observer = 0;
	double snapshot_time = 0;

	void fail_locked(int p_error, const std::string &p_message) {
		status.running = false;
		status.error = p_error;
		status.message = p_message;
		status.enumeration = "failed";
		for (auto &entry : anchors) {
			entry.second.tracked = false;
			entry.second.revision = ++sequence;
		}
		for (auto &entry : requests) {
			if (!entry.second.complete) {
				entry.second.complete = true;
				entry.second.success = false;
				entry.second.error = p_error;
				entry.second.message = p_message;
			}
		}
		for (auto it = requests.begin(); it != requests.end();) {
			if (it->second.cancelled || it->second.internal) {
				it = requests.erase(it);
			} else {
				++it;
			}
		}
	}

	void update_locked(Anchor p_anchor, bool p_unavailable, uint64_t p_snapshot_revision = UINT64_MAX) {
		if (p_anchor.observation_time > 0 && p_anchor.observation_time < snapshot_time) {
			return;
		}
		auto existing = anchors.find(p_anchor.uuid);
		if (existing == anchors.end()) {
			if (anchors.size() >= MAX_ANCHORS) {
				fail_locked(ERR_OUT_OF_MEMORY, "World anchor cache capacity exceeded; restart anchor tracking.");
				return;
			}
			existing = anchors.emplace(p_anchor.uuid, Anchor()).first;
			existing->second.uuid = p_anchor.uuid;
		}
		Anchor &anchor = existing->second;
		// A snapshot may race a newer update or a confirmed removal.
		if (anchor.removed || (p_anchor.observation_time == 0 && anchor.revision > p_snapshot_revision) ||
				(p_anchor.observation_time > 0 && (p_anchor.observation_time < anchor.observation_time || (p_anchor.observation_time == anchor.observation_time && p_anchor.tracked && !p_unavailable)))) {
			return;
		}
		anchor.observation_time = p_anchor.observation_time;
		anchor.generation = status.generation;
		anchor.revision = ++sequence;
		anchor.present = !p_unavailable;
		anchor.shared = p_anchor.shared;
		anchor.tracked = !p_unavailable && p_anchor.tracked && !anchor.add_failed;
		if (!p_unavailable) {
			anchor.transform = p_anchor.transform;
			if (anchor.create_request == 0 && !anchor.add_failed) {
				anchor.persisted = !p_anchor.shared;
			}
		}
	}

public:
	template <typename Query>
	ProviderState sample_provider_state(Query p_query) const {
		const uint64_t revision = get_status().provider_revision;
		return { revision, p_query() };
	}

	uint64_t watch_provider() {
		std::lock_guard<std::mutex> lock(mutex);
		return ++provider_observer;
	}

	void unwatch_provider() {
		std::lock_guard<std::mutex> lock(mutex);
		++provider_observer;
		fail_locked(ERR_UNAVAILABLE, "World anchor observation stopped.");
	}

	void provider_changed(uint64_t p_observer) {
		std::lock_guard<std::mutex> lock(mutex);
		if (p_observer == provider_observer) {
			status.provider_revision++;
			fail_locked(ERR_UNAVAILABLE, "World tracking provider changed state.");
		}
	}

	uint64_t start(uint64_t p_provider_revision = UINT64_MAX) {
		std::lock_guard<std::mutex> lock(mutex);
		if (p_provider_revision != UINT64_MAX && p_provider_revision != status.provider_revision) {
			return 0;
		}
		fail_locked(ERR_UNAVAILABLE, "World anchor tracking restarted.");
		uint64_t provider_revision = status.provider_revision;
		status = Status();
		status.provider_revision = provider_revision;
		status.generation = ++generation_counter;
		status.running = true;
		anchors.clear();
		snapshot_time = 0;
		return status.generation;
	}

	void stop() {
		std::lock_guard<std::mutex> lock(mutex);
		fail_locked(ERR_UNAVAILABLE, "World tracking provider is not running.");
	}

	Status get_status() const {
		std::lock_guard<std::mutex> lock(mutex);
		return status;
	}

	std::string get_last_error() const {
		std::lock_guard<std::mutex> lock(mutex);
		return last_error;
	}

	uint64_t reject(const std::string &p_message) {
		std::lock_guard<std::mutex> lock(mutex);
		last_error = p_message;
		return 0;
	}

	uint64_t begin(const std::string &p_operation, const std::string &p_uuid = "", const Transform3D &p_transform = Transform3D(), bool p_shared = false, bool p_internal = false) {
		std::lock_guard<std::mutex> lock(mutex);
		if (!status.running || requests.size() >= MAX_REQUESTS) {
			last_error = !status.running ? "World tracking is unavailable." : "Drain completed requests before submitting more world anchor operations.";
			if (p_operation == "enumerate") {
				status.enumeration = "failed";
				status.error = ERR_UNAVAILABLE;
				status.message = last_error;
			}
			return 0;
		}
		for (const auto &entry : requests) {
			if (!entry.second.complete && ((p_operation == "enumerate" && entry.second.operation == "enumerate") || (!p_uuid.empty() && entry.second.uuid == p_uuid))) {
				last_error = "A world anchor operation is already pending.";
				return 0;
			}
		}
		if ((p_operation == "create" && anchors.count(p_uuid)) ||
				((p_operation == "create" || p_operation == "remove") && !anchors.count(p_uuid) && anchors.size() >= MAX_ANCHORS)) {
			last_error = "World anchor cache is full or UUID already exists.";
			return 0;
		}
		Request request;
		request.id = ++next_request;
		request.generation = status.generation;
		request.revision = sequence;
		request.operation = p_operation;
		request.uuid = p_uuid;
		request.internal = p_internal;
		requests.emplace(request.id, request);
		if (p_operation == "create") {
			Anchor anchor;
			anchor.uuid = p_uuid;
			anchor.transform = p_transform;
			anchor.shared = p_shared;
			anchor.create_request = request.id;
			anchor.generation = status.generation;
			anchor.revision = ++sequence;
			anchors.emplace(p_uuid, anchor);
		} else if (p_operation == "enumerate") {
			status.enumeration = "pending";
		} else if (p_operation == "remove" && !anchors.count(p_uuid)) {
			Anchor anchor;
			anchor.uuid = p_uuid;
			anchor.generation = status.generation;
			anchor.revision = ++sequence;
			anchors.emplace(p_uuid, anchor);
		}
		last_error.clear();
		return request.id;
	}

	bool cancel(uint64_t p_request) {
		std::lock_guard<std::mutex> lock(mutex);
		auto found = requests.find(p_request);
		if (found == requests.end()) {
			return false;
		}
		// Keep in-flight requests reserved: cancellation does not cancel ARKit side effects.
		if (found->second.complete) {
			requests.erase(found);
		} else {
			found->second.cancelled = true;
		}
		return true;
	}

	void update(uint64_t p_generation, const Anchor &p_anchor, bool p_unavailable = false) {
		std::lock_guard<std::mutex> lock(mutex);
		if (!status.running || p_generation != status.generation) {
			return;
		}
		update_locked(p_anchor, p_unavailable);
	}

	void complete(uint64_t p_generation, uint64_t p_request, bool p_success, int p_error, const std::string &p_message) {
		std::lock_guard<std::mutex> lock(mutex);
		auto found = requests.find(p_request);
		if (!status.running || p_generation != status.generation || found == requests.end() || found->second.complete) {
			return;
		}
		Request &request = found->second;
		request.complete = true;
		request.success = p_success;
		request.error = p_success ? OK : (p_error == OK ? FAILED : p_error);
		request.message = p_message;
		auto anchor = anchors.find(request.uuid);
		if (request.operation == "create" && anchor != anchors.end()) {
			anchor->second.create_request = 0;
			anchor->second.persisted = p_success && !anchor->second.shared;
			anchor->second.add_failed = !p_success;
			if (!p_success) {
				anchor->second.tracked = false;
			}
			anchor->second.revision = ++sequence;
		} else if (request.operation == "remove" && p_success) {
			if (anchor == anchors.end() && anchors.size() < MAX_ANCHORS) {
				Anchor value;
				value.uuid = request.uuid;
				anchor = anchors.emplace(request.uuid, value).first;
			}
			if (anchor != anchors.end()) {
				anchor->second.removed = true;
				anchor->second.persisted = false;
				anchor->second.tracked = false;
				anchor->second.present = false;
				anchor->second.generation = status.generation;
				anchor->second.revision = ++sequence;
			}
		}
		if (request.cancelled) {
			requests.erase(found);
		}
	}

	void enumerated(uint64_t p_generation, uint64_t p_request, const std::vector<Anchor> &p_anchors, bool p_success, double p_snapshot_time = 0) {
		std::lock_guard<std::mutex> lock(mutex);
		auto found = requests.find(p_request);
		if (!status.running || p_generation != status.generation || found == requests.end() || found->second.complete) {
			return;
		}
		Request &request = found->second;
		if (p_anchors.size() > MAX_ANCHORS) {
			fail_locked(ERR_OUT_OF_MEMORY, "World anchor enumeration exceeded cache capacity.");
			return;
		}
		if (p_success) {
			std::map<std::string, bool> seen;
			for (Anchor anchor : p_anchors) {
				seen[anchor.uuid] = true;
				anchor.observation_time = p_snapshot_time;
				update_locked(anchor, false, request.revision);
				if (!status.running) {
					return;
				}
			}
			for (auto &entry : anchors) {
				if (!seen.count(entry.first) && !entry.second.removed &&
						(p_snapshot_time > 0 ? entry.second.observation_time <= p_snapshot_time : entry.second.revision <= request.revision)) {
					entry.second.present = false;
					entry.second.tracked = false;
					entry.second.revision = ++sequence;
					entry.second.observation_time = p_snapshot_time;
				}
			}
			snapshot_time = MAX(snapshot_time, p_snapshot_time);
		}
		request.complete = true;
		request.success = p_success;
		request.error = p_success ? OK : ERR_UNAVAILABLE;
		request.message = p_success ? "" : "ARKit returned no enumeration result; provider unavailable or enumeration failed.";
		status.enumeration = p_success ? "complete" : "failed";
		status.error = request.error;
		status.message = request.message;
		if (request.cancelled || request.internal) {
			requests.erase(found);
		}
	}

	std::vector<Anchor> get_anchors() const {
		std::lock_guard<std::mutex> lock(mutex);
		std::vector<Anchor> result;
		for (const auto &entry : anchors) {
			result.push_back(entry.second);
		}
		return result;
	}

	std::vector<Request> take_completed() {
		std::lock_guard<std::mutex> lock(mutex);
		std::vector<Request> result;
		for (auto it = requests.begin(); it != requests.end();) {
			if (it->second.complete && !it->second.legacy) {
				if (!it->second.cancelled) {
					result.push_back(it->second);
				}
				it = requests.erase(it);
			} else {
				++it;
			}
		}
		return result;
	}

	Request get_request(uint64_t p_id) const {
		std::lock_guard<std::mutex> lock(mutex);
		auto found = requests.find(p_id);
		return found == requests.end() ? Request() : found->second;
	}

	void mark_legacy(uint64_t p_id) {
		std::lock_guard<std::mutex> lock(mutex);
		auto found = requests.find(p_id);
		if (found != requests.end()) {
			found->second.legacy = true;
		}
	}

private:
	uint64_t generation_counter = 0;
};
