/**************************************************************************/
/*  test_visionos_presentation_thread.cpp                                 */
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

#include "tests/test_macros.h"

#include "modules/visionos_xr/visionos_presentation_thread.h"

#include <chrono>
#include <future>

TEST_FORCE_LINK(test_visionos_presentation_thread)

namespace TestVisionOSPresentationThread {

using namespace std::chrono_literals;

struct Owner {
	VisionOSPresentationThread thread;
	std::promise<void> &destructor_entered;
	std::atomic<bool> &joined;

	Owner(std::promise<void> &p_destructor_entered, std::atomic<bool> &p_joined) :
			destructor_entered(p_destructor_entered), joined(p_joined) {}

	~Owner() {
		destructor_entered.set_value();
		thread.request_stop();
		thread.join();
		joined = true;
	}
};

TEST_CASE("[visionOS] Presenter teardown joins while late GPU callbacks retain only output and completion state") {
	std::promise<void> entered;
	std::promise<void> release;
	auto gate = release.get_future().share();
	std::promise<void> destructor_entered;
	std::promise<std::function<void()>> encoded;
	std::atomic<bool> joined{ false };
	std::atomic<bool> stopped_before_encode{ false };
	auto owner = std::make_shared<Owner>(destructor_entered, joined);
	std::weak_ptr<Owner> weak_owner = owner;
	auto completions = owner->thread.get_completions();
	auto output = std::make_shared<int>(42);
	std::weak_ptr<int> weak_output = output;
	Owner *raw_owner = owner.get();
	owner->thread.start([raw_owner, &entered, gate, &encoded, output, &stopped_before_encode] {
		entered.set_value();
		gate.wait();
		stopped_before_encode = raw_owner->thread.is_stopping();
		auto counters = raw_owner->thread.get_completions();
		counters->in_flight.fetch_add(1);
		encoded.set_value([counters, output] {
			(void)output;
			counters->completed.fetch_add(1);
			counters->in_flight.fetch_sub(1);
		});
	});
	output.reset();
	CHECK(entered.get_future().wait_for(5s) == std::future_status::ready);
	std::thread destroyer([owner = std::move(owner)]() mutable { owner.reset(); });
	CHECK(destructor_entered.get_future().wait_for(5s) == std::future_status::ready);
	CHECK(weak_owner.expired());
	CHECK_FALSE(joined.load());
	release.set_value();
	destroyer.join();
	CHECK(joined.load());
	CHECK(stopped_before_encode.load());
	auto completed = encoded.get_future().get();
	CHECK_FALSE(weak_output.expired());
	CHECK(completions->in_flight == 1);
	completed();
	completed = {};
	CHECK(weak_output.expired());
	CHECK(completions->completed == 1);
	CHECK(completions->in_flight == 0);
}

TEST_CASE("[visionOS] GPU completion before presenter loop exit cannot destroy or self-join its owner") {
	std::promise<void> destructor_entered;
	std::atomic<bool> joined{ false };
	auto owner = std::make_shared<Owner>(destructor_entered, joined);
	auto completions = owner->thread.get_completions();
	std::promise<void> completed;
	std::promise<void> release;
	auto gate = release.get_future().share();
	owner->thread.start([completions, &completed, gate] {
		completions->in_flight.fetch_add(1);
		std::thread gpu([completions] {
			completions->completed.fetch_add(1);
			completions->in_flight.fetch_sub(1);
		});
		gpu.join();
		completed.set_value();
		gate.wait();
	});
	CHECK(completed.get_future().wait_for(5s) == std::future_status::ready);
	CHECK(completions->completed == 1);
	std::thread destroyer([owner = std::move(owner)]() mutable { owner.reset(); });
	CHECK(destructor_entered.get_future().wait_for(5s) == std::future_status::ready);
	CHECK_FALSE(joined.load());
	release.set_value();
	destroyer.join();
	CHECK(joined.load());
	CHECK(completions->in_flight == 0);
}

} // namespace TestVisionOSPresentationThread
