import QuickLookThumbnailing
import SwiftUI
import UIKit

/// 按文件扩展名归类的占位图标（缩略图不可用时的兜底，也是非媒体文件的常驻图标）
struct FileKindIcon: View {
    let fileExtension: String
    var cornerRadius: CGFloat = 12

    private struct IconStyle {
        let symbol: String
        let tint: Color
    }

    private var style: IconStyle {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "bmp":
            return IconStyle(symbol: "photo", tint: .pink)
        case "mp4", "mov", "m4v", "avi", "mkv":
            return IconStyle(symbol: "play.rectangle.fill", tint: .red)
        case "mp3", "wav", "aac", "flac", "m4a":
            return IconStyle(symbol: "music.note", tint: .purple)
        case "pdf":
            return IconStyle(symbol: "doc.richtext.fill", tint: .red)
        case "zip", "rar", "7z", "tar", "gz":
            return IconStyle(symbol: "archivebox.fill", tint: .brown)
        case "txt", "log", "md":
            return IconStyle(symbol: "doc.text.fill", tint: .gray)
        case "json", "xml", "yaml", "yml", "toml":
            return IconStyle(symbol: "curlybraces", tint: .orange)
        case "doc", "docx":
            return IconStyle(symbol: "doc.fill", tint: .blue)
        case "xls", "xlsx", "csv":
            return IconStyle(symbol: "tablecells.fill", tint: .green)
        case "ppt", "pptx", "key":
            return IconStyle(symbol: "rectangle.on.rectangle.fill", tint: .orange)
        case "html", "htm":
            return IconStyle(symbol: "globe", tint: .blue)
        default:
            return IconStyle(symbol: "doc", tint: .secondary)
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(style.tint.opacity(0.18))
            Image(systemName: style.symbol)
                .font(.title3)
                .foregroundStyle(style.tint)
        }
    }
}

/// 用 QuickLook 为图片/视频/PDF 生成真实缩略图；其余类型显示 FileKindIcon
struct FileThumbnailView: View {
    let url: URL
    /// 缓存键需包含会随内容变化的成分（如修改时间），避免文件被替换后显示旧图
    var cacheKey: String
    var cornerRadius: CGFloat = 12
    /// 请求生成的边长（pt），应不小于展示尺寸
    var generationSide: CGFloat = 96

    @State private var image: UIImage?

    private var fileExtension: String {
        url.pathExtension.lowercased()
    }

    var body: some View {
        ZStack {
            if let image {
                Color.clear
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
            } else {
                FileKindIcon(fileExtension: fileExtension, cornerRadius: cornerRadius)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: cacheKey) {
            guard ThumbnailLoader.supports(fileExtension: fileExtension) else {
                image = nil
                return
            }
            image = await ThumbnailLoader.thumbnail(for: url, side: generationSide, cacheKey: cacheKey)
        }
    }
}

@MainActor
enum ThumbnailLoader {
    private static let cache = NSCache<NSString, UIImage>()

    // 纯文本、表格数据之类在 46pt 里渲染出来只是一页灰字，不如类型图标好认，不做缩略图
    private nonisolated static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "bmp",
        "mp4", "mov", "m4v",
        "pdf",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf",
    ]

    nonisolated static func supports(fileExtension: String) -> Bool {
        supportedExtensions.contains(fileExtension.lowercased())
    }

    static func thumbnail(for url: URL, side: CGFloat, cacheKey: String) async -> UIImage? {
        if let hit = cache.object(forKey: cacheKey as NSString) {
            return hit
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: UIScreen.main.scale,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = representation.uiImage
        cache.setObject(image, forKey: cacheKey as NSString)
        return image
    }
}
