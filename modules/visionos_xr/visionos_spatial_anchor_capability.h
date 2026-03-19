/**************************************************************************/
/*  visionos_spatial_anchor_capability.h                                  */
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

#include "core/object/ref_counted.h"
#include "visionos_anchor_tracker.h"

class VisionOSSceneUnderstanding;

class VisionOSSpatialAnchorCapability : public Object {
	GDCLASS(VisionOSSpatialAnchorCapability, Object);

public:
	static VisionOSSpatialAnchorCapability *get_singleton();

	VisionOSSpatialAnchorCapability();
	~VisionOSSpatialAnchorCapability();

	void set_scene_understanding(VisionOSSceneUnderstanding *p_scene_understanding);

	// Mirrors OpenXRSpatialAnchorCapability API
	bool is_spatial_anchor_supported();
	bool is_spatial_persistence_supported();

	Ref<VisionOSAnchorTracker> create_new_anchor(const Transform3D &p_transform);
	void remove_anchor(Ref<VisionOSAnchorTracker> p_anchor_tracker);

	// Persistence - visionOS world anchors are automatically persistent,
	// so persist is a no-op that fires the callback, and unpersist removes the anchor.
	void persist_anchor(Ref<VisionOSAnchorTracker> p_anchor_tracker, const Callable &p_user_callback = Callable());
	void unpersist_anchor(Ref<VisionOSAnchorTracker> p_anchor_tracker, const Callable &p_user_callback = Callable());

	// visionOS-specific: SharePlay shared anchors
	bool is_sharing_available();
	Ref<VisionOSAnchorTracker> create_shared_anchor(const Transform3D &p_transform);

protected:
	static void _bind_methods();

private:
	static VisionOSSpatialAnchorCapability *singleton;
	VisionOSSceneUnderstanding *scene_understanding = nullptr;
};

#endif // VISIONOS_ENABLED
