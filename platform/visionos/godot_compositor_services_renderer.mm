/**************************************************************************/
/*  godot_compositor_services_renderer.mm                                 */
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

#import "godot_compositor_services_renderer.h"

#import "godot_app_delegate_service_visionos.h"

#import "drivers/apple_embedded/os_apple_embedded.h"

#include "modules/modules_enabled.gen.h"
#if defined(MODULE_VISIONOS_XR_ENABLED)
#include "servers/rendering/rendering_server.h"

#include "modules/visionos_xr/visionos_engine_thread.h"
#include "modules/visionos_xr/visionos_presentation.h"
#include "modules/visionos_xr/visionos_render_diagnostics.h"
#include "modules/visionos_xr/visionos_xr_interface.h"
#endif

#import <CompositorServices/CompositorServices.h>

extern void apple_embedded_finish();

#if defined(MODULE_VISIONOS_XR_ENABLED)

@interface GDTCompositorServicesRenderer ()
- (uint32_t)iterateLayer;
- (void)invalidateLayer;
@end

static GDTCompositorServicesRenderer *active_renderer = nil;
static std::mutex presentation_mutex;
static std::shared_ptr<VisionOSPresentation> current_presentation;

std::shared_ptr<VisionOSPresentation> visionos_get_presentation() {
	std::lock_guard<std::mutex> lock(presentation_mutex);
	return current_presentation;
}

static VisionOSEngineThread &engine_thread() {
	static VisionOSEngineThread *owner = [] {
		auto *thread = new VisionOSEngineThread;
		thread->start();
		return thread;
	}();
	return *owner;
}

void visionos_dispatch_to_engine(void (^block)(void)) {
	if (GDTAppDelegateServiceVisionOS.renderMode == GDTRenderModeCompositorServices) {
		engine_thread().post([block] {
			@autoreleasepool {
				block();
			}
		});
	} else {
		dispatch_async(dispatch_get_main_queue(), block);
	}
}

void visionos_finish_engine() {
	auto presentation = visionos_get_presentation();
	if (presentation) {
		presentation->stop();
	}
	engine_thread().finish([] {
		@autoreleasepool {
			if (active_renderer) {
				[active_renderer invalidateLayer];
			}
			apple_embedded_finish();
		}
	});
}

@implementation GDTCompositorServicesRenderer {
	cp_layer_renderer_t _layer_renderer;
	cp_layer_renderer_capabilities_t _layer_renderer_capabilities;
	cp_layer_renderer_state _previous_state;
	void (^_completion)(void);
	uint32_t _diagnostic_frames;
	BOOL _rendered_frame;
	std::shared_ptr<VisionOSPresentation> _presentation;
}

@synthesize alphaBlendEnabled = _alphaBlendEnabled;

- (void)setAlphaBlendEnabled:(BOOL)enabled {
	_alphaBlendEnabled = enabled;
	if (_presentation) {
		_presentation->request_alpha_blend(enabled);
	}
}

- (instancetype)initWithLayerRenderer:(cp_layer_renderer_t)layer_renderer
						 capabilities:(cp_layer_renderer_capabilities_t)capabilities {
	self = [super init];
	if (self) {
		_layer_renderer = layer_renderer;
		_layer_renderer_capabilities = capabilities;
	}
	return self;
}

// On visionOS Compositor Services mode (used by the visionOS XR module),
// there's no way to easily show the boot logo on a simple quad.
- (void)performOnEngineThread:(void (^)(void))block {
	NSAssert(!NSThread.isMainThread, @"Immersive engine work must not run on UIKit's main thread.");
	block();
}

- (void)setUpProjectDataShowingBootLogo:(BOOL)p_show_boot_logo {
	[super setUpProjectDataShowingBootLogo:NO];
}

- (void)updateXRInterface {
	Ref<VisionOSXRInterface> visionos_xr_interface = VisionOSXRInterface::find_interface();
	if (visionos_xr_interface.is_valid()) {
		visionos_xr_interface->update_layer_renderer(_layer_renderer, _layer_renderer_capabilities);
	}
}

- (GDTCompositorStartupState)startupState {
	if (!_presentation) {
		return GDTCompositorStartupStateLoading;
	}
	switch (_presentation->get_startup_state()) {
		case VisionOSStartupStatus::LOADING:
			return GDTCompositorStartupStateLoading;
		case VisionOSStartupStatus::PREPARING_PIPELINES:
			return GDTCompositorStartupStatePreparingPipelines;
		case VisionOSStartupStatus::TRACKING_UNAVAILABLE:
			return GDTCompositorStartupStateTrackingUnavailable;
		case VisionOSStartupStatus::FRAME_UNAVAILABLE:
			return GDTCompositorStartupStateFrameUnavailable;
		case VisionOSStartupStatus::READY:
			return GDTCompositorStartupStateReady;
		case VisionOSStartupStatus::FAILED:
			return GDTCompositorStartupStateFailed;
		case VisionOSStartupStatus::CLOSED:
			return GDTCompositorStartupStateClosed;
	}
}

- (void)startRenderLoopWithCompletion:(void (^)(void))completion {
	_completion = [completion copy];
	// Begin servicing Compositor Services before project setup or Main::iteration.
	// Neither path can borrow this owner's frame or drawable.
	_presentation = std::make_shared<VisionOSPresentation>(_layer_renderer, _layer_renderer_capabilities, _alphaBlendEnabled);
	{
		std::lock_guard<std::mutex> lock(presentation_mutex);
		if (current_presentation) {
			current_presentation->stop();
		}
		current_presentation = _presentation;
	}
	_presentation->start();
	visionos_dispatch_to_engine(^{
		static bool did_set_up = false;
		if (active_renderer) {
			[active_renderer invalidateLayer];
		}
		GDTAppDelegateServiceVisionOS.layerRenderer = self->_layer_renderer;
		GDTAppDelegateServiceVisionOS.layerRendererCapabilities = self->_layer_renderer_capabilities;
		if (!did_set_up) {
			[self setUp];
			did_set_up = true;
			NSLog(@"visionOS compositor engine setup finished (dedicated owner)");
			VisionOSRenderDiagnostics::schedule_watchdogs();
		} else {
			[self updateXRInterface];
		}
		NSAssert(Thread::is_main_thread(), @"The immersive owner must be Godot's main thread.");
		self->_previous_state = cp_layer_renderer_state_running;
		active_renderer = self;
		Ref<VisionOSXRInterface> interface = VisionOSXRInterface::find_interface();
		if (interface.is_valid()) {
			interface->emit_signal_enum(VisionOSXRInterface::VISIONOS_XR_SIGNAL_SESSION_STARTED);
		}
		engine_thread().set_iteration([self] {
			@autoreleasepool {
				return [self iterateLayer];
			}
		});
	});
}

- (uint32_t)iterateLayer {
	Ref<VisionOSXRInterface> visionos_xr_interface = VisionOSXRInterface::find_interface();
	cp_layer_renderer_state state = cp_layer_renderer_get_state(_layer_renderer);
	if (state == cp_layer_renderer_state_invalidated || _presentation->is_stopped()) {
		[self invalidateLayer];
		return 2;
	}
	if (state == cp_layer_renderer_state_paused) {
		if (_previous_state == cp_layer_renderer_state_running && visionos_xr_interface.is_valid()) {
			visionos_xr_interface->emit_signal_enum(VisionOSXRInterface::VISIONOS_XR_SIGNAL_SESSION_PAUSED);
		}
		_previous_state = state;
		// An interruptible wait also services focus, authorization and teardown.
		return 10;
	}
	if (_previous_state == cp_layer_renderer_state_paused && visionos_xr_interface.is_valid()) {
		visionos_xr_interface->emit_signal_enum(VisionOSXRInterface::VISIONOS_XR_SIGNAL_SESSION_RESUMED);
	}
	_previous_state = state;
	[self renderFrame];
	return _rendered_frame ? 1 : 2;
}

- (void)invalidateLayer {
	_presentation->stop();
	Ref<VisionOSXRInterface> interface = VisionOSXRInterface::find_interface();
	if (interface.is_valid()) {
		interface->emit_signal_enum(VisionOSXRInterface::VISIONOS_XR_SIGNAL_SESSION_INVALIDATED);
		interface->update_layer_renderer(nullptr, nullptr);
	}
	{
		std::lock_guard<std::mutex> lock(presentation_mutex);
		if (current_presentation == _presentation) {
			current_presentation.reset();
		}
	}
	GDTAppDelegateServiceVisionOS.layerRenderer = nil;
	engine_thread().set_iteration({});
	if (_completion) {
		dispatch_async(dispatch_get_main_queue(), _completion);
		_completion = nil;
	}
	active_renderer = nil;
}

- (void)renderFrame {
	NSAssert(!NSThread.isMainThread && Thread::is_main_thread(), @"Invalid immersive iteration owner.");
	_rendered_frame = NO;
	if (!OS_AppleEmbedded::get_singleton() || cp_layer_renderer_get_state(_layer_renderer) != cp_layer_renderer_state_running) {
		return;
	}
	CFTimeInterval start = CACurrentMediaTime();
	auto startup_diagnostics = visionos_get_startup_diagnostics();
	if (startup_diagnostics) {
		startup_diagnostics->iteration_begin(start);
	}
	uint64_t diagnostic_iteration = 0;
	if (VisionOSRenderDiagnostics::enabled()) {
		diagnostic_iteration = VisionOSRenderDiagnostics::iterations().fetch_add(1) + 1;
	}
	if (_diagnostic_frames < 4) {
		NSLog(@"visionOS immersive iteration %u begin (UIKit main: no)", _diagnostic_frames);
		uint32_t frame = _diagnostic_frames;
		dispatch_async(dispatch_get_main_queue(), ^{
			NSLog(@"visionOS UIKit serviced immersive iteration %u", frame);
		});
	}
	VisionOSRenderDiagnostics::scene(diagnostic_iteration, true);
	OS_AppleEmbedded::get_singleton()->iterate();
	if (startup_diagnostics) {
		startup_diagnostics->iteration_end(CACurrentMediaTime());
	}
	VisionOSRenderDiagnostics::scene(diagnostic_iteration);
	Ref<VisionOSXRInterface> visionos_xr_interface = VisionOSXRInterface::find_interface();
	_rendered_frame = visionos_xr_interface.is_valid() && visionos_xr_interface->has_rendered_frame();
	if (_diagnostic_frames < 4) {
		NSLog(@"visionOS immersive iteration %u end (scene encoded: %d, elapsed_ms: %.1f)", _diagnostic_frames, _rendered_frame, (CACurrentMediaTime() - start) * 1000.0);
		_diagnostic_frames++;
	}
}

- (void)worldRecentered {
	visionos_dispatch_to_engine(^{
		if (active_renderer != self) {
			return;
		}
		Ref<VisionOSXRInterface> interface = VisionOSXRInterface::find_interface();
		if (interface.is_valid()) {
			interface->emit_signal_enum(VisionOSXRInterface::VISIONOS_XR_SIGNAL_POSE_RECENTERED);
		}
	});
}

@end

#else

void visionos_dispatch_to_engine(void (^block)(void)) {
	dispatch_async(dispatch_get_main_queue(), block);
}

void visionos_finish_engine() {
	apple_embedded_finish();
}

@implementation GDTCompositorServicesRenderer

- (GDTCompositorStartupState)startupState {
	return GDTCompositorStartupStateFailed;
}

- (instancetype)initWithLayerRenderer:(cp_layer_renderer_t)layer_renderer
						 capabilities:(cp_layer_renderer_capabilities_t)capabilities {
	self = [super init];
	return self;
}

- (void)updateXRInterface {
}

- (void)startRenderLoopWithCompletion:(void (^)(void))completion {
	completion();
}

- (void)renderFrame {
}

- (void)worldRecentered {
}

@end

#endif
