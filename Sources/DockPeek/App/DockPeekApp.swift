import SwiftUI

@main
struct DockPeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 메뉴바 앱 — 별도 윈도우 없음
        Settings { EmptyView() }
    }
}
