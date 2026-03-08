import SwiftUI

// MARK: - 전체 패널 뷰

struct PreviewPanelView: View {
    let app: NSRunningApplication
    let windows: [WindowInfo]
    let onSelect: (WindowInfo) -> Void

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

            // 썸네일 그리드
            let columns = min(windows.count, 4)
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(200), spacing: 12), count: columns),
                spacing: 12
            ) {
                ForEach(windows) { window in
                    WindowThumbnailCard(window: window, onSelect: onSelect)
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
    let onSelect: (WindowInfo) -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovered = false

    private let thumbSize = CGSize(width: 200, height: 120)

    var body: some View {
        VStack(spacing: 4) {
            // 썸네일 이미지
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: thumbSize.width, height: thumbSize.height)

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: thumbSize.width, height: thumbSize.height)
                        .clipped()
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
        .task {
            thumbnail = await ThumbnailGenerator.shared.thumbnail(for: window, size: thumbSize)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct PreviewPanelView_Previews: PreviewProvider {
    static var previews: some View {
        let dummyWindows = (1...3).map { i in
            WindowInfo(
                id: CGWindowID(i),
                title: "Document \(i).swift",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                isOnScreen: true,
                pid: 1234
            )
        }
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
