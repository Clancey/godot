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

#include "core/input/input.h"
#include "core/math/math_funcs.h"
#include "core/os/os.h"
#include "drivers/metal/metal_objects.h"
#include "platform/visionos/godot_app_delegate_service_visionos.h"
#include "scene/main/scene_tree.h"
#include "scene/main/viewport.h"
#include "scene/main/window.h"
#include "servers/rendering/rendering_device.h"
#include "servers/rendering/rendering_server_globals.h"

#include "core/os/thread.h"
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <cstdint>
#include <initializer_list>

#if GODOT_VISIONOS_XR_HAS_ACCESSORY_TRACKING
#import <ARKit/accessory_tracking.h>
#import <ARKit/transform_correction.h>
#define Key GodotVisionOSXRGameControllerKey
#import <GameController/GameController.h>
#undef Key
#endif

const String VisionOSXRInterface::name = "visionOS";

RenderingServer *VisionOSXRInterface::rendering_server = nullptr;
ar_world_tracking_provider_t VisionOSXRInterface::world_tracking_provider = nullptr;

static const char *VISIONOS_INTERACTION_PROFILE_HAND = "/interaction_profiles/ext/hand_interaction_ext";
static const char *VISIONOS_INTERACTION_PROFILE_SIMPLE_CONTROLLER = "/interaction_profiles/khr/simple_controller";
static const char *VISIONOS_INTERACTION_PROFILE_OCULUS_TOUCH = "/interaction_profiles/oculus/touch_controller";
static const char *VISIONOS_INTERACTION_PROFILE_NONE = "/interaction_profiles/none";
static constexpr float VISIONOS_PINCH_PRESS_DISTANCE_M = 0.025f;
static constexpr float VISIONOS_PINCH_RELEASE_DISTANCE_M = 0.04f;
static constexpr float VISIONOS_PINCH_ANALOG_MAX_DISTANCE_M = 0.06f;
static constexpr float VISIONOS_PINCH_SMOOTHING_FACTOR = 0.35f;
static constexpr float VISIONOS_DPAD_THRESHOLD = 0.7f;
static constexpr uint64_t VISIONOS_CONTROLLER_DISCOVERY_RETRY_INTERVAL_MSEC = 10000;
static constexpr uint64_t VISIONOS_CONTROLLER_STREAM_FALLBACK_MAX_AGE_MSEC = 2000;

static RD::DataFormat _rd_data_format_from_metal_pixel_format(MTLPixelFormat p_format) {
	switch (p_format) {
		case MTLPixelFormatBGRA8Unorm:
			return RD::DATA_FORMAT_B8G8R8A8_UNORM;
		case MTLPixelFormatBGRA8Unorm_sRGB:
			return RD::DATA_FORMAT_B8G8R8A8_SRGB;
		case MTLPixelFormatRGBA8Unorm:
			return RD::DATA_FORMAT_R8G8B8A8_UNORM;
		case MTLPixelFormatRGB10A2Unorm:
			return RD::DATA_FORMAT_A2B10G10R10_UNORM_PACK32;
		case MTLPixelFormatBGR10A2Unorm:
			return RD::DATA_FORMAT_A2R10G10B10_UNORM_PACK32;
		case MTLPixelFormatRGBA16Float:
			return RD::DATA_FORMAT_R16G16B16A16_SFLOAT;
		case MTLPixelFormatDepth16Unorm:
			return RD::DATA_FORMAT_D16_UNORM;
		case MTLPixelFormatDepth32Float:
			return RD::DATA_FORMAT_D32_SFLOAT;
		case MTLPixelFormatStencil8:
			return RD::DATA_FORMAT_S8_UINT;
		case MTLPixelFormatDepth32Float_Stencil8:
			return RD::DATA_FORMAT_D32_SFLOAT_S8_UINT;
		default:
			return RD::DATA_FORMAT_B8G8R8A8_UNORM;
	}
}

static Vector3 _simd_to_vector3(const simd_float3 &p_value) {
	return Vector3(p_value.x, p_value.y, p_value.z);
}

static bool _is_world_tracking_provider_running(ar_world_tracking_provider_t p_provider) {
	if (p_provider == nullptr) {
		return false;
	}
	return ar_data_provider_get_state((ar_data_provider_t)p_provider) == ar_data_provider_state_running;
}

static bool _is_hand_tracking_provider_running(ar_hand_tracking_provider_t p_provider) {
	if (p_provider == nullptr) {
		return false;
	}
	return ar_data_provider_get_state((ar_data_provider_t)p_provider) == ar_data_provider_state_running;
}

#if GODOT_VISIONOS_XR_HAS_ACCESSORY_TRACKING
static bool _is_runtime_accessory_tracking_available() {
	if (@available(visionOS 26.0, *)) {
		return true;
	}
	return false;
}

static bool _is_accessory_tracking_provider_running(ar_accessory_tracking_provider_t p_provider) {
	if (p_provider == nullptr) {
		return false;
	}
	return ar_data_provider_get_state((ar_data_provider_t)p_provider) == ar_data_provider_state_running;
}

static ar_accessory_chirality_t _resolve_accessory_anchor_chirality(ar_accessory_anchor_t p_anchor, bool *r_is_held = nullptr) {
	if (r_is_held != nullptr) {
		*r_is_held = false;
	}
	if (p_anchor == nullptr) {
		return ar_accessory_chirality_unspecified;
	}

	const bool is_held = ar_accessory_anchor_is_held(p_anchor);
	if (r_is_held != nullptr) {
		*r_is_held = is_held;
	}

	ar_accessory_chirality_t chirality = ar_accessory_chirality_unspecified;
	if (is_held) {
		chirality = ar_accessory_anchor_get_held_chirality(p_anchor);
	}

	ar_accessory_t accessory = ar_accessory_anchor_get_accessory(p_anchor);
	if (chirality == ar_accessory_chirality_unspecified && accessory != nullptr) {
		chirality = ar_accessory_get_inherent_chirality(accessory);
	}

	return chirality;
}

static bool _is_spatial_controller_device(id<GCDevice> p_device) {
	if (p_device == nil) {
		return false;
	}
	NSString *product_category = p_device.productCategory;
	if (product_category != nil) {
		if ([product_category isEqualToString:GCProductCategorySpatialController]) {
			return true;
		}
		NSRange compact_match = [[product_category stringByReplacingOccurrencesOfString:@" " withString:@""] rangeOfString:@"SpatialController" options:NSCaseInsensitiveSearch];
		if (compact_match.location != NSNotFound) {
			return true;
		}
		NSRange spaced_match = [product_category rangeOfString:@"Spatial Controller" options:NSCaseInsensitiveSearch];
		if (spaced_match.location != NSNotFound) {
			return true;
		}
	}

	if ([p_device isKindOfClass:[GCController class]]) {
		GCPhysicalInputProfile *physical_input_profile = ((GCController *)p_device).physicalInputProfile;
		if (physical_input_profile != nil) {
			if (physical_input_profile.buttons[GCInputGripButton] != nil) {
				return true;
			}
			GCControllerElement *grip_element = [physical_input_profile objectForKeyedSubscript:GCInputGripButton];
			if ([grip_element isKindOfClass:[GCControllerButtonInput class]]) {
				return true;
			}
		}
	}

	return false;
}

static bool _is_spatial_stylus_device(id<GCDevice> p_device) {
	if (p_device == nil) {
		return false;
	}
	NSString *product_category = p_device.productCategory;
	if (product_category != nil) {
		if (@available(visionOS 26.0, *)) {
			if ([product_category isEqualToString:GCProductCategorySpatialStylus]) {
				return true;
			}
		}
		NSRange compact_match = [[product_category stringByReplacingOccurrencesOfString:@" " withString:@""] rangeOfString:@"SpatialStylus" options:NSCaseInsensitiveSearch];
		if (compact_match.location != NSNotFound) {
			return true;
		}
		NSRange spaced_match = [product_category rangeOfString:@"Spatial Stylus" options:NSCaseInsensitiveSearch];
		if (spaced_match.location != NSNotFound) {
			return true;
		}
	}
	if (@available(visionOS 26.0, *)) {
		if ([p_device isKindOfClass:[GCStylus class]]) {
			return true;
		}
	}
	return false;
}

static bool _is_spatial_accessory_device(id<GCDevice> p_device) {
	return _is_spatial_controller_device(p_device) || _is_spatial_stylus_device(p_device);
}

static GCControllerButtonInput *_get_button_input(GCPhysicalInputProfile *p_profile, NSString *p_name) {
	if (p_profile == nil || p_name == nil) {
		return nil;
	}
	GCControllerButtonInput *button = (GCControllerButtonInput *)p_profile.buttons[p_name];
	if (button != nil) {
		return button;
	}
	GCControllerElement *element = [p_profile objectForKeyedSubscript:p_name];
	if ([element isKindOfClass:[GCControllerButtonInput class]]) {
		return (GCControllerButtonInput *)element;
	}
	return nil;
}

static bool _read_button_state(GCPhysicalInputProfile *p_profile, NSString *p_name, float &r_value, bool &r_pressed, bool *r_touched = nullptr) {
	GCControllerButtonInput *button = _get_button_input(p_profile, p_name);
	if (button == nil) {
		return false;
	}
	r_value = button.value;
	r_pressed = button.isPressed;
	if (r_touched != nullptr) {
		if ([button respondsToSelector:@selector(isTouched)]) {
			*r_touched = button.isTouched;
		} else {
			*r_touched = button.isPressed;
		}
	}
	return true;
}

static bool _read_button_state_any(GCPhysicalInputProfile *p_profile, std::initializer_list<NSString *> p_names, float &r_value, bool &r_pressed, bool *r_touched = nullptr) {
	for (NSString *name : p_names) {
		if (name == nil) {
			continue;
		}
		if (_read_button_state(p_profile, name, r_value, r_pressed, r_touched)) {
			return true;
		}
	}
	return false;
}

static GCControllerDirectionPad *_get_direction_pad_input(GCPhysicalInputProfile *p_profile, NSString *p_name) {
	if (p_profile == nil || p_name == nil) {
		return nil;
	}
	GCControllerDirectionPad *dpad = (GCControllerDirectionPad *)p_profile.dpads[p_name];
	if (dpad != nil) {
		return dpad;
	}
	GCControllerElement *element = [p_profile objectForKeyedSubscript:p_name];
	if ([element isKindOfClass:[GCControllerDirectionPad class]]) {
		return (GCControllerDirectionPad *)element;
	}
	return nil;
}

static bool _read_directional_input(GCPhysicalInputProfile *p_profile, NSString *p_name, Vector2 &r_value) {
	GCControllerDirectionPad *dpad = _get_direction_pad_input(p_profile, p_name);
	if (dpad == nil) {
		return false;
	}
	r_value.x = dpad.xAxis.value;
	r_value.y = dpad.yAxis.value;
	return true;
}

static id<GCButtonElement> _get_device_button_element(id<GCDevicePhysicalInputState> p_input_state, GCInputButtonName p_name) {
	if (p_input_state == nil || p_name == nil) {
		return nil;
	}
	id<GCButtonElement> button = p_input_state.buttons[p_name];
	if (button != nil) {
		return button;
	}
	id<GCPhysicalInputElement> element = [p_input_state objectForKeyedSubscript:p_name];
	if ([element conformsToProtocol:@protocol(GCButtonElement)]) {
		return (id<GCButtonElement>)element;
	}
	return nil;
}

static bool _read_device_button_state(id<GCDevicePhysicalInputState> p_input_state, GCInputButtonName p_name, float &r_value, bool &r_pressed, bool *r_touched = nullptr, float *r_force = nullptr) {
	id<GCButtonElement> button = _get_device_button_element(p_input_state, p_name);
	if (button == nil) {
		return false;
	}

	id<GCPressedStateInput, GCLinearInput> pressed_input = button.pressedInput;
	if (pressed_input == nil) {
		return false;
	}

	r_value = pressed_input.value;
	r_pressed = pressed_input.pressed;

	if (r_touched != nullptr) {
		if (button.touchedInput != nil) {
			*r_touched = button.touchedInput.touched;
		} else {
			*r_touched = r_pressed;
		}
	}

	if (r_force != nullptr) {
		*r_force = button.forceInput != nil ? button.forceInput.value : 0.0f;
	}

	return true;
}

static bool _read_device_button_state_any(id<GCDevicePhysicalInputState> p_input_state, std::initializer_list<GCInputButtonName> p_names, float &r_value, bool &r_pressed, bool *r_touched = nullptr, float *r_force = nullptr) {
	for (const GCInputButtonName &name : p_names) {
		if (name == nil) {
			continue;
		}
		if (_read_device_button_state(p_input_state, name, r_value, r_pressed, r_touched, r_force)) {
			return true;
		}
	}
	return false;
}

static int _accessory_tracking_rank(ar_accessory_anchor_tracking_state_t p_tracking_state) {
	switch (p_tracking_state) {
		case ar_accessory_anchor_tracking_state_position_orientation_tracked:
			return 3;
		case ar_accessory_anchor_tracking_state_position_orientation_tracked_low_accuracy:
			return 2;
		case ar_accessory_anchor_tracking_state_orientation_tracked:
			return 1;
		case ar_accessory_anchor_tracking_state_untracked:
		default:
			return 0;
	}
}

static bool _get_accessory_location_transform(ar_accessory_anchor_t p_anchor, const char *p_location_name, Transform3D &r_transform) {
	ERR_FAIL_NULL_V(p_anchor, false);
	ERR_FAIL_NULL_V(p_location_name, false);

	const simd_float4x4 origin_from_anchor = ar_accessory_anchor_get_origin_from_anchor_transform_with_correction(p_anchor, ar_transform_correction_rendered);
	const simd_float4x4 anchor_from_location = ar_accessory_anchor_get_anchor_from_location_transform_with_correction(p_anchor, p_location_name, ar_transform_correction_rendered);
	const simd_float4x4 origin_from_location = simd_mul(origin_from_anchor, anchor_from_location);
	const Transform3D location_transform = MTL::simd_to_transform3D(origin_from_location);
	if (!location_transform.is_finite()) {
		return false;
	}

	r_transform = location_transform;
	return true;
}
#endif

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

void VisionOSXRInterface::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_eye_height", "eye_height"), &VisionOSXRInterface::set_eye_height);
	ClassDB::bind_method(D_METHOD("get_eye_height"), &VisionOSXRInterface::get_eye_height);

	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "eye_height", PROPERTY_HINT_RANGE, "0.0,3.0,0.01"), "set_eye_height", "get_eye_height");

	// Signals
	for (int i = 0; i < VISIONOS_XR_SIGNAL_MAX; i++) {
		ADD_SIGNAL(MethodInfo(get_signal_name((SignalEnum)i)));
	}
}

VisionOSXRInterface::VisionOSXRInterface() {}

VisionOSXRInterface::~VisionOSXRInterface() {
	// and make sure we cleanup if we haven't already
	if (is_initialized()) {
		uninitialize();
	};
}

float VisionOSXRInterface::get_tracking_floor_offset() const {
	switch (play_area_mode) {
		case XR_PLAY_AREA_ROOMSCALE:
		case XR_PLAY_AREA_STAGE:
			if (tracking_reference_head_height_valid) {
				return eye_height - tracking_reference_head_height;
			}
			return eye_height;
		default:
			return 0.0f;
	}
}

Transform3D VisionOSXRInterface::apply_tracking_floor_offset(const Transform3D &p_transform) const {
	Transform3D adjusted = p_transform;
	adjusted.origin.y += get_tracking_floor_offset();
	return adjusted;
}

void VisionOSXRInterface::reset_tracking_floor_reference() {
	tracking_reference_head_height = 0.0f;
	tracking_reference_head_height_valid = false;
}

void VisionOSXRInterface::update_tracking_floor_reference_from_head(const Transform3D &p_head_transform) {
	if (tracking_reference_head_height_valid) {
		return;
	}
	if (play_area_mode != XR_PLAY_AREA_ROOMSCALE && play_area_mode != XR_PLAY_AREA_STAGE) {
		return;
	}
	if (!p_head_transform.is_finite()) {
		return;
	}

	tracking_reference_head_height = p_head_transform.origin.y;
	tracking_reference_head_height_valid = true;
}

void VisionOSXRInterface::initialize_interaction_trackers(XRServer *p_xr_server) {
	ERR_FAIL_NULL(p_xr_server);

	for (int i = 0; i < HAND_INDEX_MAX; i++) {
		const bool is_left = i == HAND_INDEX_LEFT;
		const StringName tracker_name = is_left ? StringName("left_hand") : StringName("right_hand");
		const StringName hand_tracker_name = is_left ? StringName("/user/hand_tracker/left") : StringName("/user/hand_tracker/right");
		const String tracker_desc = is_left ? "Left hand controller" : "Right hand controller";

		Ref<XRControllerTracker> controller_tracker;
		controller_tracker.instantiate();
		controller_tracker->set_tracker_name(tracker_name);
		controller_tracker->set_tracker_desc(tracker_desc);
		controller_tracker->set_tracker_hand(is_left ? XRPositionalTracker::TRACKER_HAND_LEFT : XRPositionalTracker::TRACKER_HAND_RIGHT);
		controller_tracker->set_tracker_profile(VISIONOS_INTERACTION_PROFILE_NONE);
		p_xr_server->add_tracker(controller_tracker);
		hand_controller_trackers[i] = controller_tracker;

		Ref<XRHandTracker> hand_tracker;
		hand_tracker.instantiate();
		hand_tracker->set_tracker_name(hand_tracker_name);
		hand_tracker->set_tracker_desc(tracker_desc + " skeleton");
		hand_tracker->set_tracker_hand(is_left ? XRPositionalTracker::TRACKER_HAND_LEFT : XRPositionalTracker::TRACKER_HAND_RIGHT);
		hand_tracker->set_has_tracking_data(false);
		hand_tracker->set_hand_tracking_source(XRHandTracker::HAND_TRACKING_SOURCE_NOT_TRACKED);
		p_xr_server->add_tracker(hand_tracker);
		hand_trackers[i] = hand_tracker;

		reset_hand_state((HandIndex)i);
		reset_spatial_controller_state((HandIndex)i);
	}
}

void VisionOSXRInterface::uninitialize_interaction_trackers(XRServer *p_xr_server) {
	ERR_FAIL_NULL(p_xr_server);

	for (int i = 0; i < HAND_INDEX_MAX; i++) {
		if (hand_controller_trackers[i].is_valid()) {
			p_xr_server->remove_tracker(hand_controller_trackers[i]);
			hand_controller_trackers[i].unref();
		}

		if (hand_trackers[i].is_valid()) {
			p_xr_server->remove_tracker(hand_trackers[i]);
			hand_trackers[i].unref();
		}

		reset_hand_state((HandIndex)i);
		reset_spatial_controller_state((HandIndex)i);
	}
}

void VisionOSXRInterface::reset_hand_state(HandIndex p_hand_index) {
	ERR_FAIL_INDEX(p_hand_index, HAND_INDEX_MAX);
	hand_interaction_states[p_hand_index] = HandInteractionState();
}

void VisionOSXRInterface::reset_spatial_controller_state(HandIndex p_hand_index) {
	ERR_FAIL_INDEX(p_hand_index, HAND_INDEX_MAX);
	spatial_controller_states[p_hand_index] = SpatialControllerState();
}

int VisionOSXRInterface::map_arkit_joint_to_xr_hand_joint(uint64_t p_joint_index) {
	switch ((ar_hand_skeleton_joint_name_t)p_joint_index) {
		case ar_hand_skeleton_joint_name_wrist:
			return XRHandTracker::HAND_JOINT_WRIST;
		case ar_hand_skeleton_joint_name_thumb_knuckle:
			return XRHandTracker::HAND_JOINT_THUMB_METACARPAL;
		case ar_hand_skeleton_joint_name_thumb_intermediate_base:
			return XRHandTracker::HAND_JOINT_THUMB_PHALANX_PROXIMAL;
		case ar_hand_skeleton_joint_name_thumb_intermediate_tip:
			return XRHandTracker::HAND_JOINT_THUMB_PHALANX_DISTAL;
		case ar_hand_skeleton_joint_name_thumb_tip:
			return XRHandTracker::HAND_JOINT_THUMB_TIP;
		case ar_hand_skeleton_joint_name_index_finger_metacarpal:
			return XRHandTracker::HAND_JOINT_INDEX_FINGER_METACARPAL;
		case ar_hand_skeleton_joint_name_index_finger_knuckle:
			return XRHandTracker::HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL;
		case ar_hand_skeleton_joint_name_index_finger_intermediate_base:
			return XRHandTracker::HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE;
		case ar_hand_skeleton_joint_name_index_finger_intermediate_tip:
			return XRHandTracker::HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL;
		case ar_hand_skeleton_joint_name_index_finger_tip:
			return XRHandTracker::HAND_JOINT_INDEX_FINGER_TIP;
		case ar_hand_skeleton_joint_name_middle_finger_metacarpal:
			return XRHandTracker::HAND_JOINT_MIDDLE_FINGER_METACARPAL;
		case ar_hand_skeleton_joint_name_middle_finger_knuckle:
			return XRHandTracker::HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL;
		case ar_hand_skeleton_joint_name_middle_finger_intermediate_base:
			return XRHandTracker::HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE;
		case ar_hand_skeleton_joint_name_middle_finger_intermediate_tip:
			return XRHandTracker::HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL;
		case ar_hand_skeleton_joint_name_middle_finger_tip:
			return XRHandTracker::HAND_JOINT_MIDDLE_FINGER_TIP;
		case ar_hand_skeleton_joint_name_ring_finger_metacarpal:
			return XRHandTracker::HAND_JOINT_RING_FINGER_METACARPAL;
		case ar_hand_skeleton_joint_name_ring_finger_knuckle:
			return XRHandTracker::HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL;
		case ar_hand_skeleton_joint_name_ring_finger_intermediate_base:
			return XRHandTracker::HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE;
		case ar_hand_skeleton_joint_name_ring_finger_intermediate_tip:
			return XRHandTracker::HAND_JOINT_RING_FINGER_PHALANX_DISTAL;
		case ar_hand_skeleton_joint_name_ring_finger_tip:
			return XRHandTracker::HAND_JOINT_RING_FINGER_TIP;
		case ar_hand_skeleton_joint_name_little_finger_metacarpal:
			return XRHandTracker::HAND_JOINT_PINKY_FINGER_METACARPAL;
		case ar_hand_skeleton_joint_name_little_finger_knuckle:
			return XRHandTracker::HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL;
		case ar_hand_skeleton_joint_name_little_finger_intermediate_base:
			return XRHandTracker::HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE;
		case ar_hand_skeleton_joint_name_little_finger_intermediate_tip:
			return XRHandTracker::HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL;
		case ar_hand_skeleton_joint_name_little_finger_tip:
			return XRHandTracker::HAND_JOINT_PINKY_FINGER_TIP;
		default:
			return -1;
	}
}

Transform3D VisionOSXRInterface::make_aim_transform_from_hand(const Transform3D &p_fallback, const Transform3D &p_index_knuckle, bool p_has_index_knuckle, const Transform3D &p_index_tip, bool p_has_index_tip) {
	Transform3D aim_transform = p_fallback;
	if (!p_has_index_knuckle || !p_has_index_tip) {
		return aim_transform;
	}

	Vector3 forward = p_index_tip.origin - p_index_knuckle.origin;
	if (Math::is_zero_approx(forward.length_squared())) {
		return aim_transform;
	}
	forward.normalize();

	Vector3 up = p_fallback.basis.get_column(1);
	if (Math::is_zero_approx(up.length_squared())) {
		up = Vector3(0.0f, 1.0f, 0.0f);
	}

	if (Math::abs(forward.dot(up)) > 0.98f) {
		up = p_fallback.basis.get_column(0);
	}
	if (Math::is_zero_approx(up.length_squared()) || Math::abs(forward.dot(up)) > 0.98f) {
		up = Vector3(0.0f, 1.0f, 0.0f);
	}

	Vector3 right = up.cross(forward);
	if (Math::is_zero_approx(right.length_squared())) {
		return aim_transform;
	}
	right.normalize();
	up = forward.cross(right).normalized();

	Basis basis;
	basis.set_column(0, right);
	basis.set_column(1, up);
	basis.set_column(2, forward);

	// Keep aim origin near the hand body (not at fingertip) so controller-space
	// interactions like pickup colliders stay aligned while still aiming with index direction.
	aim_transform.origin = p_index_knuckle.origin;
	aim_transform.basis = basis.orthonormalized();

	return aim_transform;
}

void VisionOSXRInterface::configure_arkit_session_authorization_and_state_handlers() {
	ERR_FAIL_NULL(ar_session);

	ar_session_set_data_provider_state_change_handler(ar_session, nullptr, nullptr);
	ar_session_set_authorization_update_handler(ar_session, nullptr, nullptr);

	NSDictionary *info_plist = [[NSBundle mainBundle] infoDictionary];

	ar_authorization_type_t requested_authorizations = ar_authorization_type_none;
	if (hand_tracking_active && hand_tracking_provider != nullptr) {
		if (info_plist[@"NSHandsTrackingUsageDescription"] != nil) {
			requested_authorizations = ar_authorization_type_t(requested_authorizations | ar_hand_tracking_provider_get_required_authorization_type());
		} else {
			WARN_PRINT("visionOS: NSHandsTrackingUsageDescription missing from Info.plist, skipping hand tracking authorization request.");
		}
	}
#if GODOT_VISIONOS_XR_HAS_ACCESSORY_TRACKING
	if (accessory_tracking_supported && accessory_tracking_provider != nullptr) {
		if (info_plist[@"NSAccessoryTrackingUsageDescription"] != nil) {
			requested_authorizations = ar_authorization_type_t(requested_authorizations | ar_accessory_tracking_provider_get_required_authorization_type());
		} else {
			WARN_PRINT("visionOS: NSAccessoryTrackingUsageDescription missing from Info.plist, skipping accessory tracking authorization request.");
		}
	}
#endif

	// Request world sensing authorization if the plist key is present.
	if (info_plist[@"NSWorldSensingUsageDescription"] != nil) {
		requested_authorizations = ar_authorization_type_t(requested_authorizations | ar_authorization_type_world_sensing);
	}

	run_arkit_session_with_active_providers();

	if (requested_authorizations == ar_authorization_type_none) {
		return;
	}

	ar_session_request_authorization(ar_session, requested_authorizations, ^(ar_authorization_results_t p_authorization_results, ar_error_t p_error) {
		if (p_error != nullptr) {
			print_verbose("visionOS: ARKit authorization request completed with error.");
		}
	});
}

void VisionOSXRInterface::run_arkit_session_with_active_providers() {
	ERR_FAIL_NULL(ar_session);
	ERR_FAIL_NULL(world_tracking_provider);

	ar_data_providers_t data_providers = ar_data_providers_create();
	ar_data_providers_add_data_provider(data_providers, world_tracking_provider);

	const bool include_hand_provider = hand_tracking_active && hand_tracking_provider != nullptr;
	if (hand_tracking_active && hand_tracking_provider != nullptr) {
		ar_data_providers_add_data_provider(data_providers, hand_tracking_provider);
	}

	bool include_accessory_provider = false;
	int configured_accessory_count = 0;
#if GODOT_VISIONOS_XR_HAS_ACCESSORY_TRACKING
	configured_accessory_count = accessory_tracking_accessories != nullptr ? int(ar_accessories_get_count(accessory_tracking_accessories)) : 0;
	const bool has_configured_accessories = configured_accessory_count > 0;
	if (accessory_tracking_active && has_configured_accessories && accessory_tracking_provider != nullptr) {
		include_accessory_provider = true;
		ar_data_providers_add_data_provider(data_providers, accessory_tracking_provider);
	}
#endif
	(void)include_hand_provider;
	(void)include_accessory_provider;
	(void)configured_accessory_count;

	ar_session_run(ar_session, data_providers);
}

void VisionOSXRInterface::configure_accessory_tracking_provider_update_handler() {
#if GODOT_VISIONOS_XR_HAS_ACCESSORY_TRACKING
	ERR_FAIL_NULL(accessory_tracking_provider);

	// Keep an anchor stream active and cache per-hand controller state from updates.
	ar_accessory_tracking_provider_set_update_handler(accessory_tracking_provider, nullptr, ^(ar_accessory_anchors_t p_added_anchors, ar_accessory_anchors_t p_updated_anchors, ar_accessory_anchors_t p_removed_anchors) {
		OS *os_singleton = OS::get_singleton();
		const uint64_t now_msec = os_singleton != nullptr ? os_singleton->get_ticks_msec() : 0;

		auto clear_device_assignment = [&](uint64_t p_device_key) {
			if (p_device_key == 0) {
				return;
			}
			const HandIndex *assigned_hand_ptr = accessory_tracking_device_hand_assignments.getptr(p_device_key);
			if (assigned_hand_ptr != nullptr) {
				const HandIndex assigned_hand = *assigned_hand_ptr;
				if (assigned_hand >= HAND_INDEX_LEFT && assigned_hand < HAND_INDEX_MAX && accessory_tracking_assigned_device_keys[assigned_hand] == p_device_key) {
					accessory_tracking_assigned_device_keys[assigned_hand] = 0;
				}
				accessory_tracking_device_hand_assignments.erase(p_device_key);
			}
		};

		auto assign_device_to_hand = [&](uint64_t p_device_key, HandIndex p_hand_index) {
			if (p_device_key == 0) {
				return;
			}
			const HandIndex *existing_hand_ptr = accessory_tracking_device_hand_assignments.getptr(p_device_key);
			const HandIndex previous_hand = existing_hand_ptr != nullptr ? *existing_hand_ptr : HAND_INDEX_MAX;
			if (previous_hand != HAND_INDEX_MAX && previous_hand != p_hand_index && accessory_tracking_assigned_device_keys[previous_hand] == p_device_key) {
				accessory_tracking_assigned_device_keys[previous_hand] = 0;
			}

			const uint64_t previous_device_key = accessory_tracking_assigned_device_keys[p_hand_index];
			if (previous_device_key != 0 && previous_device_key != p_device_key) {
				accessory_tracking_device_hand_assignments.erase(previous_device_key);
			}

			accessory_tracking_assigned_device_keys[p_hand_index] = p_device_key;
			accessory_tracking_device_hand_assignments.insert(p_device_key, p_hand_index);
		};

		auto get_anchor_source_device_key = [&](ar_accessory_anchor_t p_anchor) -> uint64_t {
			ar_accessory_t accessory = ar_accessory_anchor_get_accessory(p_anchor);
			if (accessory == nullptr) {
				return 0;
			}
			id<GCDevice> source_device = ar_accessory_get_source_device(accessory);
			if (!_is_spatial_accessory_device(source_device)) {
				return 0;
			}
			return uint64_t((uintptr_t)(__bridge void *)source_device);
		};

		auto resolve_hand_index = [&](ar_accessory_anchor_t p_anchor, uint64_t p_source_device_key, bool p_assign_if_needed) -> int {
			bool is_held = false;
			const ar_accessory_chirality_t chirality = _resolve_accessory_anchor_chirality(p_anchor, &is_held);
			if (chirality == ar_accessory_chirality_left) {
				if (p_source_device_key != 0) {
					const uint64_t current_left_device = accessory_tracking_assigned_device_keys[HAND_INDEX_LEFT];
					const bool left_conflict = current_left_device != 0 && current_left_device != p_source_device_key;
					if (left_conflict && (accessory_tracking_assigned_device_keys[HAND_INDEX_RIGHT] == 0 || accessory_tracking_assigned_device_keys[HAND_INDEX_RIGHT] == p_source_device_key)) {
						assign_device_to_hand(p_source_device_key, HAND_INDEX_RIGHT);
						return HAND_INDEX_RIGHT;
					}
					assign_device_to_hand(p_source_device_key, HAND_INDEX_LEFT);
				}
				return HAND_INDEX_LEFT;
			}
			if (chirality == ar_accessory_chirality_right) {
				if (p_source_device_key != 0) {
					const uint64_t current_right_device = accessory_tracking_assigned_device_keys[HAND_INDEX_RIGHT];
					const bool right_conflict = current_right_device != 0 && current_right_device != p_source_device_key;
					if (right_conflict && (accessory_tracking_assigned_device_keys[HAND_INDEX_LEFT] == 0 || accessory_tracking_assigned_device_keys[HAND_INDEX_LEFT] == p_source_device_key)) {
						assign_device_to_hand(p_source_device_key, HAND_INDEX_LEFT);
						return HAND_INDEX_LEFT;
					}
					assign_device_to_hand(p_source_device_key, HAND_INDEX_RIGHT);
				}
				return HAND_INDEX_RIGHT;
			}

			if (p_source_device_key == 0) {
				return -1;
			}

			const HandIndex *assigned_hand_ptr = accessory_tracking_device_hand_assignments.getptr(p_source_device_key);
			if (assigned_hand_ptr != nullptr) {
				return int(*assigned_hand_ptr);
			}

			if (!p_assign_if_needed) {
				return -1;
			}

			const bool left_free = accessory_tracking_assigned_device_keys[HAND_INDEX_LEFT] == 0;
			const bool right_free = accessory_tracking_assigned_device_keys[HAND_INDEX_RIGHT] == 0;
			HandIndex assigned_hand = HAND_INDEX_LEFT;
			if (left_free && !right_free) {
				assigned_hand = HAND_INDEX_LEFT;
			} else if (!left_free && right_free) {
				assigned_hand = HAND_INDEX_RIGHT;
			} else if (accessory_tracking_stream_states[HAND_INDEX_LEFT].tracked != accessory_tracking_stream_states[HAND_INDEX_RIGHT].tracked) {
				assigned_hand = accessory_tracking_stream_states[HAND_INDEX_LEFT].tracked ? HAND_INDEX_RIGHT : HAND_INDEX_LEFT;
			} else {
				assigned_hand = (p_source_device_key & 1) == 0 ? HAND_INDEX_LEFT : HAND_INDEX_RIGHT;
			}

			assign_device_to_hand(p_source_device_key, assigned_hand);
			return int(assigned_hand);
		};

		auto apply_anchor_update = [&](ar_accessory_anchor_t p_anchor, bool p_removed) {
			if (p_anchor == nullptr) {
				return;
			}

			const uint64_t source_device_key = get_anchor_source_device_key(p_anchor);
			const bool anchor_tracked = ar_accessory_anchor_is_tracked(p_anchor);
			const bool assign_if_needed = !p_removed && anchor_tracked;
			const int hand_index = resolve_hand_index(p_anchor, source_device_key, assign_if_needed);
			if (hand_index < 0 || hand_index >= HAND_INDEX_MAX) {
				return;
			}

			if (p_removed || !anchor_tracked) {
				accessory_tracking_stream_states[hand_index] = SpatialControllerState();
				accessory_tracking_stream_state_timestamp_msec[hand_index] = 0;
				clear_device_assignment(source_device_key);
				return;
			}

			update_spatial_controller_state_from_anchor_to_target(accessory_tracking_stream_states, (HandIndex)hand_index, p_anchor);
			if (accessory_tracking_stream_states[hand_index].tracked) {
				accessory_tracking_stream_state_timestamp_msec[hand_index] = now_msec;
			}
		};

		auto enumerate_anchor_updates = [&](ar_accessory_anchors_t p_anchors, bool p_removed) {
			if (p_anchors == nullptr) {
				return;
			}
			ar_accessory_anchors_enumerate_anchors(p_anchors, ^bool(ar_accessory_anchor_t p_anchor) {
				apply_anchor_update(p_anchor, p_removed);
				return true;
			});
		};

		enumerate_anchor_updates(p_added_anchors, false);
		enumerate_anchor_updates(p_updated_anchors, false);
		enumerate_anchor_updates(ar_accessory_tracking_provider_get_latest_anchors(accessory_tracking_provider), false);
		enumerate_anchor_updates(p_removed_anchors, true);
	});
#endif
}

void VisionOSXRInterface::initialize_accessory_tracking_provider() {
	accessory_tracking_supported = false;
	accessory_tracking_active = false;
	accessory_tracking_needs_session_refresh = false;
	accessory_tracking_load_requests.clear();
	accessory_tracking_device_hand_assignments.clear();
	accessory_tracking_assigned_device_keys[HAND_INDEX_LEFT] = 0;
	accessory_tracking_assigned_device_keys[HAND_INDEX_RIGHT] = 0;
	for (int i = 0; i < HAND_INDEX_MAX; i++) {
		accessory_tracking_stream_states[i] = SpatialControllerState();
		accessory_tracking_stream_state_timestamp_msec[i] = 0;
	}

#if GODOT_VISIONOS_XR_HAS_ACCESSORY_TRACKING
	accessory_tracking_provider = nullptr;
	accessory_tracking_configuration = nullptr;
	accessory_tracking_accessories = nullptr;
	accessory_tracking_predicted_anchor = nullptr;

	if (!_is_runtime_accessory_tracking_available()) {
		return;
	}

	accessory_tracking_supported = ar_accessory_tracking_provider_is_supported();
	if (!accessory_tracking_supported) {
		return;
	}

	accessory_tracking_accessories = ar_accessories_create();
	accessory_tracking_configuration = ar_accessory_tracking_configuration_create();
	if (accessory_tracking_accessories == nullptr || accessory_tracking_configuration == nullptr) {
		accessory_tracking_accessories = nullptr;
		accessory_tracking_configuration = nullptr;
		return;
	}

	ar_accessory_tracking_configuration_set_accessories(accessory_tracking_configuration, accessory_tracking_accessories);
	accessory_tracking_provider = ar_accessory_tracking_provider_create(accessory_tracking_configuration);
	if (accessory_tracking_provider == nullptr) {
		accessory_tracking_configuration = nullptr;
		accessory_tracking_accessories = nullptr;
		return;
	}
	accessory_tracking_predicted_anchor = ar_accessory_anchor_create();

	configure_accessory_tracking_provider_update_handler();

	// The provider requires at least one configured accessory before being added to the session.
	accessory_tracking_active = false;
	accessory_tracking_needs_session_refresh = false;
	// Start discovery immediately so controllers powered on after app launch can still be picked up.
	[GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
#endif
}

void VisionOSXRInterface::update_accessory_tracking_devices() {
#if GODOT_VISIONOS_XR_HAS_ACCESSORY_TRACKING
	if (!accessory_tracking_supported || accessory_tracking_provider == nullptr || accessory_tracking_accessories == nullptr) {
		return;
	}

	HashSet<uint64_t> connected_spatial_accessories;
	NSMutableArray<id<GCDevice>> *devices = [NSMutableArray array];
	[devices addObjectsFromArray:[GCController controllers]];
	if (@available(visionOS 26.0, *)) {
		[devices addObjectsFromArray:[GCStylus styli]];
	}
	for (id<GCDevice> device in devices) {
		if (!_is_spatial_accessory_device(device)) {
			continue;
		}

		const uint64_t controller_key = uint64_t((uintptr_t)(__bridge void *)device);
		connected_spatial_accessories.insert(controller_key);

		if (accessory_tracking_load_requests.has(controller_key)) {
			continue;
		}

		accessory_tracking_load_requests.insert(controller_key);
		ar_accessory_load_from_device(device, ^(id<GCDevice> device, bool successful, ar_error_t error, ar_accessory_t accessory) {
			(void)error;
			dispatch_async(dispatch_get_main_queue(), ^{
				const uint64_t device_key = uint64_t((uintptr_t)(__bridge void *)device);
				if (!successful || accessory == nullptr) {
					accessory_tracking_load_requests.erase(device_key);
					return;
				}
				if (accessory_tracking_accessories != nullptr) {
					ar_accessories_add_accessory(accessory_tracking_accessories, accessory);
					const int configured_accessory_count = int(ar_accessories_get_count(accessory_tracking_accessories));
					accessory_tracking_active = configured_accessory_count > 0;
					accessory_tracking_needs_session_refresh = true;
				}
			});
		});
	}

	// Remove accessories whose source devices are no longer connected.
	ar_accessories_t disconnected_accessories = ar_accessories_create();
	if (disconnected_accessories != nullptr) {
		const HashSet<uint64_t> *connected_spatial_accessories_ptr = &connected_spatial_accessories;
		ar_accessories_enumerate_accessories(accessory_tracking_accessories, ^bool(ar_accessory_t accessory) {
			if (accessory == nullptr) {
				return true;
			}
			id<GCDevice> source_device = ar_accessory_get_source_device(accessory);
			if (source_device == nil || !_is_spatial_accessory_device(source_device)) {
				return true;
			}
			const uint64_t source_key = uint64_t((uintptr_t)(__bridge void *)source_device);
			if (!connected_spatial_accessories_ptr->has(source_key)) {
				ar_accessories_add_accessory(disconnected_accessories, accessory);
			}
			return true;
		});

		if (ar_accessories_get_count(disconnected_accessories) > 0) {
			ar_accessories_remove_accessories(accessory_tracking_accessories, disconnected_accessories);
			accessory_tracking_active = ar_accessories_get_count(accessory_tracking_accessories) > 0;
			accessory_tracking_needs_session_refresh = true;
		}
	}

	Vector<uint64_t> stale_request_keys;
	for (const uint64_t &controller_key : accessory_tracking_load_requests) {
		if (!connected_spatial_accessories.has(controller_key)) {
			stale_request_keys.push_back(controller_key);
		}
	}
	for (const uint64_t &controller_key : stale_request_keys) {
		accessory_tracking_load_requests.erase(controller_key);
	}
	for (int i = 0; i < HAND_INDEX_MAX; i++) {
		const uint64_t assigned_device_key = accessory_tracking_assigned_device_keys[i];
		if (assigned_device_key == 0 || connected_spatial_accessories.has(assigned_device_key)) {
			continue;
		}
		accessory_tracking_assigned_device_keys[i] = 0;
		accessory_tracking_device_hand_assignments.erase(assigned_device_key);
		accessory_tracking_stream_states[i] = SpatialControllerState();
		accessory_tracking_stream_state_timestamp_msec[i] = 0;
	}

	if (connected_spatial_accessories.is_empty() && accessory_tracking_load_requests.is_empty() && ar_accessories_get_count(accessory_tracking_accessories) == 0) {
		static uint64_t next_discovery_retry_msec = 0;
		const uint64_t now_msec = OS::get_singleton()->get_ticks_msec();
		if (now_msec >= next_discovery_retry_msec) {
			[GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
			next_discovery_retry_msec = now_msec + VISIONOS_CONTROLLER_DISCOVERY_RETRY_INTERVAL_MSEC;
		}
	}
#endif
}

void VisionOSXRInterface::update_accessory_tracking_session() {
	if (!accessory_tracking_needs_session_refresh) {
		return;
	}

#if GODOT_VISIONOS_XR_HAS_ACCESSORY_TRACKING
	if (accessory_tracking_accessories == nullptr) {
		accessory_tracking_active = false;
		accessory_tracking_needs_session_refresh = false;
		return;
	}

	const int configured_accessory_count = int(ar_accessories_get_count(accessory_tracking_accessories));
	const bool has_configured_accessories = configured_accessory_count > 0;
	accessory_tracking_active = has_configured_accessories;

	if (has_configured_accessories) {
		ar_accessory_tracking_configuration_t new_configuration = ar_accessory_tracking_configuration_create();
		if (new_configuration == nullptr) {
			accessory_tracking_needs_session_refresh = false;
			return;
		}

		ar_accessory_tracking_configuration_set_accessories(new_configuration, accessory_tracking_accessories);

		ar_accessory_tracking_provider_t new_provider = ar_accessory_tracking_provider_create(new_configuration);
		if (new_provider == nullptr) {
			accessory_tracking_needs_session_refresh = false;
			return;
		}

		accessory_tracking_configuration = new_configuration;
		accessory_tracking_provider = new_provider;
		configure_accessory_tracking_provider_update_handler();
	}

	run_arkit_session_with_active_providers();
#endif

	accessory_tracking_needs_session_refresh = false;
}

void VisionOSXRInterface::uninitialize_accessory_tracking_provider() {
	accessory_tracking_supported = false;
	accessory_tracking_active = false;
	accessory_tracking_needs_session_refresh = false;
	accessory_tracking_load_requests.clear();
	accessory_tracking_device_hand_assignments.clear();
	accessory_tracking_assigned_device_keys[HAND_INDEX_LEFT] = 0;
	accessory_tracking_assigned_device_keys[HAND_INDEX_RIGHT] = 0;
	for (int i = 0; i < HAND_INDEX_MAX; i++) {
		accessory_tracking_stream_states[i] = SpatialControllerState();
		accessory_tracking_stream_state_timestamp_msec[i] = 0;
	}

#if GODOT_VISIONOS_XR_HAS_ACCESSORY_TRACKING
	[GCController stopWirelessControllerDiscovery];
	accessory_tracking_provider = nullptr;
	accessory_tracking_configuration = nullptr;
	accessory_tracking_accessories = nullptr;
	accessory_tracking_predicted_anchor = nullptr;
#endif
}

void VisionOSXRInterface::update_hand_state_from_anchor(HandIndex p_hand_index, ar_hand_anchor_t p_anchor) {
	ERR_FAIL_INDEX(p_hand_index, HAND_INDEX_MAX);

	const float previous_pinch_value = hand_interaction_states[p_hand_index].pinch_value;
	const bool previous_pinch_click = hand_interaction_states[p_hand_index].pinch_click;

	reset_hand_state(p_hand_index);
	HandInteractionState &state = hand_interaction_states[p_hand_index];

	if (p_anchor == nullptr || !ar_hand_anchor_is_tracked(p_anchor)) {
		return;
	}

	state.tracked = true;

	// ARKit joint orientation does not match OpenXR joint orientation directly.
	// Align to OpenXR-style joint frames first, then apply Godot's humanoid rig conversion.
	const Basis arkit_to_openxr_joint_adjustment_left(
			Vector3(0.0f, 0.0f, -1.0f),
			Vector3(0.0f, -1.0f, 0.0f),
			Vector3(-1.0f, 0.0f, 0.0f));
	const Basis arkit_to_openxr_joint_adjustment_right(
			Vector3(0.0f, 0.0f, -1.0f),
			Vector3(0.0f, 1.0f, 0.0f),
			Vector3(1.0f, 0.0f, 0.0f));
	const Basis &arkit_to_openxr_joint_adjustment = (p_hand_index == HAND_INDEX_LEFT) ? arkit_to_openxr_joint_adjustment_left : arkit_to_openxr_joint_adjustment_right;

	const Basis bone_adjustment(
			Vector3(-1.0f, 0.0f, 0.0f),
			Vector3(0.0f, 0.0f, -1.0f),
			Vector3(0.0f, -1.0f, 0.0f));

	const simd_float4x4 origin_from_anchor_simd = ar_hand_anchor_get_origin_from_anchor_transform(p_anchor);
	state.palm_transform = MTL::simd_to_transform3D(origin_from_anchor_simd);
	state.default_transform = state.palm_transform;
	state.aim_transform = state.palm_transform;
	state.grip_transform = state.palm_transform;

	ar_hand_skeleton_t hand_skeleton = ar_hand_anchor_get_hand_skeleton(p_anchor);
	if (hand_skeleton == nullptr) {
		state.joints[XRHandTracker::HAND_JOINT_PALM].tracked = true;
		state.joints[XRHandTracker::HAND_JOINT_PALM].transform = state.palm_transform;
		return;
	}

	ar_hand_skeleton_enumerate_joints(hand_skeleton, ^bool(ar_skeleton_joint_t joint) {
		uint64_t joint_index = ar_skeleton_joint_get_index(joint);
		int xr_joint_index = map_arkit_joint_to_xr_hand_joint(joint_index);
		if (xr_joint_index < 0) {
			return true;
		}

		const simd_float4x4 anchor_from_joint_simd = ar_skeleton_joint_get_anchor_from_joint_transform(joint);
		const simd_float4x4 origin_from_joint_simd = simd_mul(origin_from_anchor_simd, anchor_from_joint_simd);

		HandJointState &joint_state = state.joints[xr_joint_index];
		joint_state.tracked = ar_skeleton_joint_is_tracked(joint);
		joint_state.transform = MTL::simd_to_transform3D(origin_from_joint_simd);
		joint_state.transform.basis.orthonormalize();
		joint_state.transform.basis *= arkit_to_openxr_joint_adjustment;
		joint_state.transform.basis *= bone_adjustment;
		joint_state.radius = 0.01f;

		state.has_joint_data = true;
		return true;
	});

	const HandJointState &middle_metacarpal = state.joints[XRHandTracker::HAND_JOINT_MIDDLE_FINGER_METACARPAL];
	const HandJointState &middle_proximal = state.joints[XRHandTracker::HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL];
	HandJointState &palm = state.joints[XRHandTracker::HAND_JOINT_PALM];
	if (middle_metacarpal.tracked && middle_proximal.tracked) {
		palm.tracked = true;
		palm.transform = middle_metacarpal.transform;
		palm.transform.origin = (middle_metacarpal.transform.origin + middle_proximal.transform.origin) * 0.5f;
	} else {
		palm.tracked = true;
		palm.transform = state.palm_transform;
	}
	palm.radius = 0.01f;
	state.palm_transform = palm.transform;

	const HandJointState &wrist = state.joints[XRHandTracker::HAND_JOINT_WRIST];
	if (wrist.tracked) {
		state.grip_transform = wrist.transform;
	} else {
		state.grip_transform = state.palm_transform;
	}

	const HandJointState &index_knuckle = state.joints[XRHandTracker::HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL];
	const HandJointState &index_tip = state.joints[XRHandTracker::HAND_JOINT_INDEX_FINGER_TIP];
	state.aim_transform = make_aim_transform_from_hand(state.grip_transform, index_knuckle.transform, index_knuckle.tracked, index_tip.transform, index_tip.tracked);
	state.default_transform = state.aim_transform;

	const HandJointState &thumb_tip = state.joints[XRHandTracker::HAND_JOINT_THUMB_TIP];
	if (thumb_tip.tracked && index_tip.tracked) {
		const float distance = thumb_tip.transform.origin.distance_to(index_tip.transform.origin);
		const float raw_pinch = CLAMP((VISIONOS_PINCH_ANALOG_MAX_DISTANCE_M - distance) / (VISIONOS_PINCH_ANALOG_MAX_DISTANCE_M - VISIONOS_PINCH_PRESS_DISTANCE_M), 0.0f, 1.0f);
		state.pinch_value = Math::lerp(previous_pinch_value, raw_pinch, VISIONOS_PINCH_SMOOTHING_FACTOR);
		state.pinch_click = previous_pinch_click ? distance < VISIONOS_PINCH_RELEASE_DISTANCE_M : distance < VISIONOS_PINCH_PRESS_DISTANCE_M;
	} else {
		state.pinch_value = 0.0f;
		state.pinch_click = false;
	}

	// Map grasp to a pinch proxy for now, but saturate the analog value when click is active
	// so grip-threshold based gameplay (e.g. XR Tools pickup) can trigger reliably.
	state.grasp_value = state.pinch_click ? 1.0f : state.pinch_value;
	state.grasp_click = state.pinch_click;
}

void VisionOSXRInterface::update_hand_states_from_arkit(CFTimeInterval p_prediction_timestamp) {
	if (!hand_tracking_active || hand_tracking_provider == nullptr || current_left_hand_anchor == nullptr || current_right_hand_anchor == nullptr) {
		reset_hand_state(HAND_INDEX_LEFT);
		reset_hand_state(HAND_INDEX_RIGHT);
		return;
	}
	if (!_is_hand_tracking_provider_running(hand_tracking_provider)) {
		reset_hand_state(HAND_INDEX_LEFT);
		reset_hand_state(HAND_INDEX_RIGHT);
		return;
	}

	bool got_hand_anchors = false;
	if (@available(visionOS 2.0, *)) {
		got_hand_anchors = ar_hand_tracking_provider_query_anchors_at_timestamp(hand_tracking_provider, p_prediction_timestamp, current_left_hand_anchor, current_right_hand_anchor) == ar_hand_anchor_query_status_success;
	}
	if (!got_hand_anchors) {
		got_hand_anchors = ar_hand_tracking_provider_get_latest_anchors(hand_tracking_provider, current_left_hand_anchor, current_right_hand_anchor);
	}
	if (!got_hand_anchors) {
		reset_hand_state(HAND_INDEX_LEFT);
		reset_hand_state(HAND_INDEX_RIGHT);
		return;
	}

	update_hand_state_from_anchor(HAND_INDEX_LEFT, current_left_hand_anchor);
	update_hand_state_from_anchor(HAND_INDEX_RIGHT, current_right_hand_anchor);
}

void VisionOSXRInterface::update_spatial_controller_states_from_arkit(CFTimeInterval p_prediction_timestamp) {
	reset_spatial_controller_state(HAND_INDEX_LEFT);
	reset_spatial_controller_state(HAND_INDEX_RIGHT);

#if GODOT_VISIONOS_XR_HAS_ACCESSORY_TRACKING
	if (!accessory_tracking_active || accessory_tracking_provider == nullptr || !_is_runtime_accessory_tracking_available()) {
		return;
	}

	if (!_is_accessory_tracking_provider_running(accessory_tracking_provider)) {
		return;
	}

	ar_accessory_anchors_t latest_anchors = ar_accessory_tracking_provider_get_latest_anchors(accessory_tracking_provider);
	if (latest_anchors == nullptr) {
		return;
	}
	ar_accessory_anchor_t predicted_anchor = accessory_tracking_predicted_anchor;
	ar_accessory_anchors_enumerate_anchors(latest_anchors, ^bool(ar_accessory_anchor_t accessory_anchor) {
		if (accessory_anchor == nullptr) {
			return true;
		}
		if (!ar_accessory_anchor_is_tracked(accessory_anchor)) {
			return true;
		}

		ar_accessory_anchor_t sampled_anchor = accessory_anchor;
		if (predicted_anchor != nullptr) {
			const bool has_predicted_anchor = ar_accessory_tracking_provider_predict_anchor_at_timestamp(accessory_tracking_provider, accessory_anchor, p_prediction_timestamp, predicted_anchor);
			if (has_predicted_anchor && ar_accessory_anchor_is_tracked(predicted_anchor)) {
				sampled_anchor = predicted_anchor;
			}
		}

		const ar_accessory_chirality_t chirality = _resolve_accessory_anchor_chirality(sampled_anchor);

		switch (chirality) {
			case ar_accessory_chirality_left:
				update_spatial_controller_state_from_anchor(HAND_INDEX_LEFT, sampled_anchor);
				break;
			case ar_accessory_chirality_right:
				update_spatial_controller_state_from_anchor(HAND_INDEX_RIGHT, sampled_anchor);
				break;
			case ar_accessory_chirality_unspecified:
			default:
				break;
		}
		return true;
	});

	const uint64_t now_msec = OS::get_singleton()->get_ticks_msec();
	for (int i = 0; i < HAND_INDEX_MAX; i++) {
		if (spatial_controller_states[i].tracked) {
			continue;
		}
		const uint64_t last_update_msec = accessory_tracking_stream_state_timestamp_msec[i];
		if (last_update_msec == 0 || now_msec < last_update_msec) {
			continue;
		}
		const uint64_t age_msec = now_msec - last_update_msec;
		if (age_msec > VISIONOS_CONTROLLER_STREAM_FALLBACK_MAX_AGE_MSEC) {
			continue;
		}
		if (!accessory_tracking_stream_states[i].tracked) {
			continue;
		}
		spatial_controller_states[i] = accessory_tracking_stream_states[i];
	}
#endif
}

#if GODOT_VISIONOS_XR_HAS_ACCESSORY_TRACKING
void VisionOSXRInterface::update_spatial_controller_state_from_anchor(HandIndex p_hand_index, ar_accessory_anchor_t p_anchor) {
	update_spatial_controller_state_from_anchor_to_target(spatial_controller_states, p_hand_index, p_anchor);
}

void VisionOSXRInterface::update_spatial_controller_state_from_anchor_to_target(SpatialControllerState p_target_states[HAND_INDEX_MAX], HandIndex p_hand_index, ar_accessory_anchor_t p_anchor) {
	ERR_FAIL_NULL(p_target_states);
	ERR_FAIL_INDEX(p_hand_index, HAND_INDEX_MAX);
	ERR_FAIL_NULL(p_anchor);

	if (!_is_runtime_accessory_tracking_available() || !ar_accessory_anchor_is_tracked(p_anchor)) {
		return;
	}

	const ar_accessory_anchor_tracking_state_t tracking_state = ar_accessory_anchor_get_tracking_state(p_anchor);
	const int tracking_rank = _accessory_tracking_rank(tracking_state);
	if (tracking_rank <= 0) {
		return;
	}

	SpatialControllerState &state = p_target_states[p_hand_index];
	if (tracking_rank < state.tracking_rank) {
		return;
	}

	const simd_float4x4 origin_from_anchor_simd = ar_accessory_anchor_get_origin_from_anchor_transform_with_correction(p_anchor, ar_transform_correction_rendered);
	const Transform3D origin_from_anchor = MTL::simd_to_transform3D(origin_from_anchor_simd);
	if (!origin_from_anchor.is_finite()) {
		return;
	}

	state = SpatialControllerState();
	state.tracked = true;
	state.tracking_rank = tracking_rank;
	state.default_transform = origin_from_anchor;
	state.aim_transform = origin_from_anchor;
	state.grip_transform = origin_from_anchor;
	state.skeleton_transform = origin_from_anchor;
	state.linear_velocity = _simd_to_vector3(ar_accessory_anchor_get_velocity(p_anchor));
	state.angular_velocity = _simd_to_vector3(ar_accessory_anchor_get_angular_velocity(p_anchor));

	Transform3D grip_surface_transform;
	if (_get_accessory_location_transform(p_anchor, ar_accessory_location_name_grip_surface, grip_surface_transform)) {
		state.grip_transform = grip_surface_transform;
	} else {
		Transform3D grip_transform;
		if (_get_accessory_location_transform(p_anchor, ar_accessory_location_name_grip, grip_transform)) {
			state.grip_transform = grip_transform;
		}
	}

	Transform3D aim_transform;
	if (_get_accessory_location_transform(p_anchor, ar_accessory_location_name_aim, aim_transform)) {
		state.aim_transform = aim_transform;
	}

	state.default_transform = state.grip_transform;
	state.skeleton_transform = state.grip_transform;

	ar_accessory_t accessory = ar_accessory_anchor_get_accessory(p_anchor);
	if (accessory == nullptr) {
		return;
	}

	id<GCDevice> source_device = ar_accessory_get_source_device(accessory);
	if (!_is_spatial_accessory_device(source_device)) {
		return;
	}

	const bool is_left = p_hand_index == HAND_INDEX_LEFT;
	if (_is_spatial_controller_device(source_device)) {
		GCPhysicalInputProfile *physical_input_profile = nil;
		if ([source_device respondsToSelector:@selector(physicalInputProfile)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
			physical_input_profile = source_device.physicalInputProfile;
#pragma clang diagnostic pop
		}
		if (physical_input_profile == nil && [source_device isKindOfClass:[GCController class]]) {
			physical_input_profile = ((GCController *)source_device).physicalInputProfile;
		}
		if (physical_input_profile == nil) {
			return;
		}

		NSString *trigger_fallback_name = is_left ? GCInputLeftTrigger : GCInputRightTrigger;
		NSString *grip_fallback_name = is_left ? GCInputLeftShoulder : GCInputRightShoulder;
		NSString *bumper_fallback_name = is_left ? GCInputLeftBumper : GCInputRightBumper;
		NSString *thumbstick_axis_fallback_name = is_left ? GCInputLeftThumbstick : GCInputRightThumbstick;
		NSString *thumbstick_button_fallback_name = is_left ? GCInputLeftThumbstickButton : GCInputRightThumbstickButton;
		NSString *ax_primary_name = is_left ? GCInputButtonX : GCInputButtonA;
		NSString *ax_fallback_name = is_left ? GCInputButtonA : GCInputButtonX;
		NSString *by_primary_name = is_left ? GCInputButtonY : GCInputButtonB;
		NSString *by_fallback_name = is_left ? GCInputButtonB : GCInputButtonY;

		float button_value = 0.0f;
		bool button_pressed = false;
		bool button_touched = false;

		const bool has_trigger = _read_button_state_any(physical_input_profile, { GCInputTrigger, trigger_fallback_name }, button_value, button_pressed, &button_touched);
		if (has_trigger) {
			state.trigger_value = button_value;
			state.trigger_click = button_pressed || button_value >= 0.5f;
			state.trigger_touch = button_touched || state.trigger_click || button_value > 0.01f;
		}

		const bool has_grip = _read_button_state_any(physical_input_profile, { GCInputGripButton, grip_fallback_name, bumper_fallback_name }, button_value, button_pressed, &button_touched);
		if (has_grip) {
			state.grip_value = button_value;
			state.grip_click = button_pressed || button_value >= 0.5f;
		}

		const bool has_primary_axis = _read_directional_input(physical_input_profile, GCInputThumbstick, state.primary_value) ||
				_read_directional_input(physical_input_profile, thumbstick_axis_fallback_name, state.primary_value);
		if (!has_primary_axis) {
			_read_directional_input(physical_input_profile, GCInputDirectionPad, state.primary_value);
		}
		state.thumbstick_dpad_up = state.primary_value.y >= VISIONOS_DPAD_THRESHOLD;
		state.thumbstick_dpad_down = state.primary_value.y <= -VISIONOS_DPAD_THRESHOLD;
		state.thumbstick_dpad_left = state.primary_value.x <= -VISIONOS_DPAD_THRESHOLD;
		state.thumbstick_dpad_right = state.primary_value.x >= VISIONOS_DPAD_THRESHOLD;

		const bool has_primary_click = _read_button_state_any(physical_input_profile, { GCInputThumbstickButton, thumbstick_button_fallback_name }, button_value, button_pressed, &button_touched);
		if (has_primary_click) {
			state.primary_click = button_pressed || button_value >= 0.5f;
			state.primary_touch = button_touched || state.primary_click || button_value > 0.01f;
		} else {
			state.primary_touch = state.primary_value.length() > 0.01f;
		}

		const bool has_ax = _read_button_state_any(physical_input_profile, { ax_primary_name, ax_fallback_name }, button_value, button_pressed, &button_touched);
		if (has_ax) {
			state.ax_click = button_pressed || button_value >= 0.5f;
			state.ax_touch = button_touched || state.ax_click || button_value > 0.01f;
		}

		const bool has_by = _read_button_state_any(physical_input_profile, { by_primary_name, by_fallback_name }, button_value, button_pressed, &button_touched);
		if (has_by) {
			state.by_click = button_pressed || button_value >= 0.5f;
			state.by_touch = button_touched || state.by_click || button_value > 0.01f;
		}

		if (_read_button_state_any(physical_input_profile, { GCInputButtonMenu, GCInputButtonOptions, GCInputButtonHome, GCInputButtonShare }, button_value, button_pressed)) {
			state.menu_click = button_pressed || button_value >= 0.5f;
		}

		state.has_extended_inputs = has_trigger || has_grip || has_primary_axis || has_primary_click || has_ax || has_by;
		state.select_click = state.has_extended_inputs ? false : (state.trigger_click || state.primary_click);
		return;
	}

	if (_is_spatial_stylus_device(source_device)) {
		id<GCDevicePhysicalInputState> stylus_input_state = nil;
		if (@available(visionOS 26.0, *)) {
			if ([source_device isKindOfClass:[GCStylus class]]) {
				stylus_input_state = ((GCStylus *)source_device).input;
			}
		}
		if (stylus_input_state == nil) {
			return;
		}

		float button_value = 0.0f;
		float button_force = 0.0f;
		bool button_pressed = false;
		bool button_touched = false;

		const bool has_tip = _read_device_button_state_any(stylus_input_state, { GCInputStylusTip }, button_value, button_pressed, &button_touched, &button_force);
		if (has_tip) {
			const float tip_value = MAX(button_value, button_force);
			state.trigger_value = tip_value;
			state.trigger_click = button_pressed || tip_value >= 0.5f;
			state.trigger_touch = button_touched || state.trigger_click || tip_value > 0.01f;
		}

		const bool has_primary_button = _read_device_button_state_any(stylus_input_state, { GCInputStylusPrimaryButton }, button_value, button_pressed, &button_touched, &button_force);
		if (has_primary_button) {
			const float primary_value = MAX(button_value, button_force);
			state.primary_click = button_pressed || primary_value >= 0.5f;
			state.primary_touch = button_touched || state.primary_click || primary_value > 0.01f;
			state.ax_click = state.primary_click;
			state.ax_touch = state.primary_touch;
			state.grip_value = primary_value;
			state.grip_click = state.primary_click;
		}

		const bool has_secondary_button = _read_device_button_state_any(stylus_input_state, { GCInputStylusSecondaryButton }, button_value, button_pressed, &button_touched, &button_force);
		if (has_secondary_button) {
			const float secondary_value = MAX(button_value, button_force);
			state.secondary_click = button_pressed || secondary_value >= 0.5f;
			state.secondary_touch = button_touched || state.secondary_click || secondary_value > 0.01f;
			state.by_click = state.secondary_click;
			state.by_touch = state.secondary_touch;
		}

		state.has_extended_inputs = has_tip || has_primary_button || has_secondary_button;
		state.select_click = state.trigger_click || state.primary_click || state.secondary_click;
	}
}
#endif

void VisionOSXRInterface::apply_hand_states_to_trackers() {
	const float tracking_floor_offset = get_tracking_floor_offset();
	auto apply_floor_offset = [tracking_floor_offset](const Transform3D &p_transform) -> Transform3D {
		Transform3D adjusted = p_transform;
		adjusted.origin.y += tracking_floor_offset;
		return adjusted;
	};

	for (int i = 0; i < HAND_INDEX_MAX; i++) {
		const HandInteractionState &hand_state = hand_interaction_states[i];
		const SpatialControllerState &controller_state = spatial_controller_states[i];
		const bool use_controller_state = controller_state.tracked;
		const Ref<XRControllerTracker> &controller_tracker = hand_controller_trackers[i];
		const Ref<XRHandTracker> &hand_tracker = hand_trackers[i];

		if (controller_tracker.is_valid()) {
			if (use_controller_state) {
				const XRPose::TrackingConfidence tracking_confidence = controller_state.tracking_rank >= 3 ? XRPose::XR_TRACKING_CONFIDENCE_HIGH : XRPose::XR_TRACKING_CONFIDENCE_LOW;
				controller_tracker->set_tracker_profile(controller_state.has_extended_inputs ? VISIONOS_INTERACTION_PROFILE_OCULUS_TOUCH : VISIONOS_INTERACTION_PROFILE_SIMPLE_CONTROLLER);
				controller_tracker->set_pose(SNAME("default"), apply_floor_offset(controller_state.default_transform), controller_state.linear_velocity, controller_state.angular_velocity, tracking_confidence);
				controller_tracker->set_pose(SNAME("aim"), apply_floor_offset(controller_state.aim_transform), controller_state.linear_velocity, controller_state.angular_velocity, tracking_confidence);
				controller_tracker->set_pose(SNAME("grip"), apply_floor_offset(controller_state.grip_transform), controller_state.linear_velocity, controller_state.angular_velocity, tracking_confidence);
				controller_tracker->set_pose(SNAME("pose"), apply_floor_offset(controller_state.grip_transform), controller_state.linear_velocity, controller_state.angular_velocity, tracking_confidence);
				controller_tracker->set_pose(SNAME("skeleton"), apply_floor_offset(controller_state.skeleton_transform), controller_state.linear_velocity, controller_state.angular_velocity, tracking_confidence);
			} else if (hand_state.tracked) {
				controller_tracker->set_tracker_profile(VISIONOS_INTERACTION_PROFILE_HAND);
				controller_tracker->set_pose(SNAME("default"), apply_floor_offset(hand_state.default_transform), Vector3(), Vector3(), XRPose::XR_TRACKING_CONFIDENCE_HIGH);
				controller_tracker->set_pose(SNAME("aim"), apply_floor_offset(hand_state.aim_transform), Vector3(), Vector3(), XRPose::XR_TRACKING_CONFIDENCE_HIGH);
				controller_tracker->set_pose(SNAME("grip"), apply_floor_offset(hand_state.grip_transform), Vector3(), Vector3(), XRPose::XR_TRACKING_CONFIDENCE_HIGH);
				controller_tracker->set_pose(SNAME("pose"), apply_floor_offset(hand_state.grip_transform), Vector3(), Vector3(), XRPose::XR_TRACKING_CONFIDENCE_HIGH);
				controller_tracker->set_pose(SNAME("skeleton"), apply_floor_offset(hand_state.palm_transform), Vector3(), Vector3(), XRPose::XR_TRACKING_CONFIDENCE_HIGH);
			} else {
				controller_tracker->set_tracker_profile(VISIONOS_INTERACTION_PROFILE_NONE);
				controller_tracker->invalidate_pose(SNAME("default"));
				controller_tracker->invalidate_pose(SNAME("aim"));
				controller_tracker->invalidate_pose(SNAME("grip"));
				controller_tracker->invalidate_pose(SNAME("pose"));
				controller_tracker->invalidate_pose(SNAME("skeleton"));
			}

			if (use_controller_state) {
				controller_tracker->set_input(SNAME("trigger"), controller_state.trigger_value);
				controller_tracker->set_input(SNAME("trigger_click"), controller_state.trigger_click);
				controller_tracker->set_input(SNAME("trigger_touch"), controller_state.trigger_touch);
				controller_tracker->set_input(SNAME("primary"), controller_state.primary_value);
				controller_tracker->set_input(SNAME("primary_click"), controller_state.primary_click);
				controller_tracker->set_input(SNAME("primary_touch"), controller_state.primary_touch);
				controller_tracker->set_input(SNAME("thumbstick_dpad_up"), controller_state.thumbstick_dpad_up);
				controller_tracker->set_input(SNAME("thumbstick_dpad_down"), controller_state.thumbstick_dpad_down);
				controller_tracker->set_input(SNAME("thumbstick_dpad_left"), controller_state.thumbstick_dpad_left);
				controller_tracker->set_input(SNAME("thumbstick_dpad_right"), controller_state.thumbstick_dpad_right);
				controller_tracker->set_input(SNAME("primary_dpad_up"), controller_state.thumbstick_dpad_up);
				controller_tracker->set_input(SNAME("primary_dpad_down"), controller_state.thumbstick_dpad_down);
				controller_tracker->set_input(SNAME("primary_dpad_left"), controller_state.thumbstick_dpad_left);
				controller_tracker->set_input(SNAME("primary_dpad_right"), controller_state.thumbstick_dpad_right);
				controller_tracker->set_input(SNAME("secondary"), controller_state.secondary_value);
				controller_tracker->set_input(SNAME("secondary_click"), controller_state.secondary_click);
				controller_tracker->set_input(SNAME("secondary_touch"), controller_state.secondary_touch);
				controller_tracker->set_input(SNAME("grip"), controller_state.grip_value);
				controller_tracker->set_input(SNAME("grip_click"), controller_state.grip_click);
				controller_tracker->set_input(SNAME("menu_button"), controller_state.menu_click);
				controller_tracker->set_input(SNAME("ax_button"), controller_state.ax_click);
				controller_tracker->set_input(SNAME("ax_touch"), controller_state.ax_touch);
				controller_tracker->set_input(SNAME("by_button"), controller_state.by_click);
				controller_tracker->set_input(SNAME("by_touch"), controller_state.by_touch);
				controller_tracker->set_input(SNAME("select_button"), controller_state.select_click);
			} else {
				controller_tracker->set_input(SNAME("trigger"), hand_state.pinch_value);
				controller_tracker->set_input(SNAME("trigger_click"), hand_state.pinch_click);
				controller_tracker->set_input(SNAME("trigger_touch"), hand_state.pinch_click);
				controller_tracker->set_input(SNAME("primary"), hand_state.pinch_value);
				controller_tracker->set_input(SNAME("primary_click"), hand_state.pinch_click);
				controller_tracker->set_input(SNAME("primary_touch"), hand_state.pinch_click);
				controller_tracker->set_input(SNAME("thumbstick_dpad_up"), false);
				controller_tracker->set_input(SNAME("thumbstick_dpad_down"), false);
				controller_tracker->set_input(SNAME("thumbstick_dpad_left"), false);
				controller_tracker->set_input(SNAME("thumbstick_dpad_right"), false);
				controller_tracker->set_input(SNAME("primary_dpad_up"), false);
				controller_tracker->set_input(SNAME("primary_dpad_down"), false);
				controller_tracker->set_input(SNAME("primary_dpad_left"), false);
				controller_tracker->set_input(SNAME("primary_dpad_right"), false);
				controller_tracker->set_input(SNAME("secondary"), Vector2());
				controller_tracker->set_input(SNAME("secondary_click"), false);
				controller_tracker->set_input(SNAME("secondary_touch"), false);
				controller_tracker->set_input(SNAME("grip"), hand_state.grasp_value);
				controller_tracker->set_input(SNAME("grip_click"), hand_state.grasp_click);
				controller_tracker->set_input(SNAME("menu_button"), false);
				controller_tracker->set_input(SNAME("ax_button"), false);
				controller_tracker->set_input(SNAME("ax_touch"), false);
				controller_tracker->set_input(SNAME("by_button"), false);
				controller_tracker->set_input(SNAME("by_touch"), false);
				controller_tracker->set_input(SNAME("select_button"), hand_state.pinch_click);
			}
		}

		if (hand_tracker.is_valid()) {
			if (hand_state.tracked && hand_state.has_joint_data && !use_controller_state) {
				hand_tracker->set_has_tracking_data(true);
				hand_tracker->set_hand_tracking_source(XRHandTracker::HAND_TRACKING_SOURCE_UNOBSTRUCTED);
				for (int joint = 0; joint < XRHandTracker::HAND_JOINT_MAX; joint++) {
					const HandJointState &joint_state = hand_state.joints[joint];
					BitField<XRHandTracker::HandJointFlags> flags;
					if (joint_state.tracked) {
						flags.set_flag(XRHandTracker::HAND_JOINT_FLAG_ORIENTATION_VALID);
						flags.set_flag(XRHandTracker::HAND_JOINT_FLAG_POSITION_VALID);
						flags.set_flag(XRHandTracker::HAND_JOINT_FLAG_ORIENTATION_TRACKED);
						flags.set_flag(XRHandTracker::HAND_JOINT_FLAG_POSITION_TRACKED);
					}
					hand_tracker->set_hand_joint_flags((XRHandTracker::HandJoint)joint, flags);
					hand_tracker->set_hand_joint_transform((XRHandTracker::HandJoint)joint, apply_floor_offset(joint_state.transform));
					hand_tracker->set_hand_joint_radius((XRHandTracker::HandJoint)joint, joint_state.radius);
					hand_tracker->set_hand_joint_linear_velocity((XRHandTracker::HandJoint)joint, Vector3());
					hand_tracker->set_hand_joint_angular_velocity((XRHandTracker::HandJoint)joint, Vector3());
				}

				if (hand_state.joints[XRHandTracker::HAND_JOINT_PALM].tracked) {
					hand_tracker->set_pose(SNAME("default"), apply_floor_offset(hand_state.palm_transform), Vector3(), Vector3(), XRPose::XR_TRACKING_CONFIDENCE_HIGH);
				} else {
					hand_tracker->invalidate_pose(SNAME("default"));
				}
			} else {
				hand_tracker->set_has_tracking_data(false);
				hand_tracker->set_hand_tracking_source(XRHandTracker::HAND_TRACKING_SOURCE_NOT_TRACKED);
				hand_tracker->invalidate_pose(SNAME("default"));
				for (int joint = 0; joint < XRHandTracker::HAND_JOINT_MAX; joint++) {
					hand_tracker->set_hand_joint_flags((XRHandTracker::HandJoint)joint, BitField<XRHandTracker::HandJointFlags>());
				}
			}
		}
	}
}

StringName VisionOSXRInterface::get_name() const {
	return VisionOSXRInterface::name;
}

uint32_t VisionOSXRInterface::get_capabilities() const {
	return XRInterface::XR_VR + XRInterface::XR_AR + XRInterface::XR_STEREO;
}

PackedStringArray VisionOSXRInterface::get_suggested_tracker_names() const {
	return PackedStringArray{
		"head",
		"left_hand",
		"right_hand",
		"/user/hand_tracker/left",
		"/user/hand_tracker/right",
	};
}

XRInterface::TrackingStatus VisionOSXRInterface::get_tracking_status() const {
	return tracking_state;
}

bool VisionOSXRInterface::is_initialized() const {
	return (initialized);
}

bool VisionOSXRInterface::initialize() {
	if (![NSThread isMainThread]) {
		__block bool initialized_on_main = false;
		dispatch_sync(dispatch_get_main_queue(), ^{
			initialized_on_main = initialize();
		});
		return initialized_on_main;
	}

	if (initialized) {
		ERR_PRINT("VisionOSXRInterface already initialized");
		return true;
	}

	tracking_state = XRInterface::XR_NOT_TRACKING;
	reset_tracking_floor_reference();

	XRServer *xr_server = XRServer::get_singleton();
	ERR_FAIL_NULL_V(xr_server, false);

	String driver_name = OS::get_singleton()->get_current_rendering_driver_name().to_lower();
	ERR_FAIL_COND_V_MSG(driver_name != "metal", false, "The visionOS XR interface requires the Metal rendering driver.");

	GDTRenderMode app_delegate_render_mode = GDTAppDelegateServiceVisionOS.renderMode;
	ERR_FAIL_COND_V_MSG(app_delegate_render_mode != GDTRenderModeCompositorServices, false, "The visionOS XR interface requires GDTRenderModeCompositorServices render mode.");

	layer_renderer = GDTAppDelegateServiceVisionOS.layerRenderer;
	layer_renderer_capabilities = GDTAppDelegateServiceVisionOS.layerRendererCapabilities;

	ERR_FAIL_NULL_V_MSG(layer_renderer, false, "GDTAppDelegateServiceVisionOS.layerRenderer not set");
	ERR_FAIL_NULL_V_MSG(layer_renderer_capabilities, false, "GDTAppDelegateServiceVisionOS.layerRendererCapabilities not set");

	// ARKit session initialization
	ar_session = ar_session_create();
	ar_world_tracking_configuration_t world_tracking_configuration = ar_world_tracking_configuration_create();
	world_tracking_provider = ar_world_tracking_provider_create(world_tracking_configuration);
	current_device_anchor = ar_device_anchor_create();

	hand_tracking_supported = ar_hand_tracking_provider_is_supported();
	hand_tracking_active = false;
	hand_tracking_provider = nullptr;
	current_left_hand_anchor = nullptr;
	current_right_hand_anchor = nullptr;

	if (hand_tracking_supported) {
		ar_hand_tracking_configuration_t hand_tracking_configuration = ar_hand_tracking_configuration_create();
		hand_tracking_provider = ar_hand_tracking_provider_create(hand_tracking_configuration);
		if (hand_tracking_provider != nullptr) {
			current_left_hand_anchor = ar_hand_anchor_create();
			current_right_hand_anchor = ar_hand_anchor_create();

			if (current_left_hand_anchor != nullptr && current_right_hand_anchor != nullptr) {
				hand_tracking_active = true;
			} else {
				hand_tracking_provider = nullptr;
				current_left_hand_anchor = nullptr;
				current_right_hand_anchor = nullptr;
			}
		}
	}

	initialize_accessory_tracking_provider();
	configure_arkit_session_authorization_and_state_handlers();
	accessory_tracking_needs_session_refresh = false;

	// Head tracker initialization
	head_tracker.instantiate();
	head_tracker->set_tracker_type(XRServer::TRACKER_HEAD);
	head_tracker->set_tracker_name("head");
	head_tracker->set_tracker_desc("Device head pose");
	xr_server->add_tracker(head_tracker);

	initialize_interaction_trackers(xr_server);

	// RenderThread
	rendering_server = RenderingServer::get_singleton();
	ERR_FAIL_NULL_V(rendering_server, false);
	rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::initialize));

	float minimum_supported_near_plane = cp_layer_renderer_capabilities_supported_minimum_near_plane_distance(layer_renderer_capabilities);
	rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::set_minimum_supported_near_plane).bind(minimum_supported_near_plane));

	// Detect immersion style from Info.plist to set environment blend mode
	// and auto-enable transparent background for mixed immersion passthrough.
	NSDictionary *info_plist = [[NSBundle mainBundle] infoDictionary];
	NSDictionary *scene_manifest = info_plist[@"UIApplicationSceneManifest"];
	if (scene_manifest != nil) {
		NSDictionary *scene_configs = scene_manifest[@"UISceneConfigurations"];
		if (scene_configs != nil) {
			NSArray *cp_configs = scene_configs[@"CPSceneSessionRoleImmersiveSpaceApplication"];
			if (cp_configs == nil) {
				cp_configs = scene_configs[@"UISceneSessionRoleImmersiveSpaceApplication"];
			}
			if (cp_configs != nil && [cp_configs count] > 0) {
				NSString *immersion_style = cp_configs[0][@"UISceneInitialImmersionStyle"];
				if (immersion_style != nil && [immersion_style isEqualToString:@"UIImmersionStyleFull"]) {
					environment_blend_mode = XR_ENV_BLEND_MODE_OPAQUE;
				} else {
					environment_blend_mode = XR_ENV_BLEND_MODE_ALPHA_BLEND;
				}
			}
		}
	}

	if (environment_blend_mode == XR_ENV_BLEND_MODE_ALPHA_BLEND) {
		// For mixed immersion, visionOS requires alpha=0 where depth=0 for correct
		// passthrough compositing. Enable transparent background on the main viewport.
		Window *main_vp = SceneTree::get_singleton() ? SceneTree::get_singleton()->get_root() : nullptr;
		if (main_vp != nullptr) {
			main_vp->set_transparent_background(true);
			print_verbose("visionOS: Mixed immersion detected, enabled transparent background for passthrough.");
		}
	}

	// Make this our primary interface
	xr_server->set_primary_interface(this);

	initialized = true;
	return initialized;
}

void VisionOSXRInterface::uninitialize() {
	if (![NSThread isMainThread]) {
		dispatch_sync(dispatch_get_main_queue(), ^{
			uninitialize();
		});
		return;
	}

	if (!initialized) {
		return;
	}

	reset_tracking_floor_reference();

	if (rendering_server != nullptr) {
		rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::uninitialize));
	}

	if (ar_session != nullptr) {
		ar_session_stop(ar_session);
	}

	uninitialize_accessory_tracking_provider();

	hand_tracking_supported = false;
	hand_tracking_active = false;
	hand_tracking_provider = nullptr;
	current_left_hand_anchor = nullptr;
	current_right_hand_anchor = nullptr;
	current_device_anchor = nullptr;
	world_tracking_provider = nullptr;
	ar_session = nullptr;
	tracking_state = XRInterface::XR_NOT_TRACKING;

	XRServer *xr_server = XRServer::get_singleton();
	if (xr_server != nullptr) {
		uninitialize_interaction_trackers(xr_server);

		if (head_tracker.is_valid()) {
			xr_server->remove_tracker(head_tracker);
			head_tracker.unref();
		}

		if (xr_server->get_primary_interface() == this) {
			// no longer our primary interface
			xr_server->set_primary_interface(nullptr);
		}
	} else {
		if (head_tracker.is_valid()) {
			head_tracker.unref();
		}

		for (int i = 0; i < HAND_INDEX_MAX; i++) {
			hand_controller_trackers[i].unref();
			hand_trackers[i].unref();
			reset_hand_state((HandIndex)i);
			reset_spatial_controller_state((HandIndex)i);
		}
	}

	initialized = false;
}

void VisionOSXRInterface::RenderThread::initialize() {
	ERR_NOT_ON_RENDER_THREAD;
	rendering_device = RenderingDevice::get_singleton();

	current_device_anchor = ar_device_anchor_create();
	has_valid_device_anchor = false;
	has_valid_origin_from_head = false;
	origin_from_head = Transform3D();

	initialized = true;
}

void VisionOSXRInterface::RenderThread::uninitialize() {
	ERR_NOT_ON_RENDER_THREAD;
	if (current_color_texture_id != RID()) {
		rendering_device->texture_owner.free(current_color_texture_id);
	}
	if (current_depth_texture_id != RID()) {
		rendering_device->texture_owner.free(current_depth_texture_id);
	}
	if (current_rasterization_rate_map_id != RID()) {
		rendering_device->texture_owner.free(current_rasterization_rate_map_id);
	}
	current_frame = nullptr;
	current_drawable = nullptr;
	current_view_count = 2;
	current_device_anchor = nullptr;
	has_valid_device_anchor = false;
	has_valid_origin_from_head = false;
	origin_from_head = Transform3D();
	initialized = false;
}

void VisionOSXRInterface::update_layer_renderer(cp_layer_renderer_t p_layer_renderer, cp_layer_renderer_capabilities_t p_layer_renderer_capabilities) {
	layer_renderer = p_layer_renderer;
	layer_renderer_capabilities = p_layer_renderer_capabilities;

	if (rendering_server) {
		float minimum_supported_near_plane = cp_layer_renderer_capabilities_supported_minimum_near_plane_distance(layer_renderer_capabilities);
		rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::set_minimum_supported_near_plane).bind(minimum_supported_near_plane));
	}
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
	return p_mode == XR_PLAY_AREA_SITTING || p_mode == XR_PLAY_AREA_ROOMSCALE || p_mode == XR_PLAY_AREA_STAGE;
}

XRInterface::PlayAreaMode VisionOSXRInterface::get_play_area_mode() const {
	return play_area_mode;
}

bool VisionOSXRInterface::set_play_area_mode(XRInterface::PlayAreaMode p_mode) {
	if (!supports_play_area_mode(p_mode)) {
		return false;
	}
	if (play_area_mode == p_mode) {
		return true;
	}

	play_area_mode = p_mode;
	reset_tracking_floor_reference();

	XRServer *xr_server = XRServer::get_singleton();
	if (xr_server != nullptr) {
		xr_server->clear_reference_frame();
	}
	return true;
}

Array VisionOSXRInterface::get_supported_environment_blend_modes() {
	Array modes;
	modes.push_back(XR_ENV_BLEND_MODE_OPAQUE);
	modes.push_back(XR_ENV_BLEND_MODE_ALPHA_BLEND);
	return modes;
}

XRInterface::EnvironmentBlendMode VisionOSXRInterface::get_environment_blend_mode() const {
	return environment_blend_mode;
}

bool VisionOSXRInterface::set_environment_blend_mode(EnvironmentBlendMode p_mode) {
	if (p_mode != XR_ENV_BLEND_MODE_OPAQUE && p_mode != XR_ENV_BLEND_MODE_ALPHA_BLEND) {
		return false;
	}
	environment_blend_mode = p_mode;
	return true;
}

void VisionOSXRInterface::set_eye_height(float p_eye_height) {
	eye_height = MAX(0.0f, p_eye_height);
}

float VisionOSXRInterface::get_eye_height() const {
	return eye_height;
}

void VisionOSXRInterface::set_head_pose_from_arkit() {
	ERR_FAIL_NULL_MSG(current_frame, "Current frame is nil, probably process() has not been called, using identity transform");
	const auto sync_render_head_pose = [&](const Transform3D &p_head_transform, bool p_valid) {
		if (rendering_server != nullptr) {
			rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::set_origin_from_head).bind(p_head_transform, p_valid));
		}
	};
	if (!_is_world_tracking_provider_running(world_tracking_provider)) {
		tracking_state = XRInterface::XR_NOT_TRACKING;
		sync_render_head_pose(Transform3D(), false);
		return;
	}

	cp_frame_timing_t frame_timing = cp_frame_predict_timing(current_frame);

	CFTimeInterval presentation_time = cp_time_to_cf_time_interval(cp_frame_timing_get_presentation_time(frame_timing));
	ar_device_anchor_query_status_t query_anchor_result = ar_world_tracking_provider_query_device_anchor_at_timestamp(world_tracking_provider, presentation_time, current_device_anchor);

	if (query_anchor_result != ar_device_anchor_query_status_success) {
		tracking_state = XRInterface::XR_NOT_TRACKING;
		sync_render_head_pose(Transform3D(), false);
		return;
	}

	simd_float4x4 origin_from_head_simd = ar_anchor_get_origin_from_anchor_transform(current_device_anchor);
	tracking_state = XRInterface::XR_NORMAL_TRACKING;
	Transform3D head_transform = MTL::simd_to_transform3D(origin_from_head_simd);
	update_tracking_floor_reference_from_head(head_transform);
	const Transform3D adjusted_head_transform = apply_tracking_floor_offset(head_transform);
	sync_render_head_pose(adjusted_head_transform, true);

	if (head_tracker.is_valid()) {
		// Set our head position (in real space, reference frame and world scale is applied later)
		head_tracker->set_pose("default", adjusted_head_transform, Vector3(), Vector3(), XRPose::XR_TRACKING_CONFIDENCE_HIGH);
	}
}

void VisionOSXRInterface::process() {
	if (!initialized) {
		return;
	}

	current_frame = cp_layer_renderer_query_next_frame(layer_renderer);

	ERR_FAIL_NULL_MSG(current_frame, "Layer renderer unexpectedly returned a nil frame, probably the layer renderer has been invalidated and it hasn't been updated to a new one");

	cp_frame_timing_t frame_timing = cp_frame_predict_timing(current_frame);
	CFTimeInterval trackable_anchor_time = cp_time_to_cf_time_interval(cp_frame_timing_get_presentation_time(frame_timing));
	if (@available(visionOS 2.0, *)) {
		trackable_anchor_time = cp_time_to_cf_time_interval(cp_frame_timing_get_trackable_anchor_time(frame_timing));
	}

	// Set head pose before engine update, so scripts can access fresh head tracker data
	set_head_pose_from_arkit();
	update_hand_states_from_arkit(trackable_anchor_time);
	update_accessory_tracking_devices();
	update_accessory_tracking_session();
	update_spatial_controller_states_from_arkit(trackable_anchor_time);
	apply_hand_states_to_trackers();

	rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::set_current_frame).bind((uint64_t)current_frame));
	rendering_server->call_on_render_thread(callable_mp(&rt, &RenderThread::start_frame_update));
}

void VisionOSXRInterface::RenderThread::set_minimum_supported_near_plane(float p_minimum_supported_near_plane) {
	ERR_NOT_ON_RENDER_THREAD;
	minimum_supported_near_plane = p_minimum_supported_near_plane;
}

void VisionOSXRInterface::RenderThread::set_origin_from_head(const Transform3D &p_origin_from_head, bool p_has_valid_origin_from_head) {
	ERR_NOT_ON_RENDER_THREAD;
	origin_from_head = p_origin_from_head;
	has_valid_origin_from_head = p_has_valid_origin_from_head;
}

void VisionOSXRInterface::RenderThread::set_current_frame(uint64_t p_current_frame) {
	ERR_NOT_ON_RENDER_THREAD;
	current_frame = (cp_frame_t)p_current_frame;
	current_drawable = nullptr;
	has_valid_device_anchor = false;

	if (!_is_world_tracking_provider_running(world_tracking_provider) || current_device_anchor == nullptr || current_frame == nullptr) {
		return;
	}

	cp_frame_timing_t current_timing = cp_frame_predict_timing(current_frame);
	CFTimeInterval presentation_time = cp_time_to_cf_time_interval(cp_frame_timing_get_presentation_time(current_timing));
	ar_device_anchor_query_status_t query_anchor_result = ar_world_tracking_provider_query_device_anchor_at_timestamp(world_tracking_provider, presentation_time, current_device_anchor);
	if (query_anchor_result == ar_device_anchor_query_status_success) {
		has_valid_device_anchor = true;
	}
}

uint32_t VisionOSXRInterface::RenderThread::get_view_count() {
	// No need for ERR_NOT_ON_RENDER_THREAD
	if (current_drawable != nullptr) {
		size_t drawable_view_count = cp_drawable_get_view_count(current_drawable);
		if (drawable_view_count > 0) {
			current_view_count = uint32_t(drawable_view_count);
		}
	}
	return current_view_count;
}

Transform3D VisionOSXRInterface::RenderThread::get_camera_transform() {
	Transform3D camera_transform;
	ERR_NOT_ON_RENDER_THREAD_V(camera_transform);

	if (!initialized) {
		return camera_transform;
	}

	XRServer *xr_server = XRServer::get_singleton();
	ERR_FAIL_NULL_V(xr_server, camera_transform);
	if (!has_valid_origin_from_head) {
		return camera_transform;
	}

	Transform3D scaled_origin_from_head = origin_from_head;
	// scale our origin point of our transform
	float world_scale = xr_server->get_world_scale();
	scaled_origin_from_head.origin *= world_scale;
	camera_transform = scaled_origin_from_head;
	return camera_transform;
}

Transform3D VisionOSXRInterface::RenderThread::get_transform_for_view(uint32_t p_view, const Transform3D &p_cam_transform) {
	Transform3D origin_from_eye;
	ERR_NOT_ON_RENDER_THREAD_V(origin_from_eye);

	XRServer *xr_server = XRServer::get_singleton();
	ERR_FAIL_NULL_V(xr_server, origin_from_eye);
	if (initialized) {
		ERR_FAIL_COND_V(p_view >= get_view_count(), origin_from_eye);
		ERR_FAIL_NULL_V_MSG(current_drawable, origin_from_eye, "Current drawable is nil, probably pre_render() has not been called, using identity transform");
		if (!has_valid_origin_from_head) {
			return origin_from_eye;
		}

		cp_view_t view = cp_drawable_get_view(current_drawable, p_view);
		simd_float4x4 head_from_eye_simd = cp_view_get_transform(view);
		Transform3D head_from_eye = MTL::simd_to_transform3D(head_from_eye_simd);

		origin_from_eye = origin_from_head * head_from_eye;

		// Scale origin point by XROrigin3D's World Scale attribute
		float world_scale = xr_server->get_world_scale();
		origin_from_eye.origin *= world_scale;
	} else {
		ERR_PRINT("vision_vr_interface not initialized, returning received camera transform");
		origin_from_eye = Transform3D();
	};
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
	ERR_FAIL_NULL_V_MSG(current_drawable, eye_projection, "Current drawable is nil, probably pre_render() has not been called");

	XRServer *xr_server = XRServer::get_singleton();
	float world_scale = xr_server->get_world_scale();

	double scaled_z_far = p_z_far / world_scale;
	double scaled_z_near = p_z_near / world_scale;

	if (scaled_z_near < minimum_supported_near_plane) {
		scaled_z_near = minimum_supported_near_plane;
	}

	simd_float2 depth_range = simd_make_float2(scaled_z_far, scaled_z_near);
	cp_drawable_set_depth_range(current_drawable, depth_range);
	simd_float4x4 eye_simd_projection = cp_drawable_compute_projection(current_drawable, cp_axis_direction_convention_right_up_forward, p_view);
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
	return eye_projection;
}

// The render region is the logical texture size. With foveated rendering, it's bigger than the
// physical texture size. This value is equivalent to rasterizationRateMap.screenSize.
Rect2i VisionOSXRInterface::RenderThread::get_render_region() {
	Rect2 viewport_rect;

	ERR_NOT_ON_RENDER_THREAD_V(viewport_rect);

	if (!initialized) {
		return viewport_rect;
	}

	ERR_FAIL_NULL_V_MSG(current_drawable, viewport_rect, "Current drawable is nil, probably pre_render() has not been called");

	// The viewport should be the same for both eyes, so only get it from the first view
	cp_view_t view = cp_drawable_get_view(current_drawable, 0);
	cp_view_texture_map_t view_texture_map = cp_view_get_view_texture_map(view);
	MTLViewport viewport = cp_view_texture_map_get_viewport(view_texture_map);
	viewport_rect = MTL::rect_from_mtl_viewport(viewport);
	return viewport_rect;
}

Size2 VisionOSXRInterface::RenderThread::get_render_target_size() {
	// Read atomic values cached by pre_render(). Safe to call from any thread.
	return Size2(cached_render_target_width.get(), cached_render_target_height.get());
}

void VisionOSXRInterface::RenderThread::start_frame_update() {
	ERR_NOT_ON_RENDER_THREAD;

	if (!initialized) {
		return;
	}

	ERR_FAIL_NULL_MSG(current_frame, "Current frame is nil, probably process() has not been called");
	cp_frame_start_update(current_frame);
}

void VisionOSXRInterface::RenderThread::end_frame_update() {
	ERR_NOT_ON_RENDER_THREAD;

	if (!initialized) {
		return;
	}
	ERR_FAIL_NULL_MSG(current_frame, "Current frame is nil, probably process() has not been called");
	cp_frame_end_update(current_frame);
}

void VisionOSXRInterface::RenderThread::pre_render() {
	ERR_NOT_ON_RENDER_THREAD;

	if (!initialized) {
		return;
	}
	end_frame_update();

	cp_frame_timing_t timing = cp_frame_predict_timing(current_frame);
	cp_time_wait_until(cp_frame_timing_get_optimal_input_time(timing));

	cp_frame_start_submission(current_frame);
	cp_drawable_array_t drawables = cp_frame_query_drawables(current_frame);
	size_t drawable_count = cp_drawable_array_get_count(drawables);

	for (size_t i = 0; i < drawable_count; i++) {
		cp_drawable_t drawable = cp_drawable_array_get_drawable(drawables, i);
		// Find screen drawable (target = cp_drawable_target_built_in).
		// High quality recording (target = cp_drawable_target_capture) not supported yet,
		// to support this feature, we'd need Godot to perform an additional render pass on the extra drawable
		if (cp_drawable_get_target(drawable) == cp_drawable_target_built_in) {
			current_drawable = drawable;
		}
	}
	ERR_FAIL_NULL_MSG(current_drawable, "Built-in drawable not found, aborting");

	// Cache render target size atomically so it can be safely read from the game thread.
	id<MTLTexture> color_texture = cp_drawable_get_color_texture(current_drawable, 0);
	cached_render_target_width.set(color_texture.width);
	cached_render_target_height.set(color_texture.height);

	if (has_valid_device_anchor && current_device_anchor != nil) {
		cp_drawable_set_device_anchor(current_drawable, current_device_anchor);
	}
}

Vector<BlitToScreen> VisionOSXRInterface::RenderThread::post_draw_viewport(RID p_render_target, const Rect2 &p_screen_rect) {
	ERR_NOT_ON_RENDER_THREAD_V(Vector<BlitToScreen>());

	if (!initialized) {
		return Vector<BlitToScreen>();
	}

	// We're overriding the color and depth textures, no need for screen blits, return empty BlitToScreen vector
	// However, we need to acquire the dummy frame buffer
	RD::get_singleton()->screen_prepare_for_drawing(DisplayServer::MAIN_WINDOW_ID);
	return Vector<BlitToScreen>();
}

void VisionOSXRInterface::RenderThread::encode_present(MDCommandBuffer *p_cmd_buffer) {
	ERR_NOT_ON_RENDER_THREAD;

	if (!initialized) {
		return;
	}
	ERR_FAIL_NULL_MSG(current_drawable, "Current drawable is nil, probably process() has not been called");
	id<MTLCommandBuffer> cmd_buffer = p_cmd_buffer->ensure_command_buffer();
	cp_drawable_encode_present(current_drawable, cmd_buffer);
	current_drawable = nullptr;
}

void VisionOSXRInterface::RenderThread::end_frame() {
	ERR_NOT_ON_RENDER_THREAD;

	if (!initialized) {
		return;
	}
	ERR_FAIL_NULL_MSG(current_frame, "Current frame is nil, probably process() has not been called");
	cp_frame_end_submission(current_frame);
	current_frame = nullptr;
}

RID VisionOSXRInterface::RenderThread::get_color_texture() {
	ERR_NOT_ON_RENDER_THREAD_V(RID());

	if (!initialized) {
		return RID();
	}

	if (current_color_texture_id != RID()) {
		rendering_device->texture_owner.free(current_color_texture_id);
	}

	ERR_FAIL_NULL_V_MSG(current_drawable, RID(), "Current drawable is nil, probably pre_render() has not been called");

	id<MTLTexture> color_texture = cp_drawable_get_color_texture(current_drawable, 0);
	current_color_texture_id = rendering_device->texture_create_from_extension(
			MTL::texture_type_from_metal(color_texture.textureType),
			_rd_data_format_from_metal_pixel_format(color_texture.pixelFormat),
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

	if (!initialized) {
		return RID();
	}

	if (current_depth_texture_id != RID()) {
		rendering_device->texture_owner.free(current_depth_texture_id);
	}

	ERR_FAIL_NULL_V_MSG(current_drawable, RID(), "Current drawable is nil, probably pre_render() has not been called");
	id<MTLTexture> depth_texture = cp_drawable_get_depth_texture(current_drawable, 0);

	current_depth_texture_id = rendering_device->texture_create_from_extension(
			MTL::texture_type_from_metal(depth_texture.textureType),
			_rd_data_format_from_metal_pixel_format(depth_texture.pixelFormat),
			MTL::texture_samples_from_metal(depth_texture.sampleCount),
			RD::TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT,
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

	if (!initialized) {
		return RID();
	}

	if (current_rasterization_rate_map_id != RID()) {
		rendering_device->texture_owner.free(current_rasterization_rate_map_id);
	}

	ERR_FAIL_NULL_V_MSG(current_drawable, RID(), "Current drawable is nil, probably pre_render() has not been called");
	size_t count = cp_drawable_get_rasterization_rate_map_count(current_drawable);
	ERR_FAIL_COND_V_MSG(count == 0, RID(), "No rasterizationRateMaps found");
	id<MTLRasterizationRateMap> rasterization_rate_map = cp_drawable_get_rasterization_rate_map(current_drawable, 0);
	MTLSize logical_size = rasterization_rate_map.screenSize;

	RD::Texture texture;
	texture.driver_id = RDD::TextureID((__bridge void *)rasterization_rate_map);
	texture.usage_flags = RD::TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RD::TEXTURE_USAGE_SAMPLING_BIT | RD::TEXTURE_USAGE_STORAGE_BIT | RD::TEXTURE_USAGE_VRS_ATTACHMENT_BIT;
	texture.width = logical_size.width;
	texture.height = logical_size.height;
	texture.layers = rasterization_rate_map.layerCount;
	// The following spoofed values are unused, but they are required
	// to pass RenderingDevice::_render_pass_create() validation
	texture.type = RDD::TEXTURE_TYPE_2D_ARRAY;
	texture.format = RDD::DATA_FORMAT_R8_UINT;
	texture.samples = RDD::TEXTURE_SAMPLES_1;
	texture.depth = 1;
	texture.mipmaps = 1;
	ERR_FAIL_COND_V(!texture.driver_id, RID());

	current_rasterization_rate_map = texture;
	current_rasterization_rate_map_id = rendering_device->texture_owner.make_rid(current_rasterization_rate_map);

	return current_rasterization_rate_map_id;
}

#endif // VISIONOS_ENABLED
