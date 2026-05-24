import PersonalMemory
import SwiftUI

struct MemoryDeletionSheet: View {
    @ObservedObject var viewModel: PersonalMemoryViewModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.black.opacity(0.12))
                .ignoresSafeArea()
                .background(.ultraThinMaterial.opacity(0.28))
                .onTapGesture {
                    viewModel.dismissDeletionFlow()
                }

            sheet
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("删除记忆面板")
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            capsuleHandle
            if let deletion = viewModel.pendingDeletion {
                confirmationContent(deletion)
            } else {
                pickerContent
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .frame(maxWidth: 520)
        .background {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(LuminaTheme.softAmber.opacity(0.28))
                        .frame(width: 150, height: 150)
                        .blur(radius: 38)
                        .offset(x: -44, y: -64)
                }
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(LuminaTheme.mint.opacity(0.16))
                        .frame(width: 190, height: 190)
                        .blur(radius: 42)
                        .offset(x: 76, y: 72)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(Color.white.opacity(0.74), lineWidth: 1)
        }
        .shadow(color: LuminaTheme.deepInk.opacity(0.14), radius: 28, y: 16)
    }

    private var capsuleHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.72))
            .frame(width: 42, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)
    }

    private var pickerContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            sheetHeader(
                icon: "trash",
                title: "删除记忆",
                subtitle: viewModel.deleteDialogMessage
            )

            if viewModel.results.isEmpty {
                emptySelectableState
            } else {
                VStack(spacing: 10) {
                    ForEach(viewModel.results, id: \.chunk.id) { result in
                        Button {
                            viewModel.requestSingleDeletion(id: result.chunk.id, title: result.chunk.title)
                        } label: {
                            memoryOption(result)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if viewModel.stats.chunkCount > 0 {
                Button {
                    viewModel.requestDeleteAll()
                } label: {
                    destructiveAllRow
                }
                .buttonStyle(.plain)
            }

            Button {
                viewModel.dismissDeletionFlow()
            } label: {
                Text("取消")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(LuminaTheme.deepInk.opacity(0.66))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.white.opacity(0.56), in: Capsule())
                    .overlay {
                        Capsule().stroke(Color.white.opacity(0.68), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
        }
    }

    private func confirmationContent(_ deletion: MemoryDeletionRequest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeader(
                icon: "exclamationmark.triangle.fill",
                title: deletion.title,
                subtitle: deletion.message
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("本机删除确认")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LuminaTheme.rose)
                    .textCase(.uppercase)
                Text(confirmationSummary(for: deletion))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LuminaTheme.ink)
                    .lineLimit(3)
                Label("删除会立即写入本地 memory index，不会发送到云端。", systemImage: "lock.iphone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(LuminaTheme.rose.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(LuminaTheme.rose.opacity(0.18), lineWidth: 1)
            }

            HStack(spacing: 10) {
                Button {
                    viewModel.pendingDeletion = nil
                } label: {
                    Text("返回")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(LuminaTheme.deepInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.white.opacity(0.62), in: Capsule())
                        .overlay {
                            Capsule().stroke(Color.white.opacity(0.72), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)

                Button {
                    Task { await viewModel.confirmPendingDeletion() }
                } label: {
                    Label("确认删除", systemImage: "trash.fill")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(LuminaTheme.rose, in: Capsule())
                        .shadow(color: LuminaTheme.rose.opacity(0.24), radius: 14, y: 7)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sheetHeader(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(LuminaTheme.rose)
                .frame(width: 42, height: 42)
                .background(LuminaTheme.rose.opacity(0.10), in: Circle())
                .overlay {
                    Circle().stroke(Color.white.opacity(0.72), lineWidth: 1)
                }
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(LuminaTheme.ink)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label("Local only", systemImage: "lock.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LuminaTheme.mint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(LuminaTheme.mint.opacity(0.11), in: Capsule())
            }
        }
    }

    private func memoryOption(_ result: LuminaMemorySearchResult) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(result.chunk.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LuminaTheme.ink)
                    .lineLimit(1)
                Text("\(result.chunk.source.kind.rawValue)/\(result.chunk.source.identifier)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(result.chunk.sensitivity.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LuminaTheme.deepInk.opacity(0.56))
            }
            Spacer()
            Image(systemName: "trash")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(LuminaTheme.rose)
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.68), in: Circle())
        }
        .padding(14)
        .background(Color.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.74), lineWidth: 1)
        }
    }

    private var destructiveAllRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(LuminaTheme.rose)
                .frame(width: 38, height: 38)
                .background(LuminaTheme.rose.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("删除全部 \(viewModel.stats.chunkCount) 条记忆")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(LuminaTheme.rose)
                Text("清空整个本机记忆库")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(LuminaTheme.rose.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(LuminaTheme.rose.opacity(0.18), lineWidth: 1)
        }
    }

    private var emptySelectableState: some View {
        Text("当前筛选下没有可单独删除的记忆。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.white.opacity(0.52), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.72), lineWidth: 1)
            }
    }

    private func confirmationSummary(for deletion: MemoryDeletionRequest) -> String {
        switch deletion {
        case .one(_, let title):
            return title
        case .all(let count):
            return "全部 \(count) 条本地记忆"
        }
    }
}
