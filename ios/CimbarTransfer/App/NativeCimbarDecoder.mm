#import "NativeCimbarDecoder.h"
#import "ReceivedFileStorage.h"

#include "cimbar_js/cimbar_recv_js.h"

#include <opencv2/imgproc.hpp>
#include <exception>
#include <vector>

@implementation NativeCimbarDecodeOutput
@end

// 自动模式按 cimbar.org 接收端的做法逐帧轮换候选模式，某一帧解出数据即锁定。
// 8C 是旧版模式，发送端已不再提供，只保留手动选择
static const int kAutoDetectModes[] = {68, 67, 66, 4};
static const NSUInteger kAutoDetectModeCount = sizeof(kAutoDetectModes) / sizeof(kAutoDetectModes[0]);
// 锁定后连续这么多帧（约 5 秒）解不出数据、且传输从未产生进度，视为误锁，重新轮换
static const NSUInteger kAutoUnlockFrames = 150;
// 已有进度后连续这么多帧（约 3 秒）解不出数据，开始每隔几帧用别的模式试一帧：
// 发送端中途换了模式时能跟上。试探不动喷泉流，原来的进度不受影响
static const NSUInteger kStuckFramesBeforeProbe = 90;
// 连续这么多帧「找到了码但一个字节都没读出来」才提示（相机 30fps 约 3 秒）。
// 自动模式轮换时 4 个模式里有 3 个本来就读不出，正常传输里成功的那帧会把计数清零
static const NSUInteger kUnreadableFramesBeforeHint = 90;

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
    // 自动模式：已锁定的模式（0 = 仍在轮换）及误锁检测
    int _lockedMode;
    NSUInteger _framesWithoutData;
    BOOL _hasProgress;
    NSUInteger _stuckFrames;
    NSUInteger _probeCursor;
    NSUInteger _unreadableFrames;
    BOOL _reportedUnreadable;
    // 上一个收到的文件：不随 -reset 清空。点「继续接收」时发送端往往还在放同一个文件，
    // 几秒内会再收一遍；内容一致就复用已保存的文件，不再存出「xxx (1).jpg」
    uint32_t _lastFileID;
    NSURL *_lastFileURL;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _emittedFileIDs = [NSMutableSet set];
        _progressRegex = [NSRegularExpression regularExpressionWithPattern:@"([0-9]+(?:\\.[0-9]+)?)" options:0 error:nil];
        _decodeMode = 0;
        [self reset];
    }
    return self;
}

- (BOOL)isAutoMode {
    return _decodeMode <= 0;
}

- (void)reset {
    cimbard_reset();

    // 每帧缓冲区大小随模式而变；自动模式会轮换，按候选模式里最大的分配
    int scanBufferSize = 0;
    if (self.isAutoMode) {
        for (NSUInteger i = 0; i < kAutoDetectModeCount; ++i) {
            cimbard_configure_decode(kAutoDetectModes[i]);
            scanBufferSize = MAX(scanBufferSize, cimbard_get_bufsize());
        }
        cimbard_configure_decode(kAutoDetectModes[0]);
    } else {
        cimbard_configure_decode(_decodeMode);
        scanBufferSize = cimbard_get_bufsize();
    }
    _scanBuffer.assign(MAX(scanBufferSize, 0), 0);

    const int decompressBufferSize = cimbard_get_decompress_bufsize();
    _decompressBuffer.assign(MAX(decompressBufferSize, 64 * 1024), 0);
    _reportBuffer.assign(8192, 0);
    _rgbBuffer.release();

    [_emittedFileIDs removeAllObjects];
    _processedFrameCount = 0;
    _detectedFrameCount = 0;
    _stickyErrorText = nil;
    _lockedMode = 0;
    _framesWithoutData = 0;
    _hasProgress = NO;
    _stuckFrames = 0;
    _unreadableFrames = 0;
    _reportedUnreadable = NO;
}

- (void)latchError:(NSString *)message into:(NativeCimbarDecodeOutput *)output {
    _stickyErrorText = message;
    output.statusText = message;
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

    // 一帧异常不该抹掉已锁存的错误和已识别的模式（VM 会照单全收这两个字段）
    NativeCimbarDecodeOutput *failure = [NativeCimbarDecodeOutput new];
    failure.statusText = _stickyErrorText ?: NSLocalizedString(@"解码出错，已自动恢复", nil);
    failure.hasStickyError = (_stickyErrorText != nil);
    failure.detectedMode = self.isAutoMode ? _lockedMode : 0;
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
    int probingMode = 0;
    int switchProbeMode = 0;
    if (self.isAutoMode && _lockedMode == 0) {
        probingMode = kAutoDetectModes[_processedFrameCount % kAutoDetectModeCount];
        cimbard_configure_decode(probingMode);
    } else if (self.isAutoMode && _hasProgress && _stuckFrames > kStuckFramesBeforeProbe
               && (_processedFrameCount % 3) == 0) {
        do {
            switchProbeMode = kAutoDetectModes[_probeCursor++ % kAutoDetectModeCount];
        } while (switchProbeMode == _lockedMode);
        cimbard_set_decode_mode_keep_sink(switchProbeMode);
    }

    const int bytes = cimbard_scan_extract_decode(
        _rgbBuffer.data,
        static_cast<unsigned>(_rgbBuffer.cols),
        static_cast<unsigned>(_rgbBuffer.rows),
        3,
        _scanBuffer.data(),
        static_cast<unsigned>(_scanBuffer.size())
    );
    _processedFrameCount += 1;

    if (switchProbeMode != 0) {
        cimbard_set_decode_mode_keep_sink(_lockedMode);
        if (bytes > 0) {
            // 发送端换了模式：旧传输按原模式已经接不上，按新模式从头收
            cimbard_reset();
            cimbard_configure_decode(switchProbeMode);
            _lockedMode = switchProbeMode;
            _hasProgress = NO;
            _stuckFrames = 0;
        }
    }
    if (self.isAutoMode && _hasProgress) {
        _stuckFrames = bytes > 0 ? 0 : _stuckFrames + 1;
    }

    // 0 = 找到了码但没读出数据；负数 = 没找到码（-3）或参数错误。没找到码的帧慢慢抵消计数，
    // 免得手抖一下、码短暂出框就把「一直读不出来」的判断清零
    if (bytes > 0) {
        _unreadableFrames = 0;
    } else if (bytes == 0) {
        // 封顶：不然对着读不出的码 30 秒后计数到 900，码移开后提示还要再挂 30 秒才消失
        _unreadableFrames = MIN(_unreadableFrames + 1, kUnreadableFramesBeforeHint + 30);
    } else if (_unreadableFrames > 0) {
        _unreadableFrames -= 1;
    }
    const BOOL unreadable = !_hasProgress && _unreadableFrames >= kUnreadableFramesBeforeHint;

    if (bytes <= 0) {
        if (self.isAutoMode && _lockedMode != 0 && !_hasProgress
            && ++_framesWithoutData > kAutoUnlockFrames) {
            _lockedMode = 0;
            _framesWithoutData = 0;
        }
        if ((_processedFrameCount % 20) == 0 || unreadable != _reportedUnreadable) {
            _reportedUnreadable = unreadable;
            NativeCimbarDecodeOutput *idle = [NativeCimbarDecodeOutput new];
            idle.isIdle = YES;
            idle.codeUnreadable = unreadable;
            idle.statusText = _stickyErrorText ?: NSLocalizedString(@"正在寻找动画码", nil);
            idle.hasStickyError = (_stickyErrorText != nil);
            idle.detectedMode = self.isAutoMode ? _lockedMode : 0;
            return idle;
        }
        return nil;
    }

    if (probingMode != 0) {
        _lockedMode = probingMode;
    }
    _framesWithoutData = 0;
    _reportedUnreadable = NO; // 读出数据的输出 codeUnreadable 默认是 NO，界面据此收起提示
    _detectedFrameCount += 1;
    NativeCimbarDecodeOutput *output = [NativeCimbarDecodeOutput new];
    output.detectedFrameCount = _detectedFrameCount;
    output.detectedMode = self.isAutoMode ? _lockedMode : 0;
    output.statusText = NSLocalizedString(@"正在接收", nil);

    const int64_t decodeResult = cimbard_fountain_decode(_scanBuffer.data(), static_cast<unsigned>(bytes));
    [self fillProgressFromReportInto:output];
    if (output.progressFraction.doubleValue > 0) {
        _hasProgress = YES;
    }

    if (decodeResult > 0) {
        [self recoverFileWithID:static_cast<uint32_t>(decodeResult) into:output];
    }

    // 锁存的错误优先于逐帧状态文案，避免失败提示一闪而过
    if (_stickyErrorText != nil && output.fileURL == nil) {
        output.statusText = _stickyErrorText;
    }
    output.hasStickyError = (_stickyErrorText != nil);

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
        return;
    }

    NSArray<NSTextCheckingResult *> *matches = [_progressRegex matchesInString:report options:0 range:NSMakeRange(0, report.length)];
    if (matches.count == 0) {
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
        return;
    }

    output.progressFraction = @(total / (double)count);
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

// 同一次传输（喷泉 ID 相同）且内容逐字节一致时，删掉刚写的临时文件，交回上次保存的文件
// 换了解码器（重开 App、中间收过别的文件）后再收到同一个文件：收件目录里已有同名、内容一样的就不再另存一份
- (BOOL)reuseStoredFileIfSame:(uint32_t)fileID tmpURL:(NSURL *)tmpURL originalName:(NSString *)filename into:(NativeCimbarDecodeOutput *)output {
    NSURL *stored = [ReceivedFileStorage storedFileMatchingContentsOf:tmpURL filename:filename];
    if (stored == nil) {
        return NO;
    }
    _lastFileID = fileID;
    _lastFileURL = stored;
    [self emitDuplicateOf:fileID tmpURL:tmpURL originalName:filename into:output];
    return YES;
}

- (BOOL)reuseLastFileIfSame:(uint32_t)fileID tmpURL:(NSURL *)tmpURL originalName:(NSString *)filename into:(NativeCimbarDecodeOutput *)output {
    if (_lastFileURL == nil || fileID != _lastFileID) {
        return NO;
    }
    if (![[NSFileManager defaultManager] contentsEqualAtPath:tmpURL.path andPath:_lastFileURL.path]) {
        return NO;
    }
    [self emitDuplicateOf:fileID tmpURL:tmpURL originalName:filename into:output];
    return YES;
}

// 丢掉刚写的临时文件，把已有的 _lastFileURL 当作这次收到的文件交出去
- (void)emitDuplicateOf:(uint32_t)fileID tmpURL:(NSURL *)tmpURL originalName:(NSString *)filename into:(NativeCimbarDecodeOutput *)output {
    [[NSFileManager defaultManager] removeItemAtURL:tmpURL error:nil];
    _stickyErrorText = nil;
    [_emittedFileIDs addObject:@(fileID)];
    output.fileURL = _lastFileURL;
    output.originalFilename = filename;
    output.progressFraction = @(1.0);
    output.isDuplicate = YES;
    output.statusText = [NSString stringWithFormat:NSLocalizedString(@"已收到 %@", nil), _lastFileURL.lastPathComponent];
}

- (void)recoverFileWithID:(uint32_t)fileID into:(NativeCimbarDecodeOutput *)output {
    NSNumber *boxedID = @(fileID);
    if ([_emittedFileIDs containsObject:boxedID]) {
        output.statusText = NSLocalizedString(@"文件已收到", nil);
        return;
    }

    char filenameBuffer[512] = {0};
    const int filenameLength = cimbard_get_filename(fileID, filenameBuffer, sizeof(filenameBuffer));
    if (filenameLength < 0) {
        [self latchError:[NSString stringWithFormat:NSLocalizedString(@"文件没能收完整（错误 %d）", nil), filenameLength] into:output];
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
        [self latchError:NSLocalizedString(@"无法保存文件", nil) into:output];
        return;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:tmpURL.path];
    if (handle == nil) {
        [fileManager removeItemAtURL:tmpURL error:nil];
        [self latchError:NSLocalizedString(@"无法保存文件", nil) into:output];
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
            [self latchError:NSLocalizedString(@"保存失败，请检查剩余存储空间", nil) into:output];
        } else {
            [self latchError:[NSString stringWithFormat:NSLocalizedString(@"文件收到了，但解不开（错误 %d）", nil), readSize] into:output];
        }
        return;
    }

    if ([self reuseLastFileIfSame:fileID tmpURL:tmpURL originalName:filename into:output]
        || [self reuseStoredFileIfSame:fileID tmpURL:tmpURL originalName:filename into:output]) {
        return;
    }

    // 写入完成，移动到最终位置（同卷 rename，原子操作）。
    // uniqueDestinationURL 的存在性探测与 move 之间存在竞态窗口（启动迁移线程
    // 可能同时占用同名路径）；喷泉流此刻已在 sink 中标记完成、无法重放，
    // 所以失败时必须换个名字重试而不是删掉 tmp 丢弃整份文件。
    NSURL *fileURL = nil;
    NSError *lastError = nil;
    for (int attempt = 0; attempt < 3 && fileURL == nil; ++attempt) {
        NSError *pathError = nil;
        NSURL *candidate = [ReceivedFileStorage uniqueDestinationURLForFilename:filename error:&pathError];
        if (candidate == nil) {
            lastError = pathError;
            continue;
        }
        NSError *moveError = nil;
        if ([fileManager moveItemAtURL:tmpURL toURL:candidate error:&moveError]) {
            fileURL = candidate;
        } else {
            lastError = moveError;
        }
    }
    if (fileURL == nil) {
        [fileManager removeItemAtURL:tmpURL error:nil];
        [self latchError:(lastError.localizedDescription ?: NSLocalizedString(@"无法保存文件", nil)) into:output];
        return;
    }
    NSString *safeName = fileURL.lastPathComponent;
    _lastFileID = fileID;
    _lastFileURL = fileURL;

    _stickyErrorText = nil;
    [_emittedFileIDs addObject:boxedID];
    output.fileURL = fileURL;
    output.originalFilename = filename;
    output.progressFraction = @(1.0);

    NSDictionary<NSFileAttributeKey, id> *attributes = [fileManager attributesOfItemAtPath:fileURL.path error:nil];
    NSNumber *fileSize = attributes[NSFileSize];
    if (fileSize != nil) {
        output.statusText = [NSString stringWithFormat:NSLocalizedString(@"已收到 %@（%@）", nil), safeName, [NSByteCountFormatter stringFromByteCount:fileSize.longLongValue countStyle:NSByteCountFormatterCountStyleFile]];
    } else {
        output.statusText = [NSString stringWithFormat:NSLocalizedString(@"已收到 %@", nil), safeName];
    }
}

@end
