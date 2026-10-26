#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NativeCimbarDecodeOutput : NSObject
@property (nonatomic, copy, nullable) NSString *statusText;
@property (nonatomic, strong, nullable) NSNumber *progressFraction;
// 本帧没有识别到码（码不在取景框内）；进度保留在喷泉流里，不会丢
@property (nonatomic, assign) BOOL isIdle;
@property (nonatomic, strong, nullable) NSURL *fileURL;
@property (nonatomic, assign) BOOL didDetectFirstFrame;
@property (nonatomic, assign) NSUInteger revision;
// 本次扫码会话累计识别到的有效码帧数（0 表示该输出不携带计数）
@property (nonatomic, assign) NSUInteger detectedFrameCount;
// 存在锁存的落盘/解压错误（一次性失败且喷泉流不可重放，需用户重扫）
@property (nonatomic, assign) BOOL hasStickyError;
// 发送端原始文件名（未经 sanitize/去重），仅在 fileURL 非空时有意义
@property (nonatomic, copy, nullable) NSString *originalFilename;
// 自动模式下已锁定的发送端模式（mode_val）；0 表示尚未识别或非自动模式
@property (nonatomic, assign) int detectedMode;
@end

@interface NativeCimbarDecoder : NSObject
/// 解码模式（cimbar mode_val）：0 自动识别（默认）、68 B、67 Bm、66 Bu、4 4C、8 8C（旧版）。
/// 修改后需调用 -reset 才会生效（会清空当前解码进度并重建缓冲区）。
@property (nonatomic) int decodeMode;
- (nullable NativeCimbarDecodeOutput *)processPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)reset;
@end

NS_ASSUME_NONNULL_END
