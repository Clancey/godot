/**************************************************************************/
/*  export_plugin.cpp                                                     */
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

#include "export_plugin.h"

#include "logo_svg.gen.h"
#include "run_icon_svg.gen.h"

Vector<String> EditorExportPlatformVisionOS::device_types({ "realityDevice" });

EditorExportPlatformVisionOS::EditorExportPlatformVisionOS() :
		EditorExportPlatformAppleEmbedded(_visionos_logo_svg, _visionos_run_icon_svg) {
#ifdef MACOS_ENABLED
	_start_remote_device_poller_thread();
#endif
}

EditorExportPlatformVisionOS::~EditorExportPlatformVisionOS() {
#ifdef MACOS_ENABLED
	_stop_remote_device_poller_thread();
#endif
}

void EditorExportPlatformVisionOS::get_export_options(List<ExportOption> *r_options) const {
	EditorExportPlatformAppleEmbedded::get_export_options(r_options);

	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "application/min_visionos_version"), get_minimum_deployment_target()));

	r_options->push_back(ExportOption(PropertyInfo(Variant::INT, "application/app_role", PROPERTY_HINT_ENUM, "Window,Immersive"), 1));
	r_options->push_back(ExportOption(PropertyInfo(Variant::INT, "application/immersion_style", PROPERTY_HINT_ENUM, "Full,Mixed"), 1));
	r_options->push_back(ExportOption(PropertyInfo(Variant::INT, "application/game_controller_interaction", PROPERTY_HINT_ENUM, "Disabled,Supported,Required"), 1));
	r_options->push_back(ExportOption(PropertyInfo(Variant::INT, "application/upper_limb_visibility", PROPERTY_HINT_ENUM, "Auto,Visible,Hidden"), 0));
	r_options->push_back(ExportOption(PropertyInfo(Variant::INT, "application/persistent_system_overlays", PROPERTY_HINT_ENUM, "Auto,Visible,Hidden"), 0));

	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "privacy/hands_tracking_usage_description", PROPERTY_HINT_PLACEHOLDER_TEXT, "Provide a message if you need access to hand tracking"), ""));
	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "privacy/accessory_tracking_usage_description", PROPERTY_HINT_PLACEHOLDER_TEXT, "Provide a message if you need access to accessory tracking"), ""));
	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "privacy/world_sensing_usage_description", PROPERTY_HINT_PLACEHOLDER_TEXT, "Provide a message if you need access to world-sensing data"), ""));
}

Vector<EditorExportPlatformAppleEmbedded::IconInfo> EditorExportPlatformVisionOS::get_icon_infos() const {
	return Vector<EditorExportPlatformAppleEmbedded::IconInfo>();
}
