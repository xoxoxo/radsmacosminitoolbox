#import "machine.h"

#import <IOKit/IOCFPlugIn.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreWLAN/CoreWLAN.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <mach/mach.h>
#import <mach/processor_info.h>
#import <sys/mount.h>
#import <sys/sysctl.h>

@implementation CoreReading
- (instancetype)init {
    self = [super init];
    if (self) _temperature = NAN;
    return self;
}
@end

@implementation FanReading
@end

@implementation NetworkReading
@end

@implementation DriveReading
- (instancetype)init {
    self = [super init];
    if (self) {
        _temperature = NAN;
        _freeFraction = -1;
        _health = NAN;
        _powerCycles = -1;
        _criticalWarning = -1;
    }
    return self;
}
@end

@implementation MachineStats
- (instancetype)init {
    self = [super init];
    if (self) {
        _gpuTemperature = NAN;
        _batteryTemperature = NAN;
        _batteryCharge = NAN;
        _batteryHealth = NAN;
        _cores = @[];
        _fans = @[];
        _networks = @[];
        _drives = @[];
    }
    return self;
}
@end

typedef struct {
    char major;
    char minor;
    char build;
    char reserved[1];
    UInt16 release;
} SMCVers;

typedef struct {
    UInt16 version;
    UInt16 length;
    UInt32 cpuPLimit;
    UInt32 gpuPLimit;
    UInt32 memPLimit;
} SMCLimit;

typedef struct {
    UInt32 dataSize;
    UInt32 dataType;
    char dataAttributes;
} SMCInfo;

typedef struct {
    UInt32 key;
    SMCVers vers;
    SMCLimit limit;
    SMCInfo keyInfo;
    char result;
    char status;
    char data8;
    UInt32 data32;
    unsigned char bytes[32];
} SMCData;

static io_connect_t gSMC;

static UInt32 smcKey(const char *key) {
    return ((UInt32)(unsigned char)key[0] << 24) | ((UInt32)(unsigned char)key[1] << 16) |
           ((UInt32)(unsigned char)key[2] << 8) | (UInt32)(unsigned char)key[3];
}

static BOOL smcCall(SMCData *input, SMCData *output) {
    if (!gSMC) {
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
        if (!service) return NO;
        kern_return_t opened = IOServiceOpen(service, mach_task_self(), 0, &gSMC);
        IOObjectRelease(service);
        if (opened != KERN_SUCCESS) {
            gSMC = 0;
            return NO;
        }
    }
    size_t inSize = sizeof(SMCData);
    size_t outSize = sizeof(SMCData);
    if (IOConnectCallStructMethod(gSMC, 2, input, inSize, output, &outSize) != KERN_SUCCESS) {
        IOServiceClose(gSMC);
        gSMC = 0;
        return NO;
    }
    return YES;
}

// A missing key comes back as a successful call with an empty type.
static BOOL smcReadBytes(const char *key, char type[5], unsigned char *bytes, UInt32 *size) {
    SMCData input, output;
    memset(&input, 0, sizeof input);
    memset(&output, 0, sizeof output);
    input.key = smcKey(key);
    input.data8 = 9;
    if (!smcCall(&input, &output) || output.keyInfo.dataSize == 0 || output.keyInfo.dataSize > 32) return NO;
    type[0] = (char)((output.keyInfo.dataType >> 24) & 0xff);
    type[1] = (char)((output.keyInfo.dataType >> 16) & 0xff);
    type[2] = (char)((output.keyInfo.dataType >> 8) & 0xff);
    type[3] = (char)(output.keyInfo.dataType & 0xff);
    type[4] = 0;
    UInt32 length = output.keyInfo.dataSize;
    memset(&input, 0, sizeof input);
    input.key = smcKey(key);
    input.keyInfo.dataSize = length;
    input.data8 = 5;
    memset(&output, 0, sizeof output);
    if (!smcCall(&input, &output)) return NO;
    memcpy(bytes, output.bytes, length);
    *size = length;
    return YES;
}

// Apple Silicon stores SMC "flt " values in native byte order. Older fans use fpe2.
static BOOL smcReadFloatValue(const char *key, double *out, double minimum, double maximum) {
    char type[5];
    unsigned char bytes[32];
    UInt32 size = 0;
    if (!smcReadBytes(key, type, bytes, &size)) return NO;
    double value = 0;
    if (size == 4 && strncmp(type, "flt ", 4) == 0) {
        float native = 0;
        memcpy(&native, bytes, sizeof native);
        value = native;
    } else if (size == 2 && strncmp(type, "fpe2", 4) == 0) {
        value = (((unsigned)bytes[0] << 8) | bytes[1]) / 4.0;
    } else {
        return NO;
    }
    if (value < minimum || value > maximum) return NO;
    *out = value;
    return YES;
}

static BOOL smcReadFloat(const char *key, double *out) {
    return smcReadFloatValue(key, out, 1, 125);
}

static double registryNumber(io_registry_entry_t entry, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    double number = NAN;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue(value, kCFNumberDoubleType, &number);
    }
    if (value) CFRelease(value);
    return number;
}

// Charge is the percentage the menu bar shows. Health is how much of the
// original capacity the battery can still hold.
static void readBatteryLevels(double *charge, double *health) {
    *charge = NAN;
    *health = NAN;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!service) return;
    double current = registryNumber(service, CFSTR("CurrentCapacity"));
    if (current >= 0 && current <= 100) *charge = current;
    CFDictionaryRef data = IORegistryEntryCreateCFProperty(service, CFSTR("BatteryData"), kCFAllocatorDefault, 0);
    if (data && CFGetTypeID(data) == CFDictionaryGetTypeID()) {
        NSDictionary *info = (__bridge NSDictionary *)data;
        double design = [info[@"DesignCapacity"] doubleValue];
        double full = [info[@"AppleRawMaxCapacity"] doubleValue];
        if (full <= 0) full = [info[@"FullChargeCapacity"] doubleValue];
        if (isnan(*charge) && full > 0) {
            double raw = [info[@"AppleRawCurrentCapacity"] doubleValue];
            if (raw >= 0) *charge = MIN(raw / full * 100.0, 100);
        }
        if (design > 0 && full > 0) *health = MIN(full / design * 100.0, 100);
    }
    if (data) CFRelease(data);
    IOObjectRelease(service);
}

static NSArray<FanReading *> *readFans(void) {
    char type[5];
    unsigned char bytes[32];
    UInt32 size = 0;
    if (!smcReadBytes("FNum", type, bytes, &size) || size < 1 || strncmp(type, "ui8 ", 4) != 0) return @[];
    int count = bytes[0];
    if (count < 1 || count > 6) return @[];
    NSMutableArray<FanReading *> *fans = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        char key[5];
        snprintf(key, sizeof key, "F%dAc", i);
        double rpm = 0;
        if (!smcReadFloatValue(key, &rpm, 0, 20000)) continue;
        FanReading *fan = [FanReading new];
        if (count == 1) fan.name = @"Fan";
        else if (count == 2) fan.name = i == 0 ? @"Left" : @"Right";
        else fan.name = [NSString stringWithFormat:@"Fan %d", i + 1];
        fan.rpm = rpm;
        [fans addObject:fan];
    }
    return fans;
}

typedef struct {
    const char *performance[16];
    int performanceCount;
    const char *efficiency[8];
    int efficiencyCount;
    const char *gpu[12];
    int gpuCount;
} CoreTempMap;

// Die sensors used by the cores, one key per core. The lists are the ones
// that read as real core temperatures; each chip generation moved them.
static const CoreTempMap kM1Temps = {
    .performance = {"Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"},
    .performanceCount = 8,
    .efficiency = {"Tp09", "Tp0T"},
    .efficiencyCount = 2,
    .gpu = {"Tg05", "Tg0D", "Tg0L", "Tg0T"},
    .gpuCount = 4,
};

static const CoreTempMap kM2Temps = {
    .performance = {"Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"},
    .performanceCount = 8,
    .efficiency = {"Tp1h", "Tp1t", "Tp1p", "Tp1l"},
    .efficiencyCount = 4,
    .gpu = {"Tg0f", "Tg0j"},
    .gpuCount = 2,
};

static const CoreTempMap kM3Temps = {
    .performance = {"Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"},
    .performanceCount = 12,
    .efficiency = {"Te05", "Te0L", "Te0P", "Te0S"},
    .efficiencyCount = 4,
    .gpu = {"Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"},
    .gpuCount = 8,
};

static const CoreTempMap kM4Temps = {
    .performance = {"Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"},
    .performanceCount = 8,
    .efficiency = {"Te05", "Te0S", "Te09", "Te0H"},
    .efficiencyCount = 4,
    .gpu = {"Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"},
    .gpuCount = 10,
};

static const CoreTempMap *tempMap(void) {
    static const CoreTempMap *cached = NULL;
    static BOOL resolved = NO;
    if (resolved) return cached;
    resolved = YES;
    char brand[128] = {0};
    size_t length = sizeof brand;
    sysctlbyname("machdep.cpu.brand_string", brand, &length, NULL, 0);
    NSString *name = [NSString stringWithUTF8String:brand] ?: @"";
    if ([name containsString:@"M4"]) cached = &kM4Temps;
    else if ([name containsString:@"M3"]) cached = &kM3Temps;
    else if ([name containsString:@"M2"]) cached = &kM2Temps;
    else if ([name containsString:@"M1"]) cached = &kM1Temps;
    return cached;
}

static int logicalCPUs(int level) {
    char name[40];
    snprintf(name, sizeof name, "hw.perflevel%d.logicalcpu", level);
    int value = 0;
    size_t length = sizeof value;
    if (sysctlbyname(name, &value, &length, NULL, 0) != 0 || value < 0) return 0;
    return value;
}

static double averageKeys(const char *const keys[], int count) {
    double sum = 0;
    int found = 0;
    for (int i = 0; i < count; i++) {
        double value = 0;
        if (smcReadFloat(keys[i], &value)) {
            sum += value;
            found++;
        }
    }
    return found ? sum / found : NAN;
}

static void readUsage(double *total, double *cores, int capacity, int *count) {
    static processor_cpu_load_info_t previous = NULL;
    static natural_t previousCount = 0;
    natural_t ncpu = 0;
    processor_info_array_t raw = NULL;
    mach_msg_type_number_t infoCount = 0;
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &ncpu, &raw, &infoCount) != KERN_SUCCESS) {
        *count = 0;
        return;
    }
    processor_cpu_load_info_t info = (processor_cpu_load_info_t)raw;
    *count = (int)MIN(ncpu, (natural_t)capacity);
    if (previous && previousCount == ncpu) {
        double usedSum = 0;
        double totalSum = 0;
        for (natural_t i = 0; i < ncpu && (int)i < capacity; i++) {
            unsigned long long user = info[i].cpu_ticks[CPU_STATE_USER] - previous[i].cpu_ticks[CPU_STATE_USER];
            unsigned long long system = info[i].cpu_ticks[CPU_STATE_SYSTEM] - previous[i].cpu_ticks[CPU_STATE_SYSTEM];
            unsigned long long nice = info[i].cpu_ticks[CPU_STATE_NICE] - previous[i].cpu_ticks[CPU_STATE_NICE];
            unsigned long long idle = info[i].cpu_ticks[CPU_STATE_IDLE] - previous[i].cpu_ticks[CPU_STATE_IDLE];
            unsigned long long all = user + system + nice + idle;
            cores[i] = all ? (double)(user + system + nice) / (double)all * 100.0 : 0;
            usedSum += (double)(user + system + nice);
            totalSum += (double)all;
        }
        *total = totalSum ? usedSum / totalSum * 100.0 : 0;
    } else {
        *total = 0;
        for (int i = 0; i < *count; i++) cores[i] = 0;
    }
    if (previousCount != ncpu) {
        free(previous);
        previous = calloc(ncpu, sizeof(*previous));
        previousCount = ncpu;
    }
    if (previous) memcpy(previous, info, ncpu * sizeof(*previous));
    vm_deallocate(mach_task_self(), (vm_address_t)raw, (vm_size_t)infoCount * sizeof(integer_t));
}

static double readGPUUsage(void) {
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) != KERN_SUCCESS) {
        return 0;
    }
    double best = 0;
    BOOL found = NO;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        CFDictionaryRef stats = IORegistryEntryCreateCFProperty(service, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
        if (stats && CFGetTypeID(stats) == CFDictionaryGetTypeID()) {
            CFTypeRef value = CFDictionaryGetValue(stats, CFSTR("Device Utilization %"));
            if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
                double usage = 0;
                CFNumberGetValue(value, kCFNumberDoubleType, &usage);
                if (!found || usage > best) best = usage;
                found = YES;
            }
        }
        if (stats) CFRelease(stats);
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    if (best < 0) return 0;
    if (best > 100) return 100;
    return best;
}

static void readMemory(double *percent, uint64_t *usedOut, uint64_t *totalOut) {
    uint64_t total = 0;
    size_t length = sizeof total;
    sysctlbyname("hw.memsize", &total, &length, NULL, 0);
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS) {
        *percent = 0;
        *usedOut = 0;
        *totalOut = total;
        return;
    }
    uint64_t app = vm.internal_page_count > vm.purgeable_count
        ? (uint64_t)vm.internal_page_count - vm.purgeable_count : 0;
    uint64_t used = (app + vm.wire_count + vm.compressor_page_count) * (uint64_t)vm_kernel_page_size;
    if (total && used > total) used = total;
    *percent = total ? (double)used / (double)total * 100.0 : 0;
    *usedOut = used;
    *totalOut = total;
}

static NSString *copyStringProperty(io_registry_entry_t entry, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    NSString *string = nil;
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) string = [(__bridge NSString *)value copy];
    if (value) CFRelease(value);
    return string;
}

static BOOL boolProperty(io_registry_entry_t entry, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    BOOL result = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value);
    if (value) CFRelease(value);
    return result;
}

static BOOL parentIsBlockStorage(io_service_t media) {
    io_service_t parent = 0;
    if (IORegistryEntryGetParentEntry(media, kIOServicePlane, &parent) != KERN_SUCCESS) return NO;
    io_name_t className;
    IOObjectGetClass(parent, className);
    IOObjectRelease(parent);
    return strcmp(className, "IOBlockStorageDriver") == 0;
}

static BOOL isVirtualDisk(io_service_t media) {
    CFTypeRef protocol = IORegistryEntrySearchCFProperty(
        media, kIOServicePlane, CFSTR("Protocol Characteristics"), kCFAllocatorDefault,
        kIORegistryIterateRecursively | kIORegistryIterateParents);
    if (!protocol || CFGetTypeID(protocol) != CFDictionaryGetTypeID()) {
        if (protocol) CFRelease(protocol);
        return NO;
    }
    CFTypeRef interconnect = CFDictionaryGetValue(protocol, CFSTR("Physical Interconnect"));
    BOOL virtual = interconnect && CFGetTypeID(interconnect) == CFStringGetTypeID() &&
        CFStringCompare(interconnect, CFSTR("Virtual Interface"), 0) == kCFCompareEqualTo;
    CFRelease(protocol);
    return virtual;
}

static NSString *trimmedCString(const uint8_t *bytes, size_t length) {
    NSString *text = [[NSString alloc] initWithBytes:bytes length:length encoding:NSASCIIStringEncoding];
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static void readSMART(io_service_t media, DriveReading *drive) {
    io_service_t current = media;
    IOObjectRetain(current);
    io_service_t smartService = 0;
    while (current) {
        CFTypeRef capable = IORegistryEntryCreateCFProperty(current, CFSTR("NVMe SMART Capable"), kCFAllocatorDefault, 0);
        if (capable) {
            CFRelease(capable);
            smartService = current;
            break;
        }
        io_service_t parent = 0;
        kern_return_t parentResult = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent);
        IOObjectRelease(current);
        if (parentResult != KERN_SUCCESS) {
            current = 0;
            break;
        }
        current = parent;
    }
    if (!smartService) return;

    CFDictionaryRef characteristics = IORegistryEntryCreateCFProperty(
        smartService, CFSTR("Device Characteristics"), kCFAllocatorDefault, 0);
    if (characteristics && CFGetTypeID(characteristics) == CFDictionaryGetTypeID()) {
        CFTypeRef product = CFDictionaryGetValue(characteristics, CFSTR("Product Name"));
        if (product && CFGetTypeID(product) == CFStringGetTypeID()) {
            NSString *name = [(__bridge NSString *)product stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (name.length && !drive.name.length) drive.name = name;
        }
    }
    if (characteristics) CFRelease(characteristics);

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn created = IOCreatePlugInInterfaceForService(
        smartService, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(smartService);
    if (created != kIOReturnSuccess || !plugin) return;
    IONVMeSMARTInterface **smart = NULL;
    HRESULT queried = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID)&smart);
    if (queried == S_OK && smart) {
        NVMeSMARTData data;
        memset(&data, 0, sizeof data);
        if ((*smart)->SMARTReadData(smart, &data) == kIOReturnSuccess) {
            if (data.TEMPERATURE > 200) drive.temperature = data.TEMPERATURE - 273.15;
            else if (data.TEMPERATURE > 0) drive.temperature = data.TEMPERATURE;
            drive.bytesWritten = (double)data.DATA_UNITS_WRITTEN[0] * 512.0 * 1000.0;
            drive.hasBytesWritten = YES;
            drive.health = data.PERCENTAGE_USED >= 100 ? 0 : 100 - data.PERCENTAGE_USED;
            drive.powerCycles = (long long)data.POWER_CYCLES[0];
            drive.criticalWarning = data.CRITICAL_WARNING;
        }
        NVMeIdentifyControllerStruct identity;
        memset(&identity, 0, sizeof identity);
        if ((*smart)->GetIdentifyData(smart, &identity, 0) == kIOReturnSuccess) {
            NSString *model = trimmedCString(identity.MODEL_NUMBER, sizeof identity.MODEL_NUMBER);
            if (model.length && !drive.name.length) drive.name = model;
        }
        (*smart)->Release(smart);
    }
    IODestroyPlugInInterface(plugin);
}

static BOOL userVisibleMount(const char *path) {
    return strcmp(path, "/") == 0 || strncmp(path, "/Volumes/", 9) == 0;
}

static BOOL wantedFilesystem(const char *type) {
    return strcmp(type, "apfs") == 0 || strcmp(type, "hfs") == 0 || strcmp(type, "msdos") == 0 ||
        strcmp(type, "exfat") == 0 || strcmp(type, "ntfs") == 0 || strcmp(type, "ufs") == 0;
}

static NSArray<DriveReading *> *readDrives(void) {
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator) != KERN_SUCCESS) {
        return @[];
    }
    NSMutableArray<NSDictionary *> *disks = [NSMutableArray array];
    io_service_t media;
    while ((media = IOIteratorNext(iterator))) {
        if (!boolProperty(media, CFSTR("Whole")) || !parentIsBlockStorage(media) || isVirtualDisk(media)) {
            IOObjectRelease(media);
            continue;
        }
        NSString *bsd = copyStringProperty(media, CFSTR("BSD Name"));
        uint64_t entryID = 0;
        IORegistryEntryGetRegistryEntryID(media, &entryID);
        if (!bsd.length || entryID == 0) {
            IOObjectRelease(media);
            continue;
        }
        [disks addObject:@{
            @"id": @(entryID),
            @"bsd": bsd,
            @"removable": @(boolProperty(media, CFSTR("Removable"))),
            @"media": @(media),
        }];
    }
    IOObjectRelease(iterator);
    if (disks.count == 0) return @[];

    NSMutableDictionary<NSNumber *, NSMutableArray<NSDictionary *> *> *mounts = [NSMutableDictionary dictionary];
    struct statfs *mounted = NULL;
    int mountCount = getmntinfo(&mounted, MNT_NOWAIT);
    for (int i = 0; i < mountCount; i++) {
        if (!wantedFilesystem(mounted[i].f_fstypename) || !userVisibleMount(mounted[i].f_mntonname)) continue;
        const char *device = strrchr(mounted[i].f_mntfromname, '/');
        device = device ? device + 1 : mounted[i].f_mntfromname;
        NSString *path = [NSString stringWithUTF8String:mounted[i].f_mntonname];
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, device));
        if (!service) continue;
        io_service_t current = service;
        NSNumber *matched = nil;
        for (int depth = 0; current && depth < 16 && !matched; depth++) {
            uint64_t entryID = 0;
            IORegistryEntryGetRegistryEntryID(current, &entryID);
            for (NSDictionary *disk in disks) {
                if ([disk[@"id"] unsignedLongLongValue] == entryID) {
                    matched = disk[@"id"];
                    break;
                }
            }
            io_service_t parent = 0;
            kern_return_t parentResult = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent);
            if (current != service) IOObjectRelease(current);
            current = parentResult == KERN_SUCCESS ? parent : 0;
        }
        if (current && current != service) IOObjectRelease(current);
        IOObjectRelease(service);
        if (!matched || !path.length) continue;
        NSURL *url = [NSURL fileURLWithPath:path];
        NSNumber *total = nil;
        NSNumber *important = nil;
        NSNumber *available = nil;
        NSString *name = nil;
        [url getResourceValue:&total forKey:NSURLVolumeTotalCapacityKey error:nil];
        [url getResourceValue:&important forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil];
        [url getResourceValue:&available forKey:NSURLVolumeAvailableCapacityKey error:nil];
        // Some external volumes report zero for the purgeable-aware value.
        NSNumber *free = important.unsignedLongLongValue > 0 ? important : available;
        [url getResourceValue:&name forKey:NSURLVolumeLocalizedNameKey error:nil];
        if (total.unsignedLongLongValue == 0) continue;
        NSMutableArray *list = mounts[matched];
        if (!list) {
            list = [NSMutableArray array];
            mounts[matched] = list;
        }
        [list addObject:@{
            @"path": path,
            @"name": name ?: path.lastPathComponent,
            @"total": total,
            @"free": free ?: @0,
        }];
    }

    NSMutableArray<DriveReading *> *drives = [NSMutableArray array];
    for (NSDictionary *disk in disks) {
        DriveReading *drive = [DriveReading new];
        io_service_t media = [disk[@"media"] unsignedIntValue];
        readSMART(media, drive);
        IOObjectRelease(media);
        NSDictionary *best = nil;
        for (NSDictionary *mount in mounts[disk[@"id"]]) {
            if (!best || [mount[@"total"] unsignedLongLongValue] > [best[@"total"] unsignedLongLongValue]) best = mount;
        }
        BOOL startup = NO;
        for (NSDictionary *mount in mounts[disk[@"id"]]) {
            if ([mount[@"path"] isEqualToString:@"/"]) startup = YES;
        }
        drive.startupDisk = startup;
        if (best) {
            if ([best[@"name"] length]) drive.name = best[@"name"];
            uint64_t total = [best[@"total"] unsignedLongLongValue];
            uint64_t free = [best[@"free"] unsignedLongLongValue];
            if (free > total) free = total;
            drive.freeFraction = total ? (double)free / (double)total : -1;
        }
        if (!drive.name.length) drive.name = disk[@"bsd"];
        BOOL hasDetail = !isnan(drive.temperature) || drive.freeFraction >= 0 || drive.hasBytesWritten ||
            !isnan(drive.health) || drive.powerCycles >= 0;
        drive.external = [disk[@"removable"] boolValue];
        if (hasDetail) [drives addObject:drive];
    }
    [drives sortUsingComparator:^NSComparisonResult(DriveReading *a, DriveReading *b) {
        if (a.startupDisk != b.startupDisk) return a.startupDisk ? NSOrderedAscending : NSOrderedDescending;
        if (a.external != b.external) return a.external ? NSOrderedDescending : NSOrderedAscending;
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    return drives;
}

static NSArray<DriveReading *> *cachedDrives(BOOL refresh) {
    static NSArray<DriveReading *> *cache = nil;
    static CFTimeInterval fetchedAt = 0;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (!refresh && cache && now - fetchedAt < 30) return cache;
    cache = readDrives();
    fetchedAt = now;
    return cache;
}

static NSString *usableWiFiName(NSString *name) {
    if (!name.length || [name isEqualToString:@"<redacted>"]) return nil;
    return name;
}

@interface WiFiLocation : NSObject <CLLocationManagerDelegate>
@property(strong) CLLocationManager *manager;
@end

@implementation WiFiLocation
- (instancetype)init {
    self = [super init];
    if (self) {
        _manager = [CLLocationManager new];
        _manager.delegate = self;
    }
    return self;
}

- (void)ensureAuthorized {
    if (self.manager.authorizationStatus != kCLAuthorizationStatusNotDetermined) return;
    [self.manager requestWhenInUseAuthorization];
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    (void)manager;
}
@end

static WiFiLocation *sharedWiFiLocation(void) {
    static WiFiLocation *location;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ location = [WiFiLocation new]; });
    return location;
}

static NSString *wifiNetworkName(void) {
    [sharedWiFiLocation() ensureAuthorized];
    return usableWiFiName(CWWiFiClient.sharedWiFiClient.interface.ssid);
}

static BOOL interfaceLinkActive(SCDynamicStoreRef store, NSString *bsd) {
    NSString *key = [NSString stringWithFormat:@"State:/Network/Interface/%@/Link", bsd];
    CFDictionaryRef link = SCDynamicStoreCopyValue(store, (__bridge CFStringRef)key);
    if (!link) return NO;
    CFBooleanRef flag = CFDictionaryGetValue(link, CFSTR("Active"));
    BOOL active = flag && CFBooleanGetValue(flag);
    CFRelease(link);
    return active;
}

static NSArray<NetworkReading *> *readNetworks(void) {
    NSMutableArray<NetworkReading *> *found = [NSMutableArray array];
    SCDynamicStoreRef store = SCDynamicStoreCreate(kCFAllocatorDefault, CFSTR("RMT"), NULL, NULL);
    SCPreferencesRef prefs = SCPreferencesCreate(kCFAllocatorDefault, CFSTR("RMT"), NULL);
    if (!store || !prefs) {
        if (store) CFRelease(store);
        if (prefs) CFRelease(prefs);
        return found;
    }
    NSString *primary = nil;
    CFDictionaryRef global = SCDynamicStoreCopyValue(store, CFSTR("State:/Network/Global/IPv4"));
    if (global) {
        CFStringRef name = CFDictionaryGetValue(global, CFSTR("PrimaryInterface"));
        if (name) primary = [(__bridge NSString *)name copy];
        CFRelease(global);
    }
    SCNetworkSetRef set = SCNetworkSetCopyCurrent(prefs);
    CFArrayRef services = set ? SCNetworkSetCopyServices(set) : NULL;
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    BOOL wifiUp = NO;
    if (services) {
        for (id item in (__bridge NSArray *)services) {
            SCNetworkServiceRef service = (__bridge SCNetworkServiceRef)item;
            if (!SCNetworkServiceGetEnabled(service)) continue;
            SCNetworkInterfaceRef iface = SCNetworkServiceGetInterface(service);
            if (!iface) continue;
            NSString *type = (__bridge NSString *)SCNetworkInterfaceGetInterfaceType(iface);
            NSString *bsd = (__bridge NSString *)SCNetworkInterfaceGetBSDName(iface);
            if (!bsd.length || [seen containsObject:bsd]) continue;
            BOOL wifi = [type isEqualToString:(__bridge NSString *)kSCNetworkInterfaceTypeIEEE80211];
            BOOL wired = [type isEqualToString:(__bridge NSString *)kSCNetworkInterfaceTypeEthernet];
            if (!wifi && !wired) continue;
            if (!interfaceLinkActive(store, bsd)) continue;
            [seen addObject:bsd];
            NetworkReading *reading = [NetworkReading new];
            reading.kind = wifi ? @"Wi-Fi" : @"Wired";
            if (wifi) {
                wifiUp = YES;
                reading.name = @"Connected";
            } else {
                NSString *serviceName = (__bridge NSString *)SCNetworkServiceGetName(service);
                reading.name = serviceName.length ? serviceName : @"Ethernet";
            }
            reading.primary = primary && [bsd isEqualToString:primary];
            [found addObject:reading];
        }
    }
    if (services) CFRelease(services);
    if (set) CFRelease(set);
    CFRelease(prefs);
    CFRelease(store);
    if (wifiUp) {
        NSString *ssid = wifiNetworkName();
        if (ssid.length) {
            for (NetworkReading *reading in found) {
                if ([reading.kind isEqualToString:@"Wi-Fi"]) reading.name = ssid;
            }
        }
    }
    [found sortUsingComparator:^NSComparisonResult(NetworkReading *a, NetworkReading *b) {
        if (a.primary != b.primary) return a.primary ? NSOrderedAscending : NSOrderedDescending;
        return [a.kind compare:b.kind];
    }];
    return found;
}

@implementation MachineStats (Sampling)

+ (MachineStats *)snapshotRefreshingDrives:(BOOL)refreshDrives {
    MachineStats *stats = [MachineStats new];
    double usage[64] = {0};
    int coreCount = 0;
    double cpu = 0;
    readUsage(&cpu, usage, 64, &coreCount);
    stats.cpuUsage = cpu;
    stats.gpuUsage = readGPUUsage();
    double memory = 0;
    uint64_t used = 0;
    uint64_t total = 0;
    readMemory(&memory, &used, &total);
    stats.memoryUsage = memory;
    stats.memoryUsed = used;
    stats.memoryTotal = total;

    int performance = logicalCPUs(0);
    int efficiency = logicalCPUs(1);
    BOOL grouped = logicalCPUs(2) == 0 && performance + efficiency == coreCount && performance > 0;
    const CoreTempMap *map = tempMap();
    NSMutableArray<CoreReading *> *cores = [NSMutableArray array];
    for (int i = 0; i < coreCount; i++) {
        CoreReading *core = [CoreReading new];
        core.usage = usage[i];
        double temperature = NAN;
        if (grouped && i < performance) {
            core.name = [NSString stringWithFormat:@"Performance %d", i + 1];
            if (map && i < map->performanceCount) smcReadFloat(map->performance[i], &temperature);
        } else if (grouped) {
            int index = i - performance;
            core.name = [NSString stringWithFormat:@"Efficiency %d", index + 1];
            if (map && index < map->efficiencyCount) smcReadFloat(map->efficiency[index], &temperature);
        } else {
            core.name = [NSString stringWithFormat:@"Core %d", i + 1];
        }
        core.temperature = temperature;
        [cores addObject:core];
    }
    stats.cores = cores;
    if (map) stats.gpuTemperature = averageKeys(map->gpu, map->gpuCount);
    const char *batteryKeys[] = {"TB0T", "TB1T", "TB2T"};
    stats.batteryTemperature = averageKeys(batteryKeys, 3);
    double charge = NAN;
    double health = NAN;
    readBatteryLevels(&charge, &health);
    stats.batteryCharge = charge;
    stats.batteryHealth = health;
    stats.fans = readFans();
    stats.networks = readNetworks();
    stats.drives = cachedDrives(refreshDrives);
    return stats;
}

@end

static NSColor *usageColor(double usage) {
    if (usage >= 90) return NSColor.systemRedColor;
    if (usage >= 70) return NSColor.systemOrangeColor;
    return NSColor.labelColor;
}

static void drawRGBMark(NSPoint origin) {
    CGFloat diameter = 4.6;
    NSPoint centers[] = {
        NSMakePoint(origin.x + 6.4, origin.y + 8.6),
        NSMakePoint(origin.x + 2.2, origin.y + 1.6),
        NSMakePoint(origin.x + 10.6, origin.y + 1.6),
    };
    NSColor *colors[] = {NSColor.systemRedColor, NSColor.systemGreenColor, NSColor.systemBlueColor};
    for (int i = 0; i < 3; i++) {
        NSRect dot = NSMakeRect(centers[i].x - diameter / 2, centers[i].y - diameter / 2, diameter, diameter);
        [colors[i] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
    }
}

static void strokeIcon(NSBezierPath *path) {
    path.lineWidth = 1.15;
    path.lineCapStyle = NSLineCapStyleRound;
    path.lineJoinStyle = NSLineJoinStyleRound;
    [NSColor.labelColor setStroke];
    [path stroke];
}

static void drawCPUIcon(NSRect rect) {
    NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, 2.4, 2.4) xRadius:1.4 yRadius:1.4];
    strokeIcon(body);
    [NSColor.labelColor setStroke];
    for (int i = 0; i < 2; i++) {
        CGFloat y = NSMinY(rect) + 4.2 + i * 3.4;
        NSBezierPath *pins = [NSBezierPath bezierPath];
        [pins moveToPoint:NSMakePoint(NSMinX(rect) + 0.8, y)];
        [pins lineToPoint:NSMakePoint(NSMinX(rect) + 2.4, y)];
        [pins moveToPoint:NSMakePoint(NSMaxX(rect) - 2.4, y)];
        [pins lineToPoint:NSMakePoint(NSMaxX(rect) - 0.8, y)];
        pins.lineWidth = 1.15;
        pins.lineCapStyle = NSLineCapStyleRound;
        [pins stroke];
    }
}

static void drawGPUIcon(NSRect rect) {
    NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, 2.2, 2.6) xRadius:1.6 yRadius:1.6];
    strokeIcon(body);
    NSBezierPath *mark = [NSBezierPath bezierPath];
    [mark moveToPoint:NSMakePoint(NSMidX(rect), NSMidY(rect) + 2.3)];
    [mark lineToPoint:NSMakePoint(NSMidX(rect) - 2.5, NSMidY(rect) - 2.1)];
    [mark lineToPoint:NSMakePoint(NSMidX(rect) + 2.5, NSMidY(rect) - 2.1)];
    [mark closePath];
    [NSColor.labelColor setFill];
    [mark fill];
}

static void drawMemoryIcon(NSRect rect) {
    [NSColor.labelColor setFill];
    for (int i = 0; i < 3; i++) {
        NSRect bar = NSMakeRect(NSMinX(rect) + 1.6, NSMinY(rect) + 2.2 + i * 3.15, NSWidth(rect) - 3.2, 1.7);
        [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:0.8 yRadius:0.8] fill];
    }
}

static void drawKind(int kind, NSRect rect) {
    if (kind == 0) drawCPUIcon(rect);
    else if (kind == 1) drawGPUIcon(rect);
    else drawMemoryIcon(rect);
}

// Wide enough for "100%" so a value going from 9% to 100% does not shift the icons.
static CGFloat usageTextWidth(NSDictionary *labelAttrs, NSDictionary *valueAttrs, NSArray<NSString *> *labels) {
    CGFloat width = [@"100%" sizeWithAttributes:valueAttrs].width;
    for (NSString *label in labels) {
        width = MAX(width, [label sizeWithAttributes:labelAttrs].width);
    }
    return ceil(width);
}

static CGFloat drawMetric(NSString *label, NSString *value, int kind, CGFloat x, CGFloat height, CGFloat textWidth,
                          NSDictionary *labelAttrs, NSDictionary *valueAttrs) {
    NSSize labelSize = [label sizeWithAttributes:labelAttrs];
    NSSize valueSize = [value sizeWithAttributes:valueAttrs];
    CGFloat iconSize = 13;
    CGFloat blockWidth = iconSize + 2 + textWidth;
    CGFloat labelX = x + (blockWidth - labelSize.width) / 2.0;
    [label drawAtPoint:NSMakePoint(labelX, height - labelSize.height + 1) withAttributes:labelAttrs];
    CGFloat iconY = 0.5;
    drawKind(kind, NSMakeRect(x, iconY, iconSize, iconSize));
    CGFloat valueY = iconY + (iconSize - valueSize.height) / 2.0;
    CGFloat valueX = x + iconSize + 2 + textWidth - valueSize.width;
    [value drawAtPoint:NSMakePoint(valueX, valueY) withAttributes:valueAttrs];
    return blockWidth;
}

NSImage *menuBarNameImage(BOOL showRGB, BOOL showYPbPr) {
    NSFont *nameFont = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    NSDictionary *nameAttrs = @{
        NSFontAttributeName: nameFont,
        NSForegroundColorAttributeName: NSColor.labelColor,
    };
    NSDictionary *signalAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.systemOrangeColor,
    };
    NSString *name = @"RMT";
    NSSize nameSize = [name sizeWithAttributes:nameAttrs];
    CGFloat height = 22;
    CGFloat width = nameSize.width + 2;
    if (showRGB) width += 6 + 14;
    else if (showYPbPr) width += 6 + [@"YPbPr" sizeWithAttributes:signalAttrs].width;
    return [NSImage imageWithSize:NSMakeSize(width, height) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        (void)rect;
        [name drawAtPoint:NSMakePoint(0, (height - nameSize.height) / 2.0) withAttributes:nameAttrs];
        CGFloat cursor = nameSize.width + 6;
        if (showRGB) {
            drawRGBMark(NSMakePoint(cursor, (height - 12) / 2.0));
        } else if (showYPbPr) {
            NSSize signalSize = [@"YPbPr" sizeWithAttributes:signalAttrs];
            [@"YPbPr" drawAtPoint:NSMakePoint(cursor, (height - signalSize.height) / 2.0) withAttributes:signalAttrs];
        }
        return YES;
    }];
}

NSImage *menuBarUsageImage(MachineStats *stats) {
    NSFont *labelFont = [NSFont systemFontOfSize:8 weight:NSFontWeightSemibold];
    NSFont *valueFont = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightSemibold];
    NSDictionary *labelAttrs = @{
        NSFontAttributeName: labelFont,
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
    };
    double cpu = stats ? stats.cpuUsage : 0;
    double gpu = stats ? stats.gpuUsage : 0;
    double memory = stats ? stats.memoryUsage : 0;
    NSArray *values = @[
        [NSString stringWithFormat:@"%.0f%%", cpu],
        [NSString stringWithFormat:@"%.0f%%", gpu],
        [NSString stringWithFormat:@"%.0f%%", memory],
    ];
    NSArray *labels = @[@"CPU", @"GPU", @"MEM"];
    NSArray *colors = @[usageColor(cpu), usageColor(gpu), usageColor(memory)];
    NSDictionary *measureAttrs = @{NSFontAttributeName: valueFont};
    CGFloat textWidth = usageTextWidth(labelAttrs, measureAttrs, labels);
    CGFloat height = 22;
    CGFloat gap = 8;
    CGFloat width = labels.count * (13 + 2 + textWidth) + (labels.count - 1) * gap;
    return [NSImage imageWithSize:NSMakeSize(width, height) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        (void)rect;
        CGFloat cursor = 0;
        for (NSUInteger i = 0; i < labels.count; i++) {
            NSDictionary *valueAttrs = @{
                NSFontAttributeName: valueFont,
                NSForegroundColorAttributeName: colors[i],
            };
            cursor += drawMetric(labels[i], values[i], (int)i, cursor, height, textWidth, labelAttrs, valueAttrs);
            cursor += gap;
        }
        return YES;
    }];
}
