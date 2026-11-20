#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CoreReading : NSObject
@property(copy) NSString *name;
@property double usage;
@property double temperature;
@end

@interface FanReading : NSObject
@property(copy) NSString *name;
@property double rpm;
@end

@interface NetworkReading : NSObject
@property(copy) NSString *kind;
@property(copy) NSString *name;
@property BOOL primary;
@end

@interface DriveReading : NSObject
@property(copy) NSString *name;
@property double temperature;
@property double freeFraction;
@property double bytesWritten;
@property BOOL hasBytesWritten;
@property double health;
@property long long powerCycles;
@property int criticalWarning;
@property BOOL external;
@property BOOL startupDisk;
@end

@interface MachineStats : NSObject
@property double cpuUsage;
@property double gpuUsage;
@property double memoryUsage;
@property uint64_t memoryUsed;
@property uint64_t memoryTotal;
@property(copy) NSArray<CoreReading *> *cores;
@property double gpuTemperature;
@property double batteryTemperature;
@property double batteryCharge;
@property double batteryHealth;
@property(copy) NSArray<FanReading *> *fans;
@property(copy) NSArray<NetworkReading *> *networks;
@property(copy) NSArray<DriveReading *> *drives;
@end

@interface MachineStats (Sampling)
+ (MachineStats *)snapshotRefreshingDrives:(BOOL)refreshDrives;
@end

NSImage *menuBarNameImage(BOOL showRGB, BOOL showYPbPr);
NSImage *menuBarUsageImage(MachineStats *_Nullable stats);

NS_ASSUME_NONNULL_END
