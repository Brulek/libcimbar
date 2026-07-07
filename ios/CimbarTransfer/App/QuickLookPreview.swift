import QuickLook
import SwiftUI
import UIKit

struct QuickLookPreview: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.delegate = context.coordinator
        let nav = UINavigationController(rootViewController: preview)
        nav.modalPresentationStyle = .fullScreen
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        context.coordinator.fileURL = fileURL
        if let preview = uiViewController.viewControllers.first as? QLPreviewController {
            preview.reloadData()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        var fileURL: URL

        init(fileURL: URL) {
            self.fileURL = fileURL
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            fileURL as NSURL
        }
    }
}
