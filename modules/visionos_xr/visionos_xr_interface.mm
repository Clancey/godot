/**************************************************************************/
/*  visionos_xr_interface.mm                                              */
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

#ifdef VISIONOS_ENABLED

#include "visionos_xr_interface.h"

#include "visionos_presentation.h"
#include "visionos_render_diagnostics.h"
#include "visionos_simd_helpers.h"
#include "visionos_spatial_anchor_capability.h"
#include "visionos_tracking.h"

#include "core/config/project_settings.h"
#include "core/error/error_macros.h"
#include "core/input/input.h"
#include "core/math/transform_3d.h"
#include "core/math/vector3.h"
#include "core/object/callable_mp.h"
#include "core/object/class_db.h"
#include "core/os/os.h"
#include "core/os/thread.h"
#include "core/string/print_string.h"
#include "drivers/metal/metal3_objects.h"
#include "scene/main/scene_tree.h"
#include "scene/main/window.h"
#include "servers/rendering/renderer_rd/storage_rd/texture_storage.h"
#include "servers/rendering/rendering_device.h"
#include "servers/rendering/rendering_server.h" // ERR_NOT_ON_RENDER_THREAD_V
#include "servers/rendering/rendering_server_globals.h"
#include "servers/rendering/rendering_server_types.h"
#include "servers/xr/xr_controller_tracker.h"
#include "servers/xr/xr_server.h"

#include "platform/visionos/godot_app_delegate_service_visionos.h"
#include "platform/visionos/godot_compositor_services_renderer.h"

const String VisionOSXRInterface::name = "visionOS";

StringName VisionOSXRInterface::get_signal_name(SignalEnum p_signal) {
	switch (p_signal) {
		case VISIONOS_XR_SIGNAL_SESSION_STARTED:
			return SNAME("session_started");
			break;
		case VISIONOS_XR_SIGNAL_SESSION_PAUSED:
			return SNAME("session_paused");
			break;
		case VISIONOS_XR_SIGNAL_SESSION_RESUMED:
			return SNAME("session_resumed");
			break;
		case VISIONOS_XR_SIGNAL_SESSION_INVALIDATED:
			return SNAME("session_invalidated");
			break;
		case VISIONOS_XR_SIGNAL_POSE_RECENTERED:
			return SNAME("pose_recentered");
			break;
		default:
			return "";
			break;
	}
}

void VisionOSXRInterface::emit_signal_enum(SignalEnum p_signal) {
	emit_signal(get_signal_name(p_signal));
}

VisionOSSpatialAnchorCapability *VisionOSXRInterface::get_spatial_anchor_capability() const {
	return VisionOSSpatialAnchorCapability::get_singleton();
}

Ref<VisionOSAnchorTracker> VisionOSXRInterface::create_spatial_anchor(const Transform3D &p_transform, bool p_shared) {
	return scene_understanding.create_anchor(p_transform, p_shared);
}

void VisionOSXRInterface::remove_spatial_anchor(Ref<VisionOSAnchorTracker> p_anchor) {
	scene_understanding.remove_anchor(p_anchor);
}

bool VisionOSXRInterface::is_anchor_sharing_available() const {
	return scene_understanding.is_anchor_sharing_available();
}

bool VisionOSXRInterface::is_image_tracking_supported() const {
	return scene_understanding.is_image_tracking_supported();
}

bool VisionOSXRInterface::add_marker_reference_image(const String &p_name, const Ref<Image> &p_image, float p_physical_width) {
	return scene_understanding.add_marker_reference_image(p_name, p_image, p_physical_width);
}

void VisionOSXRInterface::clear_marker_reference_images() {
	scene_understanding.clear_marker_reference_images();
}

int VisionOSXRInterface::get_marker_reference_image_count() const {
	return scene_understanding.get_marker_reference_image_count();
}

void VisionOSXRInterface::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_spatial_anchor_capability"), &VisionOSXRInterface::get_spatial_anchor_capability);
	// Signals
	for (int i = 0; i < VISIONOS_XR_SIGNAL_MAX; i++) {
		ADD_SIGNAL(MethodInfo(get_signal_name((SignalEnum)i)));
	}

	ClassDB::bind_method(D_METHOD("get_current_render_quality"), &VisionOSXRInterface::get_current_render_quality);
	ClassDB::bind_method(D_METHOD("set_current_render_quality", "render_quality"), &VisionOSXRInterface::set_current_render_quality);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "current_render_quality"), "set_current_render_quality", "get_current_render_quality");

	// Scene understanding
	ClassDB::bind_method(D_METHOD("create_spatial_anchor", "transform", "shared"), &VisionOSXRInterface::create_spatial_anchor, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("remove_spatial_anchor", "anchor"), &VisionOSXRInterface::remove_spatial_anchor);
	ClassDB::bind_method(D_METHOD("is_anchor_sharing_available"), &VisionOSXRInterface::is_anchor_sharing_available);
	ClassDB::bind_method(D_METHOD("is_image_tracking_supported"), &VisionOSXRInterface::is_image_tracking_supported);
	ClassDB::bind_method(D_METHOD("add_marker_reference_image", "name", "image", "physical_width"), &VisionOSXRInterface::add_marker_reference_image);
	ClassDB::bind_method(D_METHOD("clear_marker_reference_images"), &VisionOSXRInterface::clear_marker_reference_images);
	ClassDB::bind_method(D_METHOD("get_marker_reference_image_count"), &VisionOSXRInterface::get_marker_reference_image_count);

	BIND_ENUM_CONSTANT(IMMERSION_STYLE_FULL);
	BIND_ENUM_CONSTANT(IMMERSION_STYLE_MIXED);
	BIND_ENUM_CONSTANT(IMMERSION_STYLE_PROGRESSIVE);
	ClassDB::bind_method(D_METHOD("get_immersion_style"), &VisionOSXRInterface::get_immersion_style);
	ClassDB::bind_method(D_METHOD("set_immersion_style", "immersion_style"), &VisionOSXRInterface::set_immersion_style);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "immersion_style", PROPERTY_HINT_ENUM, "Full,Mixed,Progressive"), "set_immersion_style", "get_immersion_style");

	BIND_ENUM_CONSTANT(VISIBILITY_AUTOMATIC);
	BIND_ENUM_CONSTANT(VISIBILITY_VISIBLE);
	BIND_ENUM_CONSTANT(VISIBILITY_HIDDEN);
	ClassDB::bind_method(D_METHOD("get_upper_limb_visibility"), &VisionOSXRInterface::get_upper_limb_visibility);
	ClassDB::bind_method(D_METHOD("set_upper_limb_visibility", "upper_limb_visibility"), &VisionOSXRInterface::set_upper_limb_visibility);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "upper_limb_visibility", PROPERTY_HINT_ENUM, "Automatic,Visible,Hidden"), "set_upper_limb_visibility", "get_upper_limb_visibility");

	ClassDB::bind_method(D_METHOD("get_persistent_system_overlays"), &VisionOSXRInterface::get_persistent_system_overlays);
	ClassDB::bind_method(D_METHOD("set_persistent_system_overlays", "persistent_system_overlays"), &VisionOSXRInterface::set_persistent_system_overlays);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "persistent_system_overlays", PROPERTY_HINT_ENUM, "Automatic,Visible,Hidden"), "set_persistent_system_overlays", "get_persistent_system_overlays");
}

VisionOSXRInterface::VisionOSXRInterface() {}

VisionOSXRInterface::~VisionOSXRInterface() {
	if (is_initialized()) {
		uninitialize();
	}
}

StringName VisionOSXRInterface::get_name() const {
	return VisionOSXRInterface::name;
}

uint32_t VisionOSXRInterface::get_capabilities() const {
	return XRInterface::XR_VR + XRInterface::XR_AR + XRInterface::XR_STEREO;
}

XRInterface::TrackingStatus VisionOSXRInterface::get_tracking_status() const {
	return tracking_state;
}

bool VisionOSXRInterface::is_initialized() const {
	return initialized;
}

bool VisionOSXRInterface::initialize() {
	ERR_FAIL_COND_V_MSG(initialized, true, "VisionOSXRInterface already initialized.");

	XRServer *xr_server = XRServer::get_singleton();
	ERR_FAIL_NULL_V(xr_server, false);

	// Checking features
	GDTRenderMode app_delegate_render_mode = GDTAppDelegateServiceVisionOS.renderMode;
	cs.enabled = (app_delegate_render_mode == GDTRenderModeCompositorServices);
	hands.enabled = GLOBAL_GET("xr/visionos/enable_hand_tracking");
	controllers.enabled = GLOBAL_GET("xr/visionos/enable_controller_tracking");
	scene_understanding.configure_from_project_settings();

	// ARKit session
	ar_session = ar_session_create();
	if (cs.enabled) {
		auto presentation = visionos_get_presentation();
		ERR_FAIL_NULL_V(presentation, false);
		ar_session = presentation->get_session();
	}

	// CompositorServices
	if (cs.enabled) {
		if (!cs.initialize(xr_server)) {
			ar_session = nullptr;
			return false;
		}

		// RenderThread
		rendering_server = RenderingServer::get_singleton();
		ERR_FAIL_NULL_V(rendering_server, false);
		rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::initialize));

		minimum_supported_near_plane = cp_layer_renderer_capabilities_supported_minimum_near_plane_distance(cs.layer_renderer_capabilities);
		rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::set_minimum_supported_near_plane).bind(minimum_supported_near_plane));

		rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::prepare_screen));

		// Make this our primary interface, since it's used for rendering
		xr_server->set_primary_interface(this);
	}

	// Hand tracking
	if (hands.enabled) {
		hands.initialize(xr_server, controllers.enabled);
	}

	// Controllers
	if (controllers.enabled) {
		controllers.initialize(xr_server, this);
	}

	// Scene understanding
	scene_understanding.initialize(ar_session, cs.world_tracking_provider);

	spatial_events.initialize(xr_server);

	// Running the ARKit session for head tracking, at first
	run_ar_session();

	// Check the authorizations asynchronously
	if (hands.enabled || controllers.enabled || scene_understanding.enabled()) {
		update_authorizations_async();
	}

	initialized = true;

	// Apply the passthrough transparency implied by the initial immersion style.
	update_transparent_background(get_environment_blend_mode() == XR_ENV_BLEND_MODE_ALPHA_BLEND);

	print_verbose(String("VisionOSXRInterface initialized with:") + " compositorservices=" + (cs.enabled ? "yes" : "no") + " hands=" + (hands.enabled ? "yes" : "no") + " controllers=" + (controllers.enabled ? "yes" : "no") + " scene_understanding=" + (scene_understanding.enabled() ? "yes" : "no"));

	return initialized;
}

bool VisionOSXRInterface::CompositorServicesData::initialize(XRServer *p_xr_server) {
	String driver_name = OS::get_singleton()->get_current_rendering_driver_name().to_lower();
	ERR_FAIL_COND_V_MSG(driver_name != "metal", false, "The visionOS XR interface requires the Metal rendering driver.");

	layer_renderer = GDTAppDelegateServiceVisionOS.layerRenderer;
	layer_renderer_capabilities = GDTAppDelegateServiceVisionOS.layerRendererCapabilities;

	ERR_FAIL_NULL_V_MSG(layer_renderer, false, "GDTAppDelegateServiceVisionOS.layerRenderer not set.");
	ERR_FAIL_NULL_V_MSG(layer_renderer_capabilities, false, "GDTAppDelegateServiceVisionOS.layerRendererCapabilities not set.");

	auto presentation = visionos_get_presentation();
	ERR_FAIL_NULL_V(presentation, false);
	world_tracking_provider = presentation->get_world_tracking();

	// Head tracker initialization
	head_tracker.instantiate();
	head_tracker->set_tracker_type(XRServer::TRACKER_HEAD);
	head_tracker->set_tracker_name("head");
	head_tracker->set_tracker_desc("Device head pose");
	p_xr_server->add_tracker(head_tracker);

	return true;
}

void VisionOSXRInterface::uninitialize() {
	if (!initialized) {
		return;
	}

	if (cs.enabled && rendering_server) {
		rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::uninitialize));
	}

	XRServer *xr_server = XRServer::get_singleton();
	if (xr_server != nullptr) {
		scene_understanding.uninitialize();

		if (controllers.enabled) {
			controllers.uninitialize(xr_server);
		}

		if (hands.enabled) {
			if (hands.left_hand_tracker.is_valid()) {
				xr_server->remove_tracker(hands.left_hand_tracker);
				hands.left_hand_tracker.unref();
			}
			if (hands.right_hand_tracker.is_valid()) {
				xr_server->remove_tracker(hands.right_hand_tracker);
				hands.right_hand_tracker.unref();
			}
			hands.uninitialize(xr_server);
		}

		if (cs.enabled) {
			if (cs.head_tracker.is_valid()) {
				xr_server->remove_tracker(cs.head_tracker);
				cs.head_tracker.unref();
			}

			if (xr_server->get_primary_interface() == this) {
				// no longer our primary interface
				xr_server->set_primary_interface(nullptr);
			}
		}

		spatial_events.uninitialize(xr_server);

		initialized = false;
	}

	// equivalent to "ar_release(ar_session)" since automatic reference counting is enabled
	ar_session = nullptr;
}

void VisionOSXRInterface::RenderThread::initialize() {
	ERR_NOT_ON_RENDER_THREAD;
	rendering_device = RenderingDevice::get_singleton();
	RenderingDeviceDriverMetal *rendering_device_driver_metal = (RenderingDeviceDriverMetal *)rendering_device->get_device_driver();
	pixel_formats = &rendering_device_driver_metal->get_pixel_formats();

	initialized = true;
	update_presentation();
}

void VisionOSXRInterface::RenderThread::update_presentation() {
	ERR_NOT_ON_RENDER_THREAD;
	end_frame();
	presentation = visionos_get_presentation();
}

void VisionOSXRInterface::RenderThread::prepare_screen() {
	ERR_NOT_ON_RENDER_THREAD;

	// Trigger the swap-chain resize so the format is initialized; must happen outside any submission.
	rendering_device->screen_prepare_for_drawing(DisplayServerEnums::MAIN_WINDOW_ID);
}

void VisionOSXRInterface::RenderThread::uninitialize() {
	ERR_NOT_ON_RENDER_THREAD;
	end_frame();
	if (current_color_texture_id != RID()) {
		rendering_device->free_rid(current_color_texture_id);
		current_color_texture_id = RID();
	}
	if (current_depth_texture_id != RID()) {
		rendering_device->free_rid(current_depth_texture_id);
		current_depth_texture_id = RID();
	}
	if (current_rasterization_rate_map_id != RID()) {
		rendering_device->free_rid(current_rasterization_rate_map_id);
		current_rasterization_rate_map_id = RID();
	}
	presentation.reset();
	cached_render_target_width.set(0);
	cached_render_target_height.set(0);
	initialized = false;
}

void VisionOSXRInterface::update_layer_renderer(cp_layer_renderer_t p_layer_renderer, cp_layer_renderer_capabilities_t p_layer_renderer_capabilities) {
	ERR_FAIL_COND((p_layer_renderer == nullptr) != (p_layer_renderer_capabilities == nullptr));
	cs.layer_renderer = p_layer_renderer;
	cs.layer_renderer_capabilities = p_layer_renderer_capabilities;
	cs.presentation_time = 0;
	cs.trackable_time = 0;
	if (!initialized || !cs.enabled || !rendering_server) {
		return;
	}

	rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::end_frame));
	if (!p_layer_renderer) {
		return;
	}
	rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::update_presentation));
	minimum_supported_near_plane = cp_layer_renderer_capabilities_supported_minimum_near_plane_distance(cs.layer_renderer_capabilities);
	rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::set_minimum_supported_near_plane).bind(minimum_supported_near_plane));
}

Dictionary VisionOSXRInterface::get_system_info() {
	Dictionary dict;

	dict[SNAME("XRRuntimeName")] = String("Godot visionOS XR interface");
	dict[SNAME("XRRuntimeVersion")] = String("1.0");

	return dict;
}

VisionOSXRInterface::VRSTextureFormat VisionOSXRInterface::get_vrs_texture_format() {
	return XR_VRS_TEXTURE_FORMAT_RASTERIZATION_RATE_MAP;
}

bool VisionOSXRInterface::supports_play_area_mode(XRInterface::PlayAreaMode p_mode) {
	return p_mode == XR_PLAY_AREA_ROOMSCALE;
}

XRInterface::PlayAreaMode VisionOSXRInterface::get_play_area_mode() const {
	return XR_PLAY_AREA_ROOMSCALE;
}

bool VisionOSXRInterface::set_play_area_mode(XRInterface::PlayAreaMode p_mode) {
	return p_mode == XR_PLAY_AREA_ROOMSCALE;
}

Array VisionOSXRInterface::get_supported_environment_blend_modes() {
	Array modes;
	modes.push_back(XR_ENV_BLEND_MODE_OPAQUE);
	modes.push_back(XR_ENV_BLEND_MODE_ALPHA_BLEND);
	return modes;
}

XRInterface::EnvironmentBlendMode VisionOSXRInterface::get_environment_blend_mode() const {
	// The blend mode is a portable view of the immersion style, so reading it live
	// keeps it correct when the style is changed at runtime.
	return get_current_immersion_style() == IMMERSION_STYLE_FULL ? XR_ENV_BLEND_MODE_OPAQUE : XR_ENV_BLEND_MODE_ALPHA_BLEND;
}

bool VisionOSXRInterface::set_environment_blend_mode(XRInterface::EnvironmentBlendMode p_mode) {
	switch (p_mode) {
		case XR_ENV_BLEND_MODE_OPAQUE:
			set_immersion_style(IMMERSION_STYLE_FULL);
			return true;
		case XR_ENV_BLEND_MODE_ALPHA_BLEND:
			// Progressive immersion already shows passthrough, so leave it alone
			// rather than collapsing it to mixed.
			if (get_current_immersion_style() != IMMERSION_STYLE_PROGRESSIVE) {
				set_immersion_style(IMMERSION_STYLE_MIXED);
			}
			update_transparent_background(true);
			return true;
		default:
			return false;
	}
}

void VisionOSXRInterface::update_transparent_background(bool p_alpha_blend) {
	// CompositorServices composites passthrough where alpha is 0. Without a
	// transparent viewport the cleared background stays opaque and shows up as
	// blocky artifacts around anything rendered in front of passthrough.
	SceneTree *scene_tree = SceneTree::get_singleton();
	Window *root = scene_tree != nullptr ? scene_tree->get_root() : nullptr;
	if (root != nullptr) {
		bool current = root->has_transparent_background();
		// Restore only transparency enabled by this interface, not a project's
		// explicit transparent viewport setting or a replacement root.
		bool transparent = viewport_transparency.update(root->get_instance_id(), p_alpha_blend, current);
		if (transparent != current) {
			root->set_transparent_background(transparent);
			print_verbose(vformat("VisionOSXRInterface: transparent background for passthrough compositing: %s.", transparent ? "enabled" : "restored"));
		}
	}
}

float VisionOSXRInterface::get_current_render_quality() {
	return cp_layer_renderer_get_render_quality(cs.layer_renderer);
}

void VisionOSXRInterface::set_current_render_quality(float p_render_quality) {
	ERR_FAIL_COND_MSG(!GDTAppDelegateServiceVisionOS.isDynamicRenderQualityEnabled, "Attempting to set current render quality but Dynamic Render Quality has not been enabled in Project Settings.");
	float maxRenderQuality = GDTAppDelegateServiceVisionOS.maxRenderQuality;
	ERR_FAIL_COND_MSG(p_render_quality > GDTAppDelegateServiceVisionOS.maxRenderQuality, vformat("Attempting to set a current render quality higher than the Max Render Quality configured in Project Settings (%f).", maxRenderQuality));
	cp_layer_renderer_set_render_quality(cs.layer_renderer, p_render_quality);
}

VisionOSXRInterface::ImmersionStyle VisionOSXRInterface::get_immersion_style() {
	return get_current_immersion_style();
}

VisionOSXRInterface::ImmersionStyle VisionOSXRInterface::get_current_immersion_style() const {
	switch (GDTAppDelegateServiceVisionOS.immersionStyle) {
		case GDTImmersionStyleFull:
			return IMMERSION_STYLE_FULL;
		case GDTImmersionStyleMixed:
			return IMMERSION_STYLE_MIXED;
		case GDTImmersionStyleProgressive:
			return IMMERSION_STYLE_PROGRESSIVE;
		default:
			return IMMERSION_STYLE_FULL;
	}
}

void VisionOSXRInterface::set_immersion_style(ImmersionStyle p_immersion_style) {
	switch (p_immersion_style) {
		case IMMERSION_STYLE_FULL:
			GDTAppDelegateServiceVisionOS.immersionStyle = GDTImmersionStyleFull;
			break;
		case IMMERSION_STYLE_MIXED:
			GDTAppDelegateServiceVisionOS.immersionStyle = GDTImmersionStyleMixed;
			break;
		case IMMERSION_STYLE_PROGRESSIVE:
			GDTAppDelegateServiceVisionOS.immersionStyle = GDTImmersionStyleProgressive;
			break;
	}

	update_transparent_background(get_environment_blend_mode() == XR_ENV_BLEND_MODE_ALPHA_BLEND);
}

VisionOSXRInterface::Visibility VisionOSXRInterface::get_upper_limb_visibility() {
	switch (GDTAppDelegateServiceVisionOS.upperLimbVisibility) {
		case GDTVisibilityAutomatic:
			return VISIBILITY_AUTOMATIC;
		case GDTVisibilityVisible:
			return VISIBILITY_VISIBLE;
		case GDTVisibilityHidden:
			return VISIBILITY_HIDDEN;
		default:
			return VISIBILITY_AUTOMATIC;
	}
}

void VisionOSXRInterface::set_upper_limb_visibility(Visibility p_upper_limb_visibility) {
	switch (p_upper_limb_visibility) {
		case VISIBILITY_AUTOMATIC:
			GDTAppDelegateServiceVisionOS.upperLimbVisibility = GDTVisibilityAutomatic;
			break;
		case VISIBILITY_VISIBLE:
			GDTAppDelegateServiceVisionOS.upperLimbVisibility = GDTVisibilityVisible;
			break;
		case VISIBILITY_HIDDEN:
			GDTAppDelegateServiceVisionOS.upperLimbVisibility = GDTVisibilityHidden;
			break;
	}
}

VisionOSXRInterface::Visibility VisionOSXRInterface::get_persistent_system_overlays() {
	switch (GDTAppDelegateServiceVisionOS.persistentSystemOverlays) {
		case GDTVisibilityAutomatic:
			return VISIBILITY_AUTOMATIC;
		case GDTVisibilityVisible:
			return VISIBILITY_VISIBLE;
		case GDTVisibilityHidden:
			return VISIBILITY_HIDDEN;
		default:
			return VISIBILITY_AUTOMATIC;
	}
}

void VisionOSXRInterface::set_persistent_system_overlays(Visibility p_persistent_system_overlays) {
	switch (p_persistent_system_overlays) {
		case VISIBILITY_AUTOMATIC:
			GDTAppDelegateServiceVisionOS.persistentSystemOverlays = GDTVisibilityAutomatic;
			break;
		case VISIBILITY_VISIBLE:
			GDTAppDelegateServiceVisionOS.persistentSystemOverlays = GDTVisibilityVisible;
			break;
		case VISIBILITY_HIDDEN:
			GDTAppDelegateServiceVisionOS.persistentSystemOverlays = GDTVisibilityHidden;
			break;
	}
}

namespace {
VisionOSAuthorizationStatus convert(ar_authorization_status_t p_status) {
	switch (p_status) {
		case ar_authorization_status_not_determined:
			return VisionOSAuthorizationStatus::NOT_DETERMINED;
		case ar_authorization_status_allowed:
			return VisionOSAuthorizationStatus::ALLOWED;
		case ar_authorization_status_denied:
			return VisionOSAuthorizationStatus::DENIED;
	}
	// Unknown/future cases
	return VisionOSAuthorizationStatus::NOT_DETERMINED;
}
} // namespace

void VisionOSXRInterface::update_authorizations_async() {
	uintptr_t types = ar_authorization_type_none;

	if (hands.enabled) {
		types |= ar_authorization_type_hand_tracking;
	}

	if (controllers.enabled) {
		types |= ar_authorization_type_accessory_tracking;
	}

	if (scene_understanding.requires_world_sensing()) {
		types |= ar_authorization_type_world_sensing;
	}

	if (types == ar_authorization_type_none) {
		// Nothing to request
		return;
	}

	Ref<VisionOSXRInterface> ref_this = this;
	ar_session_t request_session = ar_session;
	ar_session_request_authorization(ar_session, static_cast<ar_authorization_type_t>(types), ^(ar_authorization_results_t authorization_results, ar_error_t _Nullable error) {
		visionos_dispatch_to_engine(^(void) {
			ERR_FAIL_COND_MSG(error != nullptr, "Could not query ARKit authorizations.");

			if (ref_this->is_initialized() && ref_this->ar_session == request_session) {
				ref_this->update_from_authorizations(authorization_results);
			}
		});
	});
}

void VisionOSXRInterface::update_from_authorizations(ar_authorization_results_t p_authorization_results) {
	VisionOSAuthorizationStatus previous_hands = hands.authorization;
	VisionOSAuthorizationStatus previous_controllers = controllers.authorization;
	VisionOSAuthorizationStatus previous_scene_understanding = scene_understanding.authorization;

	ar_authorization_results_enumerate_results(p_authorization_results, ^bool(ar_authorization_result_t authorization_result) {
		ar_authorization_type_t type = ar_authorization_result_get_authorization_type(authorization_result);
		ar_authorization_status_t status = ar_authorization_result_get_status(authorization_result);

		switch (type) {
			case ar_authorization_type_hand_tracking:
				hands.authorization = convert(status);
				if (status == ar_authorization_status_denied) {
					ERR_PRINT("Hand tracking not authorized. Enable it in `Settings > Privacy` and restart the app.");
				}
				break;
			case ar_authorization_type_accessory_tracking:
				controllers.authorization = convert(status);
				if (status == ar_authorization_status_denied) {
					ERR_PRINT("Controller tracking not authorized. Enable it in `Settings > Privacy` and restart the app.");
				}
				break;
			case ar_authorization_type_world_sensing:
				scene_understanding.authorization = convert(status);
				if (status == ar_authorization_status_denied) {
					ERR_PRINT("World sensing not authorized. Enable it in `Settings > Privacy` and restart the app.");
				}
				break;
			default:
				break;
		}

		return true; // continue with the enumeration
	});

	// If something changed, re-run the ARKit session with updated authorizations
	if (previous_hands != hands.authorization || previous_controllers != controllers.authorization || previous_scene_understanding != scene_understanding.authorization) {
		run_ar_session();
	}
}

void VisionOSXRInterface::run_ar_session() {
	scene_understanding.consume_providers_changed();
	ar_data_providers_t ar_data_providers = ar_data_providers_create();

	if (cs.enabled) {
		ar_data_providers_add_data_provider(ar_data_providers, cs.world_tracking_provider);
	}

	if (hands.active()) {
		ar_data_providers_add_data_provider(ar_data_providers, hands.hand_tracking_provider);
	}

	if (controllers.active()) {
		ar_data_providers_add_data_provider(ar_data_providers, controllers.accessory_tracking_provider);
	}

	if (scene_understanding.active()) {
		scene_understanding.add_providers_to(ar_data_providers);
	}

	// Running the ARSession with the given providers, after it has been configured
	if (cs.enabled) {
		visionos_run_tracking_session(ar_data_providers);
	} else {
		ar_session_run(ar_session, ar_data_providers);
	}
}

void VisionOSXRInterface::on_spatial_event(const VisionOSSpatialEvent &p_event) {
	spatial_events.on_spatial_event(p_event);
}

CFTimeInterval VisionOSXRInterface::get_trackable_anchor_time() {
	// Computing the time to use for pose prediction
	CFTimeInterval trackable_anchor_time = 0;

	if (cs.enabled) {
		// If CompositorServices is enabled, use its presentation time for pose prediction
		trackable_anchor_time = cs.trackable_time != 0 ? cs.trackable_time : CACurrentMediaTime();
	} else if (!cs.enabled) {
		// If not using CompositorServices, we obtain the estimatedPresentationTime from the active UIScene
		UIWindowScene *window_scene = nil;
		for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
			if ([scene isKindOfClass:[UIWindowScene class]]) {
				UIWindowScene *window_scene_candidate = (UIWindowScene *)scene;
				if (window_scene_candidate.activationState == UISceneActivationStateForegroundActive) {
					window_scene = window_scene_candidate;
					break;
				}
			}
		}
		if (window_scene != nil) {
			UIUpdateInfo *ui_update_info = [UIUpdateInfo currentUpdateInfoForWindowScene:window_scene];
			trackable_anchor_time = ui_update_info.estimatedPresentationTime;
		}
	}

	return trackable_anchor_time;
}

void VisionOSXRInterface::process() {
	if (!initialized) {
		return;
	}
	if (scene_understanding.enabled()) {
		// Registering marker images replaces the image provider; ARKit only picks it up on a re-run.
		if (scene_understanding.consume_providers_changed() && scene_understanding.active()) {
			run_ar_session();
		}
		scene_understanding.process();
	}
	if (!initialized) {
		return;
	}

	if (cs.enabled) {
		auto presentation = visionos_get_presentation();
		if (presentation) {
			update_transparent_background(presentation->is_alpha_blend_requested());
		}
		auto geometry = presentation ? presentation->get_geometry() : nullptr;
		// Set head pose before engine update, so scripts can access fresh head tracker data
		tracking_state = visionos_apply_head_pose(geometry, cs.head_tracker, cs.presentation_time, cs.trackable_time) ? XRInterface::XR_NORMAL_TRACKING : XRInterface::XR_NOT_TRACKING;
		engine_geometry = geometry;
		uint64_t serial = ++engine_geometry_serial;
		rt.queue_frame_geometry(serial, geometry);
		RenderingServer::get_singleton()->call_on_render_thread(callable_mp(&rt, &RenderThread::select_frame_geometry).bind(serial));

		if (!geometry) {
			visionos_reset_input_tracking(hands, controllers);
			return;
		}
	}

	if (hands.active() || controllers.active()) {
		CFTimeInterval trackable_anchor_time = get_trackable_anchor_time();

		if (hands.active()) {
			hands.update_hand_trackers_from_arkit(trackable_anchor_time);

			// Mirror hand gestures onto the controller-style trackers so
			// XRController3D based gameplay works hands-free. A hand with a
			// physical accessory attached is left to the accessory.
			if (controllers.enabled) {
				if (controllers.left_gc_controller == nullptr) {
					hands.publish_gestures(VisionOSHandTracking::HAND_LEFT, controllers.left_controller_tracker);
				}
				if (controllers.right_gc_controller == nullptr) {
					hands.publish_gestures(VisionOSHandTracking::HAND_RIGHT, controllers.right_controller_tracker);
				}
			} else {
				hands.publish_gestures(VisionOSHandTracking::HAND_LEFT, hands.left_hand_controller_tracker);
				hands.publish_gestures(VisionOSHandTracking::HAND_RIGHT, hands.right_hand_controller_tracker);
			}
		}

		if (controllers.active()) {
			controllers.update_controller_trackers_from_arkit(trackable_anchor_time);
		}
	}
}

Size2 VisionOSXRInterface::get_render_target_size() {
	return rt.get_render_target_size();
}

TypedArray<Projection> VisionOSXRInterface::get_camera_projections(const StringName &p_tracker_name, double p_aspect, double p_z_near, double p_z_far) {
	TypedArray<Projection> ret;

	if (!initialized || p_tracker_name != XR_TRACKER_HEAD) {
		return ret;
	}

	XRServer *xr_server = XRServer::get_singleton();
	ERR_FAIL_NULL_V(xr_server, ret);

	float world_scale = xr_server->get_world_scale();
	double scaled_z_near = p_z_near / world_scale;
	double scaled_z_far = p_z_far / world_scale;

	if (scaled_z_near < minimum_supported_near_plane) {
		// Returning no projections would make XRServer fall back to the deprecated per-view path,
		// which has no frame to read from, so clamp instead and let the frame render.
		WARN_PRINT_ONCE("Your XRCamera3D Near value is lower than the minimum value supported by the visionOS platform, so it is clamped. Make sure that Near divided by XROrigin's World Scale is higher than or equal to the value returned by LayerRender.Capabilities.supportedMinimumNearPlaneDistance. This value is 0.1 for Apple Vision Pro.");
		scaled_z_near = minimum_supported_near_plane;
		scaled_z_far = MAX(scaled_z_far, scaled_z_near + CMP_EPSILON);
	}

	simd_float2 depth_range = simd_make_float2(scaled_z_far, scaled_z_near);
	auto presentation = visionos_get_presentation();
	if (presentation) {
		presentation->request_depth_range(depth_range);
	}
	rendering_server = RenderingServer::get_singleton();
	ERR_FAIL_NULL_V(rendering_server, ret);
	rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::set_near_and_far).bind(scaled_z_near, scaled_z_far));

	return build_camera_projections(world_scale);
}

TypedArray<Projection> VisionOSXRInterface::build_camera_projections(float p_world_scale) const {
	TypedArray<Projection> ret;

	// Godot renderers work in the normalized [-1, 1] depth space, and they do a final z remap of the projection matrixes to the [0, 1] depth space in RenderSceneDataRD::update_ubo().
	// Compositor Services projection matrices are already in the [0, 1] depth space, so we need to apply the inverse z remap before passing them to the renderer.
	Projection normalized_depth_correction;
	normalized_depth_correction.set_depth_correction(false, false, true);
	normalized_depth_correction = normalized_depth_correction.inverse();

	// Correct depth by world_scale
	Projection reverse_z;
	real_t *m = &reverse_z.columns[0][0];
	m[10] = -1.0;
	m[14] = 1.0;

	Projection world_scale_correction;
	world_scale_correction.make_scale(Vector3(1, 1, p_world_scale));
	world_scale_correction = reverse_z.inverse() * world_scale_correction * reverse_z;

	for (uint32_t v = 0; v < VISIONOS_RENDER_VIEW_COUNT; v++) {
		Projection view_projection;
		if (engine_geometry) {
			view_projection = MTL::simd_to_projection(engine_geometry->projection[v]);
		} else {
			// A valid projection before the first compositor frame prevents error spam at startup.
			view_projection = Projection::create_for_hmd(v + 1, 1.0, 6.0, 15.0, 4.0, 1.0, 0.1, 1000.0);
		}
		ret.push_back(normalized_depth_correction * world_scale_correction * view_projection);
	}

	return ret;
}

TypedArray<Transform3D> VisionOSXRInterface::get_camera_offsets(const StringName &p_tracker_name) {
	TypedArray<Transform3D> ret;

	if (!initialized || p_tracker_name != XR_TRACKER_HEAD) {
		return ret;
	}

	XRServer *xr_server = XRServer::get_singleton();
	ERR_FAIL_NULL_V(xr_server, ret);
	float world_scale = xr_server->get_world_scale();

	for (uint32_t v = 0; v < VISIONOS_RENDER_VIEW_COUNT; v++) {
		Transform3D offset = engine_geometry ? MTL::simd_to_transform3D(engine_geometry->head_from_eye[v]) : Transform3D(Basis(), Vector3(v == 0 ? -0.03 : 0.03, 0.0, 0.0));
		offset.origin *= world_scale;
		ret.push_back(offset);
	}

	return ret;
}

void VisionOSXRInterface::RenderThread::set_minimum_supported_near_plane(float p_minimum_supported_near_plane) {
	ERR_NOT_ON_RENDER_THREAD;
	minimum_supported_near_plane = p_minimum_supported_near_plane;
}

void VisionOSXRInterface::RenderThread::set_near_and_far(double p_scaled_z_near, double p_scaled_z_far) {
	ERR_NOT_ON_RENDER_THREAD;

	requested_depth_far = p_scaled_z_far;
	requested_depth_near = p_scaled_z_near;
}

void VisionOSXRInterface::RenderThread::queue_frame_geometry(uint64_t p_serial, const std::shared_ptr<const VisionOSSceneGeometry> &p_geometry) {
	MutexLock lock(mutex);
	// Bound the queue if the render thread stalls; stale predictions are useless.
	if (pending_geometries.size() >= 8) {
		pending_geometries.erase(pending_geometries.begin());
	}
	pending_geometries.push_back({ p_serial, p_geometry });
}

void VisionOSXRInterface::RenderThread::select_frame_geometry(uint64_t p_serial) {
	ERR_NOT_ON_RENDER_THREAD;

	MutexLock lock(mutex);
	frame_geometry.reset();
	while (!pending_geometries.empty() && pending_geometries.front().serial <= p_serial) {
		if (pending_geometries.front().serial == p_serial) {
			frame_geometry = pending_geometries.front().geometry;
		}
		pending_geometries.erase(pending_geometries.begin());
	}
}

uint32_t VisionOSXRInterface::RenderThread::get_view_count() {
	// No need for ERR_NOT_ON_RENDER_THREAD
	return VISIONOS_RENDER_VIEW_COUNT;
}

Transform3D VisionOSXRInterface::RenderThread::get_camera_transform() {
	Transform3D camera_transform;
	ERR_NOT_ON_RENDER_THREAD_V(camera_transform);

	if (!initialized) {
		return camera_transform;
	}

	XRServer *xr_server = XRServer::get_singleton();
	ERR_FAIL_NULL_V(xr_server, camera_transform);
	// scale our origin point of our transform
	float world_scale = xr_server->get_world_scale();
	camera_transform = origin_from_head;
	camera_transform.origin *= world_scale;
	return camera_transform;
}

#ifndef DISABLE_DEPRECATED
Transform3D VisionOSXRInterface::RenderThread::get_transform_for_view(uint32_t p_view, const Transform3D &p_cam_transform) {
	Transform3D origin_from_eye;
	ERR_NOT_ON_RENDER_THREAD_V(origin_from_eye);

	XRServer *xr_server = XRServer::get_singleton();
	ERR_FAIL_NULL_V(xr_server, origin_from_eye);
	if (initialized) {
		ERR_FAIL_COND_V(p_view >= get_view_count(), origin_from_eye);
		ERR_FAIL_NULL_V(scene_output, origin_from_eye);
		simd_float4x4 head_from_eye_simd = scene_output->geometry->head_from_eye[p_view];
		Transform3D head_from_eye = MTL::simd_to_transform3D(head_from_eye_simd);

		origin_from_eye = origin_from_head * head_from_eye;

		// Scale origin point by XROrigin3D's World Scale attribute
		float world_scale = xr_server->get_world_scale();
		origin_from_eye.origin *= world_scale;
	} else {
		ERR_PRINT("vision_vr_interface not initialized, returning received camera transform.");
		origin_from_eye = Transform3D();
	}
	Transform3D reference_frame = xr_server->get_reference_frame();
	return p_cam_transform * reference_frame * origin_from_eye;
}

Projection VisionOSXRInterface::RenderThread::get_projection_for_view(uint32_t p_view, double p_aspect, double p_z_near, double p_z_far) {
	Projection eye_projection;
	ERR_NOT_ON_RENDER_THREAD_V(eye_projection);

	if (!initialized) {
		return eye_projection;
	}

	ERR_FAIL_COND_V(p_view >= get_view_count(), eye_projection);
	ERR_FAIL_NULL_V(scene_output, eye_projection);

	XRServer *xr_server = XRServer::get_singleton();
	float world_scale = xr_server->get_world_scale();

	double scaled_z_far = p_z_far / world_scale;
	double scaled_z_near = p_z_near / world_scale;

	ERR_FAIL_COND_V_MSG(scaled_z_near < minimum_supported_near_plane, eye_projection, "Your XRCamera3D Near value is lower than the minimum value supported by the visionOS platform. Make sure that Near divided by XROrigin's World Scale is higher than or equal to the value returned by LayerRender.Capabilities.supportedMinimumNearPlaneDistance. This value is 0.1 for Apple Vision Pro.");

	simd_float2 depth_range = simd_make_float2(scaled_z_far, scaled_z_near);
	presentation->request_depth_range(depth_range);
	// A camera range change is negotiated outside the real-frame lifetime.
	// Never publish the exploratory render with the previous range.
	if (!simd_all(depth_range == scene_output->geometry->depth_range)) {
		scene_output->projection_valid = false;
	}
	simd_float4x4 eye_simd_projection = scene_output->geometry->projection[p_view];
	eye_projection = MTL::simd_to_projection(eye_simd_projection);

	// Godot renderers work in the normalized [-1, 1] depth space, and they do a final z remap of the projection matrixes to the [0, 1] depth space in RenderSceneDataRD::update_ubo().
	// Compositor Services projection matrices are already in the [0, 1] depth space, so we need to apply the inverse z remap before passing them to the renderer.
	Projection normalized_depth_correction;
	normalized_depth_correction.set_depth_correction(false, false, true);

	// Correct depth by world_scale
	Projection reverse_z;
	real_t *m = &reverse_z.columns[0][0];
	m[10] = -1.0;
	m[14] = 1.0;

	Projection world_scale_correction;
	world_scale_correction.make_scale(Vector3(1, 1, world_scale));

	eye_projection = normalized_depth_correction.inverse() * reverse_z.inverse() * world_scale_correction * reverse_z * eye_projection;
	if (VisionOSRenderDiagnostics::enabled() && VisionOSRenderProbe::sample(diagnostic_frame + 1) && diagnostic_projection_logged[p_view] != diagnostic_frame + 1) {
		diagnostic_projection_logged[p_view] = diagnostic_frame + 1;
		Projection gpu_correction;
		gpu_correction.set_depth_correction(false);
		Projection gpu_projection = gpu_correction * eye_projection;
		auto ndc_depth = [&](double p_distance) {
			Vector4 clip = gpu_projection.xform(Vector4(0, 0, -p_distance, 1));
			return clip.w != 0 ? clip.z / clip.w : 0;
		};
		NSMutableArray *columns = [NSMutableArray array];
		for (int column = 0; column < 4; column++) {
			[columns addObject:@[ VisionOSRenderDiagnostics::number(eye_projection[column][0]), VisionOSRenderDiagnostics::number(eye_projection[column][1]), VisionOSRenderDiagnostics::number(eye_projection[column][2]), VisionOSRenderDiagnostics::number(eye_projection[column][3]) ]];
		}
		MTLViewport viewport = scene_output->geometry->viewport[p_view];
		VisionOSRenderDiagnostics::write([NSString stringWithFormat:@"projection-%04llu-eye%u", (unsigned long long)(diagnostic_frame + 1), p_view], @{@"camera_near_far" : @[ @(p_z_near), @(p_z_far) ],
			@"physical_near_minimum" : @[ @(scaled_z_near), @(minimum_supported_near_plane) ],
			@"normalized_projection_columns" : columns,
			@"extracted_near_far" : @[ VisionOSRenderDiagnostics::number(eye_projection.get_z_near()), VisionOSRenderDiagnostics::number(eye_projection.get_z_far()) ],
			@"gpu_ndc_at_near_far" : @[ VisionOSRenderDiagnostics::number(ndc_depth(p_z_near)), VisionOSRenderDiagnostics::number(ndc_depth(p_z_far)) ],
			@"logical_viewport" : @[ @(viewport.originX), @(viewport.originY), @(viewport.width), @(viewport.height) ],
			@"texture_index_slice" : @[ @0, @(p_view) ],
		});
	}
	return eye_projection;
}
#endif

// The render region is the logical texture size. With foveated rendering, it's bigger than the
// physical texture size. This value is equivalent to rasterizationRateMap.screenSize.
Rect2i VisionOSXRInterface::RenderThread::get_render_region() {
	Rect2 viewport_rect;

	ERR_NOT_ON_RENDER_THREAD_V(viewport_rect);

	if (!initialized) {
		return viewport_rect;
	}

	ERR_FAIL_NULL_V(scene_output, viewport_rect);
	MTLViewport viewport = scene_output->geometry->viewport[0];
	viewport_rect = MTL::rect_from_mtl_viewport(viewport);
	return viewport_rect;
}

Size2 VisionOSXRInterface::RenderThread::get_render_target_size() {
	// Read atomic values cached by pre_render().
	return Size2(cached_render_target_width.get(), cached_render_target_height.get());
}

void VisionOSXRInterface::RenderThread::pre_render() {
	ERR_NOT_ON_RENDER_THREAD;
	rendered_frame.clear();
	diagnostic_viewport_drawn = false;
	diagnostic_frame++;
	scene_output.reset();
	if (!initialized || !presentation) {
		return;
	}
	std::shared_ptr<const VisionOSSceneGeometry> geometry;
	{
		MutexLock lock(mutex);
		geometry = frame_geometry;
	}
	auto lease = presentation->acquire(geometry);
	if (!lease.output) {
		return;
	}
	scene_output = lease.output;
	// A camera range change is negotiated outside the real-frame lifetime.
	// Never publish the exploratory render with the previous range.
	if (requested_depth_near > 0 && !simd_all(simd_make_float2(requested_depth_far, requested_depth_near) == scene_output->geometry->depth_range)) {
		scene_output->projection_valid = false;
	}
	output_generation = lease.generation;
	output_sequence = lease.sequence;
	origin_from_head = scene_output->geometry->origin_from_head;
	cached_render_target_width.set(scene_output->color.width);
	cached_render_target_height.set(scene_output->color.height);
}

bool VisionOSXRInterface::RenderThread::pre_draw_viewport() {
	ERR_NOT_ON_RENDER_THREAD_V(false);
	diagnostic_viewport_drawn = initialized && scene_output != nullptr;
	return diagnostic_viewport_drawn;
}

Vector<RenderingServerTypes::BlitToScreen> VisionOSXRInterface::RenderThread::post_draw_viewport(RID p_render_target, const Rect2 &p_screen_rect) {
	ERR_NOT_ON_RENDER_THREAD_V(Vector<RenderingServerTypes::BlitToScreen>());

	if (!initialized || !scene_output) {
		return Vector<RenderingServerTypes::BlitToScreen>();
	}

	auto *texture_storage = RendererRD::TextureStorage::get_singleton();
	scene_output->transparent_background = texture_storage->render_target_get_transparent(p_render_target);
	scene_output->color_is_srgb = !texture_storage->render_target_is_using_hdr(p_render_target);

	// We're overriding the color and depth textures, no need for screen blits, return empty BlitToScreen vector
	// However, we need to acquire the dummy frame buffer
	RD::get_singleton()->screen_prepare_for_drawing(DisplayServerEnums::MAIN_WINDOW_ID);
	return Vector<RenderingServerTypes::BlitToScreen>();
}

void VisionOSXRInterface::RenderThread::encode_present(MTL3::MDCommandBuffer *p_cmd_buffer) {
	ERR_NOT_ON_RENDER_THREAD;

	if (!initialized || !scene_output) {
		return;
	}

	ERR_FAIL_NULL(p_cmd_buffer);
	// Finish engine encoders before appending the owned output's depth hierarchy.
	p_cmd_buffer->end();
	id<MTLCommandBuffer> scene_command = (__bridge id<MTLCommandBuffer>)p_cmd_buffer->get_command_buffer();
	if (diagnostic_viewport_drawn) {
		VisionOSPresentation::Lease lease;
		lease.output = scene_output;
		lease.generation = output_generation;
		lease.sequence = output_sequence;
		presentation->complete(lease, scene_command);
		rendered_frame.set();
	}
	scene_output.reset();
}

void VisionOSXRInterface::RenderThread::end_frame() {
	ERR_NOT_ON_RENDER_THREAD;

	if (!initialized) {
		return;
	}

	scene_output.reset();
}

RID VisionOSXRInterface::RenderThread::get_color_texture() {
	ERR_NOT_ON_RENDER_THREAD_V(RID());

	if (!initialized || !scene_output) {
		return RID();
	}

	if (current_color_texture_id != RID()) {
		rendering_device->free_rid(current_color_texture_id);
		current_color_texture_id = RID();
	}

	id<MTLTexture> color_texture = scene_output->color;
	current_color_texture_id = rendering_device->texture_create_from_extension(
			MTL::texture_type_from_metal(color_texture.textureType),
			pixel_formats->getDataFormat((MTL::PixelFormat)color_texture.pixelFormat),
			MTL::texture_samples_from_metal(color_texture.sampleCount),
			RD::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT,
			(uint64_t)color_texture,
			color_texture.width,
			color_texture.height,
			color_texture.depth,
			color_texture.arrayLength,
			color_texture.mipmapLevelCount);

	return current_color_texture_id;
}

RID VisionOSXRInterface::RenderThread::get_depth_texture() {
	ERR_NOT_ON_RENDER_THREAD_V(RID());

	if (!initialized || !scene_output) {
		return RID();
	}

	if (current_depth_texture_id != RID()) {
		rendering_device->free_rid(current_depth_texture_id);
		current_depth_texture_id = RID();
	}

	id<MTLTexture> depth_texture = scene_output->depth;

	current_depth_texture_id = rendering_device->texture_create_from_extension(
			MTL::texture_type_from_metal(depth_texture.textureType),
			pixel_formats->getDataFormat((MTL::PixelFormat)depth_texture.pixelFormat),
			MTL::texture_samples_from_metal(depth_texture.sampleCount),
			RD::TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_DEPTH_RESOLVE_ATTACHMENT_BIT,
			(uint64_t)depth_texture,
			depth_texture.width,
			depth_texture.height,
			depth_texture.depth,
			depth_texture.arrayLength,
			depth_texture.mipmapLevelCount);

	return current_depth_texture_id;
}

RID VisionOSXRInterface::RenderThread::get_vrs_texture() {
	ERR_NOT_ON_RENDER_THREAD_V(RID());

	if (!initialized || !scene_output) {
		return RID();
	}

	if (current_rasterization_rate_map_id != RID()) {
		rendering_device->free_rid(current_rasterization_rate_map_id);
		current_rasterization_rate_map_id = RID();
	}

	id<MTLRasterizationRateMap> rasterization_rate_map = scene_output->geometry->rate_map;
	ERR_FAIL_NULL_V_MSG(rasterization_rate_map, RID(), "No rasterizationRateMap in scene output.");
	MTLSize logical_size = rasterization_rate_map.screenSize;

	// The type, format and sample count are spoofed. They satisfy
	// RenderingDevice::_render_pass_create() validation and have no other use.
	current_rasterization_rate_map_id = rendering_device->texture_create_from_extension(
			RD::TEXTURE_TYPE_2D_ARRAY,
			RD::DATA_FORMAT_R8_UINT,
			RD::TEXTURE_SAMPLES_1,
			RD::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_VRS_ATTACHMENT_BIT,
			(uint64_t)(__bridge void *)rasterization_rate_map,
			logical_size.width,
			logical_size.height,
			1,
			rasterization_rate_map.layerCount,
			1);

	return current_rasterization_rate_map_id;
}

void VisionOSXRInterface::trigger_haptic_pulse(const String &p_action_name, const StringName &p_tracker_name, double p_frequency, double p_amplitude, double p_duration_sec, double p_delay_sec) {
	if (controllers.enabled) {
		controllers.trigger_haptic_pulse(p_action_name, p_tracker_name, p_frequency, p_amplitude, p_duration_sec, p_delay_sec);
	}
}

#endif // VISIONOS_ENABLED
