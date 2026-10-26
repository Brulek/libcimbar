import SwiftUI
import UIKit

/// 「存到文件」：拷一份到「文件」App 里用户选的位置，萤传里的原件不动。
/// 压缩包这类预览不了的文件，收到后最常见的下一步就是放进「文件」里解压
enum FilesExport {
    /// 压缩包：「我的文件」按类型排序时单独一组
    static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]

    static func isArchive(_ fileExtension: String) -> Bool {
        archiveExtensions.contains(fileExtension.lowercased())
    }

    /// 系统预览能真正显示内容的类型。其余（压缩包、安装包、未知格式）预览只有一个图标和大小，
    /// 点进去什么也做不了：这些文件不给「预览」，点它进简介页，那里能「存到文件」
    private static let previewableExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp",
        "mp4", "mov", "m4v", "mp3", "wav", "aac", "m4a", "aiff",
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf",
        "txt", "md", "csv", "json", "xml", "yaml", "yml", "log", "html", "htm", "usdz",
    ]

    static func hasUsefulPreview(_ fileExtension: String) -> Bool {
        previewableExtensions.contains(fileExtension.lowercased())
    }
}

struct FilesExportPicker: UIViewControllerRepresentable {
    let fileURLs: [URL]
    /// true：用户选好位置存进去了；false：取消
    var onFinish: (Bool) -> Void

    init(fileURLs: [URL], onFinish: @escaping (Bool) -> Void) {
        self.fileURLs = fileURLs
        self.onFinish = onFinish
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: fileURLs, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: (Bool) -> Void

        init(onFinish: @escaping (Bool) -> Void) {
            self.onFinish = onFinish
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish(true)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(false)
        }
    }
}

extension View {
    /// `urls` 非空时弹出「存到文件」的位置选择器，关闭后自动清空；用户存好了回调存入的个数
    func filesExport(urls: Binding<[URL]>, onSaved: @escaping (Int) -> Void) -> some View {
        modifier(FilesExportModifier(urls: urls, onSaved: onSaved))
    }
}

private struct FilesExportModifier: ViewModifier {
    @Binding var urls: [URL]
    let onSaved: (Int) -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { !urls.isEmpty },
            set: { if !$0 { urls = [] } }
        )) {
            FilesExportPicker(fileURLs: urls) { [count = urls.count] saved in
                if saved { onSaved(count) }
            }
            .ignoresSafeArea()
        }
    }
}
