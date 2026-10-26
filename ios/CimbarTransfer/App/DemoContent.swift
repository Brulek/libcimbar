#if DEBUG
import UIKit

/// 模拟器截图与界面验证用的示例数据，只在 Debug 构建中存在。
///
/// - `-SeedDemoFiles YES`：启动时往接收目录写入几份示例文件（已存在则跳过）
/// - `-DemoScan waiting|receiving|lost|stalled|error|done`：扫码页跳过相机，直接展示对应状态
enum DemoContent {
    static var scanState: String? {
        UserDefaults.standard.string(forKey: "DemoScan")
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

    /// 「完成」演示状态用的文件
    static func completedSampleURL() -> URL? {
        seedFilesIfRequested(force: true)
        guard let directory = try? ReceivedFileCache.directoryURL() else { return nil }
        return directory.appendingPathComponent(isEnglish ? samples[0].en : samples[0].zh)
    }

    static func seedFilesIfRequested(force: Bool = false) {
        guard force || UserDefaults.standard.bool(forKey: "SeedDemoFiles"),
              let directory = try? ReceivedFileCache.directoryURL() else { return }
        let now = Date()
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
            ? "Meeting notes\n\n1. Ship the new scanner UI\n2. Review App Store screenshots\n3. Next sync on Friday\n"
            : "会议纪要\n\n1. 新版扫码界面上线\n2. 更新 App Store 截图\n3. 周五再对一次进度\n"
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
