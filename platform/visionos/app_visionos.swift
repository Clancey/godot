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

	var immersionStyle: any ImmersionStyle {
		didSet {
			renderer?.alphaBlendEnabled = GDTImmersionStyle(fromSwiftUIType: immersionStyle) != .full
		}
	}
	var upperLimbVisibility: Visibility = .automatic
	var persistentSystemOverlays: Visibility = .automatic

	var immersiveSpaceState: ImmersiveSpaceState = .closed
	var didRequestImmersiveSpace = false
	var immersiveSpaceError: String?

	// Engine setup belongs to the process, not to a SwiftUI scene instance.
	var renderer: GDTCompositorServicesRenderer?
	var startupGeneration: UUID?
	var startupWindowVisible = false

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

/// ObjC-accessible version of SwiftUI's "SpatialEventCollection.Event".
/// https://developer.apple.com/documentation/swiftui/spatialeventcollection/event
@MainActor
@objc
public final class SpatialEventObjC: NSObject {

    // Ray
    @objc var hasRay: Bool = false
    @objc var rayOrigin: simd_double3 = .init()
    @objc var rayDirection: simd_double3  = .init()

    // Hand
    @objc enum Chirality: Int {
        case none, left, right
    }
    @objc var chirality: Chirality
    @objc var handPose: simd_double4x4

    // Phase
    @objc enum Phase: Int {
        case unknown, active, cancelled, ended
    }
    @objc var phase: Phase

    init(_ event: SpatialEventCollection.Event) {
        if let ray = event.selectionRay {
            hasRay = true
            rayOrigin = ray.origin.vector
            rayDirection = ray.direction.vector
        }

        chirality = event.chirality.map {
            switch $0 {
            case .left: return .left
            case .right: return .right
            }
        } ?? .none

        handPose = event.inputDevicePose.map {
            return $0.pose3D.matrix
        } ?? .init(diagonal: SIMD4<Double>(repeating: 1.0))

        phase = {
            switch event.phase {
            case .active: return .active
            case .cancelled: return .cancelled
            case .ended: return .ended
            default: return .unknown
            }
        }()
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

struct ImmersiveStartupStatus: View {
	@Environment(\.openWindow) private var openWindow
	@Environment(\.dismissWindow) private var dismissWindow
	@Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

	let generation: UUID
	private let model: Model = .shared

	private func closeStatus(returnToLauncher: Bool) {
		guard model.startupGeneration == generation else {
			dismissWindow(id: "GodotStartupStatus", value: generation)
			return
		}
		guard model.startupWindowVisible else { return }
		model.startupWindowVisible = false
		if returnToLauncher {
			// A window cannot dismiss itself when it is the last open scene.
			openWindow(id: "GodotLauncher")
		}
		dismissWindow(id: "GodotStartupStatus", value: generation)
	}

	private func cancelStartup() {
		guard model.startupGeneration == generation && model.startupWindowVisible else { return }
		closeStatus(returnToLauncher: true)
		Task { @MainActor in
			guard model.startupGeneration == generation,
			      model.immersiveSpaceState == .open else { return }
			await dismissImmersiveSpace()
		}
	}

	var body: some View {
		TimelineView(.periodic(from: .now, by: 0.2)) { _ in
			let state = model.renderer?.startupState ?? .loading
			VStack(spacing: 20) {
				switch state {
				case .preparingPipelines:
					ProgressView("Preparing rendering pipelines...")
				case .loading:
					ProgressView("Loading...")
				case .trackingUnavailable:
					Text("Waiting for tracking...")
				case .frameUnavailable:
					Text("Waiting for a usable scene frame.")
				case .ready:
					Text("Scene ready.")
				case .failed:
					Text("Rendering could not start.")
				case .closed:
					Text("Immersive space closed.")
				@unknown default:
					Text("Rendering status unavailable.")
				}
				Button("Cancel", action: cancelStartup)
			}
			.padding(32)
			.onChange(of: state, initial: true) { _, state in
				if state == .ready && model.immersiveSpaceState == .open {
					closeStatus(returnToLauncher: false)
				} else if state == .closed {
					closeStatus(returnToLauncher: true)
				}
			}
		}
		.onChange(of: model.startupGeneration) { _, value in
			if value != generation {
				dismissWindow(id: "GodotStartupStatus", value: generation)
			}
		}
		.onChange(of: model.immersiveSpaceState) { _, state in
			if state == .closed {
				closeStatus(returnToLauncher: true)
			}
		}
		.onDisappear(perform: cancelStartup)
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
	@Environment(\.openWindow) private var openWindow
	@Environment(\.dismissWindow) private var dismissWindow
	@Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

	var body: some Scene {
		ImmersiveSpace(id: "ImmersiveSpace") {
			CompositorLayer(configuration: ContentStageConfiguration()) { @MainActor layerRenderer in

                NSLog("visionOS compositor layer ready (initialImmersionStyle: %@)", String(describing: model.immersionStyle))
                model.immersiveSpaceState = .open
                model.didRequestImmersiveSpace = true
                model.immersiveSpaceError = nil

                model.seedFromProjectSettings()

				guard let renderer = GDTCompositorServicesRenderer(layerRenderer: layerRenderer,
                                                         capabilities: GDTAppDelegateServiceVisionOS.layerRendererCapabilities) else {
                    fatalError("Unable to create the visionOS compositor renderer.")
                }

                layerRenderer.onSpatialEvent = { [weak renderer] events in
                    guard let renderer else { return }
                    for event in events {
                        renderer.onSpatialEvent(.init(event))
                    }
                }

                model.renderer = renderer
				renderer.alphaBlendEnabled = GDTImmersionStyle(fromSwiftUIType: model.immersionStyle) != .full
				let generation = UUID()
				model.startupGeneration = generation
				model.startupWindowVisible = supportsMultipleWindows
				if supportsMultipleWindows {
					openWindow(id: "GodotStartupStatus", value: generation)
				} else {
					NSLog("visionOS startup status requires UIApplicationSupportsMultipleScenes")
				}

				renderer.startRenderLoop {
                    Task { @MainActor in
                        if model.renderer === renderer {
							if renderer.startupState == .failed {
								model.immersiveSpaceError = "Rendering could not start."
							}
							if model.startupWindowVisible {
								model.startupWindowVisible = false
								openWindow(id: "GodotLauncher")
								dismissWindow(id: "GodotStartupStatus", value: generation)
							}
							model.startupGeneration = nil
                            model.renderer = nil
                            model.immersiveSpaceState = .closed
                        }
                        NSLog("visionOS compositor render loop ended")
                    }
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
		WindowGroup(id: "GodotLauncher") {
			if useCompositorServices {
				// A launcher window must never create a second engine renderer.
				ImmersiveLauncher()
			} else {
				GodotSwiftUIViewController()
					.ignoresSafeArea()
			}
		}
		WindowGroup(id: "GodotStartupStatus", for: UUID.self) { $generation in
			if let generation {
				ImmersiveStartupStatus(generation: generation)
			}
		}
		.defaultSize(width: 420, height: 180)
		.windowResizability(.contentSize)
		.defaultWindowPlacement { _, _ in
			WindowPlacement(.utilityPanel)
		}
		CompositorServicesImmersiveSpace()
	}
}
