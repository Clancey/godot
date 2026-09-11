/**************************************************************************/
/*  register_types.mm                                                     */
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

#include "register_types.h"

#include "visionos_anchor_tracker.h"
#include "visionos_mesh_tracker.h"
#include "visionos_plane_tracker.h"
#include "visionos_spatial_anchor_capability.h"
#include "visionos_xr_interface.h"

#include "core/config/engine.h"
#include "core/object/class_db.h"

Ref<VisionOSXRInterface> visionos_xr;
VisionOSSpatialAnchorCapability *visionos_anchor_capability = nullptr;

void initialize_visionos_xr_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	GDREGISTER_CLASS(VisionOSXRInterface);
	GDREGISTER_CLASS(VisionOSPlaneTracker);
	GDREGISTER_CLASS(VisionOSMeshTracker);
	GDREGISTER_CLASS(VisionOSAnchorTracker);
	GDREGISTER_CLASS(VisionOSSpatialAnchorCapability);

	// Exposed as a singleton, mirroring OpenXRSpatialAnchorCapability.
	visionos_anchor_capability = memnew(VisionOSSpatialAnchorCapability);
	Engine::get_singleton()->add_singleton(Engine::Singleton("VisionOSSpatialAnchorCapability", visionos_anchor_capability));

	if (XRServer::get_singleton()) {
		visionos_xr.instantiate();
		visionos_anchor_capability->set_scene_understanding(visionos_xr->get_scene_understanding());
		XRServer::get_singleton()->add_interface(visionos_xr);
	}
}

void uninitialize_visionos_xr_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	if (visionos_xr.is_valid()) {
		visionos_anchor_capability->set_scene_understanding(nullptr);
		// uninitialize our interface if it is initialized
		if (visionos_xr->is_initialized()) {
			visionos_xr->uninitialize();
		}

		// unregister our interface from the XR server
		if (XRServer::get_singleton()) {
			XRServer::get_singleton()->remove_interface(visionos_xr);
		}

		// and release
		visionos_xr.unref();
	}

	if (visionos_anchor_capability != nullptr) {
		Engine::get_singleton()->remove_singleton("VisionOSSpatialAnchorCapability");
		memdelete(visionos_anchor_capability);
		visionos_anchor_capability = nullptr;
	}
}

#endif // VISIONOS_ENABLED
