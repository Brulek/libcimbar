import QuickLook
import SwiftUI
import UIKit

/// 多个文件时可左右滑动切换（从「我的文件」打开时传入整个列表）
struct QuickLookPreview: UIViewControllerRepresentable {
    let fileURLs: [URL]
    var initialIndex: Int = 0
    /// 用户在预览里标注后另存了一份（原文件不动），存好后回调新文件
    var onSavedEditedCopy: (URL) -> Void = { _ in }

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.delegate = context.coordinator
        preview.currentPreviewItemIndex = min(max(initialIndex, 0), max(fileURLs.count - 1, 0))
        // 包在导航控制器里时 QuickLook 不会自己放「完成」按钮，只能下拉关闭，用户不容易发现
        let dismiss = context.environment.dismiss
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { _ in dismiss() }
        )
        let nav = UINavigationController(rootViewController: preview)
        nav.modalPresentationStyle = .fullScreen
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        // 只有 URL 真正变化才 reload：任何无关的 SwiftUI 重渲染都会走到这里，
        // 无条件 reload 会把用户正在浏览的页码/缩放状态重置掉
        guard context.coordinator.fileURLs != fileURLs else { return }
        context.coordinator.fileURLs = fileURLs
        if let preview = uiViewController.viewControllers.first as? QLPreviewController {
            preview.reloadData()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURLs: fileURLs, onSavedEditedCopy: onSavedEditedCopy)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        var fileURLs: [URL]
        let onSavedEditedCopy: (URL) -> Void

        init(fileURLs: [URL], onSavedEditedCopy: @escaping (URL) -> Void) {
            self.fileURLs = fileURLs
            self.onSavedEditedCopy = onSavedEditedCopy
        }

        // 系统预览里总有「标注」按钮。默认不能保存，用户画完一关就丢了；
        // 改成另存一份：收到的原文件保持原样（SHA-256 不变），标注版作为新文件出现在「我的文件」
        func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
            .createCopy
        }

        /// 同一次预览里每个原文件只留一份标注版：系统在退出标注和关闭预览时都会回调，后一次覆盖前一次
        private var savedCopies: [URL: URL] = [:]

        func previewController(_ controller: QLPreviewController, didSaveEditedCopyOf previewItem: QLPreviewItem, at modifiedContentsURL: URL) {
            guard let original = previewItem.previewItemURL else { return }
            let fileManager = FileManager.default
            let destination: URL
            if let existing = savedCopies[original], fileManager.fileExists(atPath: existing.path) {
                guard (try? fileManager.replaceItemAt(existing, withItemAt: Self.stagedCopy(of: modifiedContentsURL))) != nil else { return }
                destination = existing
            } else {
                let stem = original.deletingPathExtension().lastPathComponent
                // 系统把 .jpg 存成 .jpeg，沿用原文件的写法
                let jpegFamily: Set<String> = ["jpg", "jpeg"]
                let modifiedExt = modifiedContentsURL.pathExtension.lowercased()
                let ext = modifiedExt.isEmpty || (jpegFamily.contains(modifiedExt) && jpegFamily.contains(original.pathExtension.lowercased()))
                    ? original.pathExtension
                    : modifiedContentsURL.pathExtension
                let name = String(localized: "\(stem)（标注）") + (ext.isEmpty ? "" : ".\(ext)")
                guard let unique = try? ReceivedFileStorage.uniqueDestinationURL(for: name),
                      (try? fileManager.copyItem(at: modifiedContentsURL, to: unique)) != nil else { return }
                destination = unique
                savedCopies[original] = unique
            }
            let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            _ = ReceivedFileMetadataStore.shared.register(filename: destination.lastPathComponent, fileSize: size)
            DispatchQueue.main.async { self.onSavedEditedCopy(destination) }
        }

        /// replaceItemAt 会挪走源文件；系统给的临时文件先复制一份再用
        private static func stagedCopy(of url: URL) -> URL {
            let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
            try? FileManager.default.copyItem(at: url, to: staged)
            return staged
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            fileURLs.count
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            fileURLs[index] as NSURL
        }
    }
}
