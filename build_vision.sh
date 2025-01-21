#!/bin/bash -ex

MODULE_OPTS=""; # "disable_advanced_gui=yes  module_enet_enabled=no module_openxr_enabled=yes module_text_server_adv_enabled=no module_text_server_fb_enabled=yes module_jsonrpc_enabled=no module_mbedtls_enabled=no module_mobile_vr_enabled=yes module_regex_enabled=no module_svg_enabled=no module_tga_enabled=no module_webrtc_enabled=no module_websocket_enabled=no module_multiplayer_enabled=no module_upnp_enabled=no module_webp_enabled=no module_webxr_enabled=no module_zip_enabled=no module_vorbis_enabled=no module_vhacd_enabled=no module_tinyexr_enabled=no module_theora_enabled=no"

MODE=$1
shift;

PLATFORM=$1
shift;

if [ "$PLATFORM" == "visionos" ]; then
	PLATFORM_OPTS="visionos=yes"
elif [ "$PLATFORM" == "visionos_simulator" ]; then
	PLATFORM_OPTS="visionos_simulator=yes"
else
	echo Must specify 'visionos' or 'visionos_simulator' as the platform > /dev/stderr
	exit 1
fi

BUILD="scons p=ios library_type=shared_library $MODULE_OPTS optimize=size arch=arm64 verbose=yes $PLATFORM_OPTS opengl3=no vulkan=no metal=true module_openxr_enabled=true openxr=true $@"

if [ "$MODE" == "debug" ]; then
	$BUILD target=template_debug dev_build=yes debug_symbols=yes
elif [ "$MODE" == "release" ]; then
	$BUILD target=template_release dev_build=no debug_symbols=yes
else
	echo Must specify \'debug\' or \'release\' > /dev/stderr
	exit 1
fi

if [ "$PLATFORM" == "visionos" ]; then
    cp -rf bin/libgodot.ios.template_debug.dev.arm64.visionos.a "/Users/clancey/Projects/Godot/VisionNewTest/build/New Game Project.xcframework/xros-arm64/libgodot.a"
else
	cp -rf bin/libgodot.ios.template_debug.dev.arm64.visionos.simulator.a "/Users/clancey/Projects/Godot/VisionNewTest/build/New Game Project.xcframework/xros-arm64_x86_64-simulator/libgodot.a"
fi