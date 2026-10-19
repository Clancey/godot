# visionOS platform port

This folder contains the C++, Objective-C and Objective-C++ code for the visionOS
platform port.

This platform derives from the Apple Embedded abstract platform ([`drivers/apple_embedded`](/drivers/apple_embedded)).

This platform uses shared Apple code ([`drivers/apple`](/drivers/apple)).

See also [`misc/dist/apple_embedded_xcode`](/misc/dist/apple_embedded_xcode) folder for the Xcode
project template used for packaging the iOS export templates.

## Documentation

The compiling and exporting process is the same as on iOS, but replacing the `ios` parameter by `visionos`.

- [Compiling for iOS](https://docs.godotengine.org/en/latest/engine_details/development/compiling/compiling_for_ios.html)
  - Instructions on building this platform port from source.
- [Exporting for iOS](https://docs.godotengine.org/en/latest/tutorials/export/exporting_for_ios.html)
  - Instructions on using the compiled export templates to export a project.

## Image tracking and release validation

The native image tracking contract is documented in `VisionOSXRInterface` and
`VisionOSMarkerTracker`. Registration is distinct from observation: consumers must
require allowed authorization, a running provider and an active session, then use
only fresh observations with matching reference revision and generation. Pausing
or invalidating the compositor session closes that gate before lifecycle signal
listeners run.

The host-side image and shared world-anchor lifecycle tests run in a tests-enabled
editor without a headset:

```sh
scons platform=macos target=editor arch=arm64 tests=yes vulkan=no accesskit=no
bin/godot.macos.editor.arm64 --headless --test --test-case='[visionOS][ImageTracking]*,[visionOS][WorldAnchors]*'
```

After building the editor and all four visionOS template configurations from the
same source tree, validate actual executable links (a static archive alone does
not check unresolved symbols):

```sh
bash misc/scripts/validate_visionos_export.sh \
  bin/godot.macos.editor.arm64 bin/godot_visionos.zip /tmp/visionos-link-check
```

The output directory must not already exist. The script exports a minimal
immersive project and links unsigned Debug and Release applications for device and
simulator using the installed Xcode SDKs. It does not install or launch an app.
The visionOS release workflow requires both lifecycle tests and this matching-pair
link check before publishing. These checks do not validate camera registration,
authorization prompts, compositor events or alignment on physical hardware.
