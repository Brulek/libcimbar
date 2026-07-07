import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import os
import UIKit

final class NativeReceiverViewModel: NSObject, ObservableObject {
    @Published private(set) var statusText: String = String(localized: "准备中...")
    @Published private(set) var progressValue: Double?
    @Published private(set) var progressLabel: String?
    @Published private(set) var statsText: String?
    @Published private(set) var stallHint: String?
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
    // 仅在 frameQueue 上读写：上次向主线程发布常规进度的时间
    private var lastRoutinePublishUptime: TimeInterval = 0
    // 被主线程（apply/resetScan）与 frameQueue（captureOutput）同时访问，必须加锁
    private let revisionState = OSAllocatedUnfairLock<UInt>(initialState: 0)
    // 偏好的原子副本：主线程写入（onChange），sessionQueue/frameQueue 读取
    private let decodeModeState = OSAllocatedUnfairLock<Int32>(
        initialState: Int32(AppPreferences.shared.decodeMode)
    )
    private let highResCaptureState = OSAllocatedUnfairLock<Bool>(
        initialState: AppPreferences.shared.highResolutionCapture
    )
    private let impactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let notificationGenerator = UINotificationFeedbackGenerator()

    // 仅在 sessionQueue 上读写
    private var videoDevice: AVCaptureDevice?
    private var maxZoomFactor: CGFloat = 1.0
    // 仅在主线程读写：捏合手势开始时的基准倍率
    private var zoomGestureBase: CGFloat = 1.0
    // 仅在主线程读写：进度采样（时间, 进度分数），用于估算速率与剩余时间
    private var progressSamples: [(time: TimeInterval, fraction: Double)] = []
    // 仅在主线程读写：停滞检测
    private var lastAdvanceUptime: TimeInterval = 0
    private var lastAdvanceFraction: Double = -1
    private var stallTimer: Timer?

    func start() {
        impactGenerator.prepare()
        notificationGenerator.prepare()
        updateStatusIfIdle(String(localized: "启动相机中..."))
        publishCameraPermissionDenied(false)
        startStallTimerIfNeeded()

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStartSession()
        case .notDetermined:
            updateStatus(String(localized: "请求相机权限..."))
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
            updateStatus(String(localized: "相机权限状态未知"))
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.stallTimer?.invalidate()
            self?.stallTimer = nil
        }
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
            if let decoder = self.decoder {
                decoder.decodeMode = self.decodeModeState.withLock { $0 }
                decoder.reset()
            }
            self.publishResetState()
        }
    }

    /// 主线程调用（偏好变更）。切换模式会清空当前解码进度重新扫描
    func setDecodeMode(_ mode: Int) {
        decodeModeState.withLock { $0 = Int32(mode) }
        resetScan()
    }

    /// 主线程调用（偏好变更）。若会话已配置则立即切换采集分辨率
    func setHighResolutionCapture(_ enabled: Bool) {
        highResCaptureState.withLock { $0 = enabled }
        sessionQueue.async { [weak self] in
            self?.applyPreferredSessionPreset()
        }
    }

    /// 仅在 sessionQueue 上调用
    private func applyPreferredSessionPreset() {
        guard isConfigured else { return }
        let preset: AVCaptureSession.Preset = highResCaptureState.withLock { $0 } ? .hd1920x1080 : .hd1280x720
        guard session.sessionPreset != preset, session.canSetSessionPreset(preset) else { return }
        session.beginConfiguration()
        session.sessionPreset = preset
        session.commitConfiguration()
        // preset 切换可能更换 activeFormat 并把设备端 zoom 重置为 1；
        // 重新读取真实值，避免变焦徽标与画面脱钩、下次捏合基准跳变
        if let device = videoDevice {
            maxZoomFactor = min(device.activeFormat.videoMaxZoomFactor, 5.0)
            let actualZoom = device.videoZoomFactor
            DispatchQueue.main.async { self.zoomFactor = actualZoom }
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
                    self.updateStatus(String(localized: "相机初始化失败: \(error.localizedDescription)"))
                    return
                }
            }

            if !self.session.isRunning {
                self.session.startRunning()
            }
            // 接收过程用户全程无触摸，扫码期间禁用自动锁屏，避免长传输被打断
            self.setIdleTimerDisabled(true)
            self.updateStatusIfIdle(String(localized: "相机已启动，正在初始化解码器..."))
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        session.sessionPreset = highResCaptureState.withLock { $0 } ? .hd1920x1080 : .hd1280x720

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
            // 信号丢失（idle 输出）：清掉冻结的帧数/ETA，避免展示过期数据；
            // 采样也清空，信号恢复后重新估算速率而不是跨断档平均
            statsText = nil
            progressSamples.removeAll()
        }

        if let fileURL = result.fileURL {
            receivedFileURL = fileURL
            progressValue = result.progressFraction?.doubleValue ?? 1.0
            progressLabel = result.progressLabel ?? String(localized: "文件接收 100%")
            statsText = nil
            stallHint = nil
            progressSamples.removeAll()
            lastAdvanceFraction = -1
            // 文件已落盘，后续帧不会再产生新结果；停掉解码链，
            // 避免相机回调继续满载 CPU（用户点「继续扫码」时恢复）
            pauseProcessing()
            if preferences.hapticEnabled {
                notificationGenerator.notificationOccurred(.success)
            }
            if preferences.soundEnabled {
                AudioServicesPlaySystemSound(1001)
            }
            UIAccessibility.post(notification: .announcement, argument: statusText)
        }
    }

    // MARK: - 停滞检测

    // 主线程调用。传输开始后若进度长时间不再前进，给出分级操作建议
    private func startStallTimerIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 切走再回来时给计时一个新起点：stop() 期间 systemUptime 仍在走，
            // 不重置会在回来 1 秒内弹出最严重的假阳性警告
            if self.lastAdvanceFraction >= 0 {
                self.lastAdvanceUptime = ProcessInfo.processInfo.systemUptime
                self.stallHint = nil
            }
            guard self.stallTimer == nil else { return }
            self.stallTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.evaluateStall()
            }
        }
    }

    private func evaluateStall() {
        // 只在「传输已开始且未完成」的窗口内提示。
        // 不能依赖 progressValue：码完全离开取景框后 idle 输出会把它置 nil，
        // 而那正是最需要提示的场景；lastAdvanceFraction 只在完成/重置时清掉
        guard receivedFileURL == nil, lastAdvanceFraction >= 0 else {
            if stallHint != nil { stallHint = nil }
            return
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - lastAdvanceUptime
        let newHint: String?
        if elapsed > 12 {
            newHint = String(localized: "仍无新数据：试试靠近一点、调整角度避免反光，或调高发送端屏幕亮度")
        } else if elapsed > 5 {
            newHint = String(localized: "进度停滞了？请确保动画码完整、无遮挡地处于取景框内")
        } else {
            newHint = nil
        }
        if newHint != stallHint {
            stallHint = newHint
        }
    }

    // 主线程调用。用最近一段时间的进度斜率估算剩余时间，避免瞬时抖动
    private func updateStats(fraction: Double, frameCount: UInt) {
        let now = ProcessInfo.processInfo.systemUptime
        progressSamples.append((time: now, fraction: fraction))
        progressSamples.removeAll { now - $0.time > 12 }

        if lastAdvanceFraction < 0 || fraction > lastAdvanceFraction + 0.0001 {
            lastAdvanceFraction = fraction
            lastAdvanceUptime = now
            if stallHint != nil { stallHint = nil }
        }

        var parts: [String] = []
        if frameCount > 0 {
            parts.append(String(localized: "已识别 \(Int(frameCount)) 帧"))
        }
        if let first = progressSamples.first,
           now - first.time >= 1.5,
           fraction > first.fraction {
            let rate = (fraction - first.fraction) / (now - first.time)
            if rate > 0.0005 {
                parts.append(String(localized: "预计还需 \(Self.formatRemainingTime((1.0 - fraction) / rate))"))
            }
        }
        statsText = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func formatRemainingTime(_ seconds: Double) -> String {
        let clamped = max(1, Int(seconds.rounded(.up)))
        if clamped < 90 {
            return String(localized: "\(clamped) 秒")
        }
        let minutes = Int((Double(clamped) / 60.0).rounded())
        return String(localized: "\(minutes) 分钟")
    }

    private func updateStatus(_ text: String) {
        DispatchQueue.main.async {
            self.statusText = text
        }
    }

    // 传输进行中/完成后回前台重启相机时，启动类文案不应覆盖实时进度
    private func updateStatusIfIdle(_ text: String) {
        DispatchQueue.main.async {
            guard self.progressLabel == nil, self.receivedFileURL == nil else { return }
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
            self.stallHint = nil
            self.progressSamples.removeAll()
            self.lastAdvanceFraction = -1
            self.statusText = String(localized: "相机已启动，请将发送端动画码放入取景框")
        }
    }

    private func publishCameraPermissionDenied(_ isDenied: Bool) {
        DispatchQueue.main.async {
            self.cameraPermissionDenied = isDenied
        }
    }

    private func handlePermissionDenied() {
        setIdleTimerDisabled(false)
        updateStatus(String(localized: "未授予相机权限，请到系统设置中开启"))
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
            let created = NativeCimbarDecoder()
            let mode = decodeModeState.withLock { $0 }
            if created.decodeMode != mode {
                created.decodeMode = mode
                created.reset()
            }
            decoder = created
            updateStatusIfCurrent(String(localized: "相机已启动，请将发送端动画码放入取景框"), revision: revision)
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
                // 常规进度更新限流到 10Hz：30Hz 的 @Published 写入会让整个
                // 底部面板持续重算。关键事件（文件完成、首帧检测）始终放行
                let isCritical = result.fileURL != nil || result.didDetectFirstFrame
                let now = ProcessInfo.processInfo.systemUptime
                if !isCritical && now - lastRoutinePublishUptime < 0.1 {
                    return
                }
                lastRoutinePublishUptime = now
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
            return String(localized: "未找到可用后置相机")
        case .cannotAddInput:
            return String(localized: "无法添加相机输入")
        case .cannotAddOutput:
            return String(localized: "无法添加视频输出")
        }
    }
}
