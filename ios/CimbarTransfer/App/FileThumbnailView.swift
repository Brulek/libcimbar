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
        // 图标随底块等比缩放：列表里 46pt、简介页 132pt 都要好看
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(style.tint.opacity(0.18))
                Image(systemName: style.symbol)
                    .font(.system(size: side * 0.4, weight: .medium))
                    .foregroundStyle(style.tint)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
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

    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// 竖长的文档页裁成正方形时保留顶部：标题和第一段才认得出是哪份文件。
    /// 照片和视频仍然居中裁
    private func cropAlignment(for image: UIImage) -> Alignment {
        let isMedia = PhotoLibrarySaver.canSave(extension: fileExtension)
        return !isMedia && image.size.height > image.size.width * 1.05 ? .top : .center
    }

    var body: some View {
        ZStack {
            if let image {
                Color.clear
                    .overlay(alignment: cropAlignment(for: image)) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            // 「智能反转」下照片和文档缩略图保持原色
                            .accessibilityIgnoresInvertColors()
                    }
            } else {
                FileKindIcon(fileExtension: fileExtension, cornerRadius: cornerRadius)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // 白底的文档页、截图贴在白色列表上没有边，加一圈很淡的描边（照片、相册 App 也这样）
        .overlay {
            if image != nil {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
        }
        // 视频的缩略图只是第一帧，和照片分不出来：中间放一个播放标记
        .overlay {
            if image != nil, Self.videoExtensions.contains(fileExtension) {
                GeometryReader { proxy in
                    let side = min(proxy.size.width, proxy.size.height) * 0.3
                    Image(systemName: "play.fill")
                        .font(.system(size: side * 0.45, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: side, height: side)
                        .background(.black.opacity(0.4), in: Circle())
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
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

    // 长按的大图预览只给缩略图一定能出来的类型；文档类偶尔生成失败，会变成一块空的大图标
    private nonisolated static let largePreviewExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "bmp",
        "mp4", "mov", "m4v",
        "pdf",
    ]

    nonisolated static func supportsLargePreview(fileExtension: String) -> Bool {
        largePreviewExtensions.contains(fileExtension.lowercased())
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
