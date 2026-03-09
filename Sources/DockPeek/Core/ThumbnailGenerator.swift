import Cocoa
import ScreenCaptureKit

/// 윈도우 썸네일을 비동기로 생성하는 클래스.
///
/// - macOS 14+: ScreenCaptureKit (SCScreenshotManager) 사용 — 고품질, 권한 필요
/// - Fallback: CGWindowListCreateImageFromArray 사용 — 저품질, 권한 불필요
@MainActor
final class ThumbnailGenerator {
    static let shared = ThumbnailGenerator()

    // MARK: - Thumbnail Cache

    private var cache: [CGWindowID: CacheEntry] = [:]
    private var cacheInsertionOrder: [CGWindowID] = []
    private let cacheTTL: TimeInterval = 0.5       // 0.5초 캐시
    private let cacheMaxCount: Int = 50            // 최대 50개 항목

    private struct CacheEntry {
        let image: NSImage
        let timestamp: Date
    }

    // MARK: - SCShareableContent Cache
    //
    // Swift은 stored property에 @available을 허용하지 않으므로,
    // SCShareableContent를 Any?로 박싱하고 별도 타임스탬프와 함께 보관한다.

    private var cachedShareableContent: Any?        // SCShareableContent (macOS 14+)
    private var shareableContentTimestamp: Date?
    private let shareableContentTTL: TimeInterval = 2.5  // 2.5초 캐시

    // MARK: - Public API

    func thumbnail(for window: WindowInfo, size: CGSize) async -> NSImage? {
        // 최소화 윈도우는 캡처 불가 — WindowThumbnailCard에서 별도 UI 처리
        if window.isMinimized { return nil }

        // 썸네일 캐시 확인
        if let entry = cache[window.id], Date().timeIntervalSince(entry.timestamp) < cacheTTL {
            return entry.image
        }

        let image: NSImage?
        if #available(macOS 14.0, *) {
            image = await captureWithSCKit(windowID: window.id, size: size)
        } else {
            image = captureWithCGWindow(windowID: window.id, size: size)
        }

        if let image {
            storeThumbnailInCache(windowID: window.id, image: image)
        }
        return image
    }

    func clearCache() {
        cache.removeAll()
        cacheInsertionOrder.removeAll()
        cachedShareableContent = nil
        shareableContentTimestamp = nil
    }

    // MARK: - Thumbnail Cache Management

    private func storeThumbnailInCache(windowID: CGWindowID, image: NSImage) {
        if cache[windowID] == nil {
            // 신규 항목 — 상한선 초과 시 가장 오래된 항목 제거 (FIFO)
            if cacheInsertionOrder.count >= cacheMaxCount,
               let oldest = cacheInsertionOrder.first {
                cache.removeValue(forKey: oldest)
                cacheInsertionOrder.removeFirst()
            }
            cacheInsertionOrder.append(windowID)
        }
        cache[windowID] = CacheEntry(image: image, timestamp: Date())
    }

    // MARK: - ScreenCaptureKit (macOS 14+)

    @available(macOS 14.0, *)
    private func shareableContent() async throws -> SCShareableContent {
        // 캐시가 유효하면 재조회 없이 반환
        if let timestamp = shareableContentTimestamp,
           Date().timeIntervalSince(timestamp) < shareableContentTTL,
           let cached = cachedShareableContent as? SCShareableContent {
            return cached
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cachedShareableContent = content
        shareableContentTimestamp = Date()
        return content
    }

    @available(macOS 14.0, *)
    private func captureWithSCKit(windowID: CGWindowID, size: CGSize) async -> NSImage? {
        do {
            let content = try await shareableContent()

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
