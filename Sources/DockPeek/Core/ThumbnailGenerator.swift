import Cocoa
import ScreenCaptureKit

/// 윈도우 썸네일을 비동기로 생성하는 클래스.
///
/// - macOS 13+: ScreenCaptureKit (SCScreenshotManager) 사용 — 고품질, 권한 필요
/// - Fallback: CGWindowListCreateImageFromArray 사용 — 저품질, 권한 불필요
@MainActor
final class ThumbnailGenerator {
    static let shared = ThumbnailGenerator()

    private var cache: [CGWindowID: CacheEntry] = [:]
    private let cacheTTL: TimeInterval = 0.5 // 0.5초 캐시

    private struct CacheEntry {
        let image: NSImage
        let timestamp: Date
    }

    // MARK: - Public API

    func thumbnail(for window: WindowInfo, size: CGSize) async -> NSImage? {
        // 캐시 확인
        if let entry = cache[window.id], Date().timeIntervalSince(entry.timestamp) < cacheTTL {
            return entry.image
        }

        let image: NSImage?
        if #available(macOS 13.0, *) {
            image = await captureWithSCKit(windowID: window.id, size: size)
        } else {
            image = captureWithCGWindow(windowID: window.id, size: size)
        }

        if let image {
            cache[window.id] = CacheEntry(image: image, timestamp: Date())
        }
        return image
    }

    func clearCache() {
        cache.removeAll()
    }

    // MARK: - ScreenCaptureKit (macOS 13+)

    @available(macOS 13.0, *)
    private func captureWithSCKit(windowID: CGWindowID, size: CGSize) async -> NSImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                return captureWithCGWindow(windowID: windowID, size: size) // fallback
            }

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)

            let config = SCStreamConfiguration()
            config.width = Int(size.width * 2)  // Retina 대응
            config.height = Int(size.height * 2)
            config.scalesToFit = true
            config.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return NSImage(cgImage: cgImage, size: size)
        } catch {
            print("[ThumbnailGenerator] SCKit 캡처 실패: \(error)")
            return captureWithCGWindow(windowID: windowID, size: size)
        }
    }

    // MARK: - CGWindowList Fallback

    private func captureWithCGWindow(windowID: CGWindowID, size: CGSize) -> NSImage? {
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.bestResolution, .nominalResolution]
        ) else { return nil }

        let image = NSImage(cgImage: cgImage, size: size)
        return image
    }
}
