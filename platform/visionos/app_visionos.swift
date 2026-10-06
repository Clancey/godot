/**************************************************************************/
/*  app_visionos.swift                                                    */
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

import SwiftUI
@preconcurrency import CompositorServices

// MARK: Renderer

final class RendererTaskExecutor: TaskExecutor {
	private let queue = DispatchQueue(label: "RenderThreadQueue", qos: .userInteractive)
	func enqueue(_ job: UnownedJob) {
		queue.async {
		  job.runSynchronously(on: self.asUnownedSerialExecutor())
		}
	}
	nonisolated func asUnownedSerialExecutor() -> UnownedTaskExecutor {
		return UnownedTaskExecutor(ordinary: self)
	}
	static let shared: RendererTaskExecutor = RendererTaskExecutor()
}

// MARK: Compositor Services Scene

struct ContentStageConfiguration: CompositorLayerConfiguration {
	func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {

		GDTAppDelegateServiceVisionOS.layerRendererCapabilities = capabilities as __CP_OBJECT_cp_layer_renderer_capabilities

		configuration.depthFormat = .depth32Float_stencil8
		configuration.colorFormat = .rgba16Float

		let foveationEnabled = capabilities.supportsFoveation
		configuration.isFoveationEnabled = foveationEnabled

		let options: LayerRenderer.Capabilities.SupportedLayoutsOptions = foveationEnabled ? [.foveationEnabled] : []
		let supportedLayouts = capabilities.supportedLayouts(options: options)
		if (!supportedLayouts.contains(.layered)) {
			fatalError("Only the .layered layout is supported by Godot's visionOS XR module.")
		}
		configuration.layout = .layered
	}
}

extension GDTCompositorServicesRenderer: @unchecked Sendable {}

struct CompositorServicesImmersiveSpace: Scene {

	fileprivate static var initialImmersionStyle: ImmersionStyle {
		guard let sceneManifest = Bundle.main.infoDictionary?["UIApplicationSceneManifest"] as? [String: Any],
			  let sceneConfigurations = sceneManifest["UISceneConfigurations"] as? [String: Any],
			  let cpSceneConfiguration = sceneConfigurations["UISceneSessionRoleImmersiveSpaceApplication"] as? [[String: Any]],
			  let immersionStyleString = cpSceneConfiguration.first?["UISceneInitialImmersionStyle"] as? String  else {
			return .full
		}
		switch immersionStyleString {
			case "UIImmersionStyleFull": return .full
			case "UIImmersionStyleMixed": return .mixed
			default: return .full
		}
	}

	@State var renderer: GDTCompositorServicesRenderer!
    @State var didSetUpRenderer: Bool = false

	var body: some Scene {
		ImmersiveSpace(id: "ImmersiveSpace") {
			CompositorLayer(configuration: ContentStageConfiguration()) { @MainActor layerRenderer in
				GDTAppDelegateServiceVisionOS.layerRenderer = layerRenderer
				renderer = GDTCompositorServicesRenderer(layerRenderer: layerRenderer,
                                                         capabilities: GDTAppDelegateServiceVisionOS.layerRendererCapabilities)
                if !didSetUpRenderer {
                    renderer.setUp()
                    didSetUpRenderer = true
                } else {
                    renderer.updateXRInterface()
                }
				Task(executorPreference: RendererTaskExecutor.shared) {
					await renderer.startRenderLoop()
				}
			}
			.onWorldRecenter {
				renderer.worldRecentered()
			}
		}
		.immersionStyle(selection: .constant(Self.initialImmersionStyle), in: .mixed, .full)
	}
}

// MARK: Extension Volume

// A volumetric window declared in the App's scene graph on behalf of a GDExtension.
//
// Scenes that an extension activates through UIKit (UISceneSessionActivationRequest with a
// UIHostingSceneDelegate) skip SwiftUI window placement, so a shared-space volume always opens
// where the system puts it. Opening this window with SwiftUI's openWindow from the Godot window
// applies placement such as WindowPlacement(.utilityPanel), which opens it near the user.
//
// Extensions reach it through the Objective-C runtime, NSClassFromString("GDTExtensionVolume"),
// so they don't link against this module. Call these on the main thread:
//  - setContent: the window content, a SwiftUI AnyView.
//  - setPlacementProvider: a block called on the main thread when the window opens. It receives
//    the IDs of the app's open windows ("" for windows without an ID) and returns the placement:
//    "utilityPanel", or anything else for the system default.
//  - configure: an NSDictionary with "width", "height" and "depth" (default size in meters),
//    "resizable" (Bool) and "worldAlignment" ("automatic", "adaptive" or "gravityAligned").
//  - open: opens the window. Returns false if there is no content or no openWindow action yet.
@MainActor
final class GDTExtensionVolumeConfiguration: ObservableObject {
	@Published var size = Size3D(width: 1280.0 / 1360.0, height: 1280.0 / 1360.0, depth: 1280.0 / 1360.0)
	@Published var resizable = true
	@Published var worldAlignment: WorldAlignmentBehavior = .automatic
	var content: AnyView?
	var openWindow: OpenWindowAction?
}

@objc(GDTExtensionVolume)
@MainActor
public final class GDTExtensionVolume: NSObject {
	static let windowID = "GDTExtensionVolume"
	static let configuration = GDTExtensionVolumeConfiguration()
	// SwiftUI calls the placement closure on the main thread, but the closure isn't main-actor isolated.
	nonisolated(unsafe) static var placementProvider: (([String]) -> String)?

	@objc public static func setContent(_ content: Any?) -> Bool {
		guard let content = content as? AnyView else {
			return false
		}
		configuration.content = content
		return true
	}

	@objc public static func setPlacementProvider(_ provider: @escaping ([String]) -> String) {
		placementProvider = provider
	}

	@objc public static func configure(_ options: NSDictionary) {
		if let width = options["width"] as? Double, let height = options["height"] as? Double, let depth = options["depth"] as? Double,
				width > 0, height > 0, depth > 0 {
			configuration.size = Size3D(width: width, height: height, depth: depth)
		}
		if let resizable = options["resizable"] as? Bool {
			configuration.resizable = resizable
		}
		switch options["worldAlignment"] as? String {
			case "adaptive": configuration.worldAlignment = .adaptive
			case "gravityAligned": configuration.worldAlignment = .gravityAligned
			case "automatic": configuration.worldAlignment = .automatic
			default: break
		}
	}

	@objc public static func open() -> Bool {
		guard configuration.content != nil, configuration.openWindow != nil else {
			return false
		}
		// Let the scene pick up the configured size before the window opens.
		Task { @MainActor in
			configuration.openWindow?(id: windowID)
		}
		return true
	}
}

struct GDTExtensionVolumeScene: Scene {
	@ObservedObject var configuration = GDTExtensionVolume.configuration

	var body: some Scene {
		WindowGroup(id: GDTExtensionVolume.windowID) {
			if let content = configuration.content {
				content
			}
		}
		.windowStyle(.volumetric)
		.defaultSize(configuration.size, in: .meters)
		.windowResizability(configuration.resizable ? .contentMinSize : .automatic)
		.defaultWindowPlacement { _, context in
			let windowIDs = context.windows.map { $0.id ?? "" }
			switch GDTExtensionVolume.placementProvider?(windowIDs) {
				case "utilityPanel": return WindowPlacement(.utilityPanel)
				default: return WindowPlacement()
			}
		}
		.volumeWorldAlignment(configuration.worldAlignment)
		.restorationBehavior(.disabled)
	}
}

// Godot's window, which also provides the openWindow action for GDTExtensionVolume.
struct GodotVisionOSWindowScene: Scene {
	var body: some Scene {
		WindowGroup {
			GodotSwiftUIViewController()
				.ignoresSafeArea()
				.modifier(GDTExtensionVolumeOpenWindowCapture())
		}
	}
}

struct GDTExtensionVolumeOpenWindowCapture: ViewModifier {
	@Environment(\.openWindow) private var openWindow

	func body(content: Content) -> some View {
		content.onAppear {
			GDTExtensionVolume.configuration.openWindow = openWindow
		}
	}
}

// MARK: App

@main
struct SwiftUIApp: App {
	@UIApplicationDelegateAdaptor(GDTAppDelegateVisionOS.self) var appDelegate

	private var useCompositorServices: Bool = {
		guard let sceneManifest = Bundle.main.infoDictionary?["UIApplicationSceneManifest"] as? [String: Any],
			  let defaultSessionRole = sceneManifest["UIApplicationPreferredDefaultSceneSessionRole"] as? String else {
			return false
		}
		return defaultSessionRole == "CPSceneSessionRoleImmersiveSpaceApplication"
	}()

	init() {
		print("visionOS app init (useCompositorServices: \(useCompositorServices))")
		GDTAppDelegateServiceVisionOS.renderMode = useCompositorServices ? .compositorServices : .windowed
	}

	var body: some Scene {
		GodotVisionOSWindowScene()
		CompositorServicesImmersiveSpace()
		GDTExtensionVolumeScene()
	}
}
