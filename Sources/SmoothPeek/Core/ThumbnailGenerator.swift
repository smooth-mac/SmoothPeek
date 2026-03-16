import Cocoa
import ScreenCaptureKit

/// 윈도우 썸네일을 비동기로 생성하는 클래스.
///
/// macOS 14+ 전용으로 ScreenCaptureKit(SCScreenshotManager)을 사용한다.
/// App Store 배포 시 CGWindowListCreateImage(deprecated, sandbox 제한)를 사용하지 않는다.
@MainActor
final class ThumbnailGenerator {
    static let shared = ThumbnailGenerator()

    // MARK: - Thumbnail Cache

    private var cache: [CGWindowID: CacheEntry] = [:]
    private var cacheInsertionOrder: [CGWindowID] = []
    private let cacheTTL: TimeInterval = 0.5       // 0.5초 캐시
    private let cacheMaxCount: Int = 50            // 최대 50개 항목

    /// 현재 캡처 진행 중인 windowID → Task 매핑.
    /// 동일 창에 대한 중복 SCKit 캡처를 방지한다.
    private var inFlight: [CGWindowID: Task<NSImage?, Never>] = [:]

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

        // 동일 windowID에 대해 이미 캡처 중이면 해당 Task를 await — 중복 SCKit 캡처 방지
        if let existing = inFlight[window.id] {
            return await existing.value
        }

        let windowID = window.id
        let task = Task<NSImage?, Never> {
            let image = await captureWithSCKit(windowID: windowID, size: size)
            if let image {
                storeThumbnailInCache(windowID: windowID, image: image)
            }
            inFlight.removeValue(forKey: windowID)
            return image
        }
        inFlight[windowID] = task
        return await task.value
    }

    func clearCache() {
        cache.removeAll()
        cacheInsertionOrder.removeAll()
        cachedShareableContent = nil
        shareableContentTimestamp = nil
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
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

    // MARK: - ScreenCaptureKit

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

    private func captureWithSCKit(windowID: CGWindowID, size: CGSize) async -> NSImage? {
        do {
            let content = try await shareableContent()

            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                // 캐시된 SCShareableContent에 해당 윈도우가 없음 — 새로 열린 윈도우일 수 있다.
                cachedShareableContent = nil
                shareableContentTimestamp = nil
                return await captureWithSCKitRetry(windowID: windowID, size: size)
            }

            return try await captureWindow(scWindow, size: size)
        } catch {
            print("[ThumbnailGenerator] SCKit 캡처 실패: \(error)")
#if !MAS_BUILD
            // Direct 빌드: SCKit 실패(권한 거부 등) 시 CGWindowList로 fallback
            return captureWithCGWindow(windowID: windowID, size: size)
#else
            return nil
#endif
        }
    }

#if !MAS_BUILD
    private func captureWithCGWindow(windowID: CGWindowID, size: CGSize) -> NSImage? {
        let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        )
        guard let cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: size)
    }
#endif

    /// SCShareableContent 캐시 무효화 후 1회 재시도.
    /// 새로 열린 창이 캐시에 없을 때만 호출된다.
    private func captureWithSCKitRetry(windowID: CGWindowID, size: CGSize) async -> NSImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            cachedShareableContent = content
            shareableContentTimestamp = Date()

            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }
            return try await captureWindow(scWindow, size: size)
        } catch {
            print("[ThumbnailGenerator] SCKit 재시도 실패: \(error)")
            return nil
        }
    }

    private func captureWindow(_ scWindow: SCWindow, size: CGSize) async throws -> NSImage {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)

        let config = SCStreamConfiguration()
        config.width = Int(size.width * 2)   // Retina 대응
        config.height = Int(size.height * 2)
        config.scalesToFit = true
        config.showsCursor = false

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return NSImage(cgImage: cgImage, size: size)
    }
}
