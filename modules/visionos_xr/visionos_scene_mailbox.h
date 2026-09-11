/**************************************************************************/
/*  visionos_scene_mailbox.h                                               */
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

#include <array>
#include <cstdint>
#include <memory>
#include <mutex>
#include <utility>

// T owns scene resources and source-view metadata, never compositor frame or
// drawable handles. Its default constructor runs once per fixed pool slot.
template <typename T>
class VisionOSSceneMailbox {
public:
	struct Lease {
		std::shared_ptr<T> output;
		uint64_t generation = 0;
		uint64_t sequence = 0;
	};

private:
	// Construction and destruction of outputs never run under the mailbox lock.
	std::array<std::shared_ptr<T>, 3> pool = {
		std::make_shared<T>(),
		std::make_shared<T>(),
		std::make_shared<T>(),
	};
	mutable std::mutex mutex;
	std::shared_ptr<const T> latest_output;
	uint64_t epoch = 1;
	uint64_t next_sequence = 1;
	uint64_t published_sequence = 0;
	bool closed = false;

public:
	Lease acquire() {
		std::lock_guard<std::mutex> lock(mutex);
		if (!closed) {
			for (const std::shared_ptr<T> &output : pool) {
				if (output.use_count() == 1) {
					return { output, epoch, next_sequence++ };
				}
			}
		}
		return {};
	}

	// Call only from the producer GPU completion callback, retaining the lease
	// until then. All consumers of the mutable output must have stopped writing.
	void complete(Lease p_lease, bool p_gpu_success) {
		std::lock_guard<std::mutex> lock(mutex);
		if (closed || !p_gpu_success || !p_lease.output || p_lease.generation != epoch || p_lease.sequence <= published_sequence) {
			return;
		}
		for (const std::shared_ptr<T> &output : pool) {
			if (output == p_lease.output) {
				latest_output = std::move(p_lease.output);
				published_sequence = p_lease.sequence;
				return;
			}
		}
	}

	// Presenters retain this immutable snapshot until their own GPU completion.
	std::shared_ptr<const T> latest() const {
		std::lock_guard<std::mutex> lock(mutex);
		return latest_output;
	}

	void invalidate() {
		std::lock_guard<std::mutex> lock(mutex);
		latest_output.reset();
		++epoch;
		published_sequence = 0;
	}

	void close() {
		std::lock_guard<std::mutex> lock(mutex);
		closed = true;
		latest_output.reset();
	}

	uint64_t generation() const {
		std::lock_guard<std::mutex> lock(mutex);
		return epoch;
	}
};
