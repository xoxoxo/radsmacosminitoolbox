#import "recorder.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

static NSString *const kAppName = @"Rads macOS Mini Toolbox";

static void presentAlert(NSString *message, NSString *detail) {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [NSAlert new];
    alert.messageText = message;
    alert.informativeText = detail;
    [alert runModal];
}

static NSScreen *screenUnderPoint(NSPoint point) {
    for (NSScreen *screen in NSScreen.screens) {
        if (NSPointInRect(point, screen.frame)) return screen;
    }
    return NSScreen.mainScreen;
}

static NSScreen *screenUnderFrame(NSRect frame) {
    NSScreen *best = nil;
    CGFloat bestArea = 0;
    for (NSScreen *screen in NSScreen.screens) {
        NSRect overlap = NSIntersectionRect(screen.frame, frame);
        CGFloat area = NSWidth(overlap) * NSHeight(overlap);
        if (area > bestArea) {
            best = screen;
            bestArea = area;
        }
    }
    return best ?: NSScreen.mainScreen;
}

static CGDirectDisplayID screenID(NSScreen *screen) {
    return [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
}

// ScreenCaptureKit's sourceRect is in points, origin at the top-left of that display.
static CGRect displayRectFromCocoa(NSRect cocoa, NSScreen *screen) {
    NSRect clipped = NSIntersectionRect(cocoa, screen.frame);
    if (NSIsEmptyRect(clipped)) clipped = screen.frame;
    return CGRectMake(NSMinX(clipped) - NSMinX(screen.frame),
                      NSMaxY(screen.frame) - NSMaxY(clipped),
                      NSWidth(clipped),
                      NSHeight(clipped));
}

static NSURL *recordingURL(void) {
    NSURL *desktop = [NSFileManager.defaultManager URLsForDirectory:NSDesktopDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd 'at' HH.mm.ss";
    NSString *stamp = [formatter stringFromDate:[NSDate date]];
    NSString *name = [NSString stringWithFormat:@"Screen Recording %@.mov", stamp];
    NSURL *url = [desktop URLByAppendingPathComponent:name];
    NSInteger extra = 2;
    while ([NSFileManager.defaultManager fileExistsAtPath:url.path]) {
        name = [NSString stringWithFormat:@"Screen Recording %@ %ld.mov", stamp, (long)extra];
        url = [desktop URLByAppendingPathComponent:name];
        extra++;
    }
    return url;
}

static void promptScreenRecording(void) {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Screen Recording Access Needed";
    alert.informativeText = [NSString stringWithFormat:
        @"Turn on %@ in Privacy & Security → Screen Recording, then try the shortcut again.\n\n"
        @"If it is already on, that entry is from an older copy of the app. Select it, click −, then click + and add %@ from Applications.",
        kAppName, kAppName];
    [alert addButtonWithTitle:@"Open System Settings"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"];
        [NSWorkspace.sharedWorkspace openURL:url];
    }
}

NSImage *recordingStatusImage(void) {
    return [NSImage imageWithSize:NSMakeSize(16, 18) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        (void)rect;
        NSRect dot = NSMakeRect(3.5, 4.5, 9, 9);
        [[NSColor colorWithCalibratedRed:1 green:0.23 blue:0.19 alpha:1] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
        return YES;
    }];
}

@interface RegionSelectView : NSView
@property(copy) void (^onComplete)(NSRect cocoaRect);
@property(copy) void (^onCancel)(void);
@end

@implementation RegionSelectView {
    BOOL _dragging;
    NSPoint _start;
    NSRect _selection;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    (void)event;
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[NSColor colorWithWhite:0 alpha:0.42] setFill];
    NSRectFill(self.bounds);

    NSMutableParagraphStyle *centered = [NSMutableParagraphStyle new];
    centered.alignment = NSTextAlignmentCenter;
    NSDictionary *hint = @{
        NSFontAttributeName: [NSFont systemFontOfSize:15 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.9],
        NSParagraphStyleAttributeName: centered,
    };
    NSRect hintRect = NSMakeRect(0, NSHeight(self.bounds) - 64, NSWidth(self.bounds), 24);
    [@"Drag to record a region · Esc to cancel" drawInRect:hintRect withAttributes:hint];

    if (!_dragging && NSIsEmptyRect(_selection)) return;

    NSRect hole = _selection;
    [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositingOperationClear];
    NSRectFill(hole);
    [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositingOperationSourceOver];

    NSBezierPath *border = [NSBezierPath bezierPathWithRect:NSInsetRect(hole, 0.5, 0.5)];
    border.lineWidth = 2;
    [[NSColor colorWithCalibratedRed:1 green:0.23 blue:0.19 alpha:1] setStroke];
    [border stroke];

    NSString *size = [NSString stringWithFormat:@"%.0f × %.0f", NSWidth(hole), NSHeight(hole)];
    NSDictionary *sizeText = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: NSColor.whiteColor,
        NSParagraphStyleAttributeName: centered,
    };
    CGFloat labelY = NSMinY(hole) - 26;
    if (labelY < 8) labelY = NSMaxY(hole) + 8;
    [size drawInRect:NSMakeRect(NSMidX(hole) - 60, labelY, 120, 18) withAttributes:sizeText];
}

- (void)mouseDown:(NSEvent *)event {
    _dragging = YES;
    _start = [self convertPoint:event.locationInWindow fromView:nil];
    _selection = NSMakeRect(_start.x, _start.y, 0, 0);
    self.needsDisplay = YES;
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_dragging) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    _selection = NSMakeRect(MIN(_start.x, point.x), MIN(_start.y, point.y),
                            fabs(point.x - _start.x), fabs(point.y - _start.y));
    self.needsDisplay = YES;
}

- (void)mouseUp:(NSEvent *)event {
    (void)event;
    if (!_dragging) return;
    _dragging = NO;
    if (NSWidth(_selection) < 32 || NSHeight(_selection) < 32) {
        if (self.onCancel) self.onCancel();
        return;
    }
    NSRect screenRect = [self.window convertRectToScreen:_selection];
    if (self.onComplete) self.onComplete(screenRect);
}

- (void)rightMouseDown:(NSEvent *)event {
    (void)event;
    if (self.onCancel) self.onCancel();
}

- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 53) {
        if (self.onCancel) self.onCancel();
        return;
    }
    [super keyDown:event];
}

- (void)cancelOperation:(id)sender {
    (void)sender;
    if (self.onCancel) self.onCancel();
}

@end

@interface RecordingFrameView : NSView
@end

@implementation RecordingFrameView
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSBezierPath *path = [NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds, 1.5, 1.5)];
    path.lineWidth = 3;
    [[NSColor colorWithCalibratedRed:1 green:0.23 blue:0.19 alpha:1] setStroke];
    [path stroke];
}
@end

@interface ScreenRecorder () <SCStreamDelegate, SCStreamOutput>
@property(readwrite) BOOL recording;
@property(readwrite) BOOL picking;
@end

@implementation ScreenRecorder {
    SCStream *_stream;
    AVAssetWriter *_writer;
    AVAssetWriterInput *_videoInput;
    AVAssetWriterInput *_audioInput;
    AVAssetWriterInputPixelBufferAdaptor *_adaptor;
    dispatch_queue_t _queue;
    NSURL *_outputURL;
    BOOL _sessionStarted;
    BOOL _stopping;
    BOOL _starting;
    CFTimeInterval _lastToggle;
    IOPMAssertionID _sleepAssertion;
    NSMutableArray<NSWindow *> *_pickerWindows;
    id _keyMonitor;
    NSWindow *_frameWindow;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("local.radsmacosminitoolbox.recording", DISPATCH_QUEUE_SERIAL);
        _sleepAssertion = kIOPMNullAssertionID;
        _pickerWindows = [NSMutableArray array];
    }
    return self;
}

- (void)changed {
    if (self.onStateChange) self.onStateChange();
}

- (BOOL)ignoreRepeat {
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - _lastToggle < 0.2) return YES;
    _lastToggle = now;
    return NO;
}

- (void)toggleDisplay {
    if ([self ignoreRepeat]) return;
    if (self.recording) {
        [self stop];
        return;
    }
    [self cancelPicker];
    NSScreen *screen = screenUnderPoint(NSEvent.mouseLocation) ?: NSScreen.mainScreen;
    [self startOnScreen:screen region:screen.frame showFrame:NO];
}

- (void)toggleRegion {
    if ([self ignoreRepeat]) return;
    if (self.recording) {
        [self stop];
        return;
    }
    if (self.picking) {
        [self cancelPicker];
        return;
    }
    [self beginPicker];
}

- (void)stop {
    if (!self.recording || _stopping) return;
    _stopping = YES;
    [self hideFrame];
    SCStream *stream = _stream;
    dispatch_async(_queue, ^{
        [stream stopCaptureWithCompletionHandler:^(NSError *error) {
            (void)error;
            [self finishWriter];
        }];
    });
}

- (void)beginPicker {
    if (!CGPreflightScreenCaptureAccess()) {
        CGRequestScreenCaptureAccess();
        promptScreenRecording();
        return;
    }
    self.picking = YES;
    [self changed];
    [NSApp activateIgnoringOtherApps:YES];
    [NSCursor.crosshairCursor set];

    __weak ScreenRecorder *weakSelf = self;
    for (NSScreen *screen in NSScreen.screens) {
        NSWindow *window = [[NSWindow alloc] initWithContentRect:screen.frame
                                                       styleMask:NSWindowStyleMaskBorderless
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        window.level = NSScreenSaverWindowLevel;
        window.opaque = NO;
        window.backgroundColor = NSColor.clearColor;
        window.hasShadow = NO;
        window.ignoresMouseEvents = NO;
        window.releasedWhenClosed = NO;
        window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
            NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary;
        [window setFrame:screen.frame display:YES];

        RegionSelectView *view = [[RegionSelectView alloc] initWithFrame:window.contentView.bounds];
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        view.onComplete = ^(NSRect cocoaRect) {
            [weakSelf finishPicker:cocoaRect];
        };
        view.onCancel = ^{
            [weakSelf cancelPicker];
        };
        window.contentView = view;
        [window makeKeyAndOrderFront:nil];
        [_pickerWindows addObject:window];
    }

    _keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        if (event.keyCode == 53) {
            [weakSelf cancelPicker];
            return nil;
        }
        return event;
    }];
}

- (void)cancelPicker {
    if (!self.picking && _pickerWindows.count == 0) return;
    [self tearDownPicker];
    [self changed];
}

- (void)tearDownPicker {
    self.picking = NO;
    if (_keyMonitor) {
        [NSEvent removeMonitor:_keyMonitor];
        _keyMonitor = nil;
    }
    for (NSWindow *window in _pickerWindows) [window orderOut:nil];
    [_pickerWindows removeAllObjects];
    [NSCursor.arrowCursor set];
}

- (void)finishPicker:(NSRect)cocoaRect {
    [self tearDownPicker];
    NSScreen *screen = screenUnderFrame(cocoaRect);
    NSRect clipped = NSIntersectionRect(cocoaRect, screen.frame);
    if (NSWidth(clipped) < 32 || NSHeight(clipped) < 32) {
        [self changed];
        return;
    }
    [self startOnScreen:screen region:clipped showFrame:YES];
}

- (void)showFrame:(NSRect)cocoaRect {
    [self hideFrame];
    NSRect frame = NSInsetRect(cocoaRect, -3, -3);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.level = NSStatusWindowLevel;
    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    window.hasShadow = NO;
    window.ignoresMouseEvents = YES;
    window.releasedWhenClosed = NO;
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary;
    [window setFrame:frame display:YES];
    RecordingFrameView *view = [[RecordingFrameView alloc] initWithFrame:window.contentView.bounds];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    window.contentView = view;
    [window orderFront:nil];
    _frameWindow = window;
}

- (void)hideFrame {
    [_frameWindow orderOut:nil];
    _frameWindow = nil;
}

- (void)holdSleep:(BOOL)on {
    if (on && _sleepAssertion == kIOPMNullAssertionID) {
        IOPMAssertionID assertion = kIOPMNullAssertionID;
        if (IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep,
                                        kIOPMAssertionLevelOn,
                                        CFSTR("Screen recording"),
                                        &assertion) == kIOReturnSuccess) {
            _sleepAssertion = assertion;
        }
    } else if (!on && _sleepAssertion != kIOPMNullAssertionID) {
        IOPMAssertionRelease(_sleepAssertion);
        _sleepAssertion = kIOPMNullAssertionID;
    }
}

- (void)startOnScreen:(NSScreen *)screen region:(NSRect)cocoaRegion showFrame:(BOOL)showFrame {
    if (self.recording || _starting) return;
    if (!CGPreflightScreenCaptureAccess()) {
        CGRequestScreenCaptureAccess();
        promptScreenRecording();
        return;
    }
    _starting = YES;
    __weak ScreenRecorder *weakSelf = self;
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                               onScreenWindowsOnly:YES
                                                 completionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf startWithContent:content error:error screen:screen region:cocoaRegion showFrame:showFrame];
        });
    }];
}

- (void)startWithContent:(SCShareableContent *)content
                   error:(NSError *)error
                  screen:(NSScreen *)screen
                  region:(NSRect)cocoaRegion
               showFrame:(BOOL)showFrame {
    if (!content || error) {
        _starting = NO;
        promptScreenRecording();
        [self changed];
        return;
    }

    CGDirectDisplayID displayID = screenID(screen);
    SCDisplay *display = nil;
    for (SCDisplay *candidate in content.displays) {
        if (candidate.displayID == displayID) {
            display = candidate;
            break;
        }
    }
    if (!display) display = content.displays.firstObject;
    if (!display) {
        _starting = NO;
        presentAlert(@"Could not start recording", @"No display is available to record.");
        [self changed];
        return;
    }

    NSRunningApplication *app = NSRunningApplication.currentApplication;
    NSMutableArray<SCRunningApplication *> *exclude = [NSMutableArray array];
    for (SCRunningApplication *running in content.applications) {
        if (running.processID == app.processIdentifier) [exclude addObject:running];
    }
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display
                                                 excludingApplications:exclude
                                                      exceptingWindows:@[]];

    CGRect source = displayRectFromCocoa(cocoaRegion, screen);
    CGFloat scale = screen.backingScaleFactor;
    int width = (int)lround(source.size.width * scale) & ~1;
    int height = (int)lround(source.size.height * scale) & ~1;
    if (width < 32 || height < 32) {
        _starting = NO;
        presentAlert(@"Could not start recording", @"That region is too small.");
        [self changed];
        return;
    }

    SCStreamConfiguration *config = [SCStreamConfiguration new];
    config.width = width;
    config.height = height;
    config.sourceRect = source;
    config.showsCursor = YES;
    config.queueDepth = 8;
    config.minimumFrameInterval = CMTimeMake(1, 60);
    config.pixelFormat = kCVPixelFormatType_32BGRA;
    config.capturesAudio = YES;

    NSURL *url = recordingURL();
    NSError *writerError = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:url fileType:AVFileTypeQuickTimeMovie error:&writerError];
    if (!writer || writerError) {
        _starting = NO;
        presentAlert(@"Could not start recording", writerError.localizedDescription ?: @"The movie file could not be created.");
        [self changed];
        return;
    }

    NSDictionary *compression = @{
        AVVideoAverageBitRateKey: @(MAX((NSInteger)width * height * 4, 4000000)),
        AVVideoExpectedSourceFrameRateKey: @60,
        AVVideoMaxKeyFrameIntervalKey: @60,
    };
    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecTypeHEVC,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
        AVVideoCompressionPropertiesKey: compression,
    };
    AVAssetWriterInput *video = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    video.expectsMediaDataInRealTime = YES;
    if (![writer canAddInput:video]) {
        videoSettings = @{
            AVVideoCodecKey: AVVideoCodecTypeH264,
            AVVideoWidthKey: @(width),
            AVVideoHeightKey: @(height),
            AVVideoCompressionPropertiesKey: compression,
        };
        video = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
        video.expectsMediaDataInRealTime = YES;
    }
    if (![writer canAddInput:video]) {
        _starting = NO;
        presentAlert(@"Could not start recording", @"This Mac could not encode the recording.");
        [self changed];
        return;
    }
    [writer addInput:video];
    AVAssetWriterInputPixelBufferAdaptor *adaptor =
        [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:video
                                                                        sourcePixelBufferAttributes:@{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    }];

    AudioChannelLayout layout;
    memset(&layout, 0, sizeof layout);
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
    NSDictionary *audioSettings = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @48000,
        AVNumberOfChannelsKey: @2,
        AVEncoderBitRateKey: @192000,
        AVChannelLayoutKey: [NSData dataWithBytes:&layout length:sizeof layout],
    };
    AVAssetWriterInput *audio = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
    audio.expectsMediaDataInRealTime = YES;
    if ([writer canAddInput:audio]) [writer addInput:audio];
    else audio = nil;

    SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
    NSError *outputError = nil;
    if (![stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:_queue error:&outputError]) {
        _starting = NO;
        presentAlert(@"Could not start recording", outputError.localizedDescription ?: @"The capture stream could not be configured.");
        [self changed];
        return;
    }
    if (audio) {
        NSError *audioError = nil;
        if (![stream addStreamOutput:self type:SCStreamOutputTypeAudio sampleHandlerQueue:_queue error:&audioError]) {
            audio = nil;
        }
    }

    _writer = writer;
    _videoInput = video;
    _audioInput = audio;
    _adaptor = adaptor;
    _outputURL = url;
    _sessionStarted = NO;
    _stopping = NO;
    _stream = stream;
    self.recording = YES;
    _starting = NO;
    [self holdSleep:YES];
    if (showFrame) [self showFrame:cocoaRegion];
    [self changed];

    [stream startCaptureWithCompletionHandler:^(NSError *startError) {
        if (!startError) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self captureFailed:startError];
        });
    }];
}

- (void)captureFailed:(NSError *)error {
    [self hideFrame];
    [self holdSleep:NO];
    self.recording = NO;
    _starting = NO;
    _stopping = NO;
    _stream = nil;
    dispatch_async(_queue, ^{
        if (self->_writer && self->_writer.status == AVAssetWriterStatusWriting) {
            [self->_writer cancelWriting];
        }
        self->_writer = nil;
        self->_videoInput = nil;
        self->_audioInput = nil;
        self->_adaptor = nil;
    });
    if (_outputURL) {
        [NSFileManager.defaultManager removeItemAtURL:_outputURL error:nil];
        _outputURL = nil;
    }
    [self changed];
    NSString *detail = error.localizedDescription ?: @"The capture stream could not start.";
    if (error.code == -3801 || [detail.lowercaseString containsString:@"not authorized"]) {
        promptScreenRecording();
        return;
    }
    presentAlert(@"Could not start recording", detail);
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    (void)stream;
    if (!CMSampleBufferIsValid(sampleBuffer) || !_writer) return;

    if (type == SCStreamOutputTypeScreen) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
        if (attachments && CFArrayGetCount(attachments) > 0) {
            NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments, 0);
            NSNumber *status = info[SCStreamFrameInfoStatus];
            if (status && status.integerValue != SCFrameStatusComplete) return;
        }
        CVPixelBufferRef pixel = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!pixel || !_adaptor) return;
        CMTime time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        if (!_sessionStarted) {
            if (_writer.status == AVAssetWriterStatusUnknown) [_writer startWriting];
            if (_writer.status != AVAssetWriterStatusWriting) return;
            [_writer startSessionAtSourceTime:time];
            _sessionStarted = YES;
        }
        if (_videoInput.readyForMoreMediaData) [_adaptor appendPixelBuffer:pixel withPresentationTime:time];
        return;
    }

    if (type == SCStreamOutputTypeAudio && _sessionStarted && _audioInput.readyForMoreMediaData) {
        [_audioInput appendSampleBuffer:sampleBuffer];
    }
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    (void)stream;
    if (!error || _stopping) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.recording) return;
        [self hideFrame];
        self->_stopping = YES;
        dispatch_async(self->_queue, ^{
            [self finishWriter];
        });
        presentAlert(@"Recording stopped", error.localizedDescription ?: @"The capture stream ended unexpectedly.");
    });
}

- (void)finishWriter {
    AVAssetWriter *writer = _writer;
    AVAssetWriterInput *video = _videoInput;
    AVAssetWriterInput *audio = _audioInput;
    NSURL *url = _outputURL;
    _stream = nil;
    _writer = nil;
    _videoInput = nil;
    _audioInput = nil;
    _adaptor = nil;
    _outputURL = nil;
    BOOL started = _sessionStarted;
    _sessionStarted = NO;

    if (video) [video markAsFinished];
    if (audio) [audio markAsFinished];
    if (!writer) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self recordingEnded:nil];
        });
        return;
    }
    if (!started || writer.status != AVAssetWriterStatusWriting) {
        [writer cancelWriting];
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self recordingEnded:nil];
        });
        return;
    }
    [writer finishWritingWithCompletionHandler:^{
        NSURL *saved = writer.status == AVAssetWriterStatusCompleted ? url : nil;
        if (!saved) [NSFileManager.defaultManager removeItemAtURL:url error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self recordingEnded:saved];
        });
    }];
}

- (void)recordingEnded:(NSURL *)url {
    [self hideFrame];
    [self holdSleep:NO];
    self.recording = NO;
    _stopping = NO;
    if (url) self.lastRecordingURL = url;
    [self changed];
}

@end
