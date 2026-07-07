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
@end

@interface NativeCimbarDecoder : NSObject
- (nullable NativeCimbarDecodeOutput *)processPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)reset;
@end

NS_ASSUME_NONNULL_END
