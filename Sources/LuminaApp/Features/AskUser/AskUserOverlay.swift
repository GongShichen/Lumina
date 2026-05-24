import LuminaAppCore
import SwiftUI

struct AskUserOverlay: View {
    let request: LuminaAskUserRequest
    let submit: ([LuminaAskUserAnswer]) -> Void
    let cancel: () -> Void

    @State private var currentIndex = 0
    @State private var answers: [String: LuminaAskUserAnswer] = [:]
    @State private var isReviewing = false
    @State private var customText = ""

    private var question: LuminaAskUserQuestion {
        request.questions[min(currentIndex, max(0, request.questions.count - 1))]
    }

    private var progressText: String {
        "\(min(currentIndex + 1, request.questions.count))/\(request.questions.count)"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture {}

            VStack {
                Spacer()
                LuminaPanel(padding: 18) {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        if isReviewing {
                            reviewBody
                        } else {
                            questionBody
                        }
                        footer
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white, LuminaTheme.softAmber, LuminaTheme.amber],
                            center: .topLeading,
                            startRadius: 2,
                            endRadius: 34
                        )
                    )
                Image(systemName: "questionmark.bubble.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(LuminaTheme.deepInk)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(isReviewing ? "确认你的回答" : "Lumina 需要你补充一下")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(LuminaTheme.ink)
                Text(request.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(progressText)
                .font(.caption.weight(.bold))
                .foregroundStyle(LuminaTheme.deepInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(LuminaTheme.softAmber.opacity(0.36), in: Capsule())
        }
    }

    private var questionBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question.header.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(LuminaTheme.amber)
            Text(question.question)
                .font(.title3.weight(.bold))
                .foregroundStyle(LuminaTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                ForEach(question.options) { option in
                    Button {
                        choose(option)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(option.label)
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(LuminaTheme.ink)
                                    if option.recommended {
                                        Text("推荐")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(LuminaTheme.deepInk)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(LuminaTheme.softAmber.opacity(0.6), in: Capsule())
                                    }
                                }
                                if !option.description.isEmpty {
                                    Text(option.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer()
                            Image(systemName: answers[question.id]?.choiceID == option.id ? "checkmark.circle.fill" : "circle")
                                .font(.headline)
                                .foregroundStyle(answers[question.id]?.choiceID == option.id ? LuminaTheme.mint : .secondary.opacity(0.45))
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.56), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            if question.allowsCustomAnswer {
                VStack(alignment: .leading, spacing: 8) {
                    Text("自定义回答")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    TextField("输入你的偏好或补充说明", text: $customText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .padding(12)
                        .background(Color.white.opacity(0.56), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Button {
                        chooseCustom()
                    } label: {
                        Label("使用自定义回答", systemImage: "text.cursor")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(LuminaTheme.amber)
                    .disabled(customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var reviewBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("我会带着这些回答继续执行。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(request.questions) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(LuminaTheme.mint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.question)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(LuminaTheme.ink)
                        Text(answers[item.id]?.value ?? "未回答")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(11)
                .background(Color.white.opacity(0.52), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                cancel()
            } label: {
                Text("稍后再说")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(.secondary)

            Button {
                if isReviewing {
                    submit(request.questions.compactMap { answers[$0.id] })
                } else {
                    advance()
                }
            } label: {
                Label(isReviewing ? "继续执行" : "下一步", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(LuminaTheme.deepInk)
            .disabled(!isReviewing && answers[question.id] == nil)
        }
    }

    private func choose(_ option: LuminaAskUserChoice) {
        answers[question.id] = LuminaAskUserAnswer(
            questionID: question.id,
            choiceID: option.id,
            value: option.label,
            isCustom: false
        )
        customText = ""
        advance()
    }

    private func chooseCustom() {
        let trimmed = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        answers[question.id] = LuminaAskUserAnswer(questionID: question.id, value: trimmed, isCustom: true)
        customText = ""
        advance()
    }

    private func advance() {
        if currentIndex < request.questions.count - 1 {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                currentIndex += 1
                customText = ""
            }
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                isReviewing = true
            }
        }
    }
}
