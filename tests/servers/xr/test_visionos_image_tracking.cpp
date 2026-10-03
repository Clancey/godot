/**************************************************************************/
/*  test_visionos_image_tracking.cpp                                      */
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

#include "modules/visionos_xr/visionos_image_tracking_store.h"
#include "modules/visionos_xr/visionos_world_anchor_store.h"

#include <memory>
#include <thread>

TEST_FORCE_LINK(test_visionos_image_tracking)

namespace TestVisionOSImageTracking {

using Store = VisionOSImageTrackingStore;
using State = Store::ProviderState;

struct Provider {
	std::shared_ptr<Store> store = std::make_shared<Store>();
	uint64_t token;

	Provider() {
		store->configure(true, true);
		store->set_authorization("allowed");
		token = store->replace({ { "room-7", OK, "" } }, true);
		store->provider_changed(token, State::RUNNING);
	}

	bool observe(double p_time = 10, uint64_t p_received = 100) {
		Store::Observation observation;
		observation.name = "room-7";
		observation.uuid = "anchor";
		observation.tracked = true;
		observation.physical_size = Vector2(0.25, 0.25);
		observation.transform.origin.x = p_time;
		observation.observation_time = p_time;
		observation.received_ticks_usec = p_received;
		return store->update(token, store->get_status().generation, observation);
	}
};

TEST_CASE("[visionOS][ImageTracking] ARKit axes become printed right, top and face-out without moving raw meters") {
	Transform3D marker;
	Transform3D arkit;
	arkit.origin = Vector3(3, 2, -4);
	REQUIRE(Store::marker_transform(arkit, marker));
	CHECK(marker.origin.x == 3);
	CHECK(marker.origin.y == 2);
	CHECK(marker.origin.z == -4);
	CHECK(marker.basis.get_column(0).x == doctest::Approx(1));
	CHECK(marker.basis.get_column(1).z == doctest::Approx(-1));
	CHECK(marker.basis.get_column(2).y == doctest::Approx(1));
	CHECK(marker.basis.determinant() == doctest::Approx(1));
	// A wall-facing native image normal must not be flattened into a floor-facing marker.
	arkit.basis = Basis(Vector3(1, 0, 0), Math::PI / 2);
	REQUIRE(Store::marker_transform(arkit, marker));
	CHECK(marker.basis.get_column(1).y == doctest::Approx(1));
	CHECK(marker.basis.get_column(2).z == doctest::Approx(1));
	arkit.basis = Basis().scaled(Vector3(-1, 1, 1));
	CHECK_FALSE(Store::marker_transform(arkit, marker));
	arkit.basis = Basis().scaled(Vector3(0, 1, 1));
	CHECK_FALSE(Store::marker_transform(arkit, marker));
	arkit = Transform3D();
	arkit.origin.x = NAN;
	CHECK_FALSE(Store::marker_transform(arkit, marker));
}

TEST_CASE("[visionOS][ImageTracking] Staging, registration, authorization and actual running are distinct") {
	Store store;
	store.configure(true, true);
	CHECK_FALSE(store.get_status().running);
	uint64_t token = store.replace({ { "room-7", OK, "" } }, false);
	const uint64_t reference = store.get_status().reference_revision;
	CHECK(store.get_status().registration_state == "staged");
	store.provider_changed(token, State::RUNNING);
	store.set_authorization("allowed");
	CHECK_FALSE(store.get_status().running);
	token = store.activate();
	CHECK(store.get_status().reference_revision == reference);
	CHECK(store.get_status().registration_state == "registered");
	CHECK_FALSE(store.get_status().running);
	store.provider_changed(token, State::RUNNING);
	CHECK(store.get_status().running);
	store.set_authorization("denied");
	CHECK_FALSE(store.get_status().running);
	store.set_authorization("not_determined");
	CHECK_FALSE(store.get_status().running);
	store.set_authorization("allowed", FAILED, "Authorization query failed");
	CHECK_FALSE(store.get_status().running);
	CHECK(store.get_status().authorization_error == FAILED);
	store.set_authorization("allowed");
	CHECK(store.get_status().running);
	store.configure(false, true);
	CHECK_FALSE(store.get_status().running);
	store.configure(true, false);
	CHECK_FALSE(store.get_status().running);
}

TEST_CASE("[visionOS][ImageTracking] Replacement fences old providers and reports staged supersession") {
	Provider provider;
	REQUIRE(provider.observe());
	const auto old = provider.store->get_status();
	const auto observation = provider.store->get_observations()[0];
	provider.token = provider.store->replace({ { "room-8", OK, "" } }, false);
	CHECK(provider.store->get_status().reference_revision > old.reference_revision);
	CHECK(provider.store->get_status().generation != old.generation);
	CHECK(provider.store->get_observations().empty());
	CHECK_FALSE(provider.store->get_observation("anchor", old.generation).tracked);
	provider.store->provider_changed(old.provider_token, State::RUNNING);
	CHECK_FALSE(provider.store->get_status().running);
	CHECK_FALSE(provider.store->update(old.provider_token, old.generation, observation));
	const uint64_t staged = provider.store->get_status().reference_revision;
	provider.store->replace({ { "room-9", OK, "" } }, false);
	CHECK(provider.store->get_status().superseded_reference_revision == staged);
	provider.store->replace({}, false);
	CHECK(provider.store->get_status().registration_state == "cleared");
	CHECK(provider.store->get_status().references.empty());
	CHECK_FALSE(provider.store->get_status().running);
}

TEST_CASE("[visionOS][ImageTracking] Failed staged registration never becomes a successful empty set") {
	Store store;
	store.configure(true, true);
	store.replace({ { "bad-image", OK, "" } }, false);
	const uint64_t revision = store.get_status().reference_revision;
	store.registration_failed({ { "bad-image", ERR_CANT_CREATE, "Conversion failed" } }, ERR_CANT_CREATE, "Batch failed");
	const auto status = store.get_status();
	CHECK(status.registration_state == "failed");
	CHECK(status.reference_revision == revision);
	CHECK(status.provider_state == State::FAILED);
	CHECK(status.error == ERR_CANT_CREATE);
	REQUIRE(status.references.size() == 1);
	CHECK(status.references[0].error == ERR_CANT_CREATE);
	CHECK_FALSE(status.running);
	store.stop();
	const uint64_t retry = store.activate();
	store.set_authorization("allowed");
	store.provider_changed(retry, State::RUNNING);
	CHECK(store.get_status().running);
	CHECK(store.get_status().references[0].error == OK);
	CHECK(store.get_status().references[0].message.empty());
}

TEST_CASE("[visionOS][ImageTracking] Native timestamps and sequence reject repeat polls and late updates") {
	Provider provider;
	REQUIRE(provider.observe());
	const auto first = provider.store->get_observations()[0];
	CHECK(first.tracked);
	CHECK(first.reference_revision == provider.store->get_status().reference_revision);
	CHECK(first.observation_time == 10);
	CHECK(first.received_ticks_usec == 100);
	CHECK_FALSE(provider.observe(10, 200));
	CHECK_FALSE(provider.observe(9, 300));
	CHECK_FALSE(provider.observe(NAN, 400));
	CHECK_FALSE(provider.observe(INFINITY, 400));
	CHECK(provider.store->get_observations()[0].sequence == first.sequence);
	REQUIRE(provider.observe(11, 500));
	const auto next = provider.store->get_observations()[0];
	CHECK(next.sequence > first.sequence);
	CHECK(next.received_ticks_usec == 500);
	CHECK(next.transform.origin.x == 11);
}

TEST_CASE("[visionOS][ImageTracking] Pause invalidates immediately and fences already copied engine observations") {
	Provider provider;
	REQUIRE(provider.observe());
	const auto queued = provider.store->get_observations()[0];
	provider.store->provider_changed(provider.token, State::PAUSED);
	CHECK_FALSE(provider.store->get_observation("anchor", queued.generation).tracked);
	CHECK_FALSE(provider.store->update(provider.token, queued.generation, queued));
	provider.store->provider_changed(provider.token, State::RUNNING);
	CHECK(provider.store->get_status().running);
	CHECK_FALSE(provider.store->get_observation("anchor", queued.generation).tracked);
	CHECK_FALSE(provider.observe(10));
	REQUIRE(provider.observe(11));
	const auto current = provider.store->get_observations()[0];
	CHECK(current.generation != queued.generation);
	CHECK(current.reference_revision == queued.reference_revision);
	CHECK_FALSE(provider.store->get_observation("anchor", queued.generation).tracked);
	CHECK(provider.store->get_observation("anchor", current.generation).tracked);
}

TEST_CASE("[visionOS][ImageTracking] State query cannot race a failure into false readiness") {
	Provider provider;
	const auto queried = provider.store->get_status();
	std::thread callback([&] {
		provider.store->provider_changed(provider.token, State::STOPPED, FAILED, "Provider failed");
	});
	callback.join();
	provider.store->provider_changed(provider.token, State::RUNNING, OK, "", queried.state_revision);
	CHECK_FALSE(provider.store->get_status().running);
	CHECK(provider.store->get_status().message == "Provider failed");
	const auto failed = provider.store->get_status();
	provider.store->provider_changed(provider.token, State::STOPPED, OK, "", failed.state_revision);
	CHECK(provider.store->get_status().provider_state == State::FAILED);
	CHECK(provider.store->get_status().error == FAILED);
	provider.store->provider_changed(provider.token, State::RUNNING);
	CHECK(provider.store->get_status().running);
}

TEST_CASE("[visionOS][ImageTracking] Loss and removal with equal timestamps invalidate but cannot resurrect") {
	Provider provider;
	REQUIRE(provider.observe());
	auto observation = provider.store->get_observations()[0];
	observation.tracked = false;
	REQUIRE(provider.store->update(provider.token, observation.generation, observation));
	CHECK_FALSE(provider.store->get_observations()[0].tracked);
	CHECK_FALSE(provider.observe());
	observation.removed = true;
	observation.name.clear();
	REQUIRE(provider.store->update(provider.token, observation.generation, observation));
	CHECK(provider.store->get_observations()[0].removed);
	CHECK(provider.store->get_observations()[0].name == "room-7");
	CHECK_FALSE(provider.observe(11));
}

TEST_CASE("[visionOS][ImageTracking] Unknown names and invalid geometry never produce tracked placement") {
	Provider provider;
	REQUIRE(provider.observe());
	auto observation = provider.store->get_observations()[0];
	observation.observation_time++;
	observation.name = "not-registered";
	CHECK_FALSE(provider.store->update(provider.token, observation.generation, observation));
	observation.name = "room-7";
	observation.transform.origin.x = NAN;
	REQUIRE(provider.store->update(provider.token, observation.generation, observation));
	CHECK_FALSE(provider.store->get_observations()[0].tracked);
	observation.observation_time++;
	observation.transform = Transform3D();
	observation.estimated_scale_factor = NAN;
	REQUIRE(provider.store->update(provider.token, observation.generation, observation));
	CHECK_FALSE(provider.store->get_observations()[0].tracked);
}

TEST_CASE("[visionOS][ImageTracking] Stop keeps staged identity but never reuses an observation epoch") {
	Provider provider;
	REQUIRE(provider.observe());
	const auto old = provider.store->get_status();
	provider.store->stop();
	CHECK_FALSE(provider.store->get_status().running);
	CHECK(provider.store->get_status().registration_state == "staged");
	CHECK(provider.store->get_status().reference_revision == old.reference_revision);
	CHECK(provider.store->get_status().authorization == "not_determined");
	provider.store->provider_changed(old.provider_token, State::RUNNING);
	CHECK_FALSE(provider.store->get_status().running);
	Provider another;
	CHECK(another.store->get_status().generation != old.generation);
}

TEST_CASE("[visionOS][ImageTracking] Callback snapshots own coherent native timestamps and transforms") {
	Provider provider;
	std::atomic<bool> done{ false };
	std::thread callback([&] {
		for (int i = 1; i <= 1000; i++) {
			provider.observe(i, i * 10);
		}
		done = true;
	});
	do {
		const auto observations = provider.store->get_observations();
		if (!observations.empty()) {
			const auto &sample = observations[0];
			CHECK(sample.transform.origin.x == sample.observation_time);
			CHECK(sample.received_ticks_usec == sample.observation_time * 10);
		}
	} while (!done);
	callback.join();
	CHECK(provider.store->get_observations()[0].sequence == 1000);
}

TEST_CASE("[visionOS][ImageTracking] Image replacement does not stop the shared world anchor store") {
	VisionOSWorldAnchorStore world;
	const uint64_t observer = world.watch_provider();
	world.start();
	Provider images;
	images.store->replace({ { "room-8", OK, "" } }, true);
	CHECK(world.get_status().running);
	// The session observer dispatches a genuine world-provider event separately.
	world.provider_changed(observer);
	CHECK_FALSE(world.get_status().running);
	CHECK(images.store->get_status().provider_state == State::INITIALIZED);
}

} // namespace TestVisionOSImageTracking
