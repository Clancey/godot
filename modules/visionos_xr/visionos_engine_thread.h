/**************************************************************************/
/*  visionos_engine_thread.h                                              */
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

#include "core/os/thread.h"

#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>

// A serial dispatch queue can change native threads between jobs. Godot's main
// thread identity and scene access permissions must instead keep one owner.
class VisionOSEngineThread {
	std::mutex mutex;
	std::condition_variable condition;
	std::deque<std::function<void()>> tasks;
	std::function<uint32_t()> iteration;
	bool accepting = true;
	bool stopping = false;
	Thread thread;

	static void entry(void *p_self) {
		static_cast<VisionOSEngineThread *>(p_self)->run();
	}

	void run() {
		Thread::set_name("GodotImmersive");
		while (!stopping) {
			std::deque<std::function<void()>> pending;
			{
				std::unique_lock<std::mutex> lock(mutex);
				condition.wait(lock, [&] { return !tasks.empty() || iteration; });
				pending.swap(tasks);
			}
			for (const auto &task : pending) {
				task();
			}
			if (!stopping && iteration) {
				auto current_iteration = iteration;
				uint32_t delay_ms = current_iteration();
				if (delay_ms) {
					std::unique_lock<std::mutex> lock(mutex);
					condition.wait_for(lock, std::chrono::milliseconds(delay_ms), [&] { return !tasks.empty(); });
				}
			}
		}
	}

public:
	void start() {
		Thread::Settings settings;
		settings.priority = Thread::PRIORITY_HIGH;
		thread.start(entry, this, settings);
	}

	bool post(std::function<void()> p_task) {
		{
			std::lock_guard<std::mutex> lock(mutex);
			if (!accepting) {
				return false;
			}
			tasks.push_back(std::move(p_task));
		}
		condition.notify_one();
		return true;
	}

	// Only the owner changes the active layer, between complete iterations.
	void set_iteration(std::function<uint32_t()> p_iteration) {
		iteration = std::move(p_iteration);
	}

	void finish(std::function<void()> p_cleanup) {
		{
			std::lock_guard<std::mutex> lock(mutex);
			if (!accepting) {
				return;
			}
			accepting = false;
			tasks.push_back([this, p_cleanup = std::move(p_cleanup)] {
				iteration = {};
				p_cleanup();
				stopping = true;
			});
		}
		condition.notify_one();
	}

	void wait_to_finish() {
		thread.wait_to_finish();
	}
};
