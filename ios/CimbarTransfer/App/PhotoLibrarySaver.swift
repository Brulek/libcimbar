import Foundation
import Photos
import UIKit

enum PhotoLibrarySaverError: LocalizedError {
    case unsupportedFormat
    case permissionDenied
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "该文件不是支持的图片格式"
        case .permissionDenied:  return "未授予相册写入权限"
        case .saveFailed(let m): return m
        }
    }
}

enum PhotoLibrarySaver {
    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "bmp", "webp"
    ]

    static func canSave(extension ext: String) -> Bool {
        supportedExtensions.contains(ext.lowercased())
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
