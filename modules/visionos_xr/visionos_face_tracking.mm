/**************************************************************************/
/*  visionos_face_tracking.mm                                             */
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

#ifdef VISIONOS_ENABLED

#include "visionos_face_tracking.h"

#include "core/os/os.h"
#include "core/string/print_string.h"
#include "servers/xr/xr_server.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#include <dlfcn.h>

#include <algorithm>
#include <cmath>

namespace {

constexpr double FACE_TIMEOUT_MSEC = 1000.0;
constexpr uint64_t START_DELAY_MSEC = 2000;
constexpr double MIN_FRAME_INTERVAL = 1.0 / 24.0;
constexpr int WARMUP_FRAMES = 20;

_FORCE_INLINE_ float clamp01(float p_value) {
	return std::clamp(p_value, 0.0f, 1.0f);
}

// A neutral value learned while the face is in use. Separate rates for rising
// and falling values let it follow, for example, the open-eye level while
// ignoring blinks.
struct Baseline {
	float value = 0.0f;
	bool set = false;

	void feed(float p_value, float p_rise, float p_fall) {
		if (!set) {
			value = p_value;
			set = true;
			return;
		}
		value += (p_value - value) * (p_value > value ? p_rise : p_fall);
	}
};

struct Region {
	float min_x = 0.0f, max_x = 0.0f, min_y = 0.0f, max_y = 0.0f;
	float cx = 0.0f, cy = 0.0f;
	// Points at the smallest and largest x: the eye or mouth corners.
	CGPoint first = CGPointZero, last = CGPointZero;
	bool valid = false;

	float width() const { return max_x - min_x; }
	float height() const { return max_y - min_y; }
};

// Landmark measurements of one frame, in face widths, rolled level, with
// x pointing to the right of the image and y up. Index 0 is the image-left
// feature and 1 the image-right one.
struct Measurements {
	float eye_open[2] = {};
	float pupil_x[2] = {};
	float pupil_y[2] = {};
	float brow[2] = {};
	float corner_lift[2] = {};
	float mouth_open = 0.0f;
	float mouth_width = 0.0f;
	bool has_pupils = false;
};

} // namespace

@interface GDTVisionOSFaceCapture : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate> {
	std::shared_ptr<VisionOSFaceTracking::Shared> shared;
	BOOL mirrored;
	BOOL stopped;
	dispatch_queue_t session_queue;
	dispatch_queue_t video_queue;
	AVCaptureSession *session;
	VNDetectFaceLandmarksRequest *request;
	NSMutableArray *observers;

	CFTimeInterval last_frame_time;
	uint64_t frames;
	uint64_t faces;
	uint64_t face_frames_since_log;

	Baseline eye_open[2];
	Baseline pupil_x[2];
	Baseline pupil_y[2];
	Baseline brow[2];
	Baseline corner_lift[2];
	Baseline mouth_rest;
	Baseline mouth_width;
	float smoothed[XRFaceTracker::FT_MAX];
}

- (instancetype)initWithShared:(std::shared_ptr<VisionOSFaceTracking::Shared>)p_shared mirrored:(BOOL)p_mirrored;
- (void)start;
- (void)stop;

@end

// Vision is loaded at runtime rather than linked, so apps that leave face
// tracking off don't need the framework in their Xcode project.
static Class face_vision_class(NSString *p_name) {
	static void *vision = dlopen("/System/Library/Frameworks/Vision.framework/Vision", RTLD_LAZY);
	return vision ? NSClassFromString(p_name) : nil;
}

@implementation GDTVisionOSFaceCapture

- (instancetype)initWithShared:(std::shared_ptr<VisionOSFaceTracking::Shared>)p_shared mirrored:(BOOL)p_mirrored {
	self = [super init];
	if (self) {
		shared = p_shared;
		mirrored = p_mirrored;
		session_queue = dispatch_queue_create("org.godotengine.visionos.face.session", DISPATCH_QUEUE_SERIAL);
		video_queue = dispatch_queue_create("org.godotengine.visionos.face.video", DISPATCH_QUEUE_SERIAL);
		request = [[face_vision_class(@"VNDetectFaceLandmarksRequest") alloc] init];
		observers = [NSMutableArray array];
		for (int i = 0; i < XRFaceTracker::FT_MAX; i++) {
			smoothed[i] = 0.0f;
		}
	}
	return self;
}

- (void)start {
	if (request == nil) {
		print_line("[visionos face] the Vision framework is unavailable");
		return;
	}
	AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
	print_line(vformat("[visionos face] camera authorization status %d", (int)status));
	__weak GDTVisionOSFaceCapture *weak_self = self;
	switch (status) {
		case AVAuthorizationStatusAuthorized: {
			dispatch_async(session_queue, ^{
				[weak_self configureAndRun];
			});
		} break;
		case AVAuthorizationStatusNotDetermined: {
			print_line("[visionos face] requesting camera access");
			[AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
									 completionHandler:^(BOOL granted) {
										 GDTVisionOSFaceCapture *strong_self = weak_self;
										 if (!strong_self) {
											 return;
										 }
										 if (granted) {
											 dispatch_async(strong_self->session_queue, ^{
												 [weak_self configureAndRun];
											 });
										 } else {
											 print_line(vformat("[visionos face] camera access denied (status now %d)", (int)[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]));
										 }
									 }];
		} break;
		default:
			print_line("[visionos face] camera access denied or restricted; allow it in Settings > Privacy & Security > Camera");
			break;
	}
}

- (void)configureAndRun {
	if (stopped) {
		return;
	}
	AVCaptureDevice *device = AVCaptureDevice.systemPreferredCamera;
	if (device == nil) {
		device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
	}
	if (device == nil) {
		print_line("[visionos face] no camera available");
		return;
	}

	NSError *error = nil;
	AVCaptureDeviceInput *input = [[AVCaptureDeviceInput alloc] initWithDevice:device error:&error];
	if (input == nil) {
		print_line(vformat("[visionos face] cannot open camera %s: %s", String::utf8(device.localizedName.UTF8String), String::utf8(error.localizedDescription.UTF8String)));
		return;
	}

	AVCaptureSession *new_session = [[AVCaptureSession alloc] init];
	[new_session beginConfiguration];
	if (![new_session canAddInput:input]) {
		print_line("[visionos face] cannot add camera input");
		[new_session commitConfiguration];
		return;
	}
	[new_session addInput:input];

	AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
	output.alwaysDiscardsLateVideoFrames = YES;
	output.videoSettings = @{ (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) };
	[output setSampleBufferDelegate:self queue:video_queue];
	if (![new_session canAddOutput:output]) {
		print_line("[visionos face] cannot add video output");
		[new_session commitConfiguration];
		return;
	}
	[new_session addOutput:output];
	[new_session commitConfiguration];

	NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
	[observers addObject:[center addObserverForName:AVCaptureSessionRuntimeErrorNotification
											 object:new_session
											  queue:nil
										 usingBlock:^(NSNotification *note) {
											 NSError *e = note.userInfo[AVCaptureSessionErrorKey];
											 print_line(vformat("[visionos face] capture error: %s", String::utf8(e.localizedDescription.UTF8String)));
										 }]];
	[observers addObject:[center addObserverForName:AVCaptureSessionWasInterruptedNotification
											 object:new_session
											  queue:nil
										 usingBlock:^(NSNotification *note) {
											 NSNumber *reason = note.userInfo[AVCaptureSessionInterruptionReasonKey];
											 print_line(vformat("[visionos face] capture interrupted (reason %d)", reason ? reason.intValue : -1));
										 }]];
	[observers addObject:[center addObserverForName:AVCaptureSessionInterruptionEndedNotification
											 object:new_session
											  queue:nil
										 usingBlock:^(NSNotification *note) {
											 print_line("[visionos face] capture resumed");
										 }]];

	session = new_session;
	[session startRunning];
	print_line(vformat("[visionos face] camera '%s' running: %s", String::utf8(device.localizedName.UTF8String), session.running ? "yes" : "no"));
}

- (void)stop {
	stopped = YES;
	for (id observer in observers) {
		[NSNotificationCenter.defaultCenter removeObserver:observer];
	}
	[observers removeAllObjects];
	AVCaptureSession *old_session = session;
	session = nil;
	if (old_session) {
		dispatch_async(session_queue, ^{
			[old_session stopRunning];
		});
	}
}

static Region region_in_face(VNFaceLandmarkRegion2D *p_region, CGSize p_size, CGPoint p_center, float p_cos, float p_sin, float p_scale) {
	Region r;
	if (p_region == nil || p_region.pointCount == 0) {
		return r;
	}
	const CGPoint *points = [p_region pointsInImageOfSize:p_size];
	r.min_x = r.min_y = INFINITY;
	r.max_x = r.max_y = -INFINITY;
	for (NSUInteger i = 0; i < p_region.pointCount; i++) {
		float dx = points[i].x - p_center.x;
		float dy = points[i].y - p_center.y;
		CGPoint p = CGPointMake((dx * p_cos + dy * p_sin) / p_scale, (-dx * p_sin + dy * p_cos) / p_scale);
		if (p.x < r.min_x) {
			r.min_x = p.x;
			r.first = p;
		}
		if (p.x > r.max_x) {
			r.max_x = p.x;
			r.last = p;
		}
		r.min_y = MIN(r.min_y, (float)p.y);
		r.max_y = MAX(r.max_y, (float)p.y);
		r.cx += p.x;
		r.cy += p.y;
	}
	r.cx /= p_region.pointCount;
	r.cy /= p_region.pointCount;
	r.valid = true;
	return r;
}

static bool measure(VNFaceObservation *p_face, CGSize p_size, Measurements &r_out) {
	VNFaceLandmarks2D *lm = p_face.landmarks;
	if (lm == nil || lm.leftEye == nil || lm.rightEye == nil || lm.outerLips == nil || lm.innerLips == nil) {
		return false;
	}
	CGRect box = p_face.boundingBox;
	CGPoint center = CGPointMake((box.origin.x + box.size.width * 0.5) * p_size.width, (box.origin.y + box.size.height * 0.5) * p_size.height);
	float scale = MAX(1.0f, (float)(box.size.width * p_size.width));

	// Level the face using the line between the eyes, so head roll does not read as expression.
	Region a = region_in_face(lm.leftEye, p_size, center, 1, 0, scale);
	Region b = region_in_face(lm.rightEye, p_size, center, 1, 0, scale);
	if (!a.valid || !b.valid) {
		return false;
	}
	bool left_is_image_left = a.cx < b.cx;
	float ex = (left_is_image_left ? b.cx - a.cx : a.cx - b.cx);
	float ey = (left_is_image_left ? b.cy - a.cy : a.cy - b.cy);
	float angle = std::atan2(ey, ex);
	float c = std::cos(angle), s = std::sin(angle);

	VNFaceLandmarkRegion2D *eyes[2] = { left_is_image_left ? lm.leftEye : lm.rightEye, left_is_image_left ? lm.rightEye : lm.leftEye };
	VNFaceLandmarkRegion2D *brows[2] = { left_is_image_left ? lm.leftEyebrow : lm.rightEyebrow, left_is_image_left ? lm.rightEyebrow : lm.leftEyebrow };
	VNFaceLandmarkRegion2D *pupils[2] = { left_is_image_left ? lm.leftPupil : lm.rightPupil, left_is_image_left ? lm.rightPupil : lm.leftPupil };

	r_out.has_pupils = true;
	for (int i = 0; i < 2; i++) {
		Region eye = region_in_face(eyes[i], p_size, center, c, s, scale);
		if (!eye.valid || eye.width() <= 0.0f) {
			return false;
		}
		r_out.eye_open[i] = eye.height() / eye.width();
		// The eye corners stay put while blinking, unlike the eye's center.
		float corner_y = (eye.first.y + eye.last.y) * 0.5f;
		Region brow = region_in_face(brows[i], p_size, center, c, s, scale);
		r_out.brow[i] = brow.valid ? brow.cy - corner_y : 0.0f;
		Region pupil = region_in_face(pupils[i], p_size, center, c, s, scale);
		if (pupil.valid) {
			float half = eye.width() * 0.5f;
			r_out.pupil_x[i] = (pupil.cx - (eye.first.x + eye.last.x) * 0.5f) / half;
			r_out.pupil_y[i] = (pupil.cy - corner_y) / half;
		} else {
			r_out.has_pupils = false;
		}
	}

	Region outer = region_in_face(lm.outerLips, p_size, center, c, s, scale);
	Region inner = region_in_face(lm.innerLips, p_size, center, c, s, scale);
	if (!outer.valid || !inner.valid) {
		return false;
	}
	r_out.mouth_open = inner.height();
	r_out.mouth_width = outer.width();
	r_out.corner_lift[0] = outer.first.y - outer.cy;
	r_out.corner_lift[1] = outer.last.y - outer.cy;
	return true;
}

- (void)captureOutput:(AVCaptureOutput *)p_output didOutputSampleBuffer:(CMSampleBufferRef)p_buffer fromConnection:(AVCaptureConnection *)p_connection {
	if (stopped) {
		return;
	}
	CFTimeInterval now = CACurrentMediaTime();
	if (now - last_frame_time < MIN_FRAME_INTERVAL) {
		return;
	}
	last_frame_time = now;

	CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(p_buffer);
	if (pixels == nullptr) {
		return;
	}
	CGSize size = CGSizeMake(CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels));
	if (frames++ == 0) {
		print_line(vformat("[visionos face] first camera frame %dx%d", (int)size.width, (int)size.height));
	}

	VNImageRequestHandler *handler = [[face_vision_class(@"VNImageRequestHandler") alloc] initWithCVPixelBuffer:pixels orientation:kCGImagePropertyOrientationUp options:@{}];
	NSError *error = nil;
	if (![handler performRequests:@[ request ] error:&error]) {
		return;
	}

	VNFaceObservation *face = nil;
	for (VNFaceObservation *candidate in request.results) {
		if (face == nil || candidate.boundingBox.size.width * candidate.boundingBox.size.height > face.boundingBox.size.width * face.boundingBox.size.height) {
			face = candidate;
		}
	}

	Measurements m;
	bool found = face != nil && measure(face, size, m);
	float target[XRFaceTracker::FT_MAX] = {};
	if (found) {
		if (faces++ == 0) {
			print_line("[visionos face] face found");
		}
		face_frames_since_log++;
		[self estimate:m into:target];
	}

	// Smooth towards the target, and drop straight to zero when the face is lost.
	for (int i = 0; i < XRFaceTracker::FT_MAX; i++) {
		smoothed[i] = found ? smoothed[i] + (target[i] - smoothed[i]) * 0.6f : 0.0f;
	}

	{
		MutexLock lock(shared->mutex);
		for (int i = 0; i < XRFaceTracker::FT_MAX; i++) {
			shared->weights[i] = smoothed[i];
		}
		shared->face_found = found;
		shared->serial++;
	}

	if (frames % 240 == 0) {
		print_line(vformat("[visionos face] %d of last 240 frames had a face; blink %.2f/%.2f jaw %.2f smile %.2f/%.2f brow %.2f/%.2f",
				(int)face_frames_since_log, smoothed[XRFaceTracker::FT_EYE_CLOSED_LEFT], smoothed[XRFaceTracker::FT_EYE_CLOSED_RIGHT],
				smoothed[XRFaceTracker::FT_JAW_OPEN], smoothed[XRFaceTracker::FT_MOUTH_CORNER_PULL_LEFT], smoothed[XRFaceTracker::FT_MOUTH_CORNER_PULL_RIGHT],
				smoothed[XRFaceTracker::FT_BROW_INNER_UP_LEFT], smoothed[XRFaceTracker::FT_BROW_INNER_UP_RIGHT]));
		face_frames_since_log = 0;
	}
}

- (void)estimate:(const Measurements &)m into:(float *)w {
	bool warm = faces <= WARMUP_FRAMES;
	float slow = warm ? 0.2f : 0.003f;

	// The unmirrored camera sees the wearer's left side on the image's right.
	const int user_left = mirrored ? 0 : 1;

	float closed[2];
	for (int i = 0; i < 2; i++) {
		eye_open[i].feed(m.eye_open[i], warm ? 0.2f : 0.05f, warm ? 0.2f : 0.001f);
		float ratio = m.eye_open[i] / MAX(eye_open[i].value, 0.01f);
		closed[i] = clamp01((0.8f - ratio) / 0.5f);
		float wide = clamp01((ratio - 1.2f) / 0.35f);

		brow[i].feed(m.brow[i], slow, slow);
		float d = m.brow[i] - brow[i].value;
		float up = clamp01((d - 0.006f) / 0.035f);
		float down = clamp01((-d - 0.006f) / 0.025f);

		corner_lift[i].feed(m.corner_lift[i], slow, slow);
		float lift = m.corner_lift[i] - corner_lift[i].value;

		bool left = i == user_left;
		w[left ? XRFaceTracker::FT_EYE_CLOSED_LEFT : XRFaceTracker::FT_EYE_CLOSED_RIGHT] = closed[i];
		w[left ? XRFaceTracker::FT_EYE_WIDE_LEFT : XRFaceTracker::FT_EYE_WIDE_RIGHT] = wide;
		w[left ? XRFaceTracker::FT_BROW_INNER_UP_LEFT : XRFaceTracker::FT_BROW_INNER_UP_RIGHT] = up;
		w[left ? XRFaceTracker::FT_BROW_OUTER_UP_LEFT : XRFaceTracker::FT_BROW_OUTER_UP_RIGHT] = up;
		w[left ? XRFaceTracker::FT_BROW_LOWERER_LEFT : XRFaceTracker::FT_BROW_LOWERER_RIGHT] = down;
		w[left ? XRFaceTracker::FT_MOUTH_FROWN_LEFT : XRFaceTracker::FT_MOUTH_FROWN_RIGHT] = clamp01((-lift - 0.006f) / 0.03f);
		w[left ? XRFaceTracker::FT_MOUTH_CORNER_PULL_LEFT : XRFaceTracker::FT_MOUTH_CORNER_PULL_RIGHT] = lift;
	}

	mouth_rest.feed(m.mouth_open, warm ? 0.2f : 0.002f, warm ? 0.2f : 0.05f);
	float jaw = clamp01((m.mouth_open - mouth_rest.value - 0.01f) / 0.14f);
	w[XRFaceTracker::FT_JAW_OPEN] = jaw;

	mouth_width.feed(m.mouth_width, slow, slow);
	float widen = m.mouth_width / MAX(mouth_width.value, 0.01f) - 1.0f;
	for (int side : { XRFaceTracker::FT_MOUTH_CORNER_PULL_LEFT, XRFaceTracker::FT_MOUTH_CORNER_PULL_RIGHT }) {
		float lift = w[side];
		w[side] = clamp01(MAX(lift - 0.004f, 0.0f) / 0.03f + MAX(widen - 0.04f, 0.0f) / 0.2f);
	}
	w[XRFaceTracker::FT_LIP_PUCKER] = clamp01((-widen - 0.08f) / 0.15f) * (1.0f - jaw);

	if (m.has_pupils) {
		float ux = 0.0f, uy = 0.0f;
		float open = 0.0f;
		for (int i = 0; i < 2; i++) {
			pupil_x[i].feed(m.pupil_x[i], warm ? 0.2f : 0.002f, warm ? 0.2f : 0.002f);
			pupil_y[i].feed(m.pupil_y[i], warm ? 0.2f : 0.002f, warm ? 0.2f : 0.002f);
			float weight = 1.0f - closed[i];
			ux += (m.pupil_x[i] - pupil_x[i].value) * weight;
			uy += (m.pupil_y[i] - pupil_y[i].value) * weight;
			open += weight;
		}
		if (open > 0.5f) {
			// Positive x is towards the wearer's left.
			ux = (mirrored ? -ux : ux) / open;
			uy /= open;
			auto shape = [](float v, float gain) { return clamp01((std::fabs(v) - 0.08f) * gain); };
			float to_left = ux > 0.0f ? shape(ux, 2.5f) : 0.0f;
			float to_right = ux < 0.0f ? shape(ux, 2.5f) : 0.0f;
			float up = uy > 0.0f ? shape(uy, 3.0f) : 0.0f;
			float down = uy < 0.0f ? shape(uy, 3.0f) : 0.0f;
			w[XRFaceTracker::FT_EYE_LOOK_OUT_LEFT] = to_left;
			w[XRFaceTracker::FT_EYE_LOOK_IN_RIGHT] = to_left;
			w[XRFaceTracker::FT_EYE_LOOK_IN_LEFT] = to_right;
			w[XRFaceTracker::FT_EYE_LOOK_OUT_RIGHT] = to_right;
			w[XRFaceTracker::FT_EYE_LOOK_UP_LEFT] = up;
			w[XRFaceTracker::FT_EYE_LOOK_UP_RIGHT] = up;
			w[XRFaceTracker::FT_EYE_LOOK_DOWN_LEFT] = down;
			w[XRFaceTracker::FT_EYE_LOOK_DOWN_RIGHT] = down;
		}
	}
}

@end

void VisionOSFaceTracking::initialize(XRServer *p_xr_server) {
	shared = std::make_shared<Shared>();
	tracker.instantiate();
	tracker->set_tracker_name("/user/face_tracker");
	tracker->set_tracker_desc("visionOS Persona camera face");
	p_xr_server->add_tracker(tracker);

	GDTVisionOSFaceCapture *face_capture = [[GDTVisionOSFaceCapture alloc] initWithShared:shared mirrored:mirrored];
	capture = (__bridge_retained void *)face_capture;
	started = false;
	active_since_msec = 0;
	last_serial = 0;
	last_update_msec = OS::get_singleton()->get_ticks_msec();
	published = false;
}

void VisionOSFaceTracking::uninitialize(XRServer *p_xr_server) {
	if (capture != nullptr) {
		GDTVisionOSFaceCapture *face_capture = (__bridge_transfer GDTVisionOSFaceCapture *)capture;
		capture = nullptr;
		[face_capture stop];
	}
	if (tracker.is_valid()) {
		p_xr_server->remove_tracker(tracker);
		tracker.unref();
	}
	shared.reset();
}

void VisionOSFaceTracking::process() {
	if (!tracker.is_valid() || !shared) {
		return;
	}
	uint64_t now = OS::get_singleton()->get_ticks_msec();
	if (!started && capture != nullptr) {
		// visionOS refuses the camera permission without asking when the request
		// comes before the app's immersive scene is up, so wait until it is active.
		if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
			active_since_msec = 0;
		} else if (active_since_msec == 0) {
			active_since_msec = now;
		} else if (now - active_since_msec > START_DELAY_MSEC) {
			started = true;
			[(__bridge GDTVisionOSFaceCapture *)capture start];
		}
	}
	PackedFloat32Array weights;
	bool fresh = false;
	{
		MutexLock lock(shared->mutex);
		if (shared->serial != last_serial) {
			last_serial = shared->serial;
			fresh = true;
			weights.resize(XRFaceTracker::FT_MAX);
			float *dst = weights.ptrw();
			for (int i = 0; i < XRFaceTracker::FT_MAX; i++) {
				dst[i] = shared->weights[i];
			}
		}
	}
	if (fresh) {
		last_update_msec = now;
		tracker->set_blend_shapes(weights);
		published = true;
	} else if (published && now - last_update_msec > FACE_TIMEOUT_MSEC) {
		// The camera stopped delivering frames; a frozen face would look wrong.
		PackedFloat32Array zeros;
		zeros.resize(XRFaceTracker::FT_MAX);
		zeros.fill(0.0f);
		tracker->set_blend_shapes(zeros);
		published = false;
	}
}

#endif // VISIONOS_ENABLED
