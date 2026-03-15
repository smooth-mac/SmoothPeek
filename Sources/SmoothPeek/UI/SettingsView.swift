import SwiftUI

/// 앱 환경설정 SwiftUI 화면.
///
/// AppSettings.shared를 ObservedObject로 관찰한다.
/// 싱글톤의 소유권은 뷰 외부(AppSettings 자체)에 있으므로 @ObservedObject가 적절하다.
/// Slider + TextField 조합으로 수치 값을 조정하고
/// Toggle로 로그인 시 자동 실행을 제어한다.
struct SettingsView: View {

    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            hoverSection
            thumbnailSection
            behaviorSection
            shortcutSection
            loginSection
            updateSection
            resetSection
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 420)
    }

    // MARK: - Sections

    private var hoverSection: some View {
        Section("호버 딜레이") {
            LabeledSlider(
                label: "딜레이",
                value: $settings.hoverDelay,
                range: 0.1...1.0,
                step: 0.05,
                unit: "초",
                formatStyle: .number.precision(.fractionLength(2))
            )
        }
    }

    private var thumbnailSection: some View {
        Section("썸네일 크기") {
            LabeledSlider(
                label: "너비",
                value: $settings.thumbnailWidth,
                range: 100...400,
                step: 10,
                unit: "px",
                formatStyle: .number.precision(.fractionLength(0))
            )
            LabeledSlider(
                label: "높이",
                value: $settings.thumbnailHeight,
                range: 80...300,
                step: 10,
                unit: "px",
                formatStyle: .number.precision(.fractionLength(0))
            )
        }
    }

    private var behaviorSection: some View {
        Section("동작") {
            Toggle("패널 등장/사라짐 애니메이션", isOn: $settings.animationEnabled)
                .accessibilityLabel("패널 애니메이션")
                .accessibilityHint("활성화 시 미리보기 패널이 부드럽게 나타나고 사라집니다")

            Toggle("최소화 윈도우 미리보기에 포함", isOn: $settings.showMinimizedWindows)
                .accessibilityLabel("최소화 윈도우 포함")
                .accessibilityHint("활성화 시 Dock에 최소화된 윈도우를 미리보기 목록에 표시합니다")
        }
    }

    private var shortcutSection: some View {
        Section(
            header: Text("단축키"),
            footer: Text("단축키를 눌러 녹화하거나 필드를 클릭 후 Delete 키로 초기화합니다.\n실제 글로벌 단축키 등록은 향후 업데이트에서 지원됩니다.")
                .font(.system(size: 11))
        ) {
            HStack {
                Text("패널 토글")
                    .frame(width: 80, alignment: .leading)
                Spacer()
                KeyRecorderField(keyString: $settings.panelToggleKey)
            }
        }
    }

    private var loginSection: some View {
        Section("시스템") {
            Toggle("로그인 시 자동 실행", isOn: $settings.launchAtLogin)

            // SMAppService 등록 실패 시 토글 아래에 경고 메시지를 표시한다.
            if let errorMessage = settings.lastLaunchAtLoginError {
                Text("자동 실행 설정 실패: \(errorMessage)")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    private var updateSection: some View {
        Section("업데이트") {
            HStack {
                Spacer()
                Button("업데이트 확인") {
                    UpdateManager.shared.checkForUpdates()
                }
                .buttonStyle(.bordered)
                Spacer()
            }
        }
    }

    private var resetSection: some View {
        Section {
            HStack {
                Spacer()
                Button("기본값으로 재설정") {
                    settings.resetToDefaults()
                }
                .buttonStyle(.bordered)
                Spacer()
            }
        }
    }
}

// MARK: - KeyRecorderField

/// 단축키 입력 뷰. 클릭 후 키를 누르면 해당 키 조합을 문자열로 저장한다.
///
/// - 녹화 중: 파란색 테두리 + "녹화 중..." 텍스트
/// - 저장됨: 키 조합 문자열 표시
/// - 비어있음: 플레이스홀더 "없음" 표시
/// - Delete 키: 저장된 단축키 초기화
///
/// 실제 글로벌 단축키 등록 로직은 P3-6에서 구현 예정.
private struct KeyRecorderField: View {

    @Binding var keyString: String
    @State private var isRecording = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            isRecording ? Color.accentColor : Color(NSColor.separatorColor),
                            lineWidth: isRecording ? 2 : 1
                        )
                )

            if isRecording {
                Text("녹화 중...")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if keyString.isEmpty {
                Text("없음")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                Text(keyString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: 120, height: 26)
        .contentShape(Rectangle())
        .onTapGesture {
            isRecording = true
        }
        .background(
            KeyEventCapture(isRecording: $isRecording, keyString: $keyString)
        )
        .accessibilityLabel("패널 토글 단축키")
        .accessibilityValue(keyString.isEmpty ? "없음" : keyString)
        .accessibilityHint("클릭 후 원하는 키 조합을 눌러 단축키를 설정합니다")
    }
}

// MARK: - KeyEventCapture

/// NSViewRepresentable로 키 이벤트를 캡처하는 보조 뷰.
///
/// 녹화 모드(isRecording == true)일 때 키 입력을 가로채
/// 수정자 키(modifier flags) + 키 이름을 조합한 문자열을 keyString에 저장한다.
private struct KeyEventCapture: NSViewRepresentable {

    @Binding var isRecording: Bool
    @Binding var keyString: String

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onKeyEvent = { event in
            guard context.coordinator.isRecordingBinding.wrappedValue else { return }
            context.coordinator.handle(event: event, view: view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isRecording: $isRecording, keyString: $keyString)
    }

    // MARK: Coordinator

    final class Coordinator {
        var isRecordingBinding: Binding<Bool>
        var keyString: Binding<String>

        init(isRecording: Binding<Bool>, keyString: Binding<String>) {
            self.isRecordingBinding = isRecording
            self.keyString = keyString
        }

        func handle(event: NSEvent, view: KeyCaptureNSView?) {
            // Delete 또는 Backspace → 단축키 초기화
            if event.keyCode == 51 || event.keyCode == 117 {
                keyString.wrappedValue = ""
                isRecordingBinding.wrappedValue = false
                return
            }

            // Escape → 녹화 취소
            if event.keyCode == 53 {
                isRecordingBinding.wrappedValue = false
                return
            }

            // 수정자 키 단독 입력은 무시
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }

            var parts: [String] = []
            if flags.contains(.control) { parts.append("⌃") }
            if flags.contains(.option)  { parts.append("⌥") }
            if flags.contains(.shift)   { parts.append("⇧") }
            if flags.contains(.command) { parts.append("⌘") }
            parts.append(chars.uppercased())

            keyString.wrappedValue = parts.joined()
            isRecordingBinding.wrappedValue = false
        }
    }
}

// MARK: - KeyCaptureNSView

/// 키 이벤트 캡처를 위한 NSView 서브클래스.
final class KeyCaptureNSView: NSView {

    var onKeyEvent: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        onKeyEvent?(event)
    }

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }
}

// MARK: - LabeledSlider

/// Slider와 TextField가 나란히 놓인 입력 컴포넌트.
///
/// TextField에서 직접 값을 입력할 수 있으며 범위를 벗어난 값은
/// 자동으로 clamp된다.
private struct LabeledSlider: View {

    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let formatStyle: FloatingPointFormatStyle<Double>

    @State private var textInput: String = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 36, alignment: .leading)

            Slider(value: $value, in: range, step: step)
                .onChange(of: value) { _, newValue in
                    if !isTextFieldFocused {
                        textInput = newValue.formatted(formatStyle)
                    }
                }
                .accessibilityLabel(label)
                .accessibilityValue("\(value.formatted(formatStyle)) \(unit)")

            TextField("", text: $textInput)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
                .focused($isTextFieldFocused)
                .onAppear {
                    textInput = value.formatted(formatStyle)
                }
                .onSubmit {
                    commitTextInput()
                }
                .onChange(of: isTextFieldFocused) { _, focused in
                    if focused {
                        textInput = value.formatted(formatStyle)
                    } else {
                        commitTextInput()
                    }
                }

            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
        }
    }

    private func commitTextInput() {
        let trimmed = textInput.trimmingCharacters(in: .whitespaces)
        let decimalSeparator = Locale.current.decimalSeparator ?? "."
        let normalized = decimalSeparator == "." ? trimmed : trimmed.replacingOccurrences(of: decimalSeparator, with: ".")
        guard let parsed = Double(normalized) else {
            // 파싱 실패 시 현재 값으로 복원
            textInput = value.formatted(formatStyle)
            return
        }
        let snapped = (parsed / step).rounded() * step
        value = snapped.clamped(to: range)
        textInput = value.formatted(formatStyle)
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}
