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

// 「拍出来」的帧：开启后加透视倾斜、缩小、模糊、偏暗和噪点，近似手持拍屏幕
bool gDegrade = false;
uint64_t gFrameSeed = 1;

cv::Mat degradeFrame(const cv::Mat &bgra) {
    cv::RNG rng(gFrameSeed++);
    const float w = bgra.cols, h = bgra.rows;
    const float jitter = 0.025f * w;
    auto j = [&] { return rng.uniform(-jitter, jitter); };
    const cv::Point2f src[4] = {{0, 0}, {w, 0}, {w, h}, {0, h}};
    const cv::Point2f dst[4] = {{j(), j()}, {w + j(), j()}, {w + j(), h + j()}, {j(), h + j()}};
    cv::Mat warped;
    cv::warpPerspective(bgra, warped, cv::getPerspectiveTransform(src, dst), bgra.size(),
                        cv::INTER_LINEAR, cv::BORDER_CONSTANT, cv::Scalar(60, 60, 60, 255));
    cv::GaussianBlur(warped, warped, cv::Size(0, 0), 0.8);
    warped.convertTo(warped, -1, 0.82, 6); // 偏暗、对比度略降
    cv::Mat noise(warped.size(), warped.type());
    rng.fill(noise, cv::RNG::NORMAL, cv::Scalar::all(0), cv::Scalar(6, 6, 6, 0));
    cv::Mat out;
    cv::add(warped, noise, out, cv::noArray(), warped.type());
    return out;
}

// 把编码帧缩放后居中放进灰底竖屏画布，近似手机对着屏幕拍到的样子
CVPixelBufferRef makeCameraFrame(const cv::Mat &rgbFrame) {
    cv::Mat canvas(kCanvasHeight, kCanvasWidth, CV_8UC4, cv::Scalar(60, 60, 60, 255));
    const int side = gDegrade ? 640 : 660;
    const double scale = std::min(side / double(rgbFrame.cols), side / double(rgbFrame.rows));
    cv::Mat scaled;
    cv::resize(rgbFrame, scaled, cv::Size(), scale, scale, cv::INTER_AREA);
    cv::Mat bgra;
    cv::cvtColor(scaled, bgra, cv::COLOR_RGB2BGRA);
    const int x = (kCanvasWidth - bgra.cols) / 2;
    const int y = (kCanvasHeight - bgra.rows) / 2;
    bgra.copyTo(canvas(cv::Rect(x, y, bgra.cols, bgra.rows)));
    if (gDegrade) {
        canvas = degradeFrame(canvas);
    }

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
    double msPerFrame = 0;
};

Result runDecode(int senderMode, int receiverMode, const std::string &payload, NSString *filename) {
    Result result;
    std::vector<cv::Mat> frames = encodeFrames(senderMode, filename.UTF8String, payload, payload.size() > 100000 ? 400 : 120);
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
            const CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
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
            result.msPerFrame = (CFAbsoluteTimeGetCurrent() - start) * 1000.0 / std::max(result.framesFed, 1);
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

// 发送端给的文件名是外部数据：路径分隔符、空名、点开头、换行、超长名都要落在收件目录里且名字可用
bool runFilenameTest() {
    std::string longName;
    for (int i = 0; i < 120; ++i) longName += "长";
    longName += ".txt";
    const std::vector<std::string> names = {"../../evil.txt", "", ".hidden", "a\nb.txt", longName};
    bool ok = true;
    for (size_t i = 0; i < names.size(); ++i) {
        std::vector<CVPixelBufferRef> frames = cameraFrames(encodeFrames(67, names[i], makePayload(2048), 30, 110 + i));
        std::thread worker([&] {
            @autoreleasepool {
                NativeCimbarDecoder *decoder = [NativeCimbarDecoder new];
                NativeCimbarDecodeOutput *out = feedUntilFile(decoder, frames);
                NSString *name = out.fileURL.lastPathComponent;
                NSString *parent = out.fileURL.URLByDeletingLastPathComponent.lastPathComponent;
                const bool good = out.fileURL != nil && name.length > 0 && ![name hasPrefix:@"."]
                    && [parent isEqualToString:@"Inbox"]
                    && [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 255
                    && [name rangeOfString:@"/"].location == NSNotFound
                    && [name rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound;
                if (!good) ok = false;
                printf("%s  filename %zu -> %s\n", good ? "PASS" : "FAIL", i, name.UTF8String ?: "-");
                if (out.fileURL) [[NSFileManager defaultManager] removeItemAtURL:out.fileURL error:nil];
            }
        });
        worker.join();
        for (CVPixelBufferRef buffer : frames) CVPixelBufferRelease(buffer);
    }
    return ok;
}

// 发送端中途换模式：先收到一部分 B，再全部换成 Bm。自动模式应跟上，最终收到 Bm 那份文件
bool runModeSwitchTest() {
    const std::string first = makePayload(24 * 1024);
    std::string second = makePayload(12 * 1024);
    second[1] ^= 0x33;
    std::vector<CVPixelBufferRef> bFrames = cameraFrames(encodeFrames(68, "switch.bin", first, 2, 92));
    std::vector<CVPixelBufferRef> bmFrames = cameraFrames(encodeFrames(67, "switch.bin", second, 60, 93));
    bool ok = false;
    int framesToFinish = 0;
    std::thread worker([&] {
        @autoreleasepool {
            NativeCimbarDecoder *decoder = [NativeCimbarDecoder new];
            bool hadProgress = false;
            for (CVPixelBufferRef buffer : bFrames) {
                NativeCimbarDecodeOutput *output = [decoder processPixelBuffer:buffer];
                hadProgress = hadProgress || output.progressFraction.doubleValue > 0;
            }
            NativeCimbarDecodeOutput *done = nil;
            for (int i = 0; i < 600 && done == nil; ++i) {
                NativeCimbarDecodeOutput *output = [decoder processPixelBuffer:bmFrames[i % bmFrames.size()]];
                framesToFinish = i + 1;
                if (output.fileURL) done = output;
            }
            NSData *data = done ? [NSData dataWithContentsOfURL:done.fileURL] : nil;
            ok = hadProgress && done && done.detectedMode == 67 && data.length == second.size()
                && memcmp(data.bytes, second.data(), second.size()) == 0;
            if (done.fileURL) [[NSFileManager defaultManager] removeItemAtURL:done.fileURL error:nil];
        }
    });
    worker.join();
    for (CVPixelBufferRef buffer : bFrames) CVPixelBufferRelease(buffer);
    for (CVPixelBufferRef buffer : bmFrames) CVPixelBufferRelease(buffer);
    printf("%s  mode switch  B partial -> Bm, finished after %d Bm frames\n", ok ? "PASS" : "FAIL", framesToFinish);
    return ok;
}

// 传输中途码离开取景框很久（会触发换模式试探），再回来：应接着原来的进度收完，不能从头来
bool runLostAndBackTest() {
    const std::string payload = makePayload(24 * 1024);
    std::vector<CVPixelBufferRef> frames = cameraFrames(encodeFrames(68, "back.bin", payload, 60, 94));
    std::vector<CVPixelBufferRef> empty;
    cv::RNG rng(11);
    for (int i = 0; i < 20; ++i) {
        cv::Mat scene(kCanvasHeight / 2, kCanvasWidth / 2, CV_8UC3);
        rng.fill(scene, cv::RNG::UNIFORM, cv::Scalar::all(0), cv::Scalar::all(255));
        cv::GaussianBlur(scene, scene, cv::Size(0, 0), 3);
        empty.push_back(makeCameraFrame(scene));
    }
    bool ok = false;
    double progressBefore = 0, progressAfterFirst = 0;
    int framesAfterReturn = 0;
    std::thread worker([&] {
        @autoreleasepool {
            NativeCimbarDecoder *decoder = [NativeCimbarDecoder new];
            for (int i = 0; i < 2; ++i) {
                NativeCimbarDecodeOutput *output = [decoder processPixelBuffer:frames[i]];
                if (output.progressFraction) progressBefore = output.progressFraction.doubleValue;
            }
            for (int i = 0; i < 300; ++i) {
                [decoder processPixelBuffer:empty[i % empty.size()]];
            }
            NativeCimbarDecodeOutput *done = nil;
            for (size_t i = 2; i < frames.size() && done == nil; ++i) {
                NativeCimbarDecodeOutput *output = [decoder processPixelBuffer:frames[i]];
                framesAfterReturn += 1;
                if (framesAfterReturn == 1 && output.progressFraction) {
                    progressAfterFirst = output.progressFraction.doubleValue;
                }
                if (output.fileURL) done = output;
            }
            NSData *data = done ? [NSData dataWithContentsOfURL:done.fileURL] : nil;
            ok = done && progressAfterFirst > progressBefore && data.length == payload.size()
                && memcmp(data.bytes, payload.data(), payload.size()) == 0;
            if (done.fileURL) [[NSFileManager defaultManager] removeItemAtURL:done.fileURL error:nil];
        }
    });
    worker.join();
    for (CVPixelBufferRef buffer : frames) CVPixelBufferRelease(buffer);
    for (CVPixelBufferRef buffer : empty) CVPixelBufferRelease(buffer);
    printf("%s  lost & back  progress %.0f%% -> %.0f%% after return, done in %d frames\n", ok ? "PASS" : "FAIL",
           progressBefore * 100, progressAfterFirst * 100, framesAfterReturn);
    return ok;
}

// 取景框里没有码（拍的是噪点和渐变）：自动模式绝不能误锁某个模式、更不能产出文件
bool runNoCodeTest() {
    std::vector<CVPixelBufferRef> buffers;
    cv::RNG rng(7);
    for (int i = 0; i < 60; ++i) {
        cv::Mat scene(kCanvasHeight / 2, kCanvasWidth / 2, CV_8UC3);
        rng.fill(scene, cv::RNG::UNIFORM, cv::Scalar::all(0), cv::Scalar::all(255));
        cv::GaussianBlur(scene, scene, cv::Size(0, 0), 2 + (i % 5));
        if (CVPixelBufferRef buffer = makeCameraFrame(scene)) {
            buffers.push_back(buffer);
        }
    }
    bool ok = true;
    std::thread worker([&] {
        @autoreleasepool {
            NativeCimbarDecoder *decoder = [NativeCimbarDecoder new];
            for (int round = 0; round < 5; ++round) {
                for (CVPixelBufferRef buffer : buffers) {
                    NativeCimbarDecodeOutput *output = [decoder processPixelBuffer:buffer];
                    if (output.detectedMode != 0 || output.fileURL != nil || output.progressFraction != nil) {
                        ok = false;
                    }
                }
            }
        }
    });
    worker.join();
    for (CVPixelBufferRef buffer : buffers) CVPixelBufferRelease(buffer);
    printf("%s  no code      300 frames of noise, no lock and no file\n", ok ? "PASS" : "FAIL");
    return ok;
}

// 截图素材：把一帧 B 模式动画码存成 PNG（模拟器的 OpenCV 切片没有 imgcodecs，用 ImageIO 写）
bool writePNG(const cv::Mat &rgbFrame, const char *path) {
    cv::Mat rgba;
    cv::cvtColor(rgbFrame, rgba, cv::COLOR_RGB2RGBA);
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

bool dumpFrame(const char *path) {
    std::vector<cv::Mat> frames = encodeFrames(68, "demo.bin", makePayload(64 * 1024), 4);
    return frames.size() >= 4 && writePNG(frames[3], path);
}

// 把一个真实文件编成一整段动画码帧（000.png、001.png…），给 App 的 Debug「模拟相机」回放
bool dumpTransfer(const char *dir, int mode, const char *inputPath, int encodeId) {
    NSData *data = [NSData dataWithContentsOfFile:@(inputPath)];
    if (data.length == 0) {
        return false;
    }
    const std::string payload(static_cast<const char *>(data.bytes), data.length);
    const std::string name = [@(inputPath) lastPathComponent].UTF8String;
    // 一帧大约 6 KB，多给一半冗余，回放时循环播放。小文件至少 30 帧：循环播放的是同几帧，
    // 其中一两帧在画布上没解出来就永远凑不齐（真实发送端会一直出新帧，没有这个问题）
    const int count = std::max(30, static_cast<int>(payload.size() / 6000 * 3 / 2) + 6);
    std::vector<cv::Mat> frames = encodeFrames(mode, name, payload, count, static_cast<uint8_t>(encodeId));
    [[NSFileManager defaultManager] createDirectoryAtPath:@(dir) withIntermediateDirectories:YES attributes:nil error:nil];
    for (size_t i = 0; i < frames.size(); ++i) {
        char path[1024];
        snprintf(path, sizeof(path), "%s/%03zu.png", dir, i);
        if (!writePNG(frames[i], path)) {
            return false;
        }
    }
    printf("wrote %zu frames of %s (%zu bytes, mode %d) to %s\n", frames.size(), name.c_str(), payload.size(), mode, dir);
    return true;
}

} // namespace

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc >= 5 && strcmp(argv[1], "--dump-transfer") == 0) {
            // --dump-transfer <输出目录> <mode_val> <文件> [encode_id]
            return dumpTransfer(argv[2], atoi(argv[3]), argv[4], argc >= 6 ? atoi(argv[5]) : 101) ? 0 : 1;
        }
        if (argc >= 3 && strcmp(argv[1], "--tiny") == 0) {
            // --tiny <mode_val> [字节数] [接收模式]：只跑一个小文件，在全新进程里测，不受前面测试留下的全局状态影响。
            // 环境变量 TINY_TRACE=1（经 SIMCTL_CHILD_ 前缀传入）逐帧打印解码输出
            const int mode = atoi(argv[2]);
            const std::string payload = argc >= 4 ? makePayload(atoi(argv[3])) : std::string("https://www.apple.com/iphone/\n");
            const int receiver = argc >= 5 ? atoi(argv[4]) : 0;
            if (getenv("TINY_TRACE")) {
                std::vector<CVPixelBufferRef> frames = cameraFrames(encodeFrames(mode, "link.txt", payload, 12));
                std::thread worker([&] {
                    NativeCimbarDecoder *decoder = [NativeCimbarDecoder new];
                    decoder.decodeMode = receiver;
                    [decoder reset];
                    for (size_t i = 0; i < frames.size(); ++i) {
                        NativeCimbarDecodeOutput *o = [decoder processPixelBuffer:frames[i]];
                        printf("frame %zu idle=%d progress=%s count=%lu file=%s status=%s\n", i, o.isIdle,
                               o.progressFraction ? o.progressFraction.stringValue.UTF8String : "-",
                               (unsigned long)o.detectedFrameCount, o.fileURL.lastPathComponent.UTF8String ?: "-",
                               o.statusText.UTF8String ?: "-");
                    }
                });
                worker.join();
                return 0;
            }
            Result r = runDecode(mode, receiver, payload, @"link.txt");
            printf("tiny link rx%d<-%d received=%d detected=%d frames=%d\n", receiver, mode, r.received, r.detectedMode, r.framesFed);
            return r.received ? 0 : 1;
        }
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
            bool degrade;
        };
        const Case cases[] = {
            {"auto  <- B ", 68, 0, true, 68, false},
            {"auto  <- Bm", 67, 0, true, 67, false},
            {"auto  <- Bu", 66, 0, true, 66, false},
            {"auto  <- 4C", 4, 0, true, 4, false},
            {"B     <- B ", 68, 68, true, 0, false},
            {"Bm    <- Bm", 67, 67, true, 0, false},
            // 旧版 8C：自动识别只轮换 B/Bm/Bu/4C，手动选 8C 时要能收
            {"8C    <- 8C", 8, 8, true, 0, false},
            {"B     <- Bu", 66, 68, false, 0, false},
            // 拍摄质量变差（倾斜、模糊、偏暗、噪点）：自动模式要和对应的手动模式一样能收完
            {"~auto <- B ", 68, 0, true, 68, true},
            {"~B    <- B ", 68, 68, true, 0, true},
            {"~auto <- Bm", 67, 0, true, 67, true},
            {"~Bm   <- Bm", 67, 67, true, 0, true},
            {"~auto <- Bu", 66, 0, true, 66, true},
            {"~Bu   <- Bu", 66, 66, true, 0, true},
            {"~auto <- 4C", 4, 0, true, 4, true},
            {"~4C   <- 4C", 4, 4, true, 0, true},
        };

        int failures = 0;
        for (const Case &c : cases) {
            gDegrade = c.degrade;
            Result r = runDecode(c.sender, c.receiver, payload, @"selftest.bin");
            const bool ok = r.received == c.expectReceived
                && (!c.expectReceived || r.contentMatches)
                && r.detectedMode == c.expectDetected;
            if (!ok) {
                ++failures;
            }
            printf("%s  %-12s received=%d match=%d detected=%d frames=%d  %.1f ms/frame\n",
                   ok ? "PASS" : "FAIL", c.name, r.received, r.contentMatches, r.detectedMode, r.framesFed, r.msPerFrame);
        }
        {
            // 大文件：重组 + 分块解压 + 落盘整条链路
            const std::string big = makePayload(1024 * 1024);
            Result r = runDecode(68, 0, big, @"big.bin");
            const bool ok = r.received && r.contentMatches;
            if (!ok) {
                ++failures;
            }
            printf("%s  1 MB auto<-B received=%d match=%d frames=%d  %.1f ms/frame\n",
                   ok ? "PASS" : "FAIL", r.received, r.contentMatches, r.framesFed, r.msPerFrame);
        }
        {
            // 很容易压缩的小文本：压缩后远不到一帧，画面大部分是填充
            std::string text = "Wi-Fi 与打印机设置\n访客网络：Lumen-Guest\n密码：sunset-2027\n";
            for (int i = 1; i <= 30; ++i) {
                text += "第 " + std::to_string(i) + " 条：备注内容，用来看文字很多时取景框里怎么显示。\n";
            }
            for (int mode : {68, 67, 66, 4}) {
                // 只有一个网址的极小文件：只记录、不算失败。结果受同一进程里前面测试的影响（这里多半能收到）。
                // 全新的解码器收不到：编码端把不足一个喷泉块的文件用全 0 填满，画面绝大部分是同一种格子。
                // 填充改成伪随机字节后四种模式 1–4 帧就收完（10-27 实测，见改版记录）——要改的是发送端，
                // 接收端修不了。单独测用 --tiny <mode_val> [字节数]，每次一个新进程
                Result r = runDecode(mode, 0, "https://www.apple.com/iphone/\n", @"link.txt");
                printf("INFO  tiny link auto<-%d received=%d detected=%d frames=%d\n",
                       mode, r.received, r.detectedMode, r.framesFed);
            }
            for (int mode : {68, 67, 66, 4}) {
                Result r = runDecode(mode, 0, text, @"note.txt");
                const bool ok = r.received && r.contentMatches && r.detectedMode == mode;
                if (!ok) {
                    ++failures;
                }
                printf("%s  small text auto<-%d received=%d match=%d detected=%d frames=%d\n",
                       ok ? "PASS" : "FAIL", mode, r.received, r.contentMatches, r.detectedMode, r.framesFed);
            }
        }
        gDegrade = false;
        if (!runRepeatTest()) {
            ++failures;
        }
        if (!runFilenameTest()) {
            ++failures;
        }
        if (!runModeSwitchTest()) {
            ++failures;
        }
        if (!runLostAndBackTest()) {
            ++failures;
        }
        gDegrade = true;
        if (!runNoCodeTest()) {
            ++failures;
        }
        printf("%s (%d failure%s)\n", failures == 0 ? "ALL PASSED" : "FAILED", failures, failures == 1 ? "" : "s");
        return failures == 0 ? 0 : 1;
    }
}
