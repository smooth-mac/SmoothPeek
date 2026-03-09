import SwiftUI

// MARK: - 전체 패널 뷰

struct PreviewPanelView: View {
    let app: NSRunningApplication
    let windows: [WindowInfo]
    let onSelect: (WindowInfo) -> Void

    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 앱 이름 헤더
            HStack(spacing: 6) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                }
                Text(app.localizedName ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 12)

            // 썸네일 그리드 — 열 너비는 AppSettings.thumbnailWidth를 따른다
            let columns = min(windows.count, 4)
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.fixed(settings.thumbnailWidth), spacing: 12),
                    count: columns
                ),
                spacing: 12
            ) {
                ForEach(windows) { window in
                    WindowThumbnailCard(window: window, app: app, onSelect: onSelect)
                }
            }
            .padding([.horizontal, .bottom], 12)
        }
        .padding(.top, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }
}

// MARK: - 개별 썸네일 카드

struct WindowThumbnailCard: View {
    let window: WindowInfo
    let app: NSRunningApplication
    let onSelect: (WindowInfo) -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovered = false

    @ObservedObject private var settings = AppSettings.shared

    /// 창의 실제 비율을 유지하면서 maxWidth × maxHeight 안에 맞춘 썸네일 크기.
    ///
    /// 창이 세로로 길거나 작은 경우에도 빈 공간 없이 창 내용이 꽉 차도록 한다.
    /// 최소화 윈도우 또는 frame 정보가 없으면 기본값(maxWidth × maxHeight)을 사용한다.
    private var thumbSize: CGSize {
        let maxW = settings.thumbnailWidth
        let maxH = settings.thumbnailHeight
        guard !window.isMinimized,
              window.frame.width > 0, window.frame.height > 0 else {
            return CGSize(width: maxW, height: maxH)
        }
        let scale = min(maxW / window.frame.width, maxH / window.frame.height)
        return CGSize(
            width: max(1, (window.frame.width * scale).rounded()),
            height: max(1, (window.frame.height * scale).rounded())
        )
    }

    var body: some View {
        VStack(spacing: 4) {
            // 썸네일 영역
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: thumbSize.width, height: thumbSize.height)

                if window.isMinimized {
                    MinimizedPlaceholder(app: app)
                        .frame(width: thumbSize.width, height: thumbSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: thumbSize.width, height: thumbSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isHovered ? Color.accentColor : Color.white.opacity(0.2),
                        lineWidth: isHovered ? 2 : 1
                    )
            )
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovered)

            // 윈도우 제목
            Text(window.title)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .frame(width: thumbSize.width, alignment: .center)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            onSelect(window)
        }
        .task(id: thumbSize) {
            thumbnail = await ThumbnailGenerator.shared.thumbnail(for: window, size: thumbSize)
        }
    }
}

// MARK: - 최소화 윈도우 플레이스홀더

/// 최소화 윈도우에 표시하는 뷰: 앱 아이콘 + "최소화됨" 뱃지
private struct MinimizedPlaceholder: View {
    let app: NSRunningApplication

    var body: some View {
        ZStack {
            // 배경 — 약간 어두운 톤으로 일반 썸네일과 시각적 구분
            Color.black.opacity(0.25)

            VStack(spacing: 8) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .shadow(color: .black.opacity(0.3), radius: 4)
                }

                Text("최소화됨")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.15))
                    )
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct PreviewPanelView_Previews: PreviewProvider {
    static var previews: some View {
        let dummyWindows = [
            WindowInfo(
                id: CGWindowID(1),
                title: "Document 1.swift",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                isMinimized: false,
                pid: 1234
            ),
            WindowInfo(
                id: CGWindowID(2),
                title: "Document 2.swift",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                isMinimized: true,
                pid: 1234
            ),
            WindowInfo(
                id: CGWindowID(3),
                title: "Document 3.swift",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                isMinimized: false,
                pid: 1234
            ),
        ]
        PreviewPanelView(
            app: NSRunningApplication.current,
            windows: dummyWindows,
            onSelect: { _ in }
        )
        .frame(width: 660, height: 200)
        .padding()
    }
}
#endif
