/**************************************************************************/
/*  visionos_xr_interface.h                                               */
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

#ifdef VISIONOS_ENABLED

#include "core/templates/hash_map.h"
#include "core/templates/hash_set.h"
#include "core/templates/safe_refcount.h"
#include "drivers/metal/rendering_context_driver_metal.h"
#include "drivers/metal/rendering_device_driver_metal.h"
#include "servers/rendering/renderer_compositor.h"
#include "servers/xr/xr_controller_tracker.h"
#include "servers/xr/xr_hand_tracker.h"
#include "servers/xr/xr_interface.h"
#include "servers/xr/xr_positional_tracker.h"
#include "servers/xr/xr_vrs.h"

#import <ARKit/ARKit.h>
#import <CompositorServices/CompositorServices.h>

#if defined(__VISION_OS_VERSION_MAX_ALLOWED) && __VISION_OS_VERSION_MAX_ALLOWED >= 260000 && __has_include(<ARKit/accessory_tracking.h>)
#define GODOT_VISIONOS_XR_HAS_ACCESSORY_TRACKING 1
#else
#define GODOT_VISIONOS_XR_HAS_ACCESSORY_TRACKING 0
#endif

class VisionOSXRInterface : public XRInterface {
	GDCLASS(VisionOSXRInterface, XRInterface);

public:
	enum SignalEnum {
		VISIONOS_XR_SIGNAL_SESSION_STARTED,
		VISIONOS_XR_SIGNAL_SESSION_PAUSED,
		VISIONOS_XR_SIGNAL_SESSION_RESUMED,
		VISIONOS_XR_SIGNAL_SESSION_INVALIDATED,
		VISIONOS_XR_SIGNAL_POSE_RECENTERED,
		VISIONOS_XR_SIGNAL_MAX,
	};

	// Controls whether the user's real arms (upper-limb passthrough) are composited
	// over the immersive scene. Maps to SwiftUI's `.upperLimbVisibility`. Distinct from
	// any virtual hand/controller mesh the app draws itself.
	enum UpperLimbVisibility {
		UPPER_LIMB_VISIBILITY_AUTOMATIC,
		UPPER_LIMB_VISIBILITY_VISIBLE,
		UPPER_LIMB_VISIBILITY_HIDDEN,
	};

private:
	enum HandIndex {
		HAND_INDEX_LEFT = 0,
		HAND_INDEX_RIGHT = 1,
		HAND_INDEX_MAX = 2,
	};

	struct HandJointState {
		bool tracked = false;
		Transform3D transform;
		float radius = 0.01f;
	};

	struct HandInteractionState {
		bool tracked = false;
		bool has_joint_data = false;
		Transform3D default_transform;
		Transform3D aim_transform;
		Transform3D grip_transform;
		Transform3D palm_transform;
		float pinch_value = 0.0f;
		bool pinch_click = false;
		float grasp_value = 0.0f;
		bool grasp_click = false;
		HandJointState joints[XRHandTracker::HAND_JOINT_MAX];
	};

	struct SpatialControllerState {
		bool tracked = false;
		int tracking_rank = -1;
		Transform3D default_transform;
		Transform3D aim_transform;
		Transform3D grip_transform;
		Transform3D skeleton_transform;
		Vector3 linear_velocity;
		Vector3 angular_velocity;
		float trigger_value = 0.0f;
		bool trigger_click = false;
		bool trigger_touch = false;
		float grip_value = 0.0f;
		bool grip_click = false;
		Vector2 primary_value;
		bool primary_click = false;
		bool primary_touch = false;
		Vector2 secondary_value;
		bool secondary_click = false;
		bool secondary_touch = false;
		bool thumbstick_dpad_up = false;
		bool thumbstick_dpad_down = false;
		bool thumbstick_dpad_left = false;
		bool thumbstick_dpad_right = false;
		bool menu_click = false;
		bool ax_click = false;
		bool ax_touch = false;
		bool by_click = false;
		bool by_touch = false;
		bool select_click = false;
		bool has_extended_inputs = false;
	};

	bool initialized = false;
	XRInterface::TrackingStatus tracking_state;
	XRInterface::EnvironmentBlendMode environment_blend_mode = XRInterface::XR_ENV_BLEND_MODE_ALPHA_BLEND;
	UpperLimbVisibility upper_limb_visibility = UPPER_LIMB_VISIBILITY_AUTOMATIC;
	XRInterface::PlayAreaMode play_area_mode = XRInterface::XR_PLAY_AREA_ROOMSCALE;
	float eye_height = 1.7f;
	float tracking_reference_head_height = 0.0f;
	bool tracking_reference_head_height_valid = false;

	static RenderingServer *rendering_server;
	static ar_world_tracking_provider_t world_tracking_provider;

	cp_layer_renderer_t layer_renderer = nullptr;
	cp_layer_renderer_capabilities_t layer_renderer_capabilities = nullptr;
	ar_session_t ar_session = nullptr;
	ar_hand_tracking_provider_t hand_tracking_provider = nullptr;
#if GODOT_VISIONOS_XR_HAS_ACCESSORY_TRACKING
	ar_accessory_tracking_provider_t accessory_tracking_provider = nullptr;
	ar_accessory_tracking_configuration_t accessory_tracking_configuration = nullptr;
	ar_accessories_t accessory_tracking_accessories = nullptr;
	ar_accessory_anchor_t accessory_tracking_predicted_anchor = nullptr;
#endif

	ar_device_anchor_t current_device_anchor = nullptr;
	ar_hand_anchor_t current_left_hand_anchor = nullptr;
	ar_hand_anchor_t current_right_hand_anchor = nullptr;
	cp_frame_t current_frame = nullptr;

	// Data and functions only accessible from the rendering thread
	class RenderThread : public Object {
	private:
		bool initialized = false;
		RenderingDevice *rendering_device = nullptr;
		PixelFormats *pixel_formats = nullptr;

		float minimum_supported_near_plane = 0;

		ar_device_anchor_t current_device_anchor = nullptr;
		bool has_valid_device_anchor = false;

		bool has_valid_origin_from_head = false;
		Transform3D origin_from_head;

		cp_frame_t current_frame = nullptr;
		cp_drawable_t current_drawable = nullptr;
		uint32_t current_view_count = 2;

		RD::Texture current_color_texture;
		RID current_color_texture_id;
		RD::Texture current_depth_texture;
		RID current_depth_texture_id;
		RD::Texture current_rasterization_rate_map;
		RID current_rasterization_rate_map_id;

		// Cached render target size, set in pre_render() on the render thread
		// and read from the game thread via get_render_target_size().
		SafeNumeric<uint32_t> cached_render_target_width{ 0 };
		SafeNumeric<uint32_t> cached_render_target_height{ 0 };

	public:
		void initialize();
		void uninitialize();

		void set_minimum_supported_near_plane(float p_minimum_supported_near_plane);
		void set_origin_from_head(const Transform3D &p_origin_from_head, bool p_has_valid_origin_from_head);
		// p_current_frame should be an cp_frame_t pointer casted to uint64_t
		void set_current_frame(uint64_t p_current_frame);

		void start_frame_update();
		void end_frame_update();

		uint32_t get_view_count();
		Size2 get_render_target_size();
		Transform3D get_camera_transform();
		Transform3D get_transform_for_view(uint32_t p_view, const Transform3D &p_cam_transform);
		Projection get_projection_for_view(uint32_t p_view, double p_aspect, double p_z_near, double p_z_far);
		Rect2i get_render_region();

		void pre_render();
		Vector<BlitToScreen> post_draw_viewport(RID p_render_target, const Rect2 &p_screen_rect);
		void encode_present(MDCommandBuffer *p_cmd_buffer);
		void end_frame();

		RID get_color_texture();
		RID get_depth_texture();
		RID get_vrs_texture();
	} rt;

	// Head tracker
	Ref<XRPositionalTracker> head_tracker;

	Ref<XRControllerTracker> hand_controller_trackers[HAND_INDEX_MAX];
	Ref<XRHandTracker> hand_trackers[HAND_INDEX_MAX];
	HandInteractionState hand_interaction_states[HAND_INDEX_MAX];
	SpatialControllerState spatial_controller_states[HAND_INDEX_MAX];
	bool hand_tracking_supported = false;
	bool hand_tracking_active = false;
	bool accessory_tracking_supported = false;
	bool accessory_tracking_active = false;
	bool accessory_tracking_needs_session_refresh = false;
	HashSet<uint64_t> accessory_tracking_load_requests;
	HashMap<uint64_t, HandIndex> accessory_tracking_device_hand_assignments;
	uint64_t accessory_tracking_assigned_device_keys[HAND_INDEX_MAX] = { 0, 0 };
	SpatialControllerState accessory_tracking_stream_states[HAND_INDEX_MAX];
	uint64_t accessory_tracking_stream_state_timestamp_msec[HAND_INDEX_MAX] = { 0, 0 };

	static void _bind_methods();
	static const String name;
	static StringName get_signal_name(SignalEnum p_signal);
	float get_tracking_floor_offset() const;
	Transform3D apply_tracking_floor_offset(const Transform3D &p_transform) const;
	void reset_tracking_floor_reference();
	void update_tracking_floor_reference_from_head(const Transform3D &p_head_transform);

	void set_head_pose_from_arkit();
	void initialize_interaction_trackers(XRServer *p_xr_server);
	void uninitialize_interaction_trackers(XRServer *p_xr_server);
	void configure_arkit_session_authorization_and_state_handlers();
	void run_arkit_session_with_active_providers();
	void initialize_accessory_tracking_provider();
	void configure_accessory_tracking_provider_update_handler();
	void update_accessory_tracking_devices();
	void update_accessory_tracking_session();
	void uninitialize_accessory_tracking_provider();
	void update_hand_states_from_arkit(CFTimeInterval p_prediction_timestamp);
	void update_hand_state_from_anchor(HandIndex p_hand_index, ar_hand_anchor_t p_anchor);
	void update_spatial_controller_states_from_arkit(CFTimeInterval p_prediction_timestamp);
#if GODOT_VISIONOS_XR_HAS_ACCESSORY_TRACKING
	void update_spatial_controller_state_from_anchor(HandIndex p_hand_index, ar_accessory_anchor_t p_anchor);
	void update_spatial_controller_state_from_anchor_to_target(SpatialControllerState p_target_states[HAND_INDEX_MAX], HandIndex p_hand_index, ar_accessory_anchor_t p_anchor);
#endif
	void reset_hand_state(HandIndex p_hand_index);
	void reset_spatial_controller_state(HandIndex p_hand_index);
	void apply_hand_states_to_trackers();
	static int map_arkit_joint_to_xr_hand_joint(uint64_t p_joint_index);
	static Transform3D make_aim_transform_from_hand(const Transform3D &p_fallback, const Transform3D &p_index_knuckle, bool p_has_index_knuckle, const Transform3D &p_index_tip, bool p_has_index_tip);

public:
	static Ref<VisionOSXRInterface> find_interface() {
		return XRServer::get_singleton()->find_interface(name);
	}

	VisionOSXRInterface();
	~VisionOSXRInterface();

	void emit_signal_enum(SignalEnum p_signal);

	virtual StringName get_name() const override;
	virtual uint32_t get_capabilities() const override;
	virtual PackedStringArray get_suggested_tracker_names() const override;

	virtual TrackingStatus get_tracking_status() const override;

	virtual bool is_initialized() const override;
	virtual bool initialize() override;
	virtual void uninitialize() override;

	// The LayerRenderer and Capabilities are polled from the app delegate when initializing the VisionOSXRInterface,
	// but they need to be updated when the app backgrounds and foregrounds because they are recreated by visionOS
	void update_layer_renderer(cp_layer_renderer_t p_layer_renderer, cp_layer_renderer_capabilities_t p_layer_renderer_capabilities);

	virtual Dictionary get_system_info() override;
	virtual VRSTextureFormat get_vrs_texture_format() override;

	virtual bool supports_play_area_mode(XRInterface::PlayAreaMode p_mode) override;
	virtual XRInterface::PlayAreaMode get_play_area_mode() const override;
	virtual bool set_play_area_mode(XRInterface::PlayAreaMode p_mode) override;

	virtual Array get_supported_environment_blend_modes() override;
	virtual EnvironmentBlendMode get_environment_blend_mode() const override;
	virtual bool set_environment_blend_mode(EnvironmentBlendMode mode) override;

	void set_eye_height(float p_eye_height);
	float get_eye_height() const;

	void set_upper_limb_visibility(UpperLimbVisibility p_visibility);
	UpperLimbVisibility get_upper_limb_visibility() const;

	virtual void process() override;

	// Render thread methods
	virtual uint32_t get_view_count() override {
		return rt.get_view_count();
	}
	virtual Size2 get_render_target_size() override {
		return rt.get_render_target_size();
	}
	virtual Transform3D get_camera_transform() override {
		return rt.get_camera_transform();
	}
	virtual Transform3D get_transform_for_view(uint32_t p_view, const Transform3D &p_cam_transform) override {
		return rt.get_transform_for_view(p_view, p_cam_transform);
	}
	virtual Projection get_projection_for_view(uint32_t p_view, double p_aspect, double p_z_near, double p_z_far) override {
		return rt.get_projection_for_view(p_view, p_aspect, p_z_near, p_z_far);
	}
	virtual Rect2i get_render_region() override {
		return rt.get_render_region();
	}
	virtual void pre_render() override {
		rt.pre_render();
	}
	virtual Vector<BlitToScreen> post_draw_viewport(RID p_render_target, const Rect2 &p_screen_rect) override {
		return rt.post_draw_viewport(p_render_target, p_screen_rect);
	}
	void encode_present(MDCommandBuffer *p_cmd_buffer) {
		rt.encode_present(p_cmd_buffer);
	}
	virtual void end_frame() override {
		rt.end_frame();
	}

	virtual RID get_color_texture() override {
		return rt.get_color_texture();
	}
	virtual RID get_depth_texture() override {
		return rt.get_depth_texture();
	}
	virtual RID get_vrs_texture() override {
		return rt.get_vrs_texture();
	}
};

VARIANT_ENUM_CAST(VisionOSXRInterface::UpperLimbVisibility);

#endif
