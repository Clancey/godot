/**************************************************************************/
/*  visionos_marker_tracker.h                                             */
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

#include "servers/xr/xr_positional_tracker.h"

// A registered reference image (for example a printed QR code) that ARKit
// found in the user's surroundings. The pose follows the OpenXR spatial marker
// convention: origin at the image center, +X to the image's right, +Y towards
// the image's top edge and +Z out of the printed face.
class VisionOSMarkerTracker : public XRPositionalTracker {
	GDCLASS(VisionOSMarkerTracker, XRPositionalTracker);

public:
	VisionOSMarkerTracker();

	void set_marker_uuid(const String &p_uuid);
	String get_marker_uuid() const;

	void set_marker_data(const String &p_marker_data);
	String get_marker_data() const;

	void set_physical_size(const Vector2 &p_physical_size);
	Vector2 get_physical_size() const;

	void set_estimated_scale_factor(float p_scale_factor);
	float get_estimated_scale_factor() const;

	// Physical size corrected by ARKit's estimated scale factor.
	Vector2 get_bounds_size() const;

	void set_marker_tracked(bool p_tracked);
	bool get_marker_tracked() const;

protected:
	static void _bind_methods();

private:
	String uuid;
	String marker_data;
	Vector2 physical_size;
	float estimated_scale_factor = 1.0;
	bool tracked = false;
};

#endif // VISIONOS_ENABLED
