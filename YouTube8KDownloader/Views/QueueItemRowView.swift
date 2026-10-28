import SwiftUI

/// Row view displaying a single queued video item, its thumbnail, selected quality,
/// live progress bar + percentage text, status badge, and folder action button.
@MainActor
struct QueueItemRowView: View {
    let item: DownloadQueueItem
    let onOpenInDownloads: (DownloadQueueItem) -> Void
    let onRetry: (DownloadQueueItem) -> Void
    let onRemove: (DownloadQueueItem) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            thumbnailView

            VStack(alignment: .leading, spacing: 7) {
                // Title & Status Row
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer()

                    statusBadge
                }

                // Quality & Metadata Row
                HStack(spacing: 8) {
                    Text(item.selectedQuality.badgeLabel)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(qualityBadgeColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(qualityBadgeColor)

                    if let verified = item.verifiedCodecsText {
                        Text("[\(verified)]")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    } else {
                        Text("[\(item.expectedCodecsText)]")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let speed = item.speedText {
                        Text("· \(speed)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if let eta = item.etaText {
                        Text("· 남은 시간 \(eta)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(item.formattedProgressPercentage)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(statusColor)
                }

                // Progress Bar
                ProgressView(value: item.normalizedProgress, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(statusColor)

                // Error detail or Action Row
                HStack(spacing: 10) {
                    if let errorDetail = item.errorDetail {
                        Text(errorDetail)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    } else if let savedURL = item.savedFileURL, item.status.isCompleted {
                        Text(savedURL.lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(statusDescriptionText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if case .error = item.status {
                        Button {
                            onRetry(item)
                        } label: {
                            Label("재시도", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .controlSize(.small)
                    }

                    Button {
                        onOpenInDownloads(item)
                    } label: {
                        Label("다운로드 폴더에서 열기", systemImage: "folder")
                            .font(.caption.weight(.medium))
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(!item.status.isCompleted)

                    Button(role: .destructive) {
                        onRemove(item)
                    } label: {
                        Label("삭제", systemImage: "trash")
                            .font(.caption)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help(removeButtonHelpText)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Subviews & Helpers

    private var thumbnailView: some View {
        AsyncImage(url: item.thumbnailURL) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .aspectRatio(16.0 / 9.0, contentMode: .fill)
            case .failure:
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "play.slash")
                        .foregroundStyle(.secondary)
                }
            case .empty:
                ZStack {
                    Color.secondary.opacity(0.12)
                    ProgressView()
                        .controlSize(.small)
                }
            @unknown default:
                Color.secondary.opacity(0.15)
            }
        }
        .frame(width: 128, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            if item.status == .downloading || item.status == .muxing {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: statusIconName)
                    .font(.caption2.weight(.bold))
            }

            Text(item.status.displayText)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(statusColor.opacity(0.14), in: Capsule())
        .foregroundStyle(statusColor)
    }

    private var statusIconName: String {
        switch item.status {
        case .waiting:
            return "clock.fill"
        case .downloading:
            return "arrow.down.circle.fill"
        case .muxing:
            return "film.stack.fill"
        case .completed:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .waiting:
            return .secondary
        case .downloading:
            return .blue
        case .muxing:
            return .purple
        case .completed:
            return .green
        case .error:
            return .red
        }
    }

    private var qualityBadgeColor: Color {
        switch item.selectedQuality {
        case .uhd8K:
            return .pink
        case .uhd4K:
            return .purple
        case .qhd1440p:
            return .indigo
        case .fhd1080p, .hd720p, .sd480p:
            return .blue
        }
    }

    private var statusDescriptionText: String {
        switch item.status {
        case .waiting:
            return "순차 다운로드 대기열에서 차례를 기다리는 중입니다..."
        case .downloading:
            return "yt-dlp 스트림 다운로드 진행 중..."
        case .muxing:
            return "ffmpeg로 비디오/오디오 원본 스트림 병합(Muxing) 중 (재인코딩 없음)..."
        case .completed:
            return "~/Downloads 폴더에 저장 완료"
        case .error:
            return "다운로드 중 오류가 발생했습니다."
        }
    }

    private var removeButtonHelpText: String {
        if item.status.isActive {
            return "다운로드를 중단하고 대기열 목록 및 다운로드 파일 삭제"
        } else if item.status == .waiting {
            return "대기열 목록에서 제거"
        } else {
            return "목록에서 제거"
        }
    }
}
