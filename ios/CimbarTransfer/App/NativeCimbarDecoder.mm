#import "NativeCimbarDecoder.h"
#import "ReceivedFileStorage.h"

#include "cimbar_js/cimbar_recv_js.h"

#include <opencv2/imgproc.hpp>
#include <exception>
#include <vector>

@implementation NativeCimbarDecodeOutput
@end

@implementation NativeCimbarDecoder {
    std::vector<unsigned char> _scanBuffer;
    std::vector<unsigned char> _decompressBuffer;
    std::vector<unsigned char> _reportBuffer;
    NSMutableSet<NSNumber *> *_emittedFileIDs;
    NSRegularExpression *_progressRegex;
    NSUInteger _processedFrameCount;
    NSUInteger _detectedFrameCount;
    cv::Mat _rgbBuffer;
    // 落盘/解压失败是一次性事件，但相机每 33ms 就有新帧刷状态文案；
    // 把错误锁存在这里，持续覆盖展示，直到重置或有文件成功接收
    NSString *_stickyErrorText;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _emittedFileIDs = [NSMutableSet set];
        _progressRegex = [NSRegularExpression regularExpressionWithPattern:@"([0-9]+(?:\\.[0-9]+)?)" options:0 error:nil];
        [self reset];
    }
    return self;
}

- (void)reset {
    cimbard_reset();
    cimbard_configure_decode(68);

    const int scanBufferSize = cimbard_get_bufsize();
    _scanBuffer.assign(MAX(scanBufferSize, 0), 0);

    const int decompressBufferSize = cimbard_get_decompress_bufsize();
    _decompressBuffer.assign(MAX(decompressBufferSize, 64 * 1024), 0);
    _reportBuffer.assign(8192, 0);
    _rgbBuffer.release();

    [_emittedFileIDs removeAllObjects];
    _processedFrameCount = 0;
    _detectedFrameCount = 0;
    _stickyErrorText = nil;
}

- (void)latchError:(NSString *)message into:(NativeCimbarDecodeOutput *)output {
    NSString *full = [message stringByAppendingString:@"。点按「继续扫码」可重试"];
    _stickyErrorText = full;
    output.statusText = full;
}

- (NativeCimbarDecodeOutput *)processPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (pixelBuffer == nil || _scanBuffer.empty()) {
        return nil;
    }

    if (![self copyPixelBufferToRGB:pixelBuffer]) {
        return nil;
    }

    // libcimbar/OpenCV throw C++ exceptions (cv::Exception, bad_alloc on
    // attacker-controlled allocation sizes); an uncaught one here would
    // terminate the app from the camera callback thread.
    try {
        return [self decodeCurrentFrame];
    } catch (const std::exception &) {
    } catch (...) {
    }

    NativeCimbarDecodeOutput *failure = [NativeCimbarDecodeOutput new];
    failure.statusText = @"解码遇到异常，已自动恢复，请继续保持取景";
    return failure;
}

// Copies the camera frame into _rgbBuffer. The pixel buffer is always
// unlocked before returning, so decode work never touches camera memory.
- (BOOL)copyPixelBufferToRGB:(CVPixelBufferRef)pixelBuffer {
    if (CVPixelBufferGetPixelFormatType(pixelBuffer) != kCVPixelFormatType_32BGRA) {
        return NO;
    }
    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return NO;
    }

    BOOL copied = NO;
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    const size_t width = CVPixelBufferGetWidth(pixelBuffer);
    const size_t height = CVPixelBufferGetHeight(pixelBuffer);
    const size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    if (baseAddress != NULL && width > 0 && height > 0) {
        try {
            cv::Mat bgra(
                static_cast<int>(height),
                static_cast<int>(width),
                CV_8UC4,
                baseAddress,
                bytesPerRow
            );
            _rgbBuffer.create(static_cast<int>(height), static_cast<int>(width), CV_8UC3);
            cv::cvtColor(bgra, _rgbBuffer, cv::COLOR_BGRA2RGB);
            copied = YES;
        } catch (...) {
            copied = NO;
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    return copied;
}

- (NativeCimbarDecodeOutput *)decodeCurrentFrame {
    const int bytes = cimbard_scan_extract_decode(
        _rgbBuffer.data,
        static_cast<unsigned>(_rgbBuffer.cols),
        static_cast<unsigned>(_rgbBuffer.rows),
        3,
        _scanBuffer.data(),
        static_cast<unsigned>(_scanBuffer.size())
    );
    _processedFrameCount += 1;

    if (bytes <= 0) {
        if ((_processedFrameCount % 20) == 0) {
            NativeCimbarDecodeOutput *idle = [NativeCimbarDecodeOutput new];
            idle.statusText = _stickyErrorText ?: @"正在扫描，尚未识别到有效码帧";
            idle.progressLabel = @"请保持发送端动画码完整放入取景框";
            return idle;
        }
        return nil;
    }

    _detectedFrameCount += 1;
    NativeCimbarDecodeOutput *output = [NativeCimbarDecodeOutput new];
    output.statusText = [NSString stringWithFormat:@"已识别到码帧，正在解码（%lu）", (unsigned long)_detectedFrameCount];
    output.progressLabel = @"已检测到传输，正在重组数据";

    const int64_t decodeResult = cimbard_fountain_decode(_scanBuffer.data(), static_cast<unsigned>(bytes));
    [self fillProgressFromReportInto:output];

    if (decodeResult > 0) {
        [self recoverFileWithID:static_cast<uint32_t>(decodeResult) into:output];
    } else if (output.progressFraction == nil && output.progressLabel == nil) {
        output.progressLabel = @"已检测到传输，正在重组数据";
    }

    // 锁存的错误优先于逐帧状态文案，避免失败提示一闪而过
    if (_stickyErrorText != nil && output.fileURL == nil) {
        output.statusText = _stickyErrorText;
    }

    if (output.statusText == nil && output.progressFraction == nil && output.fileURL == nil) {
        return nil;
    }
    return output;
}

- (void)fillProgressFromReportInto:(NativeCimbarDecodeOutput *)output {
    NSString *report = [self currentReport];
    if (report.length == 0) {
        return;
    }

    NSRange bracketRange = [report rangeOfString:@"["];
    if (bracketRange.location == NSNotFound) {
        // 无进度段的报告是上游的内部计时字符串，不适合展示给用户，
        // 保留 decodeCurrentFrame 已设置的状态文案
        return;
    }

    if (_progressRegex == nil) {
        output.statusText = @"已识别到数据帧";
        return;
    }

    NSArray<NSTextCheckingResult *> *matches = [_progressRegex matchesInString:report options:0 range:NSMakeRange(0, report.length)];
    if (matches.count == 0) {
        output.statusText = @"已识别到数据帧";
        return;
    }

    double total = 0;
    NSUInteger count = 0;
    for (NSTextCheckingResult *match in matches) {
        NSString *valueString = [report substringWithRange:[match rangeAtIndex:1]];
        double value = valueString.doubleValue;
        if (value >= 0 && value <= 1.0) {
            total += value;
            count += 1;
        }
    }

    if (count == 0) {
        output.statusText = @"已识别到数据帧";
        return;
    }

    double average = total / (double)count;
    output.progressFraction = @(average);
    output.progressLabel = [NSString stringWithFormat:@"扫码解码 %ld%%", lround(average * 100.0)];
    output.statusText = [NSString stringWithFormat:@"已接收喷泉流进度，继续保持取景（%lu 路）", (unsigned long)count];
}

- (NSString *)currentReport {
    if (_reportBuffer.empty()) {
        _reportBuffer.assign(8192, 0);
    }

    const unsigned len = cimbard_get_report(_reportBuffer.data(), static_cast<unsigned>(_reportBuffer.size()));
    if (len == 0) {
        return @"";
    }

    return [[NSString alloc] initWithBytes:_reportBuffer.data() length:len encoding:NSUTF8StringEncoding] ?: @"";
}

- (void)recoverFileWithID:(uint32_t)fileID into:(NativeCimbarDecodeOutput *)output {
    NSNumber *boxedID = @(fileID);
    if ([_emittedFileIDs containsObject:boxedID]) {
        output.statusText = @"文件已接收，可直接分享";
        return;
    }

    char filenameBuffer[512] = {0};
    const int filenameLength = cimbard_get_filename(fileID, filenameBuffer, sizeof(filenameBuffer));
    if (filenameLength < 0) {
        [self latchError:[NSString stringWithFormat:@"文件重组失败: %d", filenameLength] into:output];
        return;
    }

    NSString *filename = filenameLength > 0
        ? [[NSString alloc] initWithBytes:filenameBuffer length:(NSUInteger)filenameLength encoding:NSUTF8StringEncoding]
        : nil;
    if (filename.length == 0) {
        filename = @"cimbar-output.bin";
    }

    // 先写应用沙盒的临时目录，全部写完再原子移入 Inbox：
    // 「我的文件」列表不会看到写到一半的文件，App 被杀也不会留半成品
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *tmpURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]]];
    if (![fileManager createFileAtPath:tmpURL.path contents:nil attributes:nil]) {
        [self latchError:@"无法写入接收文件" into:output];
        return;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:tmpURL.path];
    if (handle == nil) {
        [fileManager removeItemAtURL:tmpURL error:nil];
        [self latchError:@"无法写入接收文件" into:output];
        return;
    }

    // 落盘大文件时每个 chunk 会产生临时 NSData；及时排空 autorelease 池，
    // 写入失败（如磁盘已满）走错误返回而不是 NSFileHandle 的 ObjC 异常。
    int readSize = 0;
    BOOL writeFailed = NO;
    do {
        @autoreleasepool {
            try {
                readSize = cimbard_decompress_read(fileID, _decompressBuffer.data(), static_cast<unsigned>(_decompressBuffer.size()));
            } catch (...) {
                readSize = -100;
            }
            if (readSize > 0) {
                NSData *data = [NSData dataWithBytes:_decompressBuffer.data() length:(NSUInteger)readSize];
                NSError *writeError = nil;
                if (![handle writeData:data error:&writeError]) {
                    writeFailed = YES;
                    readSize = -101;
                }
            }
        }
    } while (readSize > 0);

    [handle closeAndReturnError:nil];

    if (readSize < 0) {
        [fileManager removeItemAtURL:tmpURL error:nil];
        if (writeFailed) {
            [self latchError:@"写入文件失败，请检查设备可用存储空间" into:output];
        } else {
            [self latchError:[NSString stringWithFormat:@"文件解压失败: %d", readSize] into:output];
        }
        return;
    }

    // 写入完成，移动到最终位置（同卷 rename，原子操作）
    NSError *pathError = nil;
    NSURL *fileURL = [ReceivedFileStorage uniqueDestinationURLForFilename:filename error:&pathError];
    NSError *moveError = nil;
    if (fileURL == nil || ![fileManager moveItemAtURL:tmpURL toURL:fileURL error:&moveError]) {
        [fileManager removeItemAtURL:tmpURL error:nil];
        [self latchError:(pathError.localizedDescription ?: (moveError.localizedDescription ?: @"无法保存接收文件")) into:output];
        return;
    }
    NSString *safeName = fileURL.lastPathComponent;

    _stickyErrorText = nil;
    [_emittedFileIDs addObject:boxedID];
    output.fileURL = fileURL;
    output.progressFraction = @(1.0);
    output.progressLabel = @"文件接收 100%";

    NSDictionary<NSFileAttributeKey, id> *attributes = [fileManager attributesOfItemAtPath:fileURL.path error:nil];
    NSNumber *fileSize = attributes[NSFileSize];
    if (fileSize != nil) {
        output.statusText = [NSString stringWithFormat:@"解码完成: %@ (%@)", safeName, [NSByteCountFormatter stringFromByteCount:fileSize.longLongValue countStyle:NSByteCountFormatterCountStyleFile]];
    } else {
        output.statusText = [NSString stringWithFormat:@"解码完成: %@", safeName];
    }
}

@end
