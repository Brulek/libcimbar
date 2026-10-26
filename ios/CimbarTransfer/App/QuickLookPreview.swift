import QuickLook
import SwiftUI
import UIKit

/// 多个文件时可左右滑动切换（从「我的文件」打开时传入整个列表）
struct QuickLookPreview: UIViewControllerRepresentable {
    let fileURLs: [URL]
    var initialIndex: Int = 0

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.delegate = context.coordinator
        preview.currentPreviewItemIndex = min(max(initialIndex, 0), max(fileURLs.count - 1, 0))
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
        Coordinator(fileURLs: fileURLs)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        var fileURLs: [URL]

        init(fileURLs: [URL]) {
            self.fileURLs = fileURLs
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            fileURLs.count
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            fileURLs[index] as NSURL
        }
    }
}
