#if DEBUG
import CoreVideo
import UIKit

/// Debug「模拟相机」：默认按 15 fps 依次读取预先导出的动画码帧（scripts/run_decode_selftest.sh
/// --dump-transfer），套进 720×1280 的灰底画布，交给与相机完全相同的处理链。
/// 多个目录依次播放，每个目录循环两遍，用来在模拟器里走完接收、重复、换文件等流程
final class FrameReplayer {
    private let directories: [URL]
    private var frames: [[URL]] = []
    private var directoryIndex = 0
    private var frameIndex = 0
    private var loops = 0
    private var buffer: CVPixelBuffer?
    private var timer: DispatchSourceTimer?

    init(directories: [URL]) {
        self.directories = directories
        frames = directories.map { dir in
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "png" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    func start(on queue: DispatchQueue, deliver: @escaping (CVPixelBuffer, UIImage) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / DemoContent.replayFramesPerSecond)
        timer.setEventHandler { [weak self] in
            guard let self, let (pixelBuffer, image) = self.nextFrame() else { return }
            deliver(pixelBuffer, image)
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func nextFrame() -> (CVPixelBuffer, UIImage)? {
        guard directoryIndex < frames.count, !frames[directoryIndex].isEmpty else { return nil }
        let list = frames[directoryIndex]
        let url = list[frameIndex]
        frameIndex += 1
        if frameIndex >= list.count {
            frameIndex = 0
            loops += 1
            if loops >= 2, directoryIndex + 1 < frames.count {
                directoryIndex += 1
                loops = 0
            }
        }
        guard let image = UIImage(contentsOfFile: url.path), let cgImage = image.cgImage else { return nil }
        return render(cgImage).map { ($0, image) }
    }

    private func render(_ image: CGImage) -> CVPixelBuffer? {
        let width = 720, height = 1280
        if buffer == nil {
            let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &buffer)
        }
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.setFillColor(gray: 0.24, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let side = 660.0
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: (Double(width) - side) / 2, y: (Double(height) - side) / 2, width: side, height: side))
        return buffer
    }
}
#endif
