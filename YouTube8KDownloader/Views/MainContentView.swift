import SwiftUI

/// Main window content view split into the top analyzer control area and the bottom queue list.
@MainActor
struct MainContentView: View {
    @State private var viewModel = DownloaderViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // 1. Top Control Area (Link Input, Analyze Button, Quality Picker, Add to Queue)
            // 창 크기 변경 시 상단 영역의 높이는 자체 콘텐츠 크기로 고정되고,
            // 재생목록 목록 표시 시 필요한 만큼만 자연스럽게 확장되며 불필요한 빈 여백이 생기지 않도록 설정.
            AnalyzerHeaderView(viewModel: viewModel)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // 2. Queue Section Toolbar
            queueToolbar

            Divider()

            // 3. Bottom Queue List
            if viewModel.queueItems.isEmpty {
                emptyQueuePlaceholder
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.queueItems) { item in
                            QueueItemRowView(
                                item: item,
                                onOpenInDownloads: { selected in
                                    viewModel.openInDownloadsFolder(for: selected)
                                },
                                onRetry: { selected in
                                    viewModel.retryItem(selected)
                                },
                                onRemove: { selected in
                                    viewModel.removeItem(selected)
                                }
                            )
                        }
                    }
                    .padding(16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
            }
        }
        .frame(minWidth: 820, minHeight: 580)
    }

    // MARK: - Subviews

    private var queueToolbar: some View {
        HStack(spacing: 14) {
            Label("다운로드 대기열 (Queue)", systemImage: "list.bullet.rectangle.portrait")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 8) {
                counterPill(title: "진행", count: viewModel.activeDownloadCount, color: .blue)
                counterPill(title: "대기", count: viewModel.waitingDownloadCount, color: .secondary)
                counterPill(title: "완료", count: viewModel.completedDownloadCount, color: .green)
            }

            Spacer()

            if viewModel.completedDownloadCount > 0 {
                Button("완료 항목 정리") {
                    viewModel.clearCompletedItems()
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }

            Button {
                viewModel.openDownloadsDirectory()
            } label: {
                Label("~/Downloads 열기", systemImage: "folder.fill")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func counterPill(title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(count > 0 ? color : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }

    private var emptyQueuePlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("대기열이 비어 있습니다")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("상단에 유튜브 링크를 입력하고 '분석(Analyze)'을 누른 뒤 원하는 화질(8K/4K/1440p/1080p)을 선택하여 대기열에 추가하세요.\n추가된 영상은 Actor 기반 백그라운드 큐에서 1개씩 순차적으로 다운로드됩니다.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.3))
    }
}
