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
            loginSection
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
                // macOS 13 호환: onChange 단일 인자 형식 사용
                .onChange(of: value) { newValue in
                    if !isTextFieldFocused {
                        textInput = newValue.formatted(formatStyle)
                    }
                }

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
                // macOS 13 호환: onChange 단일 인자 형식 사용
                .onChange(of: isTextFieldFocused) { focused in
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
        guard let parsed = Double(textInput.trimmingCharacters(in: .whitespaces)) else {
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
