import Foundation
import Photos
import UIKit

enum PhotoLibrarySaverError: LocalizedError {
    case unsupportedFormat
    case permissionDenied
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return String(localized: "该文件不是支持的图片格式")
        case .permissionDenied:  return String(localized: "请在设置中允许萤传添加照片")
        case .saveFailed(let m): return m
        }
    }
}

/// 跳转到系统设置里本 App 的页面（权限被拒后的补救入口）
enum AppSettingsOpener {
    @MainActor
    static func open() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

enum PhotoLibrarySaver {
    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "bmp", "webp"
    ]

    static func canSave(extension ext: String) -> Bool {
        supportedExtensions.contains(ext.lowercased())
    }

    /// 判定错误是否为「相册写入权限被拒」——需要给用户跳系统设置的入口
    static func isPermissionDenied(_ error: Error) -> Bool {
        if case PhotoLibrarySaverError.permissionDenied = error {
            return true
        }
        return false
    }

    static func save(fileURL: URL) async throws {
        let ext = fileURL.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw PhotoLibrarySaverError.unsupportedFormat
        }

        let status = await requestAddAuthorization()
        guard status == .authorized || status == .limited else {
            throw PhotoLibrarySaverError.permissionDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            request.addResource(with: .photo, fileURL: fileURL, options: options)
        }
    }

    private static func requestAddAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}
