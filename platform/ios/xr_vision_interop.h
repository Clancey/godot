#import <Foundation/Foundation.h>
#import <CompositorServices/CompositorServices.h>

@protocol VisionController
@required
- (void)objcCallsSwiftWithBool:(BOOL)value;
- (void)objcCallsSwiftWithInt:(int)value;
- (void)objcCallsSwiftWithFloat:(float)value;
- (void)objcCallsSwiftWithStruct:(id)structValue; // Use id for loose typing
- (id)returnStructToObjectiveC; // Return a generic object
@end

@interface XRVisionInterop : NSObject

// Singleton instance
+ (XRVisionInterop *)get_singleton;

// Property to expose cp_layer_renderer_t
@property (nonatomic, readonly) cp_layer_renderer_t __unsafe_unretained layerRenderer;
@property (nonatomic, assign, readonly) cp_frame_timing_t timing;
@property (nonatomic, assign, readonly) cp_frame_t frame;
@property (nonatomic, assign, readonly) cp_drawable_t drawable;
- (CGSize)getResolution;
- (void)setResolution:(int)width height:(int)height;
- (MTLViewport)viewportForViewIndex:(size_t)index;
-(void)iterate;



// Method to set up with VisionController
// - (BOOL)setup:(id<VisionController>)controller;
- (BOOL)setup:(cp_layer_renderer_t )renderer;

// AppDelegate lifecycle methods
- (void)applicationDidReceiveMemoryWarning;
- (void)applicationWillTerminate;
- (void)applicationWillResignActive;
- (void)applicationDidEnterBackground;
- (void)applicationWillEnterForeground;
- (void)applicationDidBecomeActive;

@end