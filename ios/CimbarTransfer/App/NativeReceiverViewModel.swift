import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import os
import UIKit

final class NativeReceiverViewModel: NSObject, ObservableObject {
    /// 给 VoiceOver 播报用的当前状态；界面上只展示错误类文案
    @Published private(set) var statusText: String = String(localized: "正在启动相机")
    /// 传输进度（0~1）；nil 表示还没开始接收。码离开取景框时保留最后的值
    @Published private(set) var progressValue: Double?
    /// 最近的帧里是否识别到了码
    @Published private(set) var isTracking = false
    @Published private(set) var detectedFrameCount = 0
    @Published private(set) var remainingSeconds: Int?
    @Published private(set) var stallHint: String?
    @Published private(set) var receivedFileURL: URL?
    /// 从识别到首帧到文件落盘的用时
    @Published private(set) var transferDuration: TimeInterval?
    /// 又收到一遍刚才那个文件（发送端还在放同一个），复用了已保存的那份
    @Published private(set) var receivedDuplicate = false
    @Published private(set) var scanErrorLatched = false
    /// 相机无法启动的原因（模拟器、被其他 App 占用等）
    @Published private(set) var cameraErrorText: String?
    /// 自动模式下识别出的发送端模式（mode_val），0 表示尚未识别
    @Published private(set) var detectedMode = 0
    @Published private(set) var cameraPermissionDenied = false
    /// 长时间没有东西可扫，已自动停掉相机省电；扫码期间禁用的自动锁屏也随之恢复
    @Published private(set) var isIdlePaused = false
    @Published private(set) var torchAvailable = false
    @Published private(set) var torchActive = false
    @Published private(set) var zoomFactor: CGFloat = 1.0
    /// 相机支持至少 2 倍变焦时，界面上常驻 1×/2× 切换按钮
    @Published private(set) var canQuickZoom = false

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
    /// 界面当前要不要相机在跑（扫码页可见且没自动暂停）；媒体服务重置后据此决定是否重启
    private var wantsSessionRunning = false
    private var maxZoomFactor: CGFloat = 1.0
    // 仅在主线程读写：捏合手势开始时的基准倍率
    private var zoomGestureBase: CGFloat = 1.0
    // 仅在主线程读写：进度采样（时间, 进度分数），用于估算速率与剩余时间
    private var progressSamples: [(time: TimeInterval, fraction: Double)] = []
    // 仅在主线程读写：停滞检测
    private var lastAdvanceUptime: TimeInterval = 0
    private var lastAdvanceFraction: Double = -1
    private var stallTimer: Timer?
    // 仅在主线程读写：首次识别到码帧的时间，用于计算传输用时
    private var transferStartUptime: TimeInterval?
    // 仅在主线程读写：VoiceOver 已播报到的进度档（每 25% 一档）
    private var announcedProgressStep = 0
    // 仅在主线程读写：最近一次「有事发生」（启动、识别到码、收到文件）的时间，用于空闲自动暂停
    private var lastActivityUptime: TimeInterval = 0

    /// 没识别到任何码 / 传输中途码不见了 / 已收完没再操作，各自多久后自动暂停
    private static let idleTimeoutWaiting: TimeInterval = 90
    private static let idleTimeoutInterrupted: TimeInterval = 300
    private static let idleTimeoutCompleted: TimeInterval = 45

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sessionWasInterrupted(_:)),
                           name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)),
                           name: AVCaptureSession.interruptionEndedNotification, object: session)
        center.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                           name: AVCaptureSession.runtimeErrorNotification, object: session)
    }

    // MARK: - 相机被占用 / 过热 / 媒体服务重置

    // 其他 App 抢走相机或设备过热时，画面会定住、什么提示都没有；把原因写到面板上
    @objc private func sessionWasInterrupted(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reason = AVCaptureSession.InterruptionReason(rawValue: raw) else { return }
        let message: String
        switch reason {
        case .videoDeviceNotAvailableInBackground:
            return // 退到后台本来就会停，回前台自动恢复，不用提示
        case .videoDeviceInUseByAnotherClient:
            message = String(localized: "相机正被其他 App 使用")
        case .videoDeviceNotAvailableDueToSystemPressure:
            message = String(localized: "设备温度过高，相机已暂停")
        default:
            message = String(localized: "相机暂时不可用")
        }
        DispatchQueue.main.async { self.cameraErrorText = message }
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        DispatchQueue.main.async { self.cameraErrorText = nil }
    }

    // 媒体服务重置后会话不会自己恢复，需要重新 startRunning
    @objc private func sessionRuntimeError(_ notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError,
              error.code == .mediaServicesWereReset else { return }
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, self.wantsSessionRunning, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func start() {
        #if DEBUG
        if let demo = DemoContent.scanState {
            applyDemoState(demo)
            return
        }
        #endif
        impactGenerator.prepare()
        notificationGenerator.prepare()
        DispatchQueue.main.async {
            self.isIdlePaused = false
            self.lastActivityUptime = ProcessInfo.processInfo.systemUptime
        }
        updateStatusIfIdle(String(localized: "正在启动相机"))
        publishCameraPermissionDenied(false)
        startStallTimerIfNeeded()

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStartSession()
        case .notDetermined:
            updateStatus(String(localized: "等待相机权限"))
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
            self.wantsSessionRunning = false
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

    /// 主线程调用（偏好变更）。切换模式会清空进行中的解码重新扫描；
    /// 已完成的接收卡片保留（新模式会在用户点「继续扫码」时随 resetScan 生效）
    func setDecodeMode(_ mode: Int) {
        decodeModeState.withLock { $0 = Int32(mode) }
        // 正在顺利接收（已有进度）说明当前模式是对的，不为切模式丢掉进度：新模式下次扫码生效。
        // 还没收到任何数据时才立即重置，换个模式重新找码
        if receivedFileURL == nil && progressValue == nil {
            resetScan()
        }
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
            let quickZoom = maxZoomFactor >= Self.quickZoomFactor
            DispatchQueue.main.async {
                self.zoomFactor = actualZoom
                self.canQuickZoom = quickZoom
            }
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

    static let quickZoomFactor: CGFloat = 2.0

    /// 1× ↔ 2× 快速切换；已经捏合放大过的，点一下回到 1×
    func toggleQuickZoom() {
        setZoomFactor(zoomFactor > 1.01 ? 1.0 : Self.quickZoomFactor)
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
                    let message = String(localized: "无法启动相机：\(error.localizedDescription)")
                    self.updateStatus(message)
                    DispatchQueue.main.async { self.cameraErrorText = message }
                    return
                }
            }

            self.wantsSessionRunning = true
            if !self.session.isRunning {
                self.session.startRunning()
            }
            DispatchQueue.main.async {
                if self.cameraErrorText != nil { self.cameraErrorText = nil }
            }
            // 接收过程用户全程无触摸，扫码期间禁用自动锁屏，避免长传输被打断
            self.setIdleTimerDisabled(true)
            self.updateStatusIfIdle(String(localized: "正在寻找动画码"))
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
        let quickZoom = maxZoomFactor >= Self.quickZoomFactor
        DispatchQueue.main.async { [weak self] in
            self?.torchAvailable = hasTorch
            self?.canQuickZoom = quickZoom
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

        if scanErrorLatched != result.hasStickyError {
            scanErrorLatched = result.hasStickyError
        }

        let preferences = AppPreferences.shared

        if detectedMode != Int(result.detectedMode) {
            detectedMode = Int(result.detectedMode)
        }

        if result.isIdle {
            // 码离开取景框：进度还在喷泉流里，界面保留最后的百分比；
            // ETA 已不准确，清掉，采样也清空，信号恢复后重新估算速率
            if isTracking { isTracking = false }
            remainingSeconds = nil
            progressSamples.removeAll()
        } else if result.detectedFrameCount > 0 {
            lastActivityUptime = ProcessInfo.processInfo.systemUptime
            if !isTracking { isTracking = true }
            detectedFrameCount = Int(result.detectedFrameCount)
            if transferStartUptime == nil {
                transferStartUptime = ProcessInfo.processInfo.systemUptime
            }
        }

        if let fraction = result.progressFraction {
            if result.didDetectFirstFrame, preferences.hapticEnabled {
                impactGenerator.impactOccurred()
            }
            progressValue = fraction.doubleValue
            updateStats(fraction: fraction.doubleValue)
            announceProgressIfNeeded(fraction.doubleValue)
        }

        if let fileURL = result.fileURL {
            receivedDuplicate = result.isDuplicate
            receivedFileURL = fileURL
            if !result.isDuplicate {
                // 把发送端原始文件名写进元数据（磁盘名可能经过 sanitize/加序号）
                let savedName = fileURL.lastPathComponent
                let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                ReceivedFileMetadataStore.shared.registerReceived(
                    filename: savedName,
                    originalName: result.originalFilename ?? savedName,
                    fileSize: (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                )
            }
            progressValue = 1.0
            remainingSeconds = nil
            stallHint = nil
            transferDuration = transferStartUptime.map { ProcessInfo.processInfo.systemUptime - $0 }
            transferStartUptime = nil
            progressSamples.removeAll()
            lastAdvanceFraction = -1
            // 文件已落盘，后续帧不会再产生新结果；停掉解码链，
            // 避免相机回调继续满载 CPU（用户点「继续接收」时恢复）
            pauseProcessing()
            // 收完了用户可能放下手机去看文件，恢复正常的自动锁屏。
            // 走 sessionQueue，和 start()/stop() 对 idleTimer 的写入保持先后顺序
            lastActivityUptime = ProcessInfo.processInfo.systemUptime
            sessionQueue.async { [weak self] in self?.setIdleTimerDisabled(false) }
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
                self?.evaluateIdle()
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
            newHint = String(localized: "试试靠近些、避开反光，或调亮发送端屏幕")
        } else if elapsed > 5 {
            newHint = String(localized: "让动画码完整留在取景框里")
        } else {
            newHint = nil
        }
        if newHint != stallHint {
            stallHint = newHint
        }
    }

    // 主线程调用。开着扫码页走开，相机和解码会一直满载、屏幕也不会自动锁定：
    // 一段时间没动静就停掉相机，等用户点「继续扫描」
    private func evaluateIdle() {
        guard !isIdlePaused, !cameraPermissionDenied, lastActivityUptime > 0 else { return }
        let timeout: TimeInterval
        if receivedFileURL != nil {
            timeout = Self.idleTimeoutCompleted
        } else if progressValue != nil {
            timeout = Self.idleTimeoutInterrupted
        } else {
            timeout = Self.idleTimeoutWaiting
        }
        guard ProcessInfo.processInfo.systemUptime - lastActivityUptime > timeout else { return }
        isIdlePaused = true
        stop()
        UIAccessibility.post(notification: .announcement, argument: String(localized: "扫描已暂停"))
    }

    // 主线程调用。看不到屏幕的 VoiceOver 用户只能靠播报知道进度，每过 25% 报一次
    private func announceProgressIfNeeded(_ fraction: Double) {
        let step = Int(fraction * 4)
        guard step > announcedProgressStep, step < 4 else { return }
        announcedProgressStep = step
        guard UIAccessibility.isVoiceOverRunning else { return }
        let percent = (Double(step) * 0.25).formatted(.percent.precision(.fractionLength(0)))
        UIAccessibility.post(notification: .announcement, argument: String(localized: "已接收 \(percent)"))
    }

    // 主线程调用。用最近一段时间的进度斜率估算剩余时间，避免瞬时抖动
    private func updateStats(fraction: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        // 进度明显回落 = 解码器按新模式从头收（发送端中途换了模式）：所有基线重来
        if lastAdvanceFraction >= 0, fraction + 0.02 < lastAdvanceFraction {
            lastAdvanceFraction = -1
            progressSamples.removeAll()
            announcedProgressStep = 0
            transferStartUptime = now
        }
        progressSamples.append((time: now, fraction: fraction))
        progressSamples.removeAll { now - $0.time > 12 }

        if lastAdvanceFraction < 0 || fraction > lastAdvanceFraction + 0.0001 {
            lastAdvanceFraction = fraction
            lastAdvanceUptime = now
            if stallHint != nil { stallHint = nil }
        }

        var remaining: Int?
        if let first = progressSamples.first,
           now - first.time >= 1.5,
           fraction > first.fraction {
            let rate = (fraction - first.fraction) / (now - first.time)
            if rate > 0.0005 {
                remaining = max(1, Int(((1.0 - fraction) / rate).rounded(.up)))
            }
        }
        remainingSeconds = remaining
    }

    private func updateStatus(_ text: String) {
        DispatchQueue.main.async {
            self.statusText = text
        }
    }

    // 传输进行中/完成后回前台重启相机时，启动类文案不应覆盖实时进度
    private func updateStatusIfIdle(_ text: String) {
        DispatchQueue.main.async {
            guard self.progressValue == nil, self.receivedFileURL == nil else { return }
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
            self.receivedDuplicate = false
            self.transferDuration = nil
            self.transferStartUptime = nil
            self.scanErrorLatched = false
            self.progressValue = nil
            self.isTracking = false
            self.detectedFrameCount = 0
            self.detectedMode = 0
            self.remainingSeconds = nil
            self.stallHint = nil
            self.progressSamples.removeAll()
            self.lastAdvanceFraction = -1
            self.announcedProgressStep = 0
            self.statusText = String(localized: "正在寻找动画码")
        }
    }

    private func publishCameraPermissionDenied(_ isDenied: Bool) {
        DispatchQueue.main.async {
            self.cameraPermissionDenied = isDenied
        }
    }

    private func handlePermissionDenied() {
        setIdleTimerDisabled(false)
        updateStatus(String(localized: "没有相机权限"))
        publishCameraPermissionDenied(true)
    }
}

#if DEBUG
extension NativeReceiverViewModel {
    /// 截图/界面验证用：跳过相机，直接把界面置于某个状态（见 DemoContent）
    fileprivate func applyDemoState(_ name: String) {
        DispatchQueue.main.async {
            // 模拟器没有相机，演示时把手电筒/变焦按钮也显示出来
            self.torchAvailable = true
            self.canQuickZoom = true
            switch name {
            case "receiving":
                self.progressValue = 0.62
                self.isTracking = true
                self.detectedFrameCount = 214
                self.remainingSeconds = 9
                self.detectedMode = 68
            case "lost":
                self.progressValue = 0.62
                self.isTracking = false
                self.detectedFrameCount = 214
                self.detectedMode = 68
            case "stalled":
                self.progressValue = 0.41
                self.isTracking = true
                self.detectedFrameCount = 133
                self.detectedMode = 68
                self.stallHint = String(localized: "试试靠近些、避开反光，或调亮发送端屏幕")
            case "error":
                self.scanErrorLatched = true
                self.statusText = String(format: NSLocalizedString("文件解压失败（错误 %d），传输可能受损", comment: ""), -15)
            case "paused":
                self.isIdlePaused = true
            case "done":
                self.progressValue = 1
                self.transferDuration = 23
                self.receivedFileURL = DemoContent.completedSampleURL()
            default:
                break
            }
        }
    }
}
#endif

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
            updateStatusIfCurrent(String(localized: "正在寻找动画码"), revision: revision)
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
            return String(localized: "这台设备没有后置相机")
        case .cannotAddInput:
            return String(localized: "相机输入不可用")
        case .cannotAddOutput:
            return String(localized: "视频输出不可用")
        }
    }
}
