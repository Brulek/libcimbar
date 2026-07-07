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
    @Published private(set) var receivedFileURL: URL?
    @Published private(set) var cameraPermissionDenied = false

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
        } else if let label = result.progressLabel {
            progressValue = nil
            progressLabel = label
        }

        if let fileURL = result.fileURL {
            receivedFileURL = fileURL
            progressValue = result.progressFraction?.doubleValue ?? 1.0
            progressLabel = result.progressLabel ?? "文件接收 100%"
            if preferences.hapticEnabled {
                notificationGenerator.notificationOccurred(.success)
            }
            if preferences.soundEnabled {
                AudioServicesPlaySystemSound(1001)
            }
            UIAccessibility.post(notification: .announcement, argument: statusText)
        }
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
