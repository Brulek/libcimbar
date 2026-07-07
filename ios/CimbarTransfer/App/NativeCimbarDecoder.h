#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NativeCimbarDecodeOutput : NSObject
@property (nonatomic, copy, nullable) NSString *statusText;
@property (nonatomic, strong, nullable) NSNumber *progressFraction;
@property (nonatomic, copy, nullable) NSString *progressLabel;
@property (nonatomic, strong, nullable) NSURL *fileURL;
@property (nonatomic, assign) BOOL didDetectFirstFrame;
@property (nonatomic, assign) NSUInteger revision;
// 本次扫码会话累计识别到的有效码帧数（0 表示该输出不携带计数）
@property (nonatomic, assign) NSUInteger detectedFrameCount;
// 存在锁存的落盘/解压错误（一次性失败且喷泉流不可重放，需用户重扫）
@property (nonatomic, assign) BOOL hasStickyError;
// 发送端原始文件名（未经 sanitize/去重），仅在 fileURL 非空时有意义
@property (nonatomic, copy, nullable) NSString *originalFilename;
@end

@interface NativeCimbarDecoder : NSObject
/// 解码模式（cimbar mode_val）：68 标准 B（默认）、4 兼容 4C、8 兼容 8C、67 mini、66 micro。
/// 修改后需调用 -reset 才会生效（会清空当前解码进度并重建缓冲区）。
@property (nonatomic) int decodeMode;
- (nullable NativeCimbarDecodeOutput *)processPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)reset;
@end

NS_ASSUME_NONNULL_END
