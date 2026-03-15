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
	private func preferredLayout(from supportedLayouts: [LayerRenderer.Layout]) -> LayerRenderer.Layout? {
		let preferredLayouts: [LayerRenderer.Layout] = [.layered, .dedicated, .shared]
		for layout in preferredLayouts {
			if supportedLayouts.contains(layout) {
				return layout
			}
		}
		return supportedLayouts.first
	}

	func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {

		GDTAppDelegateServiceVisionOS.layerRendererCapabilities = capabilities as __CP_OBJECT_cp_layer_renderer_capabilities

		configuration.depthFormat = .depth32Float_stencil8
		configuration.colorFormat = .rgba16Float

		let supportedLayouts = capabilities.supportedLayouts(options: [])
		if capabilities.supportsFoveation {
			let supportedFoveatedLayouts = capabilities.supportedLayouts(options: [.foveationEnabled])
			if let foveatedLayout = preferredLayout(from: supportedFoveatedLayouts) {
				configuration.isFoveationEnabled = true
				configuration.layout = foveatedLayout
				return
			}
		}

		configuration.isFoveationEnabled = false
		if let layout = preferredLayout(from: supportedLayouts) {
			configuration.layout = layout
		} else {
			configuration.layout = .layered
		}
	}
}

extension GDTCompositorServicesRenderer: @unchecked Sendable {}

struct CompositorServicesImmersiveSpace: Scene {

	fileprivate static var initialImmersionStyle: ImmersionStyle {
		guard let sceneManifest = Bundle.main.infoDictionary?["UIApplicationSceneManifest"] as? [String: Any],
			  let sceneConfigurations = sceneManifest["UISceneConfigurations"] as? [String: Any] else {
			return .mixed
		}
		let cpSceneConfiguration =
			(sceneConfigurations["CPSceneSessionRoleImmersiveSpaceApplication"] as? [[String: Any]])
			?? (sceneConfigurations["UISceneSessionRoleImmersiveSpaceApplication"] as? [[String: Any]])
		guard let cpSceneConfiguration,
			  let immersionStyleString = cpSceneConfiguration.first?["UISceneInitialImmersionStyle"] as? String  else {
			return .mixed
		}
		switch immersionStyleString {
			case "UIImmersionStyleFull": return .full
			case "UIImmersionStyleMixed": return .mixed
			default: return .mixed
		}
	}

	fileprivate static var preferredUpperLimbVisibility: Visibility {
		if let visibilityOverride = Bundle.main.infoDictionary?["GodotUpperLimbVisibility"] as? String {
			switch visibilityOverride.lowercased() {
				case "hidden":
					return .hidden
				case "visible":
					return .visible
				case "automatic", "auto":
					return .automatic
				default:
					break
			}
		}

		// If controller interaction is enabled, hide system-rendered upper limbs by default
		// so apps can render fully virtual controller/hands without passthrough overlays.
		if let supportsControllerInteraction = Bundle.main.infoDictionary?["GCSupportsControllerUserInteraction"] as? Bool, supportsControllerInteraction {
			return .hidden
		}
		return .automatic
	}

	fileprivate static var preferredPersistentSystemOverlays: Visibility {
		if let overlaysOverride = Bundle.main.infoDictionary?["GodotPersistentSystemOverlays"] as? String {
			switch overlaysOverride.lowercased() {
				case "hidden":
					return .hidden
				case "visible":
					return .visible
				case "automatic", "auto":
					return .automatic
				default:
					break
			}
		}
		return .automatic
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
			.persistentSystemOverlays(Self.preferredPersistentSystemOverlays)
		}
		.immersionStyle(selection: .constant(Self.initialImmersionStyle), in: .mixed, .full)
		.upperLimbVisibility(Self.preferredUpperLimbVisibility)
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
		GodotWindowScene()
		CompositorServicesImmersiveSpace()
	}
}
