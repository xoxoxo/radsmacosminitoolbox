#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ScreenRecorder : NSObject
@property(readonly) BOOL recording;
@property(readonly) BOOL picking;
@property(copy, nullable) NSURL *lastRecordingURL;
@property(copy, nullable) void (^onStateChange)(void);
- (void)toggleDisplay;
- (void)toggleRegion;
- (void)stop;
@end

NSImage *recordingStatusImage(void);

NS_ASSUME_NONNULL_END
