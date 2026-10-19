#!/usr/bin/env bash
# Link an unsigned immersive app using the editor/template pair from one build.
set -euo pipefail

if [[ $# -ne 3 ]]; then
	echo "Usage: $0 EDITOR VISIONOS_ZIP NEW_OUTPUT_DIRECTORY" >&2
	exit 2
fi
EDITOR="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
TEMPLATE="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
OUT="$3"
[[ -x "$EDITOR" && -f "$TEMPLATE" ]] || { echo "Missing editor or template" >&2; exit 2; }
[[ ! -e "$OUT" ]] || { echo "Refusing to overwrite validation output: $OUT" >&2; exit 2; }
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
mkdir "$OUT/project" "$OUT/export"

cat > "$OUT/project/project.godot" <<'EOF'
config_version=5

[application]
config/name="VisionOSLinkCheck"
run/main_scene="res://main.tscn"

[rendering]
renderer/rendering_method="mobile"
rendering_device/driver.visionos="metal"
textures/vram_compression/import_etc2_astc=true

[xr]
visionos/scene_understanding/enable_image_tracking=true
EOF
cat > "$OUT/project/main.tscn" <<'EOF'
[gd_scene format=3]

[node name="VisionOSLinkCheck" type="Node3D"]
EOF
# Use a local copy so arbitrary paths do not need GDScript string escaping.
cp "$TEMPLATE" "$OUT/project/visionos.zip"
cat > "$OUT/project/export_presets.cfg" <<'EOF'
[preset.0]
name="visionOS"
platform="visionOS"
runnable=true
export_filter="all_resources"
include_filter=""
exclude_filter="visionos.zip"

[preset.0.options]
custom_template/debug="res://visionos.zip"
custom_template/release="res://visionos.zip"
application/app_store_team_id="GODOTTESTS"
application/bundle_identifier="org.godotengine.visionos-link-check"
application/export_project_only=true
application/code_sign_identity_debug="-"
application/code_sign_identity_release="-"
application/app_role=1
privacy/world_sensing_usage_description="Validate native image tracking."
EOF

"$EDITOR" --headless --path "$OUT/project" --import > "$OUT/import.log" 2>&1
for CONFIGURATION in Debug Release; do
	MODE=debug
	if [[ "$CONFIGURATION" == Release ]]; then
		MODE=release
	fi
	EXPORT="$OUT/export/$CONFIGURATION"
	mkdir "$EXPORT"
	# The exporter selects the engine archive, not Xcode's build configuration.
	"$EDITOR" --headless --path "$OUT/project" "--export-$MODE" visionOS "$EXPORT/VisionOSLinkCheck.xcodeproj" > "$OUT/export-$CONFIGURATION.log" 2>&1
	if grep -E 'SCRIPT ERROR|Parse Error|Export failed|ERROR:' "$OUT/import.log" "$OUT/export-$CONFIGURATION.log"; then
		echo "Import or export reported errors" >&2
		exit 1
	fi
	for SDK in xros xrsimulator; do
		xcodebuild -quiet -project "$EXPORT/VisionOSLinkCheck.xcodeproj" \
			-scheme VisionOSLinkCheck -configuration "$CONFIGURATION" -sdk "$SDK" \
			ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
			DEVELOPMENT_TEAM= -derivedDataPath "$OUT/DerivedData/$CONFIGURATION" \
			> "$OUT/link-$CONFIGURATION-$SDK.log" 2>&1
		BINARY="$OUT/DerivedData/$CONFIGURATION/Build/Products/$CONFIGURATION-$SDK/VisionOSLinkCheck.app/VisionOSLinkCheck"
		[[ -f "$BINARY" ]] || { echo "Missing linked executable: $BINARY" >&2; exit 1; }
		file "$BINARY"
		shasum -a 256 "$BINARY"
	done
done
echo "Unsigned visionOS device/simulator Debug/Release executable links passed."
