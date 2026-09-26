/**************************************************************************/
/*  test_visionos_engine_thread.cpp                                       */
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

#include "core/os/thread_safe.h"
#include "tests/test_macros.h"
#include "tests/test_tools.h"

#include "modules/visionos_xr/visionos_engine_thread.h"

#ifdef RD_ENABLED
#include "servers/rendering/renderer_rd/pipeline_hash_map_rd.h"
#endif

#include <atomic>
#include <chrono>
#include <future>
// doctest only forward-declares std::ostream; stringifying std::thread::id needs the full definition.
#include <ostream>
#include <thread>

TEST_FORCE_LINK(test_visionos_engine_thread)

namespace TestVisionOSEngineThread {

using namespace std::chrono_literals;

#ifdef RD_ENABLED
struct StalledCompiler {
	std::promise<void> entered;
	std::promise<void> release;
	void compile(uint32_t p_key) {
		entered.set_value();
		release.get_future().wait();
	}
};

TEST_CASE("[visionOS] A pipeline wait cannot occupy the UI caller or reorder lifecycle callbacks") {
	ErrorDetector errors;
	StalledCompiler compiler;
	PipelineHashMapRD<uint32_t, StalledCompiler, decltype(&StalledCompiler::compile)> pipelines;
	pipelines.set_creation_object_and_function(&compiler, &StalledCompiler::compile);
	pipelines.compile_pipeline(1, 1, RSE::PIPELINE_SOURCE_DRAW, true);
	CHECK(compiler.entered.get_future().wait_for(5s) == std::future_status::ready);

	VisionOSEngineThread owner;
	owner.start();
	std::promise<void> waiting;
	std::promise<void> completed;
	std::atomic<int> sequence{ 0 };
	std::atomic<bool> correct_order{ true };
	std::thread::id engine_id;
	std::thread::id ui_id = std::this_thread::get_id();
	CHECK(owner.post([&] {
		engine_id = std::this_thread::get_id();
		sequence = 1;
		waiting.set_value();
		pipelines.wait_for_pipeline(1);
		correct_order = correct_order && sequence == 1;
		sequence = 2;
	}));
	CHECK(waiting.get_future().wait_for(5s) == std::future_status::ready);

	// This is the UIKit producer: it never joins a frame or a compiler worker.
	CHECK(owner.post([&] {
		correct_order = correct_order && sequence == 2 && std::this_thread::get_id() == engine_id;
		sequence = 3;
	}));
	CHECK(owner.post([&] {
		correct_order = correct_order && sequence == 3 && std::this_thread::get_id() == engine_id;
		sequence = 4;
		completed.set_value();
	}));
	CHECK(sequence == 1);
	CHECK(engine_id != ui_id);
	compiler.release.set_value();
	CHECK(completed.get_future().wait_for(5s) == std::future_status::ready);
	CHECK(sequence == 4);
	CHECK(correct_order);
	owner.finish([] {});
	owner.wait_to_finish();
	pipelines.clear_pipelines();
	CHECK_FALSE(errors.has_error);
}
#endif // RD_ENABLED

TEST_CASE("[visionOS] One native owner survives paused and replaced layers and rejects work after teardown") {
	VisionOSEngineThread owner;
	std::promise<void> paused;
	std::promise<void> replacement;
	std::promise<void> finished;
	std::atomic<int> frames{ 0 };
	std::atomic<bool> same_owner{ true };
	std::thread::id native_owner;
	owner.start();
	CHECK(owner.post([&] {
		native_owner = std::this_thread::get_id();
		owner.set_iteration([&] {
			same_owner = same_owner && std::this_thread::get_id() == native_owner;
			if (++frames == 1) {
				paused.set_value();
			}
			return 10000u;
		});
	}));
	CHECK(paused.get_future().wait_for(5s) == std::future_status::ready);
	// A ten-second paused-frame wait must be interrupted by queued lifecycle work.
	CHECK(owner.post([&] {
		same_owner = same_owner && std::this_thread::get_id() == native_owner;
		owner.set_iteration([&] {
			same_owner = same_owner && std::this_thread::get_id() == native_owner;
			frames++;
			owner.set_iteration({});
			replacement.set_value();
			return 0u;
		});
	}));
	CHECK(replacement.get_future().wait_for(5s) == std::future_status::ready);
	owner.finish([&] {
		same_owner = same_owner && std::this_thread::get_id() == native_owner;
		finished.set_value();
	});
	CHECK_FALSE(owner.post([] {}));
	CHECK(finished.get_future().wait_for(5s) == std::future_status::ready);
	owner.wait_to_finish();
	CHECK(frames == 2);
	CHECK(same_owner);
}

TEST_CASE("[visionOS] Main identity and node permission transfer without giving UIKit scene access") {
	VisionOSEngineThread owner;
	std::atomic<bool> owner_is_main{ false };
	std::atomic<bool> owner_safe_for_nodes{ false };
	std::atomic<bool> cleanup_is_main{ false };
	set_current_thread_safe_for_nodes(false);
	Thread::release_main_thread();
	bool ui_is_main = Thread::is_main_thread();
	bool ui_safe_for_nodes = is_current_thread_safe_for_nodes();
	owner.start();
	owner.post([&] {
		Thread::make_main_thread();
		set_current_thread_safe_for_nodes(true);
		owner_is_main = Thread::is_main_thread();
		owner_safe_for_nodes = is_current_thread_safe_for_nodes();
	});
	owner.finish([&] {
		cleanup_is_main = Thread::is_main_thread();
		set_current_thread_safe_for_nodes(false);
		Thread::release_main_thread();
	});
	owner.wait_to_finish();
	Thread::make_main_thread();
	set_current_thread_safe_for_nodes(true);
	CHECK_FALSE(ui_is_main);
	CHECK_FALSE(ui_safe_for_nodes);
	CHECK(owner_is_main);
	CHECK(owner_safe_for_nodes);
	CHECK(cleanup_is_main);
	CHECK(Thread::is_main_thread());
}

} // namespace TestVisionOSEngineThread
