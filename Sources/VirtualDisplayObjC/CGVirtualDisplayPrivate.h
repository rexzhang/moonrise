// CGVirtualDisplayPrivate.h — 私有类重声明：只为编译期消息类型检查。
// 这些符号都不参与链接：每个类都在运行时经 objc_getClass 查找，
// 发消息前由 +apiAvailabilityError 全量校验（类与 selector）。

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface CGVirtualDisplayDescriptor : NSObject
- (void)setName:(NSString *)name;
- (void)setMaxPixelsWide:(uint32_t)maxPixelsWide;
- (void)setMaxPixelsHigh:(uint32_t)maxPixelsHigh;
- (void)setSizeInMillimeters:(CGSize)sizeInMillimeters;
- (void)setVendorID:(uint32_t)vendorID;
- (void)setProductID:(uint32_t)productID;
- (void)setSerialNum:(uint32_t)serialNum;
- (void)setQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplay : NSObject
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(id)settings;
- (uint32_t)displayID;
@end

@interface CGVirtualDisplaySettings : NSObject
- (void)setModes:(NSArray *)modes;
// 注意类型编码 v20@0:8I16——参数是 unsigned int，不是 BOOL。
- (void)setHiDPI:(uint32_t)hiDPI;
@end

@interface CGVirtualDisplayMode : NSObject
- (nullable instancetype)initWithWidth:(uint32_t)width
                                height:(uint32_t)height
                            refreshRate:(double)refreshRate;
@end

NS_ASSUME_NONNULL_END
