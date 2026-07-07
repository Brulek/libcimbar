import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import os
import UIKit

final class NativeReceiverViewModel: NSObject, ObservableObject {
    @Published private(set) var statusText: String = "准备中..."
    @Published private(set) var progressValue: Double?
    @Published private(set) var progressLabel: String?
    @Published private(set) var statsText: String?
    @Published private(set) var receivedFileURL: URL?
    @Published private(set) var cameraPermissionDenied = false
    @Published private(set) var torchAvailable = false
    @Published private(set) var torchActive = false
    @Published private(set) var zoomFactor: CGFloat = 1.0

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "org.cimbar.receiver.session")
    private let frameQueue = DispatchQueue(label: "org.cimbar.receiver.frames")
    private var decoder: NativeCimbarDecoder?

    private var isConfigured = false
    private var hasDetectedFirstFrame = false
    private var isPaused = false
    // 被主线程（apply/resetScan）与 frameQueue（captureOutput）同时访问，必须加锁
    private let revisionState = OSAllocatedUnfairLock<UInt>(initialState: 0)
    private let impactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let notificationGenerator = UINotificationFeedbackGenerator()

    // 仅在 sessionQueue 上读写
    private var videoDevice: AVCaptureDevice?
    private var maxZoomFactor: CGFloat = 1.0
    // 仅在主线程读写：捏合手势开始时的基准倍率
    private var zoomGestureBase: CGFloat = 1.0
    // 仅在主线程读写：进度采样（时间, 进度分数），用于估算速率与剩余时间
    private var progressSamples: [(time: TimeInterval, fraction: Double)] = []

    func start() {
        impactGenerator.prepare()
        notificationGenerator.prepare()
        updateStatus("启动相机中...")
        publishCameraPermissionDenied(false)

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStartSession()
        case .notDetermined:
            updateStatus("请求相机权限...")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureAndStartSession()
                } else {
                    self.handlePermissionDenied()
                }
            }
        case .denied, .restricted:
            handlePermissionDenied()
        @unknown default:
            updateStatus("相机权限状态未知")
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let device = self.videoDevice, device.hasTorch, device.torchMode != .off,
               (try? device.lockForConfiguration()) != nil {
                device.torchMode = .off
                device.unlockForConfiguration()
            }
            DispatchQueue.main.async { self.torchActive = false }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            // 在 sessionQueue 上与 start() 串行化地恢复 idleTimer：
            // 若在主线程立即置 false，紧随其后的 start() 残留 true 会反过来覆盖它
            self.setIdleTimerDisabled(false)
        }
    }

    func pauseProcessing() {
        frameQueue.async {
            self.isPaused = true
        }
    }

    func resumeProcessing() {
        frameQueue.async {
            self.isPaused = false
        }
    }

    func resetScan() {
        // revision 递增必须与 decoder.reset() 在同一个 frameQueue 块里完成：
        // 若先在主线程递增，窗口期的帧会带着新 revision 用旧解码器状态穿过
        // apply() 的守卫。统一收进 frameQueue 后，旧帧只能拿到旧 revision；
        // 即便其 apply 先落地，随后入队的 publishResetState 也会覆盖它，终态正确。
        frameQueue.async {
            self.revisionState.withLock { $0 &+= 1 }
            self.hasDetectedFirstFrame = false
            self.isPaused = false
            self.decoder?.reset()
            self.publishResetState()
        }
    }

    // MARK: - 相机控制（手电筒 / 变焦 / 对焦）

    func toggleTorch() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                let turnOn = device.torchMode != .on
                device.torchMode = turnOn && device.isTorchAvailable ? .on : .off
                let isOn = device.torchMode == .on
                DispatchQueue.main.async { self.torchActive = isOn }
            } catch {
                // 锁定失败则保持现状，下次点击重试
            }
        }
    }

    func beginZoomGesture() {
        zoomGestureBase = zoomFactor
    }

    func updateZoomGesture(scale: CGFloat) {
        setZoomFactor(zoomGestureBase * scale)
    }

    func resetZoom() {
        setZoomFactor(1.0)
    }

    private func setZoomFactor(_ raw: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            let clamped = min(max(raw, 1.0), self.maxZoomFactor)
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.zoomFactor = clamped }
            } catch {
                // 锁定失败时跳过本次缩放更新
            }
        }
    }

    /// devicePoint 为 AVCaptureVideoPreviewLayer 转换后的设备坐标（0~1）
    func focus(atDevicePoint devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                    // 保持连续对焦模式，只移动关注点：扫动画码时画面持续变化，
                    // 一次性 autoFocus 会在对上后锁死
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    } else if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
            } catch {
                // 对焦失败无需提示，用户可再次点按
            }
        }
    }

    private var currentRevision: UInt {
        revisionState.withLock { $0 }
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = disabled
        }
    }

    private func configureAndStartSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.isConfigured {
                do {
                    try self.configureSession()
                    self.isConfigured = true
                } catch {
                    self.updateStatus("相机初始化失败: \(error.localizedDescription)")
                    return
                }
            }

            if !self.session.isRunning {
                self.session.startRunning()
            }
            // 接收过程用户全程无触摸，扫码期间禁用自动锁屏，避免长传输被打断
            self.setIdleTimerDisabled(true)
            self.updateStatus("相机已启动，正在初始化解码器...")
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        defer {
            session.commitConfiguration()
        }

        guard
            let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        else {
            throw ReceiverError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            throw ReceiverError.cannotAddInput
        }
        session.addInput(input)

        try camera.lockForConfiguration()
        if camera.isFocusModeSupported(.continuousAutoFocus) {
            camera.focusMode = .continuousAutoFocus
        }
        if camera.isExposureModeSupported(.continuousAutoExposure) {
            camera.exposureMode = .continuousAutoExposure
        }
        camera.unlockForConfiguration()

        videoDevice = camera
        // 超过 5x 后画质衰减明显、抖动被放大，对屏幕扫码没有增益
        maxZoomFactor = min(camera.activeFormat.videoMaxZoomFactor, 5.0)
        let hasTorch = camera.hasTorch
        DispatchQueue.main.async { [weak self] in
            self?.torchAvailable = hasTorch
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)

        guard session.canAddOutput(output) else {
            throw ReceiverError.cannotAddOutput
        }
        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = false
            }
        }
    }

    private func apply(_ result: NativeCimbarDecodeOutput) {
        guard result.revision == currentRevision else {
            return
        }

        if let text = result.statusText, !text.isEmpty {
            statusText = text
        }

        let preferences = AppPreferences.shared

        if let fraction = result.progressFraction {
            if result.didDetectFirstFrame, preferences.hapticEnabled {
                impactGenerator.impactOccurred()
            }
            progressValue = fraction.doubleValue
            progressLabel = result.progressLabel
            updateStats(fraction: fraction.doubleValue, frameCount: result.detectedFrameCount)
        } else if let label = result.progressLabel {
            progressValue = nil
            progressLabel = label
        }

        if let fileURL = result.fileURL {
            receivedFileURL = fileURL
            progressValue = result.progressFraction?.doubleValue ?? 1.0
            progressLabel = result.progressLabel ?? "文件接收 100%"
            statsText = nil
            progressSamples.removeAll()
            if preferences.hapticEnabled {
                notificationGenerator.notificationOccurred(.success)
            }
            if preferences.soundEnabled {
                AudioServicesPlaySystemSound(1001)
            }
            UIAccessibility.post(notification: .announcement, argument: statusText)
        }
    }

    // 主线程调用。用最近一段时间的进度斜率估算剩余时间，避免瞬时抖动
    private func updateStats(fraction: Double, frameCount: UInt) {
        let now = ProcessInfo.processInfo.systemUptime
        progressSamples.append((time: now, fraction: fraction))
        progressSamples.removeAll { now - $0.time > 12 }

        var parts: [String] = []
        if frameCount > 0 {
            parts.append("已识别 \(frameCount) 帧")
        }
        if let first = progressSamples.first,
           now - first.time >= 1.5,
           fraction > first.fraction {
            let rate = (fraction - first.fraction) / (now - first.time)
            if rate > 0.0005 {
                parts.append("预计还需\(Self.formatRemainingTime((1.0 - fraction) / rate))")
            }
        }
        statsText = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func formatRemainingTime(_ seconds: Double) -> String {
        let clamped = max(1, Int(seconds.rounded(.up)))
        if clamped < 90 {
            return " \(clamped) 秒"
        }
        let minutes = Int((Double(clamped) / 60.0).rounded())
        return " \(minutes) 分钟"
    }

    private func updateStatus(_ text: String) {
        DispatchQueue.main.async {
            self.statusText = text
        }
    }

    private func updateStatusIfCurrent(_ text: String, revision: UInt) {
        DispatchQueue.main.async {
            guard self.currentRevision == revision else { return }
            self.statusText = text
        }
    }

    private func publishResetState() {
        DispatchQueue.main.async {
            self.receivedFileURL = nil
            self.progressValue = nil
            self.progressLabel = nil
            self.statsText = nil
            self.progressSamples.removeAll()
            self.statusText = "相机已启动，请将发送端动画码放入取景框"
        }
    }

    private func publishCameraPermissionDenied(_ isDenied: Bool) {
        DispatchQueue.main.async {
            self.cameraPermissionDenied = isDenied
        }
    }

    private func handlePermissionDenied() {
        setIdleTimerDisabled(false)
        updateStatus("未授予相机权限，请到系统设置中开启")
        publishCameraPermissionDenied(true)
    }
}

extension NativeReceiverViewModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !isPaused, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        // 在处理前取 revision 快照：若处理期间发生 resetScan，
        // 快照与最新值不一致，结果会在 apply() 被丢弃
        let revision = currentRevision

        if decoder == nil {
            decoder = NativeCimbarDecoder()
            updateStatusIfCurrent("相机已启动，请将发送端动画码放入取景框", revision: revision)
            return
        }

        guard let decoder else {
            return
        }

        // 30fps 持续负载下及时排空每帧产生的临时对象，压低内存峰值
        autoreleasepool {
            if let result = decoder.processPixelBuffer(pixelBuffer) {
                result.revision = revision
                if result.progressFraction != nil && !hasDetectedFirstFrame {
                    hasDetectedFirstFrame = true
                    result.didDetectFirstFrame = true
                }
                DispatchQueue.main.async {
                    self.apply(result)
                }
            }
        }
    }
}

private enum ReceiverError: LocalizedError {
    case cameraUnavailable
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "未找到可用后置相机"
        case .cannotAddInput:
            return "无法添加相机输入"
        case .cannotAddOutput:
            return "无法添加视频输出"
        }
    }
}
