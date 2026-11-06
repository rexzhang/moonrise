// CGVirtualDisplayPrivate.m — 虚拟屏私有 API 薄封装（MRC，-fno-objc-arc）。
// 调用序列与运行时校验对齐 go-macos/virtualdisplay（BSD-3）在 macOS 26 实测的形状。

#import "VirtualDisplayObjC.h"
#import "CGVirtualDisplayPrivate.h"
#include <objc/runtime.h>

NSString *const VDVirtualDisplayErrorDomain = @"com.moonrise.virtual-display";

static BOOL VDListContainsDisplayID(CGDirectDisplayID target) {
    CGDirectDisplayID ids[64];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(64, ids, &count) != kCGErrorSuccess) {
        return NO;
    }
    for (uint32_t i = 0; i < count; ++i) {
        if (ids[i] == target) {
            return YES;
        }
    }
    return NO;
}

static NSError *VDError(VDVirtualDisplayError code, NSString *detail) {
    return [NSError errorWithDomain:VDVirtualDisplayErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: detail}];
}

@interface VDVirtualDisplay ()
{
    CGVirtualDisplay *_display;
    dispatch_queue_t _queue;
    CGDirectDisplayID _displayID;
}
@end

@implementation VDVirtualDisplay

+ (nullable NSError *)apiAvailabilityError {
    static NSDictionary<NSString *, NSArray<NSString *> *> *required;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        required = @{
            @"CGVirtualDisplayDescriptor": @[
                @"init",
                @"setName:",
                @"setMaxPixelsWide:",
                @"setMaxPixelsHigh:",
                @"setSizeInMillimeters:",
                @"setVendorID:",
                @"setProductID:",
                @"setSerialNum:",
                @"setQueue:",
            ],
            @"CGVirtualDisplay": @[
                @"initWithDescriptor:",
                @"applySettings:",
                @"displayID",
            ],
            @"CGVirtualDisplaySettings": @[
                @"init",
                @"setModes:",
                @"setHiDPI:",
            ],
            @"CGVirtualDisplayMode": @[
                @"initWithWidth:height:refreshRate:",
            ],
        };
    });

    for (NSString *className in required) {
        Class cls = objc_getClass(className.UTF8String);
        if (!cls) {
            return VDError(VDVirtualDisplayErrorUnavailable,
                           [NSString stringWithFormat:
                               @"CoreGraphics 私有类 %@ 不存在：当前 macOS 可能已移除虚拟屏私有 API", className]);
        }
        for (NSString *selectorName in required[className]) {
            SEL sel = sel_registerName(selectorName.UTF8String);
            if (!class_getInstanceMethod(cls, sel)) {
                return VDError(VDVirtualDisplayErrorUnavailable,
                               [NSString stringWithFormat:
                                   @"私有类 %@ 缺少 selector %@：当前 macOS 可能已改变虚拟屏私有 API",
                                   className, selectorName]);
            }
        }
    }
    return nil;
}

- (instancetype)init {
    if (nil != (self = [super init])) {
        _displayID = 0;
    }
    return self;
}

- (instancetype)initWithName:(NSString *)name
               maxPixelsWide:(uint32_t)maxPixelsWide
              maxPixelsHigh:(uint32_t)maxPixelsHigh
                       modes:(NSArray<NSArray<NSNumber *> *> *)modes
                       hiDPI:(BOOL)hiDPI
                    vendorID:(uint32_t)vendorID
                   productID:(uint32_t)productID
                serialNumber:(uint32_t)serialNumber
                       error:(NSError **)error
{
    NSError *failure = nil;
    CGVirtualDisplay *display = nil;

    if ((failure = [[self class] apiAvailabilityError])) {
        goto fail;  // 尚未初始化，self 携带 alloc 的 +1
    }

    if (nil == (self = [super init])) {
        return nil;  // NSObject 的 init 不会返回 nil，仅为形式完备
    }

    @autoreleasepool {
        CGVirtualDisplayDescriptor *desc = [[objc_getClass("CGVirtualDisplayDescriptor") alloc] init];
        if (!desc) {
            failure = VDError(VDVirtualDisplayErrorCreateFailed, @"CGVirtualDisplayDescriptor 分配失败");
            goto fail;
        }

        [desc setName:name];
        [desc setMaxPixelsWide:maxPixelsWide];
        [desc setMaxPixelsHigh:maxPixelsHigh];
        // 物理尺寸按 96 DPI 由像素尺寸推导（参考实现同款）
        [desc setSizeInMillimeters:CGSizeMake(maxPixelsWide * 25.4 / 96.0, maxPixelsHigh * 25.4 / 96.0)];
        [desc setVendorID:vendorID];
        [desc setProductID:productID];
        [desc setSerialNum:serialNumber];

        _queue = dispatch_queue_create(
            [NSString stringWithFormat:@"com.moonrise.virtual-display.%u", serialNumber].UTF8String,
            NULL);
        [desc setQueue:_queue];
        // 刻意不调用 setTerminationHandler:：进程退出期回调有崩溃风险，
        // 外部移除改由活动列表轮询发现。

        display = [[objc_getClass("CGVirtualDisplay") alloc] initWithDescriptor:desc];
        [desc release];
        if (!display) {
            failure = VDError(VDVirtualDisplayErrorCreateFailed,
                              @"initWithDescriptor: 返回 nil（本进程可能没有 GUI 会话）");
            goto fail;
        }

        CGVirtualDisplaySettings *settings = [[objc_getClass("CGVirtualDisplaySettings") alloc] init];
        NSMutableArray *modeObjects = [NSMutableArray array];
        for (NSArray<NSNumber *> *spec in modes) {
            if (spec.count < 3) {
                continue;
            }
            CGVirtualDisplayMode *mode = [[objc_getClass("CGVirtualDisplayMode") alloc]
                                          initWithWidth:spec[0].unsignedIntValue
                                                 height:spec[1].unsignedIntValue
                                             refreshRate:spec[2].doubleValue];
            if (!mode) {
                [settings release];
                failure = VDError(VDVirtualDisplayErrorCreateFailed, @"CGVirtualDisplayMode 分配失败");
                goto fail;
            }
            [modeObjects addObject:mode];
            [mode release];
        }

        [settings setModes:modeObjects];
        [settings setHiDPI:hiDPI ? 1u : 0u];

        BOOL accepted = [display applySettings:settings];
        [settings release];
        if (!accepted) {
            failure = VDError(VDVirtualDisplayErrorRejected,
                              [NSString stringWithFormat:@"WindowServer 拒绝了设置（%lu 个模式）",
                               (unsigned long) modeObjects.count]);
            goto fail;
        }

        // applySettings: 在 WindowServer 接受即返回，显示器配置完成前
        // displayID 可能尚不在活动列表——轮询等待（同时泵 run loop）。
        _display = display;
        _displayID = [display displayID];
        display = nil;  // 所有权移交
    }

    {
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
        while (!VDListContainsDisplayID(_displayID)) {
            if ([deadline timeIntervalSinceNow] <= 0.0) {
                failure = VDError(VDVirtualDisplayErrorNotActive,
                                  [NSString stringWithFormat:@"显示器 %u 在 5s 内未激活", _displayID]);
                goto fail;
            }
            // 泵 run loop + 睡眠：run loop 空转会立即返回，睡眠防自旋；
            // AppKit 跑过的进程里，显示器只在 run loop 运转时激活。
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.025, true);
            [NSThread sleepForTimeInterval:0.025];
        }
    }
    return self;

fail:
    if (display) {
        [display release];
    }
    [self destroy];
    if (error) {
        *error = failure;
    }
    [self release];
    return nil;
}

- (CGDirectDisplayID)displayID {
    @synchronized (self) {
        return _display ? _displayID : 0;
    }
}

- (void)destroy {
    @synchronized (self) {
        if (_display) {
            [_display release];
            _display = nil;
            _displayID = 0;
        }
        if (_queue) {
            dispatch_release(_queue);
            _queue = NULL;
        }
    }
}

- (void)dealloc {
    [self destroy];
    [super dealloc];
}

@end
