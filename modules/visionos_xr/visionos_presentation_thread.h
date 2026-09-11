/**************************************************************************/
/*  visionos_presentation_thread.h                                        */
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

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>

class VisionOSViewportTransparency {
	uint64_t overridden_viewport = 0;

public:
	bool update(uint64_t p_viewport, bool p_alpha_blend, bool p_transparent) {
		if (overridden_viewport != p_viewport) {
			overridden_viewport = 0;
		}
		if (p_alpha_blend) {
			if (!p_transparent) {
				overridden_viewport = p_viewport;
			}
			return true;
		}
		if (overridden_viewport != 0) {
			overridden_viewport = 0;
			return false;
		}
		return p_transparent;
	}
};

class VisionOSStartupStatus {
public:
	enum State { LOADING,
		PREPARING_PIPELINES,
		TRACKING_UNAVAILABLE,
		FRAME_UNAVAILABLE,
		READY,
		FAILED,
		CLOSED };

private:
	mutable std::mutex mutex;
	uint64_t generation = 1;
	bool preparing = false;
	bool ready = false;
	bool gpu_failed = false;
	bool failed = false;
	bool closed = false;
	State frame_state = LOADING;

public:
	void set_preparing(bool p_preparing) {
		std::lock_guard<std::mutex> lock(mutex);
		preparing = p_preparing;
	}
	void set_frame_state(State p_state) {
		std::lock_guard<std::mutex> lock(mutex);
		if (p_state != LOADING && p_state != frame_state) {
			generation++;
			ready = false;
		}
		frame_state = p_state;
	}
	uint64_t get_generation() const {
		std::lock_guard<std::mutex> lock(mutex);
		return generation;
	}
	void complete(uint64_t p_generation, bool p_scene, bool p_success) {
		std::lock_guard<std::mutex> lock(mutex);
		if (p_generation != generation || closed) {
			return;
		}
		ready |= p_scene && p_success;
		if (p_scene && p_success) {
			gpu_failed = false;
		}
		if (!p_success) {
			generation++;
			ready = false;
			gpu_failed = true;
			frame_state = FRAME_UNAVAILABLE;
		}
	}
	void invalidate(bool p_close = false) {
		std::lock_guard<std::mutex> lock(mutex);
		generation++;
		ready = false;
		gpu_failed = false;
		closed |= p_close;
		frame_state = LOADING;
	}
	void fail() {
		std::lock_guard<std::mutex> lock(mutex);
		failed = true;
	}
	State get_state() const {
		std::lock_guard<std::mutex> lock(mutex);
		if (failed) {
			return FAILED;
		}
		if (closed) {
			return CLOSED;
		}
		if (gpu_failed) {
			return FRAME_UNAVAILABLE;
		}
		if (ready) {
			return READY;
		}
		if (frame_state != LOADING) {
			return frame_state;
		}
		return preparing ? PREPARING_PIPELINES : LOADING;
	}
};

class VisionOSPresentationThread {
public:
	struct Completions {
		std::atomic<uint32_t> in_flight{ 0 };
		std::atomic<uint64_t> completed{ 0 };
		VisionOSStartupStatus startup;
	};

private:
	std::atomic<bool> stopping{ false };
	std::shared_ptr<Completions> completions = std::make_shared<Completions>();
	std::thread thread;

public:
	void start(std::function<void()> p_run) {
		thread = std::thread(std::move(p_run));
	}

	void request_stop() { stopping.store(true); }
	bool is_stopping() const { return stopping.load(); }
	std::shared_ptr<Completions> get_completions() const { return completions; }

	// Called by the external owner before its members are destroyed. Neither
	// the loop nor GPU callbacks may retain/release that owner; callbacks hold
	// only Completions and the immutable scene-output lease.
	void join() {
		if (thread.joinable()) {
			thread.join();
		}
	}

	~VisionOSPresentationThread() {
		request_stop();
		join();
	}
};
