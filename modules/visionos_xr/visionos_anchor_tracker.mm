/**************************************************************************/
/*  visionos_anchor_tracker.mm                                            */
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

#include "visionos_anchor_tracker.h"

#include "servers/xr/xr_server.h"

void VisionOSAnchorTracker::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_anchor_uuid", "uuid"), &VisionOSAnchorTracker::set_anchor_uuid);
	ClassDB::bind_method(D_METHOD("get_anchor_uuid"), &VisionOSAnchorTracker::get_anchor_uuid);
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "anchor_uuid"), "set_anchor_uuid", "get_anchor_uuid");

	ClassDB::bind_method(D_METHOD("get_anchor_tracked"), &VisionOSAnchorTracker::get_anchor_tracked);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "anchor_tracked"), "", "get_anchor_tracked");

	ClassDB::bind_method(D_METHOD("get_shared_with_nearby_participants"), &VisionOSAnchorTracker::get_shared_with_nearby_participants);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "shared_with_nearby_participants"), "", "get_shared_with_nearby_participants");

	ADD_SIGNAL(MethodInfo("tracking_state_changed", PropertyInfo(Variant::BOOL, "is_tracked")));
}

VisionOSAnchorTracker::VisionOSAnchorTracker() {
	set_tracker_type(XRServer::TRACKER_ANCHOR);
}

void VisionOSAnchorTracker::set_anchor_uuid(const String &p_uuid) {
	uuid = p_uuid;
}

String VisionOSAnchorTracker::get_anchor_uuid() const {
	return uuid;
}

void VisionOSAnchorTracker::set_anchor_tracked(bool p_tracked) {
	if (tracked != p_tracked) {
		tracked = p_tracked;
		emit_signal(SNAME("tracking_state_changed"), tracked);
	}
}

bool VisionOSAnchorTracker::get_anchor_tracked() const {
	return tracked;
}

void VisionOSAnchorTracker::set_shared_with_nearby_participants(bool p_shared) {
	shared_with_nearby_participants = p_shared;
}

bool VisionOSAnchorTracker::get_shared_with_nearby_participants() const {
	return shared_with_nearby_participants;
}

#endif // VISIONOS_ENABLED
