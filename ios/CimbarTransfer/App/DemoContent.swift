#if DEBUG
import UIKit

/// 模拟器截图与界面验证用的示例数据，只在 Debug 构建中存在。
///
/// - `-SeedDemoFiles YES`：启动时往接收目录写入几份示例文件（已存在则跳过）
/// - `-DemoDetail YES`：直接打开最新文件的简介页
/// - `-DemoSelect YES`：「我的文件」直接进入多选并选中前两个
/// - `-DemoNow 09:41`：示例文件按今天 9:41 往前排接收时间
/// - `-DemoFrames <目录>[:<目录>…]`：回放 run_decode_selftest.sh --dump-transfer 导出的帧，代替相机；
///   `-DemoFramesFPS 4` 调慢回放
/// - `-DemoScan waiting|receiving|lost|stalled|error|paused|done|done-text`：扫码页跳过相机，直接展示对应状态；
///   容器的 Library/Caches 里有 demo-screen.png 时把它当作对准的发送端屏幕画进取景框
enum DemoContent {
    static var scanState: String? {
        UserDefaults.standard.string(forKey: "DemoScan")
    }

    /// `-DemoFrames <目录1>:<目录2>`：不开相机，回放预先导出的动画码帧（每个目录循环两遍再换下一个）
    static var replayFrameDirectories: [URL]? {
        guard let value = UserDefaults.standard.string(forKey: "DemoFrames"), !value.isEmpty else { return nil }
        return value.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
    }

    /// `-DemoFramesFPS 4`：回放帧率（默认 15），调慢了好截进度中的画面
    static var replayFramesPerSecond: Double {
        let value = UserDefaults.standard.double(forKey: "DemoFramesFPS")
        return value > 0 ? value : 15
    }

    /// `-DemoSelect YES`：「我的文件」打开后进入多选，选中前两个文件
    static var opensSelection: Bool {
        UserDefaults.standard.bool(forKey: "DemoSelect")
    }

    /// `-DemoDetail YES`：「我的文件」打开后直接进入最新文件的简介页
    static var opensDetail: Bool {
        UserDefaults.standard.bool(forKey: "DemoDetail")
    }

    /// 演示状态下放进取景框里的「发送端屏幕」（Library/Caches/demo-screen.png，截图前拷进容器；
    /// 可用 scripts/run_decode_selftest.sh --dump-frame 导出一帧真实的动画码再加边框）
    static let senderScreen: UIImage? = {
        guard scanState != nil,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return UIImage(contentsOfFile: caches.appendingPathComponent("demo-screen.png").path)
    }()

    /// `-DemoNow 09:41`：示例文件的接收时间以今天这个时刻为基准，和截图状态栏的时间对得上
    private static var demoNow: Date {
        guard let value = UserDefaults.standard.string(forKey: "DemoNow") else { return Date() }
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return Date() }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date()) ?? Date()
    }

    private static var isEnglish: Bool {
        Locale.preferredLanguages.first?.hasPrefix("en") ?? false
    }

    private struct Sample {
        let zh: String
        let en: String
        let age: TimeInterval
        let make: (URL) throws -> Void
    }

    private static let samples: [Sample] = [
        Sample(zh: "海边日落.jpg", en: "Sunset.jpg", age: 8 * 60, make: { try sunsetJPEG().write(to: $0) }),
        Sample(zh: "季度汇报.pdf", en: "Q3 Report.pdf", age: 2 * 3600, make: { try reportPDF().write(to: $0) }),
        Sample(zh: "首页设计稿.png", en: "Home Mockup.png", age: 26 * 3600, make: { try mockupPNG().write(to: $0) }),
        Sample(zh: "会议纪要.txt", en: "Meeting Notes.txt", age: 3 * 86400, make: {
            try notesText().write(to: $0, atomically: true, encoding: .utf8)
        }),
        Sample(zh: "销售数据.csv", en: "Sales.csv", age: 9 * 86400, make: {
            try salesCSV().write(to: $0, atomically: true, encoding: .utf8)
        }),
    ]

    /// 「完成」演示状态用的文件：图片，或 text 为 true 时用文本
    static func completedSampleURL(text: Bool = false) -> URL? {
        seedFilesIfRequested(force: true)
        guard let directory = try? ReceivedFileCache.directoryURL() else { return nil }
        let sample = samples[text ? 3 : 0]
        return directory.appendingPathComponent(isEnglish ? sample.en : sample.zh)
    }

    static func seedFilesIfRequested(force: Bool = false) {
        guard force || UserDefaults.standard.bool(forKey: "SeedDemoFiles"),
              let directory = try? ReceivedFileCache.directoryURL() else { return }
        let now = demoNow
        for sample in samples {
            let name = isEnglish ? sample.en : sample.zh
            let url = directory.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try sample.make(url)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                let receivedAt = now.addingTimeInterval(-sample.age)
                try? FileManager.default.setAttributes([.modificationDate: receivedAt], ofItemAtPath: url.path)
                _ = ReceivedFileMetadataStore.shared.register(filename: name, fileSize: size, receivedAt: receivedAt)
            } catch {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - 示例内容

    private static func sunsetJPEG() throws -> Data {
        let size = CGSize(width: 1200, height: 900)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let sky = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor(red: 0.16, green: 0.12, blue: 0.38, alpha: 1).cgColor,
                         UIColor(red: 0.93, green: 0.42, blue: 0.36, alpha: 1).cgColor,
                         UIColor(red: 1.0, green: 0.78, blue: 0.42, alpha: 1).cgColor] as CFArray,
                locations: [0, 0.6, 1]
            )!
            cg.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: size.height * 0.62), options: [.drawsAfterEndLocation])
            UIColor(red: 1.0, green: 0.88, blue: 0.6, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 480, y: 380, width: 240, height: 240))
            UIColor(red: 0.12, green: 0.18, blue: 0.36, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: size.height * 0.62, width: size.width, height: size.height * 0.38))
            UIColor(red: 1.0, green: 0.8, blue: 0.5, alpha: 0.5).setFill()
            for row in 0..<6 {
                let width = CGFloat(220 - row * 30)
                cg.fill(CGRect(x: 600 - width / 2, y: 580 + CGFloat(row) * 38, width: width, height: 6))
            }
        }
        guard let data = image.jpegData(compressionQuality: 0.85) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    private static func mockupPNG() throws -> Data {
        let size = CGSize(width: 750, height: 1334)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            UIColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.05, green: 0.07, blue: 0.18, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 0, width: size.width, height: 360))
            UIColor(red: 1.0, green: 0.76, blue: 0.26, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 60, y: 120, width: 120, height: 120))
            UIColor.white.setFill()
            for index in 0..<5 {
                let card = CGRect(x: 40, y: 400 + CGFloat(index) * 180, width: size.width - 80, height: 150)
                UIBezierPath(roundedRect: card, cornerRadius: 28).fill()
            }
        }
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    private static func reportPDF() throws -> Data {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            context.beginPage()
            let title: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 28)]
            (isEnglish ? "Q3 Report" : "第三季度汇报").draw(at: CGPoint(x: 48, y: 56), withAttributes: title)
            let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.darkGray]
            for line in 0..<8 {
                let text = isEnglish ? "Section \(line + 1) — summary and key numbers" : "第 \(line + 1) 部分：要点与关键数据"
                text.draw(at: CGPoint(x: 48, y: 120 + CGFloat(line) * 26), withAttributes: body)
            }
            let colors: [UIColor] = [.systemOrange, .systemYellow, .systemTeal, .systemIndigo]
            for (index, height) in [180, 240, 210, 300].enumerated() {
                colors[index].setFill()
                UIRectFill(CGRect(x: 80 + index * 120, y: 760 - height, width: 72, height: height))
            }
        }
    }

    private static func notesText() -> String {
        isEnglish
            ? "Product review · Oct 28\n\n1. Homepage redesign approved\n2. Final designs due Monday\n3. Next review: Thursday 2 pm, Room 302\n\nGuest Wi-Fi: Lumen-Guest\nPassword: sunset-2027\n"
            : "产品评审会 · 10 月 28 日\n\n1. 首页改版方案通过\n2. 下周一前交终版设计稿\n3. 下次评审：周四下午 2 点，302 会议室\n\n访客 Wi-Fi：Lumen-Guest\n密码：sunset-2027\n"
    }

    private static func salesCSV() -> String {
        var rows = ["month,region,amount"]
        for month in 1...12 {
            rows.append("\(month),north,\(1000 + month * 87)")
        }
        return rows.joined(separator: "\n")
    }
}
#endif
