#import "xr_vision_interop.h"
#import "os_ios.h"
#include <CoreFoundation/CoreFoundation.h>

#include "core/config/project_settings.h"
#include "drivers/coreaudio/audio_driver_coreaudio.h"
#include "drivers/metal/rendering_device_driver_metal.h"
#include "servers/rendering/rendering_server_globals.h"
#include "main/main.h"

#import "drivers/metal/metal_objects.h"
#import <ARKit/ARKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioServices.h>
#import <CompositorServices/CompositorServices.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <Spatial/Spatial.h>

// External variables and functions
extern int gargc;
extern char **gargv;

static OS_IOS *os = nullptr;

extern int ios_main(int, char **);
extern void ios_finish();

@implementation XRVisionInterop {
	__unsafe_unretained cp_layer_renderer_t _layerRenderer;
	cp_frame_timing_t _timing;
	cp_frame_t _frame;
	cp_drawable_t _drawable;
	CGSize _currentResolution;
}

enum {
	SESSION_CATEGORY_AMBIENT,
	SESSION_CATEGORY_MULTI_ROUTE,
	SESSION_CATEGORY_PLAY_AND_RECORD,
	SESSION_CATEGORY_PLAYBACK,
	SESSION_CATEGORY_RECORD,
	SESSION_CATEGORY_SOLO_AMBIENT
};

// Static singleton instance
static XRVisionInterop *singleton = nil;

// Singleton getter
+ (XRVisionInterop *)get_singleton {
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		singleton = [[self alloc] init];
	});
	return singleton;
}


// Setup method
- (BOOL)setup:(cp_layer_renderer_t )renderer {

	NSLog(@"setup Called");
	_layerRenderer = renderer;
	// Initialize the default resolution (example values)
	// _currentResolution =  (Size2i){2732, 2048};
	_currentResolution = CGSizeMake(2732, 2048);
	const char *arg0 = [[[NSBundle mainBundle] executablePath] UTF8String]; // Path to the running application
    const char *arg1 = "--runLoopHandledByHost"; // Additional argument
    const char *newArgv[] = { arg0, arg1 };
    int newArgc = sizeof(newArgv) / sizeof(newArgv[0]);

    // Pass new arguments to ios_main
    int err = ios_main(newArgc, (char **)newArgv);
    if (err != 0) {
        // Exit if initialization fails
        exit(0);
		NSLog(@"Setup Failed");
        return NO;
    }

	// Add observer for audio interruptions
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(onAudioInterruption:)
												 name:AVAudioSessionInterruptionNotification
											   object:[AVAudioSession sharedInstance]];

	// Configure audio session
	int sessionCategorySetting = GLOBAL_GET("audio/general/ios/session_category");

	// Default to Ambient category
	AVAudioSessionCategory category = AVAudioSessionCategoryAmbient;
	AVAudioSessionCategoryOptions options = 0;

	if (GLOBAL_GET("audio/general/ios/mix_with_others")) {
		options |= AVAudioSessionCategoryOptionMixWithOthers;
	}

	switch (sessionCategorySetting) {
		case SESSION_CATEGORY_MULTI_ROUTE:
			category = AVAudioSessionCategoryMultiRoute;
			break;
		case SESSION_CATEGORY_PLAY_AND_RECORD:
			category = AVAudioSessionCategoryPlayAndRecord;
			options |= AVAudioSessionCategoryOptionDefaultToSpeaker;
			options |= AVAudioSessionCategoryOptionAllowBluetoothA2DP;
			options |= AVAudioSessionCategoryOptionAllowAirPlay;
			break;
		case SESSION_CATEGORY_PLAYBACK:
			category = AVAudioSessionCategoryPlayback;
			break;
		case SESSION_CATEGORY_RECORD:
			category = AVAudioSessionCategoryRecord;
			break;
		case SESSION_CATEGORY_SOLO_AMBIENT:
			category = AVAudioSessionCategorySoloAmbient;
			break;
		default:
			break;
	}

	[[AVAudioSession sharedInstance] setCategory:category withOptions:options error:nil];
	runWorldTrackingARSession();
	return YES;
}

// Get the current resolution
- (CGSize)getResolution {
	return _currentResolution;
}
// Getter for renderer
- (cp_layer_renderer_t __unsafe_unretained)layerRenderer {
    return (cp_layer_renderer_t)_layerRenderer;
}
- (cp_frame_timing_t)timing {
	return _timing;
}
- (cp_frame_t)frame {
	return _frame;
}
- (cp_drawable_t)drawable {
	return _drawable;
}

- (void)iterate {

	NSLog(@"iterate Called");
	RenderingDevice *rendering_device = RenderingDevice::get_singleton();
	if (!rendering_device) {
		NSLog(@"RenderingDevice is null.");
		return;
	}
	rendering_device->make_current();
	cp_layer_renderer_t layerRenderer = _layerRenderer;
	if (!layerRenderer) {
		NSLog(@"Layer renderer is null.");
		return;
	}
	else{
		NSLog(@"XR Vission Interop: Layer renderer is not null.");
	}
	RenderingServer *rendering_server = RenderingServer::get_singleton();
    if (!rendering_server) {
        NSLog(@"RenderingServer is null.");
        return;
    }

    // RenderingDevice *rendering_device = rendering_server->get_rendering_device();
    // if (!rendering_device) {
    //     NSLog(@"RenderingDevice is null.");
    //     return;
    // }

    // Get the Metal device from the rendering device
    // void *our_metal_device = (void *)rendering_device->get_driver_resource(RD::DRIVER_RESOURCE_LOGICAL_DEVICE);
    // if (!our_metal_device) {
    //     NSLog(@"Our Metal device is null.");
    //     return;
    // }
	

    // // Compare with the compositor's Metal device
    // id<MTLDevice> compositor_metal_device = cp_layer_renderer_get_device(layerRenderer);
    // if (compositor_metal_device != our_metal_device) {
    //     NSLog(@"Metal device mismatch: compositor = %p, our device = %p", compositor_metal_device, our_metal_device);
    //     return;
    // }

    // Query the next frame from the layer renderer
    cp_frame_t __frame = cp_layer_renderer_query_next_frame(layerRenderer);

	_frame = __frame;
	if(_frame == nullptr) {
		NSLog(@"Frame is null");
		return;
	}

	cp_frame_timing_t __timing = cp_frame_predict_timing(_frame);
	_timing = __timing;
	if (_timing == nullptr) {
		NSLog(@"Timing is null");
		return;
	}
	bool shouldContinue = [self pre_draw_viewport];
	if (!shouldContinue) {
		NSLog(@"pre_draw is not ready");
		cp_frame_end_submission(_frame);
		return;
	}
	//gather_inputs(engine, timing);
	//update_frame(engine, timing, input_state);
	NSLog(@"OS-> Iterate");
	os->iterate();


	//We need to hook into the end of the drawing and call cp_frame_end_submission(frame) to submit the frame
	cp_frame_end_submission(_frame);
}

- (bool)pre_draw_viewport {
        NSLog(@"pre-render.");
	RenderingDevice *rendering_device = RenderingDevice::get_singleton();
	if (!rendering_device) {
		NSLog(@"RenderingDevice is null.");
		return false;
	}
	rendering_device->make_current();
	cp_frame_start_update(_frame);

	cp_time_wait_until(cp_frame_timing_get_optimal_input_time(_timing));

	cp_frame_start_submission(_frame);
	cp_drawable_t __drawable = cp_frame_query_drawable(_frame);
	if (__drawable == nullptr) {
		//If no drawable, we can't render
		//so we will return false on the pre_draw_viewport
		_drawable = nullptr;
		NSLog(@"No drawable found");
		return false;
	}
	//Now that we have the drawable, we can
	//This is all the normal drawing code!
	_drawable = __drawable;
	NSLog(@"Drawable Setup found");
	
	//We will setup and do the AR stuff in pre_draw_viewport
	cp_frame_timing_t actualTiming = cp_drawable_get_frame_timing(_drawable);

	_timing = actualTiming;
	// return true;
	ar_device_anchor_t anchor = createPoseForTiming(actualTiming);
	cp_drawable_set_device_anchor(_drawable, anchor);
	return true;
}

-(MTLViewport)viewportForViewIndex:(size_t)index {
	NSLog(@"Viewport for view index called");
    cp_view_t view = cp_drawable_get_view(_drawable, index);
	if(view == nullptr) {
		NSLog(@"View is null");
	}else{
		NSLog(@"We have the view");
	}
    cp_view_texture_map_t texture_map = cp_view_get_view_texture_map(view);
	if(texture_map == nullptr) {
		NSLog(@"Texture map is null");
	}else{
		NSLog(@"We have the texture map");
	}
    MTLViewport vp = cp_view_texture_map_get_viewport(texture_map);
	if(vp.originX == 0 && vp.originY == 0 && vp.width == 0 && vp.height == 0) {
		NSLog(@"Viewport is null");
	}else{
		NSLog(@"We have the viewport");
	}
	return vp;
}

- (void)setResolutionWithWidth:(int)width height:(int)height {
	// Update the internal resolution
	_currentResolution.width = width;
	_currentResolution.height = height;
}
// Audio interruption handler
- (void)onAudioInterruption:(NSNotification *)notification {
	if ([notification.name isEqualToString:AVAudioSessionInterruptionNotification]) {
		NSNumber *type = notification.userInfo[AVAudioSessionInterruptionTypeKey];
		if (type.intValue == AVAudioSessionInterruptionTypeBegan) {
			NSLog(@"Audio interruption began");
			OS_IOS::get_singleton()->on_focus_out();
		} else if (type.intValue == AVAudioSessionInterruptionTypeEnded) {
			NSLog(@"Audio interruption ended");
			OS_IOS::get_singleton()->on_focus_in();
		}
	}
}

void runWorldTrackingARSession() {
	ar_world_tracking_configuration_t worldTrackingConfiguration = ar_world_tracking_configuration_create();
	_worldTrackingProvider = ar_world_tracking_provider_create(worldTrackingConfiguration);

	ar_data_providers_t dataProviders = ar_data_providers_create_with_data_providers(_worldTrackingProvider, nil);

	_arSession = ar_session_create();
	ar_session_run(_arSession, dataProviders);
}

ar_device_anchor_t createPoseForTiming(cp_frame_timing_t timing) {
	ar_device_anchor_t outAnchor = ar_device_anchor_create();
	cp_time_t presentationTime = cp_frame_timing_get_presentation_time(timing);
	CFTimeInterval queryTime = cp_time_to_cf_time_interval(presentationTime);
	ar_device_anchor_query_status_t status = ar_world_tracking_provider_query_device_anchor_at_timestamp(_worldTrackingProvider, queryTime, outAnchor);
	if (status != ar_device_anchor_query_status_success) {
		NSLog(@"Failed to get estimated pose from world tracking provider for presentation timestamp %0.3f", queryTime);
	}
	return outAnchor;
}

ar_session_t _arSession;
ar_world_tracking_provider_t _worldTrackingProvider;
bool _running = true;

// AppDelegate lifecycle methods
- (void)applicationDidReceiveMemoryWarning {
	if (OS::get_singleton()->get_main_loop()) {
		OS::get_singleton()->get_main_loop()->notification(MainLoop::NOTIFICATION_OS_MEMORY_WARNING);
	}
}

- (void)applicationWillTerminate {
	ios_finish();
}

- (void)applicationWillResignActive {
	OS_IOS::get_singleton()->on_focus_out();
}

- (void)applicationDidBecomeActive {
	OS_IOS::get_singleton()->on_focus_in();
}

- (void)applicationDidEnterBackground {
	OS_IOS::get_singleton()->on_enter_background();
}

- (void)applicationWillEnterForeground {
	OS_IOS::get_singleton()->on_exit_background();
}
@end
