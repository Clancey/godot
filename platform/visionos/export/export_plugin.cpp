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

#include "editor/editor_node.h"

namespace {

enum GameControllerInteractionMode {
	GAME_CONTROLLER_INTERACTION_DISABLED = 0,
	GAME_CONTROLLER_INTERACTION_SUPPORTED = 1,
	GAME_CONTROLLER_INTERACTION_REQUIRED = 2,
};

enum UpperLimbVisibilityMode {
	UPPER_LIMB_VISIBILITY_AUTO = 0,
	UPPER_LIMB_VISIBILITY_VISIBLE = 1,
	UPPER_LIMB_VISIBILITY_HIDDEN = 2,
};

bool _plist_has_key(const String &p_plist_content, const String &p_key) {
	return p_plist_content.contains("<key>" + p_key + "</key>");
}

String _build_game_controller_plist_content(const Ref<EditorExportPreset> &p_preset, const String &p_existing_plist_content) {
	const GameControllerInteractionMode interaction_mode = (GameControllerInteractionMode)(int)p_preset->get("application/game_controller_interaction");
	const bool controller_interaction_enabled = interaction_mode != GAME_CONTROLLER_INTERACTION_DISABLED;
	const UpperLimbVisibilityMode upper_limb_visibility_mode = (UpperLimbVisibilityMode)(int)p_preset->get("application/upper_limb_visibility");
	String plist;

	if (controller_interaction_enabled) {
		if (!_plist_has_key(p_existing_plist_content, "GCSupportsControllerUserInteraction")) {
			plist += "<key>GCSupportsControllerUserInteraction</key>\n";
			plist += "<true/>\n";
		}
		if (!_plist_has_key(p_existing_plist_content, "GCSupportedGameControllers")) {
			plist += "<key>GCSupportedGameControllers</key>\n";
			plist += "<array>\n";
			plist += "\t<dict>\n";
			plist += "\t\t<key>ProfileName</key>\n";
			plist += "\t\t<string>ExtendedGamepad</string>\n";
			plist += "\t</dict>\n";
			plist += "\t<dict>\n";
			plist += "\t\t<key>ProfileName</key>\n";
			plist += "\t\t<string>SpatialGamepad</string>\n";
			plist += "\t</dict>\n";
			plist += "</array>\n";
		}
		if (interaction_mode == GAME_CONTROLLER_INTERACTION_REQUIRED && !_plist_has_key(p_existing_plist_content, "GCRequiresControllerUserInteraction")) {
			plist += "<key>GCRequiresControllerUserInteraction</key>\n";
			plist += "<dict>\n";
			plist += "\t<key>visionOS</key>\n";
			plist += "\t<true/>\n";
			plist += "</dict>\n";
		}
	}

	if (!_plist_has_key(p_existing_plist_content, "NSHandsTrackingUsageDescription")) {
		String description = p_preset->get("privacy/hands_tracking_usage_description");
		if (description.is_empty()) {
			description = "This app uses hand tracking for spatial interaction.";
		}
		plist += "<key>NSHandsTrackingUsageDescription</key>\n";
		plist += "<string>" + description.xml_escape(true) + "</string>\n";
	}

	if (controller_interaction_enabled && !_plist_has_key(p_existing_plist_content, "NSAccessoryTrackingUsageDescription")) {
		String description = p_preset->get("privacy/accessory_tracking_usage_description");
		if (description.is_empty()) {
			description = "This app uses accessory tracking to track spatial game controllers.";
		}
		plist += "<key>NSAccessoryTrackingUsageDescription</key>\n";
		plist += "<string>" + description.xml_escape(true) + "</string>\n";
	}

	if (!_plist_has_key(p_existing_plist_content, "GodotUpperLimbVisibility")) {
		switch (upper_limb_visibility_mode) {
			case UPPER_LIMB_VISIBILITY_VISIBLE:
				plist += "<key>GodotUpperLimbVisibility</key>\n";
				plist += "<string>Visible</string>\n";
				break;
			case UPPER_LIMB_VISIBILITY_HIDDEN:
				plist += "<key>GodotUpperLimbVisibility</key>\n";
				plist += "<string>Hidden</string>\n";
				break;
			case UPPER_LIMB_VISIBILITY_AUTO:
			default:
				break;
		}
	}

	if (!_plist_has_key(p_existing_plist_content, "NSWorldSensingUsageDescription")) {
		String description = p_preset->get("privacy/world_sensing_usage_description");
		if (!description.is_empty()) {
			plist += "<key>NSWorldSensingUsageDescription</key>\n";
			plist += "<string>" + description.xml_escape(true) + "</string>\n";
		}
	}

	return plist;
}

} // namespace

Vector<String> EditorExportPlatformVisionOS::device_types({ "realityDevice" });

void EditorExportPlatformVisionOS::initialize() {
	if (EditorNode::get_singleton()) {
		EditorExportPlatformAppleEmbedded::_initialize(_visionos_logo_svg, _visionos_run_icon_svg);
#ifdef MACOS_ENABLED
		_start_remote_device_poller_thread();
#endif
	}
}

EditorExportPlatformVisionOS::~EditorExportPlatformVisionOS() {
#ifdef MACOS_ENABLED
	_stop_remote_device_poller_thread();
#endif
}

void EditorExportPlatformVisionOS::get_export_options(List<ExportOption> *r_options) const {
	EditorExportPlatformAppleEmbedded::get_export_options(r_options);

	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "application/min_visionos_version"), get_minimum_deployment_target()));

	r_options->push_back(ExportOption(PropertyInfo(Variant::INT, "application/app_role", PROPERTY_HINT_ENUM, "Window,Immersive"), 0));
	r_options->push_back(ExportOption(PropertyInfo(Variant::INT, "application/immersion_style", PROPERTY_HINT_ENUM, "Full,Mixed"), 1));
	r_options->push_back(ExportOption(PropertyInfo(Variant::INT, "application/game_controller_interaction", PROPERTY_HINT_ENUM, "Disabled,Supported,Required"), 0));
	r_options->push_back(ExportOption(PropertyInfo(Variant::INT, "application/upper_limb_visibility", PROPERTY_HINT_ENUM, "Auto,Visible,Hidden"), 0));

	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "privacy/hands_tracking_usage_description", PROPERTY_HINT_PLACEHOLDER_TEXT, "Provide a message if you need access to hand tracking"), ""));
	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "privacy/accessory_tracking_usage_description", PROPERTY_HINT_PLACEHOLDER_TEXT, "Provide a message if you need access to accessory tracking"), ""));
	r_options->push_back(ExportOption(PropertyInfo(Variant::STRING, "privacy/world_sensing_usage_description", PROPERTY_HINT_PLACEHOLDER_TEXT, "Provide a message if you need access to world-sensing data"), ""));
}

Vector<EditorExportPlatformAppleEmbedded::IconInfo> EditorExportPlatformVisionOS::get_icon_infos() const {
	return Vector<EditorExportPlatformAppleEmbedded::IconInfo>();
}

String EditorExportPlatformVisionOS::_process_config_file_line(const Ref<EditorExportPreset> &p_preset, const String &p_line, const AppleEmbeddedConfigData &p_config, bool p_debug, const CodeSigningDetails &p_code_signing) {
	// Do visionOS specific processing first, and call super implementation if there are no matches

	String strnew;

	// Supported Destinations
	if (p_line.contains("$targeted_device_family")) {
		strnew += p_line.replace("$targeted_device_family", "7") + "\n";

		// MoltenVK Framework not used on visionOS
	} else if (p_line.contains("$moltenvk_buildfile")) {
		strnew += p_line.replace("$moltenvk_buildfile", "") + "\n";
	} else if (p_line.contains("$moltenvk_fileref")) {
		strnew += p_line.replace("$moltenvk_fileref", "") + "\n";
	} else if (p_line.contains("$moltenvk_buildphase")) {
		strnew += p_line.replace("$moltenvk_buildphase", "") + "\n";
	} else if (p_line.contains("$moltenvk_buildgrp")) {
		strnew += p_line.replace("$moltenvk_buildgrp", "") + "\n";

		// Launch Storyboard
	} else if (p_line.contains("$plist_launch_screen_name")) {
		strnew += p_line.replace("$plist_launch_screen_name", "") + "\n";
	} else if (p_line.contains("$pbx_launch_screen_file_reference")) {
		strnew += p_line.replace("$pbx_launch_screen_file_reference", "") + "\n";
	} else if (p_line.contains("$pbx_launch_screen_copy_files")) {
		strnew += p_line.replace("$pbx_launch_screen_copy_files", "") + "\n";
	} else if (p_line.contains("$pbx_launch_screen_build_phase")) {
		strnew += p_line.replace("$pbx_launch_screen_build_phase", "") + "\n";
	} else if (p_line.contains("$pbx_launch_screen_build_reference")) {
		strnew += p_line.replace("$pbx_launch_screen_build_reference", "") + "\n";

		// OS Deployment Target
	} else if (p_line.contains("$os_deployment_target")) {
		String min_version = p_preset->get("application/min_" + get_platform_name() + "_version");
		String value = "XROS_DEPLOYMENT_TARGET = " + min_version + ";";
		strnew += p_line.replace("$os_deployment_target", value) + "\n";

		// Valid Archs
	} else if (p_line.contains("$valid_archs")) {
		strnew += p_line.replace("$valid_archs", "arm64") + "\n";

		// Application Scene Manifest
	} else if (p_line.contains("$application_scene_manifest")) {
		String value;
		int app_role_enum = (int)p_preset->get("application/app_role");

		if (app_role_enum != 0) {
			String initial_immersion_style = "UIImmersionStyleMixed";
			switch ((int)p_preset->get("application/immersion_style")) {
				case 0: // Full
					initial_immersion_style = "UIImmersionStyleFull";
					break;
				case 1: // Mixed
				default:
					initial_immersion_style = "UIImmersionStyleMixed";
					break;
			}

			value += "<key>UIApplicationSceneManifest</key>\n";
			value += "<dict>\n";
			value += "\t<key>UIApplicationPreferredDefaultSceneSessionRole</key>\n";
			value += "\t<string>CPSceneSessionRoleImmersiveSpaceApplication</string>\n";
			value += "\t<key>UIApplicationSupportsMultipleScenes</key>\n";
			value += "\t<true/>\n";
			value += "\t<key>UISceneConfigurations</key>\n";
			value += "\t<dict>\n";
			value += "\t\t<key>CPSceneSessionRoleImmersiveSpaceApplication</key>\n";
			value += "\t\t<array>\n";
			value += "\t\t\t<dict>\n";
			value += "\t\t\t\t<key>UISceneInitialImmersionStyle</key>\n";
			value += "\t\t\t\t<string>" + initial_immersion_style + "</string>\n";
			value += "\t\t\t</dict>\n";
			value += "\t\t</array>\n";
			// Keep the legacy key for compatibility with older parser code paths.
			value += "\t\t<key>UISceneSessionRoleImmersiveSpaceApplication</key>\n";
			value += "\t\t<array>\n";
			value += "\t\t\t<dict>\n";
			value += "\t\t\t\t<key>UISceneInitialImmersionStyle</key>\n";
			value += "\t\t\t\t<string>" + initial_immersion_style + "</string>\n";
			value += "\t\t\t</dict>\n";
			value += "\t\t</array>\n";
			value += "\t</dict>\n";
			value += "</dict>\n";
		}

		value += _build_game_controller_plist_content(p_preset, p_config.plist_content);

		strnew += p_line.replace("$application_scene_manifest", value) + "\n";

		// Apple Embedded common
	} else {
		strnew += EditorExportPlatformAppleEmbedded::_process_config_file_line(p_preset, p_line, p_config, p_debug, p_code_signing);
	}
	return strnew;
}
