/**************************************************************************/
/*  visionos_face_tracking.h                                              */
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

#include "core/os/mutex.h"
#include "servers/xr/xr_face_tracker.h"

#include <memory>

class XRServer;

// visionOS has no face or eye tracking API for apps. The closest thing is the
// Persona virtual front camera (`AVCaptureDevice.systemPreferredCamera`),
// which renders the wearer's face as tracked by the headset. This estimates
// face blend shapes from that image with Vision face landmarks and publishes
// them on a standard `/user/face_tracker`, so games read it the same way as
// on OpenXR headsets.
struct VisionOSFaceTracking {
	// Written on the capture queue, read on the main thread.
	struct Shared {
		Mutex mutex;
		float weights[XRFaceTracker::FT_MAX] = {};
		uint64_t serial = 0;
		bool face_found = false;
	};

	bool enabled = false;
	bool mirrored = false;

	Ref<XRFaceTracker> tracker;
	std::shared_ptr<Shared> shared;

	// Retained `GDTVisionOSFaceCapture`; opaque so C++ files can include this.
	void *capture = nullptr;

	bool started = false;
	uint64_t active_since_msec = 0;
	uint64_t last_serial = 0;
	uint64_t last_update_msec = 0;
	bool published = false;

	void initialize(XRServer *p_xr_server);
	void uninitialize(XRServer *p_xr_server);
	void process();
};

#endif // VISIONOS_ENABLED
