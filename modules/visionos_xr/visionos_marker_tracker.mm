/**************************************************************************/
/*  visionos_marker_tracker.mm                                            */
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

#include "visionos_marker_tracker.h"

#include "core/object/class_db.h"
#include "servers/xr/xr_server.h"

void VisionOSMarkerTracker::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_marker_uuid"), &VisionOSMarkerTracker::get_marker_uuid);
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "marker_uuid"), "", "get_marker_uuid");

	ClassDB::bind_method(D_METHOD("get_marker_data"), &VisionOSMarkerTracker::get_marker_data);
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "marker_data"), "", "get_marker_data");

	ClassDB::bind_method(D_METHOD("get_physical_size"), &VisionOSMarkerTracker::get_physical_size);
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "physical_size"), "", "get_physical_size");

	ClassDB::bind_method(D_METHOD("get_estimated_scale_factor"), &VisionOSMarkerTracker::get_estimated_scale_factor);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "estimated_scale_factor"), "", "get_estimated_scale_factor");

	ClassDB::bind_method(D_METHOD("get_bounds_size"), &VisionOSMarkerTracker::get_bounds_size);
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "bounds_size"), "", "get_bounds_size");

	ClassDB::bind_method(D_METHOD("get_marker_tracked"), &VisionOSMarkerTracker::get_marker_tracked);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "marker_tracked"), "", "get_marker_tracked");

	ADD_SIGNAL(MethodInfo("tracking_state_changed", PropertyInfo(Variant::BOOL, "is_tracked")));
}

VisionOSMarkerTracker::VisionOSMarkerTracker() {
	set_tracker_type(XRServer::TRACKER_ANCHOR);
}

void VisionOSMarkerTracker::set_marker_uuid(const String &p_uuid) {
	uuid = p_uuid;
}

String VisionOSMarkerTracker::get_marker_uuid() const {
	return uuid;
}

void VisionOSMarkerTracker::set_marker_data(const String &p_marker_data) {
	marker_data = p_marker_data;
}

String VisionOSMarkerTracker::get_marker_data() const {
	return marker_data;
}

void VisionOSMarkerTracker::set_physical_size(const Vector2 &p_physical_size) {
	physical_size = p_physical_size;
}

Vector2 VisionOSMarkerTracker::get_physical_size() const {
	return physical_size;
}

void VisionOSMarkerTracker::set_estimated_scale_factor(float p_scale_factor) {
	estimated_scale_factor = p_scale_factor;
}

float VisionOSMarkerTracker::get_estimated_scale_factor() const {
	return estimated_scale_factor;
}

Vector2 VisionOSMarkerTracker::get_bounds_size() const {
	return physical_size * estimated_scale_factor;
}

void VisionOSMarkerTracker::set_marker_tracked(bool p_tracked) {
	if (tracked != p_tracked) {
		tracked = p_tracked;
		emit_signal(SNAME("tracking_state_changed"), tracked);
	}
}

bool VisionOSMarkerTracker::get_marker_tracked() const {
	return tracked;
}

#endif // VISIONOS_ENABLED
