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
import OSLog

// MARK: Helpers

extension os.Logger {
	static let godot = Logger(subsystem: "com.GodotFoundation.Godot", category: "SwiftUI")
}

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

// MARK: Swift Bridge

/// Source of truth for SwiftUI scene state. ObjC/C++ mutates it through
/// `GDTSwiftBridge`; the scene reads its properties directly (Observation tracking).
@MainActor
@Observable
final class Model {
	static let shared = Model()

	enum ImmersiveSpaceState {
		case closed, opening, open
	}

	var immersionStyle: any ImmersionStyle
	var upperLimbVisibility: Visibility = .automatic
	var persistentSystemOverlays: Visibility = .automatic

	var immersiveSpaceState: ImmersiveSpaceState = .closed
	var didRequestImmersiveSpace = false
	var immersiveSpaceError: String?

	// Engine setup belongs to the process, not to a SwiftUI scene instance.
	var renderer: GDTCompositorServicesRenderer?
	var didSetUpRenderer = false

	private init() {
		immersionStyle = Self.readInitialImmersionStyleFromInfoPlist()
	}

	/// Seeds the project-setting-backed properties. Called at layer creation rather than
	/// from `init()`, because `ProjectSettings` is not loaded yet when the scene is declared.
	func seedFromProjectSettings() {
		upperLimbVisibility = GDTAppDelegateServiceVisionOS.initialUpperLimbVisibility.swiftUI
		persistentSystemOverlays = GDTAppDelegateServiceVisionOS.initialPersistentSystemOverlays.swiftUI
	}

	private static func readInitialImmersionStyleFromInfoPlist() -> any ImmersionStyle {
		guard let sceneManifest = Bundle.main.infoDictionary?["UIApplicationSceneManifest"] as? [String: Any],
		      let sceneConfigurations = sceneManifest["UISceneConfigurations"] as? [String: Any],
		      let cpSceneConfiguration = sceneConfigurations["UISceneSessionRoleImmersiveSpaceApplication"] as? [[String: Any]],
		      let immersionStyleString = cpSceneConfiguration.first?["UISceneInitialImmersionStyle"] as? String else {
			return .full
		}
		switch immersionStyleString {
		case "UIImmersionStyleFull": return .full
		case "UIImmersionStyleMixed": return .mixed
		case "UIImmersionStyleProgressive": return .progressive
		default: return .full
		}
	}
}

/// ObjC-accessible interface for `Model`.
@MainActor
@objc
public final class GDTSwiftBridge: NSObject {
	@objc public class var immersionStyle: GDTImmersionStyle {
		get { GDTImmersionStyle(fromSwiftUIType: Model.shared.immersionStyle) }
		set {
			guard let swiftUIStyle = newValue.swiftUI else { return }
			Model.shared.immersionStyle = swiftUIStyle
		}
	}

	@objc public class var upperLimbVisibility: GDTVisibility {
		get { GDTVisibility(fromSwiftUIType: Model.shared.upperLimbVisibility) }
		set { Model.shared.upperLimbVisibility = newValue.swiftUI }
	}

	@objc public class var persistentSystemOverlays: GDTVisibility {
		get { GDTVisibility(fromSwiftUIType: Model.shared.persistentSystemOverlays) }
		set { Model.shared.persistentSystemOverlays = newValue.swiftUI }
	}
}

// MARK: Immersive Launcher

struct ImmersiveLauncher: View {
	@Environment(\.openImmersiveSpace) private var openImmersiveSpace
	@Environment(\.scenePhase) private var scenePhase

	private let model: Model = .shared

	private func enterImmersiveSpace() async {
		guard model.immersiveSpaceState == .closed else { return }
		model.didRequestImmersiveSpace = true
		model.immersiveSpaceError = nil

		// The preferred scene role may already be connecting the immersive scene.
		// Do not enter the pending state without a request that can complete it.
		guard !GDTAppDelegateServiceVisionOS.hasImmersiveScene && model.renderer == nil else {
			model.immersiveSpaceError = "An immersive scene is already connecting or closing. Please try again shortly."
			NSLog("visionOS immersive space request deferred while a scene or renderer is still present")
			return
		}

		model.immersiveSpaceState = .opening
		NSLog("visionOS requesting immersive space")
		switch await openImmersiveSpace(id: "ImmersiveSpace") {
		case .opened:
			// The compositor callback owns renderer readiness and the open state.
			NSLog("visionOS immersive space request opened")
		case .userCancelled:
			if model.immersiveSpaceState == .opening {
				model.immersiveSpaceState = .closed
				model.immersiveSpaceError = "Immersive space entry was cancelled. You can try again."
			}
			NSLog("visionOS immersive space request cancelled")
		case .error:
			if model.immersiveSpaceState == .opening {
				model.immersiveSpaceState = .closed
				model.immersiveSpaceError = "Unable to open the immersive space. Please try again."
			}
			NSLog("visionOS immersive space request failed")
		@unknown default:
			if model.immersiveSpaceState == .opening {
				model.immersiveSpaceState = .closed
				model.immersiveSpaceError = "Unable to open the immersive space. Please try again."
			}
			NSLog("visionOS immersive space request returned an unknown result")
		}
	}

	var body: some View {
		VStack(spacing: 20) {
			Text("Immersive Mode")
				.font(.title)
			if let error = model.immersiveSpaceError {
				Text(error)
			}
			switch model.immersiveSpaceState {
			case .closed:
				Button("Enter Immersive Space") {
					Task { await enterImmersiveSpace() }
				}
			case .opening:
				ProgressView("Opening immersive space...")
			case .open:
				Text("Immersive space is open.")
			}
		}
		.padding(40)
		.onChange(of: scenePhase, initial: true) { _, phase in
			if phase == .active && !model.didRequestImmersiveSpace {
				model.didRequestImmersiveSpace = true
				Task { await enterImmersiveSpace() }
			}
		}
	}
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

		if GDTAppDelegateServiceVisionOS.isDynamicRenderQualityEnabled {
			let maxRenderQuality = GDTAppDelegateServiceVisionOS.maxRenderQuality
			Logger.godot.log("Enabled dynamic render quality (maxRenderQuality: \(maxRenderQuality))")
			configuration.maxRenderQuality = .init(maxRenderQuality)
		}
	}
}

extension GDTCompositorServicesRenderer: @unchecked Sendable {}

extension GDTImmersionStyle {

    var swiftUI: ImmersionStyle? {
        switch self {
        case .full: return .full
        case .mixed: return .mixed
        case .progressive: return .progressive
        @unknown default: return nil
        }
    }

    init(fromSwiftUIType swiftUIType: ImmersionStyle) {
    switch swiftUIType.self {
        case is FullImmersionStyle: self = .full
        case is MixedImmersionStyle: self = .mixed
        case is ProgressiveImmersionStyle: self = .progressive
        default: fatalError("Unsupported style")
        }
    }

}

extension GDTVisibility {
	var swiftUI: Visibility {
		switch self {
		case .automatic: return .automatic
		case .visible: return .visible
		case .hidden: return .hidden
		@unknown default: return .automatic
		}
	}

	init(fromSwiftUIType visibility: Visibility) {
		switch visibility {
		case .automatic: self = .automatic
		case .visible: self = .visible
		case .hidden: self = .hidden
		}
	}
}

struct CompositorServicesImmersiveSpace: Scene {

    let model: Model = .shared

	var body: some Scene {
		ImmersiveSpace(id: "ImmersiveSpace") {
			CompositorLayer(configuration: ContentStageConfiguration()) { @MainActor layerRenderer in

                NSLog("visionOS compositor layer ready (initialImmersionStyle: %@)", String(describing: model.immersionStyle))
                model.immersiveSpaceState = .open
                model.didRequestImmersiveSpace = true
                model.immersiveSpaceError = nil

                model.seedFromProjectSettings()

				GDTAppDelegateServiceVisionOS.layerRenderer = layerRenderer
				guard let renderer = GDTCompositorServicesRenderer(layerRenderer: layerRenderer,
                                                         capabilities: GDTAppDelegateServiceVisionOS.layerRendererCapabilities) else {
                    fatalError("Unable to create the visionOS compositor renderer.")
                }
                model.renderer = renderer

                let signposter = OSSignposter(subsystem: "org.godotengine.godot.compositorservices", category: "loading")
                let signpostID = signposter.makeSignpostID()

                if !model.didSetUpRenderer {
                    let signpost = signposter.beginInterval("setup", id: signpostID)
                    renderer.setUp()
                    model.didSetUpRenderer = true
                    signposter.endInterval("setup", signpost)
                    NSLog("visionOS compositor engine setup finished")
                } else {
                    let signpost = signposter.beginInterval("updateXRInterface", id: signpostID)
                    renderer.updateXRInterface()
                    signposter.endInterval("updateXRInterface", signpost)
                    NSLog("visionOS compositor XR layer updated")
                }
				Task(executorPreference: RendererTaskExecutor.shared) {
                    let signpost = signposter.beginInterval("startRenderLoop", id: signpostID)
					renderer.startRenderLoop()
                    signposter.endInterval("startRenderLoop", signpost)
                    await MainActor.run {
                        if model.renderer === renderer {
                            model.renderer = nil
                            GDTAppDelegateServiceVisionOS.layerRenderer = nil
                            model.immersiveSpaceState = .closed
                        }
                    }
                    NSLog("visionOS compositor render loop ended")
				}
			}
			.onDisappear {
				model.immersiveSpaceState = .closed
			}
			.onWorldRecenter {
				model.renderer?.worldRecentered()
			}
		}
		.immersionStyle(
			selection: Binding(get: { model.immersionStyle }, set: { model.immersionStyle = $0 }),
			in: .mixed, .full, .progressive
		)
        .upperLimbVisibility(model.upperLimbVisibility)
        .persistentSystemOverlays(model.persistentSystemOverlays)
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
		let useCompositorServices = self.useCompositorServices
		Logger.godot.log("visionOS app init (useCompositorServices: \(useCompositorServices))")
		GDTAppDelegateServiceVisionOS.renderMode = useCompositorServices ? .compositorServices : .windowed
	}

	var body: some Scene {
		WindowGroup {
			if useCompositorServices {
				// A launcher window must never create a second engine renderer.
				ImmersiveLauncher()
			} else {
				GodotSwiftUIViewController()
					.ignoresSafeArea()
			}
		}
		CompositorServicesImmersiveSpace()
	}
}
