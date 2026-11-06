#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const VDVirtualDisplayErrorDomain;

typedef NS_ERROR_ENUM(VDVirtualDisplayErrorDomain, VDVirtualDisplayError) {
    VDVirtualDisplayErrorUnavailable  = 1,  // 私有类或 selector 缺失（点名缺失项）
    VDVirtualDisplayErrorInvalidSpec  = 2,  // 参数越界
    VDVirtualDisplayErrorCreateFailed = 3,  // initWithDescriptor: 返回 nil（无 GUI 会话等）
    VDVirtualDisplayErrorRejected     = 4,  // applySettings: 返回 NO（WindowServer 拒绝）
    VDVirtualDisplayErrorNotActive    = 5,  // 5s 内未出现在活动显示列表
};

/// 一个由 CGVirtualDisplay 私有 API 创建的虚拟显示器。
/// 显示器的生命周期与对象一致：destroy（或对象释放）即销毁。
@interface VDVirtualDisplay : NSObject

/// 私有 API 形状校验：nil = 4 个类与全部所需 selector 都在；
/// 非 nil = 错误信息点名第一个缺失的类或 selector。创建前必调。
+ (nullable NSError *)apiAvailabilityError;

/// 创建虚拟显示器并阻塞等待其出现在活动显示列表（25ms 轮询、5s 上限、
/// 每轮泵当前线程 run loop——AppKit 跑过之后显示器只在 run loop 运转时激活）。
///
/// modes：NSArray<NSArray<NSNumber *> *>，每项 @[宽, 高, 刷新率]（像素/Hz）。
/// 第一项为主模式（= maxPixels，身份推导依据）。
/// hiDPI=YES 时系统为每个模式提供 2x 变体（受 maxPixels 上限约束）；
/// 要得到全倍 Retina 模式，必须额外声明逻辑模式（主模式的 W/2 x H/2）。
- (nullable instancetype)initWithName:(NSString *)name
                        maxPixelsWide:(uint32_t)maxPixelsWide
                       maxPixelsHigh:(uint32_t)maxPixelsHigh
                               modes:(NSArray<NSArray<NSNumber *> *> *)modes
                               hiDPI:(BOOL)hiDPI
                            vendorID:(uint32_t)vendorID
                           productID:(uint32_t)productID
                        serialNumber:(uint32_t)serialNumber
                               error:(NSError **)error;

/// CGDirectDisplayID。destroy 后归 0。
@property (nonatomic, readonly) CGDirectDisplayID displayID;

/// 销毁显示器（release 恰好一次）。幂等；异步生效（实测 ~0.2–0.4s），
/// 返回时显示器可能仍在消失中，需轮询活动列表确认。
- (void)destroy;

@end

NS_ASSUME_NONNULL_END
