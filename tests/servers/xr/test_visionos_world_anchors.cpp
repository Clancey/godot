/**************************************************************************/
/*  test_visionos_world_anchors.cpp                                       */
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

#include "servers/xr/xr_interface.h"
#include "servers/xr/xr_pose.h"
#include "servers/xr/xr_server.h"
#include "tests/test_macros.h"

#include "modules/visionos_xr/visionos_world_anchor_store.h"

#include <functional>
#include <memory>
#include <thread>

TEST_FORCE_LINK(test_visionos_world_anchors)

namespace TestVisionOSWorldAnchors {

using Store = VisionOSWorldAnchorStore;

struct FakeProvider {
	std::shared_ptr<Store> store = std::make_shared<Store>();
	uint64_t generation = store->start();

	std::function<void()> completion(uint64_t p_request, bool p_success) {
		auto owned = store;
		auto current = generation;
		return [owned, current, p_request, p_success] {
			owned->complete(current, p_request, p_success, 201, p_success ? "" : "Add failed.");
		};
	}

	void update(const std::string &p_uuid, bool p_tracked, Vector3 p_origin = Vector3(1, 2, 3)) {
		Store::Anchor anchor;
		anchor.uuid = p_uuid;
		anchor.tracked = p_tracked;
		anchor.transform.origin = p_origin;
		store->update(generation, anchor);
	}
};

TEST_CASE("[visionOS][WorldAnchors] Add success and tracking are independent in either order") {
	for (bool tracked_first : { false, true }) {
		FakeProvider provider;
		uint64_t request = provider.store->begin("create", "local");
		REQUIRE(request != 0);
		CHECK_FALSE(provider.store->get_anchors()[0].tracked);
		CHECK_FALSE(provider.store->get_anchors()[0].persisted);
		if (tracked_first) {
			provider.update("local", true);
			CHECK_FALSE(provider.store->get_anchors()[0].persisted);
		}
		std::thread callback(provider.completion(request, true));
		callback.join();
		CHECK(provider.store->get_anchors()[0].persisted);
		CHECK(provider.store->get_anchors()[0].tracked == tracked_first);
		provider.update("local", true);
		CHECK(provider.store->get_anchors()[0].tracked);
		auto completions = provider.store->take_completed();
		REQUIRE(completions.size() == 1);
		CHECK(completions[0].id == request);
		CHECK(completions[0].generation == provider.generation);
		CHECK(completions[0].success);
		CHECK(completions[0].error == OK);
		CHECK(provider.store->take_completed().empty());
	}
}

TEST_CASE("[visionOS][WorldAnchors] Dormant storage rejects requests and native pose validation requires rigid meters") {
	Store store;
	CHECK_FALSE(store.get_status().running);
	CHECK(store.get_status().generation == 0);
	CHECK(store.get_anchors().empty());
	CHECK(store.begin("create", "local") == 0);
	CHECK_FALSE(store.get_last_error().empty());
	CHECK(Store::is_valid_transform(Transform3D(Basis(Vector3(0, 1, 0), 0.5), Vector3(4, 2, -3))));
	CHECK_FALSE(Store::is_valid_transform(Transform3D(Basis().scaled(Vector3(2, 2, 2)), Vector3())));
	CHECK_FALSE(Store::is_valid_transform(Transform3D(Basis().scaled(Vector3(-1, 1, 1)), Vector3())));
	CHECK_FALSE(Store::is_valid_transform(Transform3D(Basis(), Vector3(INFINITY, 0, 0))));
	CHECK_FALSE(Store::is_valid_transform(Transform3D(Basis(), Vector3(NAN, 0, 0))));
}

TEST_CASE("[visionOS][WorldAnchors] Provider transitions invalidate without an engine frame and reject retired observers") {
	FakeProvider provider;
	uint64_t observer = provider.store->watch_provider();
	uint64_t request = provider.store->begin("create", "local");
	provider.update("local", true);
	auto late_completion = provider.completion(request, true);
	uint64_t before = provider.store->get_status().provider_revision;
	std::thread callback([owned = provider.store, observer] {
		owned->provider_changed(observer);
		owned->provider_changed(observer);
	});
	callback.join();
	CHECK_FALSE(provider.store->get_status().running);
	CHECK_FALSE(provider.store->get_anchors()[0].tracked);
	CHECK(provider.store->get_status().provider_revision == before + 2);
	CHECK(provider.store->start(before) == 0);
	late_completion();
	CHECK_FALSE(provider.store->take_completed()[0].success);
	provider.generation = provider.store->start(before + 2);
	CHECK(provider.generation != 0);
	CHECK(provider.store->get_anchors().empty());
	provider.store->unwatch_provider();
	uint64_t next_observer = provider.store->watch_provider();
	provider.store->start();
	provider.store->provider_changed(observer);
	CHECK(provider.store->get_status().running);
	provider.store->provider_changed(next_observer);
	CHECK_FALSE(provider.store->get_status().running);
}

TEST_CASE("[visionOS][WorldAnchors] Production provider sampling fences a stop during a stale running query") {
	FakeProvider provider;
	uint64_t observer = provider.store->watch_provider();
	auto sampled = provider.store->sample_provider_state([&] {
		std::thread callback([owned = provider.store, observer] {
			owned->provider_changed(observer);
		});
		callback.join();
		return true;
	});
	CHECK(sampled.running);
	CHECK(sampled.revision < provider.store->get_status().provider_revision);
	CHECK(provider.store->start(sampled.revision) == 0);
	CHECK_FALSE(provider.store->get_status().running);
	auto resumed = provider.store->sample_provider_state([] { return true; });
	CHECK(provider.store->start(resumed.revision) != 0);
}

TEST_CASE("[visionOS][WorldAnchors] Native timestamps reject late updates after a current snapshot") {
	FakeProvider provider;
	Store::Anchor old;
	old.uuid = "stored";
	old.tracked = true;
	old.observation_time = 10;
	old.transform.origin = Vector3(10, 0, 0);
	provider.store->update(provider.generation, old);
	uint64_t request = provider.store->begin("enumerate");
	Store::Anchor current = old;
	current.tracked = false;
	provider.store->enumerated(provider.generation, request, { current }, true, 20);
	provider.store->update(provider.generation, old);
	CHECK_FALSE(provider.store->get_anchors()[0].tracked);
	old.uuid = "missing-from-snapshot";
	provider.store->update(provider.generation, old);
	CHECK(provider.store->get_anchors().size() == 1);
	current.observation_time = 21;
	current.tracked = true;
	provider.store->update(provider.generation, current);
	CHECK(provider.store->get_anchors()[0].tracked);
	request = provider.store->begin("enumerate");
	current.observation_time = 30;
	current.transform.origin = Vector3(30, 0, 0);
	provider.store->update(provider.generation, current);
	provider.store->enumerated(provider.generation, request, {}, true, 25);
	CHECK(provider.store->get_anchors()[0].tracked);
	CHECK(provider.store->get_anchors()[0].transform.origin == Vector3(30, 0, 0));
}

TEST_CASE("[visionOS][WorldAnchors] Internal snapshots cannot exhaust caller request slots across restarts") {
	FakeProvider provider;
	for (size_t i = 0; i < Store::MAX_REQUESTS * 2; i++) {
		provider.generation = provider.store->start();
		uint64_t request = provider.store->begin("enumerate", "", Transform3D(), false, true);
		CHECK(request != 0);
		provider.store->enumerated(provider.generation, request, {}, i % 2 == 0);
		CHECK(provider.store->take_completed().empty());
	}
	for (size_t i = 0; i < Store::MAX_REQUESTS; i++) {
		uint64_t request = provider.store->begin("enumerate");
		CHECK(request != 0);
		provider.store->enumerated(provider.generation, request, {}, true);
	}
	CHECK(provider.store->begin("enumerate", "", Transform3D(), false, true) == 0);
	CHECK(provider.store->get_status().enumeration == "failed");
	CHECK(provider.store->get_status().error != OK);
	CHECK(provider.store->take_completed().size() == Store::MAX_REQUESTS);
	CHECK(provider.store->begin("enumerate") != 0);
}

TEST_CASE("[visionOS][WorldAnchors] Failed add does not become persisted from later tracking") {
	FakeProvider provider;
	uint64_t request = provider.store->begin("create", "local");
	provider.update("local", true);
	provider.completion(request, false)();
	provider.update("local", true);
	auto anchor = provider.store->get_anchors()[0];
	CHECK_FALSE(anchor.persisted);
	CHECK_FALSE(anchor.tracked);
	auto result = provider.store->take_completed()[0];
	CHECK_FALSE(result.success);
	CHECK(result.error == 201);
	CHECK(result.message == "Add failed.");
}

TEST_CASE("[visionOS][WorldAnchors] Restored anchors update in the new origin and lose regain tracking") {
	FakeProvider provider;
	provider.update("persisted", false, Vector3(12, 1, -9));
	CHECK(provider.store->get_anchors()[0].persisted);
	CHECK_FALSE(provider.store->get_anchors()[0].tracked);
	provider.update("persisted", true, Vector3(13, 1, -8));
	auto anchor = provider.store->get_anchors()[0];
	CHECK(anchor.transform.origin == Vector3(13, 1, -8));
	uint64_t revision = anchor.revision;
	provider.store->update(provider.generation, anchor, true);
	anchor = provider.store->get_anchors()[0];
	CHECK_FALSE(anchor.tracked);
	CHECK_FALSE(anchor.removed);
	CHECK_FALSE(anchor.present);
	CHECK(anchor.persisted);
	CHECK(anchor.revision > revision);
	provider.update("persisted", true, Vector3(14, 1, -7));
	CHECK(provider.store->get_anchors()[0].tracked);
	CHECK(provider.store->get_anchors()[0].transform.origin == Vector3(14, 1, -7));
}

TEST_CASE("[visionOS][WorldAnchors] Remove failure preserves binding and confirmed removal rejects stale updates") {
	FakeProvider provider;
	provider.update("persisted", true);
	uint64_t request = provider.store->begin("remove", "persisted");
	provider.store->complete(provider.generation, request, false, 202, "Remove failed.");
	CHECK(provider.store->get_anchors()[0].persisted);
	CHECK(provider.store->get_anchors()[0].tracked);
	CHECK_FALSE(provider.store->take_completed()[0].success);
	request = provider.store->begin("remove", "persisted");
	provider.store->complete(provider.generation, request, true, OK, "");
	provider.update("persisted", true);
	CHECK(provider.store->get_anchors()[0].removed);
	CHECK_FALSE(provider.store->get_anchors()[0].tracked);
	CHECK_FALSE(provider.store->get_anchors()[0].persisted);
	CHECK(provider.store->take_completed()[0].success);
}

TEST_CASE("[visionOS][WorldAnchors] Enumeration nil is failure while empty snapshot is not deletion") {
	FakeProvider provider;
	provider.update("persisted", true);
	uint64_t request = provider.store->begin("enumerate");
	provider.store->enumerated(provider.generation, request, {}, false);
	CHECK(provider.store->get_status().enumeration == "failed");
	CHECK_FALSE(provider.store->take_completed()[0].success);
	CHECK(provider.store->get_anchors()[0].tracked);
	request = provider.store->begin("enumerate");
	provider.store->enumerated(provider.generation, request, {}, true);
	CHECK(provider.store->get_status().enumeration == "complete");
	CHECK(provider.store->take_completed()[0].success);
	CHECK_FALSE(provider.store->get_anchors()[0].present);
	CHECK_FALSE(provider.store->get_anchors()[0].tracked);
	CHECK_FALSE(provider.store->get_anchors()[0].removed);
	CHECK(provider.store->get_anchors()[0].persisted);
}

TEST_CASE("[visionOS][WorldAnchors] Snapshot cannot overwrite newer events or confirmed removal") {
	FakeProvider provider;
	provider.update("persisted", true, Vector3(1, 0, 0));
	Store::Anchor stale = provider.store->get_anchors()[0];
	uint64_t snapshot = provider.store->begin("enumerate");
	provider.update("persisted", true, Vector3(9, 0, 0));
	provider.store->enumerated(provider.generation, snapshot, { stale }, true);
	CHECK(provider.store->get_anchors()[0].transform.origin == Vector3(9, 0, 0));
	provider.store->take_completed();
	snapshot = provider.store->begin("enumerate");
	uint64_t remove = provider.store->begin("remove", "persisted");
	provider.store->complete(provider.generation, remove, true, OK, "");
	provider.store->enumerated(provider.generation, snapshot, { stale }, true);
	CHECK(provider.store->get_anchors()[0].removed);
	CHECK_FALSE(provider.store->get_anchors()[0].tracked);
}

TEST_CASE("[visionOS][WorldAnchors] Pause restart fails pending requests and ignores old generation callbacks") {
	FakeProvider provider;
	uint64_t request = provider.store->begin("create", "pending");
	auto callback = provider.completion(request, true);
	provider.update("pending", true);
	auto old = provider.store->get_anchors()[0];
	provider.store->stop();
	CHECK_FALSE(provider.store->get_status().running);
	CHECK_FALSE(provider.store->get_anchors()[0].tracked);
	CHECK(provider.store->begin("create", "invalid") == 0);
	CHECK_FALSE(provider.store->get_last_error().empty());
	uint64_t generation = provider.store->start();
	CHECK(generation > provider.generation);
	callback();
	provider.store->update(provider.generation, old);
	CHECK(provider.store->get_anchors().empty());
	auto failed = provider.store->take_completed();
	REQUIRE(failed.size() == 1);
	CHECK_FALSE(failed[0].success);
	CHECK(failed[0].error == ERR_UNAVAILABLE);
	CHECK(failed[0].generation == provider.generation);
	CHECK(provider.store->begin("create", "new") > request);
}

TEST_CASE("[visionOS][WorldAnchors] Cancellation retains side effects but suppresses notification") {
	FakeProvider provider;
	uint64_t request = provider.store->begin("create", "cancelled");
	CHECK(provider.store->cancel(request));
	provider.completion(request, true)();
	CHECK(provider.store->take_completed().empty());
	CHECK(provider.store->get_anchors()[0].persisted);
	CHECK(provider.store->get_anchors()[0].uuid == "cancelled");
	CHECK_FALSE(provider.store->cancel(request));
}

TEST_CASE("[visionOS][WorldAnchors] Callback value ownership survives owner destruction") {
	std::function<void()> callback;
	std::weak_ptr<Store> weak;
	{
		FakeProvider provider;
		weak = provider.store;
		uint64_t request = provider.store->begin("create", "pending");
		callback = provider.completion(request, true);
		provider.store->stop();
	}
	CHECK_FALSE(weak.expired());
	std::thread worker(callback);
	worker.join();
	CHECK_FALSE(weak.lock()->take_completed()[0].success);
	callback = {};
	CHECK(weak.expired());
}

TEST_CASE("[visionOS][WorldAnchors] Terminal slots cannot be evicted by pose updates") {
	FakeProvider provider;
	for (size_t i = 0; i < Store::MAX_REQUESTS; i++) {
		uint64_t request = provider.store->begin("remove", std::to_string(i));
		REQUIRE(request != 0);
		provider.store->complete(provider.generation, request, false, 202, "Retained failure.");
	}
	for (int i = 0; i < 1000; i++) {
		provider.update("moving", true, Vector3(i, 0, 0));
	}
	CHECK(provider.store->begin("enumerate") == 0);
	CHECK_FALSE(provider.store->get_last_error().empty());
	auto completed = provider.store->take_completed();
	REQUIRE(completed.size() == Store::MAX_REQUESTS);
	for (const auto &request : completed) {
		CHECK_FALSE(request.success);
		CHECK(request.error == 202);
	}
	CHECK(provider.store->get_anchors().size() == Store::MAX_REQUESTS + 1);
	CHECK(provider.store->get_anchors().back().transform.origin == Vector3(999, 0, 0));
	CHECK(provider.store->begin("enumerate") != 0);
}

TEST_CASE("[visionOS][WorldAnchors] Overflow fails closed and preserves pending terminal outcomes") {
	FakeProvider provider;
	uint64_t request = provider.store->begin("enumerate");
	for (size_t i = 0; i <= Store::MAX_ANCHORS; i++) {
		provider.update(std::to_string(i), true);
	}
	CHECK(provider.store->get_anchors().size() == Store::MAX_ANCHORS);
	CHECK_FALSE(provider.store->get_status().running);
	CHECK(provider.store->get_status().error == ERR_OUT_OF_MEMORY);
	for (const auto &anchor : provider.store->get_anchors()) {
		CHECK_FALSE(anchor.tracked);
	}
	CHECK(provider.store->take_completed()[0].id == request);
}

TEST_CASE("[visionOS][WorldAnchors] Shared anchors never become local persistence") {
	FakeProvider provider;
	uint64_t request = provider.store->begin("create", "shared", Transform3D(), true);
	provider.completion(request, true)();
	CHECK_FALSE(provider.store->get_anchors()[0].persisted);
	Store::Anchor shared;
	shared.uuid = "restored-shared";
	shared.shared = true;
	shared.tracked = true;
	provider.store->update(provider.generation, shared);
	for (const auto &anchor : provider.store->get_anchors()) {
		CHECK_FALSE(anchor.persisted);
	}
}

TEST_CASE("[visionOS][WorldAnchors] Cancelled stopped requests free capacity and legacy outcomes remain separate") {
	FakeProvider provider;
	for (size_t i = 0; i < Store::MAX_REQUESTS; i++) {
		uint64_t request = provider.store->begin("remove", std::to_string(i));
		CHECK(provider.store->cancel(request));
	}
	provider.store->stop();
	provider.generation = provider.store->start();
	uint64_t legacy = provider.store->begin("create", "legacy");
	CHECK(legacy != 0);
	provider.store->mark_legacy(legacy);
	provider.completion(legacy, true)();
	CHECK(provider.store->take_completed().empty());
	CHECK(provider.store->get_request(legacy).success);
	CHECK(provider.store->cancel(legacy));
	CHECK(provider.store->get_request(legacy).id == 0);
}

TEST_CASE("[visionOS][WorldAnchors] Snapshot order and unavailable updates do not resurrect stale tracking") {
	FakeProvider provider;
	uint64_t snapshot = provider.store->begin("enumerate");
	Store::Anchor old;
	old.uuid = "stored";
	old.tracked = true;
	old.transform.origin = Vector3(1, 0, 0);
	provider.store->update(provider.generation, old, true);
	provider.store->enumerated(provider.generation, snapshot, { old }, true);
	CHECK_FALSE(provider.store->get_anchors()[0].tracked);
	CHECK_FALSE(provider.store->get_anchors()[0].present);
	CHECK_FALSE(provider.store->get_anchors()[0].removed);
	provider.store->take_completed();
	provider.update("stored", true, Vector3(9, 0, 0));
	CHECK(provider.store->get_anchors()[0].tracked);
	CHECK(provider.store->get_anchors()[0].persisted);
}

class TestCameraInterface : public XRInterface {
public:
	Transform3D camera;
	StringName get_name() const override { return "Anchor test"; }
	uint32_t get_capabilities() const override { return XR_AR; }
	bool is_initialized() const override { return true; }
	bool initialize() override { return true; }
	void uninitialize() override {}
	Dictionary get_system_info() override { return Dictionary(); }
	Transform3D get_camera_transform() override { return camera; }
	void process() override {}
	Size2 get_render_target_size() override { return Size2(1, 1); }
	uint32_t get_view_count() override { return 1; }
	Transform3D get_transform_for_view(uint32_t, const Transform3D &) override { return camera; }
	Projection get_projection_for_view(uint32_t, double, double, double) override { return Projection(); }
	TypedArray<Projection> get_camera_projections(const StringName &, double, double, double) override { return TypedArray<Projection>(); }
	TypedArray<Transform3D> get_camera_offsets(const StringName &) override { return TypedArray<Transform3D>(); }
	Vector<RenderingServerTypes::BlitToScreen> post_draw_viewport(RID, const Rect2 &) override { return {}; }
};

TEST_CASE("[visionOS][WorldAnchors][SceneTree] Raw anchor poses match production adjusted poses at nonunit scale and recenter") {
	XRServer *server = XRServer::get_singleton();
	bool owns_server = server == nullptr;
	if (owns_server) {
		server = memnew(XRServer);
	}
	REQUIRE(server != nullptr);
	if (!server) {
		return;
	}
	real_t previous_scale = server->get_world_scale();
	Transform3D previous_reference = server->get_reference_frame();
	Ref<XRInterface> previous_interface = server->get_primary_interface();
	Ref<TestCameraInterface> camera;
	camera.instantiate();
	server->set_primary_interface(camera);
	const Transform3D raw(Basis(Vector3(0, 1, 0), 0.4), Vector3(1, 2, -3));
	const Transform3D origin(Basis(Vector3(0, 1, 0), -0.7), Vector3(12, 0, 4));
	Ref<XRPose> pose;
	pose.instantiate();
	pose->set_transform(raw);
	for (real_t scale : { (real_t)0.5, (real_t)1.0, (real_t)3.0 }) {
		server->set_world_scale(scale);
		for (real_t yaw : { (real_t)0.0, (real_t)0.8 }) {
			Transform3D reference(Basis(Vector3(0, 1, 0), yaw), Vector3(-3, 0, 2));
			camera->camera = reference.inverse();
			server->center_on_hmd(XRServer::RESET_BUT_KEEP_TILT, false);
			Transform3D adjusted = reference * Transform3D(raw.basis, raw.origin * scale);
			CHECK(pose->get_adjusted_transform().is_equal_approx(adjusted));
			Transform3D world = origin * adjusted;
			Transform3D inverse = reference.affine_inverse() * origin.affine_inverse() * world;
			inverse.origin /= scale;
			CHECK(inverse.is_equal_approx(raw));
			Transform3D anchor_from_room(Basis(Vector3(0, 1, 0), 0.2), Vector3(0.5, 0, 1));
			Transform3D room = world * anchor_from_room;
			CHECK((world.affine_inverse() * room).is_equal_approx(anchor_from_room));
		}
	}
	camera->camera = previous_reference.inverse();
	server->center_on_hmd(XRServer::RESET_BUT_KEEP_TILT, false);
	server->set_primary_interface(previous_interface);
	server->set_world_scale(previous_scale);
	if (owns_server) {
		memdelete(server);
	}
}

} // namespace TestVisionOSWorldAnchors
