// 端到端解码自测：用 libcimbar 自带的编码器把一段数据编成动画码帧，
// 套进 720×1280 的 BGRA 画布模拟相机画面，交给 App 里的 NativeCimbarDecoder 解码，
// 核对落盘文件与原文一致。覆盖自动识别（每种发送端模式各一次）和手动模式。
//
// 由 scripts/run_decode_selftest.sh 编译为 iOS 模拟器可执行文件，经 simctl spawn 运行。

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "NativeCimbarDecoder.h"

#include "cimb_translator/Config.h"
#include "compression/zstd_compressor.h"
#include "encoder/Encoder.h"
#include "fountain/FountainInit.h"
#include "fountain/fountain_encoder_stream.h"

#include <opencv2/imgproc.hpp>

#include <cstdio>
#include <random>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {

const int kCanvasWidth = 720;
const int kCanvasHeight = 1280;

std::string makePayload(size_t size) {
    // 伪随机内容，zstd 压不小，能真正跑满多帧喷泉码
    std::mt19937 rng(42);
    std::string data(size, '\0');
    for (char &c : data) {
        c = static_cast<char>(rng() & 0xFF);
    }
    return data;
}

// 编码器的 Config 是 thread_local：放到独立线程里跑，不污染解码线程的模式设置
std::vector<cv::Mat> encodeFrames(int mode, const std::string &filename, const std::string &payload, int frameCount,
                                  uint8_t encodeId = 77) {
    std::vector<cv::Mat> frames;
    std::thread worker([&] {
        cimbar::Config::update(mode);
        if (!FountainInit::init()) {
            return;
        }
        cimbar::zstd_compressor<std::stringstream> comp;
        comp.set_compression_level(cimbar::Config::compression_level());
        comp.write_header(filename.data(), static_cast<unsigned>(filename.size()));
        comp.write(payload.data(), payload.size());

        const unsigned chunkSize = cimbar::Config::fountain_chunk_size();
        if (comp.size() < chunkSize) {
            comp.pad(chunkSize - comp.size() + 1);
        }
        auto fes = fountain_encoder_stream::create(comp, chunkSize, encodeId);
        if (!fes) {
            return;
        }
        for (int i = 0; i < frameCount; ++i) {
            Encoder enc;
            enc.set_encode_id(encodeId);
            std::optional<cv::Mat> frame = enc.encode_next(*fes);
            if (!frame) {
                break;
            }
            frames.push_back(frame->clone());
        }
    });
    worker.join();
    return frames;
}

// 把编码帧缩放后居中放进灰底竖屏画布，近似手机对着屏幕拍到的样子
CVPixelBufferRef makeCameraFrame(const cv::Mat &rgbFrame) {
    cv::Mat canvas(kCanvasHeight, kCanvasWidth, CV_8UC4, cv::Scalar(60, 60, 60, 255));
    const int side = 660;
    const double scale = std::min(side / double(rgbFrame.cols), side / double(rgbFrame.rows));
    cv::Mat scaled;
    cv::resize(rgbFrame, scaled, cv::Size(), scale, scale, cv::INTER_AREA);
    cv::Mat bgra;
    cv::cvtColor(scaled, bgra, cv::COLOR_RGB2BGRA);
    const int x = (kCanvasWidth - bgra.cols) / 2;
    const int y = (kCanvasHeight - bgra.rows) / 2;
    bgra.copyTo(canvas(cv::Rect(x, y, bgra.cols, bgra.rows)));

    CVPixelBufferRef buffer = nullptr;
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    if (CVPixelBufferCreate(kCFAllocatorDefault, kCanvasWidth, kCanvasHeight, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &buffer) != kCVReturnSuccess) {
        return nullptr;
    }
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *base = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(buffer));
    const size_t bytesPerRow = CVPixelBufferGetBytesPerRow(buffer);
    for (int row = 0; row < kCanvasHeight; ++row) {
        memcpy(base + row * bytesPerRow, canvas.ptr(row), kCanvasWidth * 4);
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return buffer;
}

struct Result {
    bool received = false;
    bool contentMatches = false;
    int framesFed = 0;
    int detectedMode = 0;
};

Result runDecode(int senderMode, int receiverMode, const std::string &payload, NSString *filename) {
    Result result;
    std::vector<cv::Mat> frames = encodeFrames(senderMode, filename.UTF8String, payload, 120);
    if (frames.empty()) {
        fprintf(stderr, "  encoder produced no frames\n");
        return result;
    }

    std::vector<CVPixelBufferRef> buffers;
    for (const cv::Mat &frame : frames) {
        if (CVPixelBufferRef buffer = makeCameraFrame(frame)) {
            buffers.push_back(buffer);
        }
    }

    // 解码在独立线程上做，和 App 里 frameQueue 一样不与编码线程共享 thread_local 配置
    std::thread worker([&] {
        @autoreleasepool {
            NativeCimbarDecoder *decoder = [NativeCimbarDecoder new];
            if (decoder.decodeMode != receiverMode) {
                decoder.decodeMode = receiverMode;
                [decoder reset];
            }
            for (size_t i = 0; i < buffers.size() * 2 && !result.received; ++i) {
                NativeCimbarDecodeOutput *output = [decoder processPixelBuffer:buffers[i % buffers.size()]];
                result.framesFed = static_cast<int>(i + 1);
                if (output.detectedMode != 0) {
                    result.detectedMode = output.detectedMode;
                }
                if (output.fileURL != nil) {
                    result.received = true;
                    NSData *data = [NSData dataWithContentsOfURL:output.fileURL];
                    result.contentMatches = data.length == payload.size()
                        && memcmp(data.bytes, payload.data(), payload.size()) == 0;
                    [[NSFileManager defaultManager] removeItemAtURL:output.fileURL error:nil];
                }
            }
        }
    });
    worker.join();

    for (CVPixelBufferRef buffer : buffers) {
        CVPixelBufferRelease(buffer);
    }
    return result;
}

std::vector<CVPixelBufferRef> cameraFrames(const std::vector<cv::Mat> &frames) {
    std::vector<CVPixelBufferRef> buffers;
    for (const cv::Mat &frame : frames) {
        if (CVPixelBufferRef buffer = makeCameraFrame(frame)) {
            buffers.push_back(buffer);
        }
    }
    return buffers;
}

NativeCimbarDecodeOutput *feedUntilFile(NativeCimbarDecoder *decoder, const std::vector<CVPixelBufferRef> &buffers) {
    for (size_t i = 0; i < buffers.size() * 2; ++i) {
        NativeCimbarDecodeOutput *output = [decoder processPixelBuffer:buffers[i % buffers.size()]];
        if (output.fileURL != nil) {
            return output;
        }
    }
    return nil;
}

// 「继续接收」时发送端还在放同一个文件：第二遍应复用已保存的文件；换一个文件则照常另存
bool runRepeatTest() {
    const std::string first = makePayload(16 * 1024);
    std::string second = first;
    second[0] ^= 0x5A;
    std::vector<CVPixelBufferRef> firstFrames = cameraFrames(encodeFrames(68, "repeat.bin", first, 60, 90));
    std::vector<CVPixelBufferRef> secondFrames = cameraFrames(encodeFrames(68, "repeat.bin", second, 60, 91));

    bool ok = false;
    std::thread worker([&] {
        @autoreleasepool {
            NativeCimbarDecoder *decoder = [NativeCimbarDecoder new];
            NativeCimbarDecodeOutput *a = feedUntilFile(decoder, firstFrames);
            [decoder reset];
            NativeCimbarDecodeOutput *b = feedUntilFile(decoder, firstFrames);
            [decoder reset];
            NativeCimbarDecodeOutput *c = feedUntilFile(decoder, secondFrames);
            ok = a != nil && b != nil && c != nil
                && !a.isDuplicate && b.isDuplicate && !c.isDuplicate
                && [a.fileURL isEqual:b.fileURL] && ![c.fileURL isEqual:a.fileURL]
                && [[NSFileManager defaultManager] fileExistsAtPath:a.fileURL.path];
            printf("%s  repeat       first=%s second=%s (dup=%d) third=%s (dup=%d)\n", ok ? "PASS" : "FAIL",
                   a.fileURL.lastPathComponent.UTF8String ?: "-",
                   b.fileURL.lastPathComponent.UTF8String ?: "-", b.isDuplicate,
                   c.fileURL.lastPathComponent.UTF8String ?: "-", c.isDuplicate);
            for (NativeCimbarDecodeOutput *output in @[a ?: [NativeCimbarDecodeOutput new], c ?: [NativeCimbarDecodeOutput new]]) {
                if (output.fileURL) {
                    [[NSFileManager defaultManager] removeItemAtURL:output.fileURL error:nil];
                }
            }
        }
    });
    worker.join();
    for (CVPixelBufferRef buffer : firstFrames) CVPixelBufferRelease(buffer);
    for (CVPixelBufferRef buffer : secondFrames) CVPixelBufferRelease(buffer);
    return ok;
}

// 截图素材：把一帧 B 模式动画码存成 PNG（模拟器的 OpenCV 切片没有 imgcodecs，用 ImageIO 写）
bool dumpFrame(const char *path) {
    std::vector<cv::Mat> frames = encodeFrames(68, "demo.bin", makePayload(64 * 1024), 4);
    if (frames.size() < 4) {
        return false;
    }
    cv::Mat rgba;
    cv::cvtColor(frames[3], rgba, cv::COLOR_RGB2RGBA);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(rgba.data, rgba.cols, rgba.rows, 8, rgba.step, space,
                                             kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault);
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    NSURL *url = [NSURL fileURLWithPath:@(path)];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url,
                                                                 (__bridge CFStringRef)UTTypePNG.identifier, 1, nullptr);
    CGImageDestinationAddImage(dest, image, nullptr);
    const bool ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CGImageRelease(image);
    CGContextRelease(ctx);
    CGColorSpaceRelease(space);
    return ok;
}

} // namespace

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "--dump-frame") == 0) {
            const bool ok = dumpFrame(argv[2]);
            printf(ok ? "wrote %s\n" : "failed to write %s\n", argv[2]);
            return ok ? 0 : 1;
        }

        const std::string payload = makePayload(24 * 1024);
        struct Case {
            const char *name;
            int sender;
            int receiver;
            bool expectReceived;
            int expectDetected;
        };
        const Case cases[] = {
            {"auto  <- B ", 68, 0, true, 68},
            {"auto  <- Bm", 67, 0, true, 67},
            {"auto  <- Bu", 66, 0, true, 66},
            {"auto  <- 4C", 4, 0, true, 4},
            {"B     <- B ", 68, 68, true, 0},
            {"Bm    <- Bm", 67, 67, true, 0},
            {"B     <- Bu", 66, 68, false, 0},
        };

        int failures = 0;
        for (const Case &c : cases) {
            Result r = runDecode(c.sender, c.receiver, payload, @"selftest.bin");
            const bool ok = r.received == c.expectReceived
                && (!c.expectReceived || r.contentMatches)
                && r.detectedMode == c.expectDetected;
            if (!ok) {
                ++failures;
            }
            printf("%s  %-12s received=%d match=%d detected=%d frames=%d\n",
                   ok ? "PASS" : "FAIL", c.name, r.received, r.contentMatches, r.detectedMode, r.framesFed);
        }
        if (!runRepeatTest()) {
            ++failures;
        }
        printf("%s (%d failure%s)\n", failures == 0 ? "ALL PASSED" : "FAILED", failures, failures == 1 ? "" : "s");
        return failures == 0 ? 0 : 1;
    }
}
