import AppKit
import SwiftUI

/// Top control panel containing the YouTube URL input, Analyze button,
/// analyzed video preview, quality Picker, and Add to Queue button.
@MainActor
struct AnalyzerHeaderView: View {
    @Bindable var viewModel: DownloaderViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !viewModel.dependencyStatus.isReady {
                dependencyWarningBanner
            }

            urlInputBar

            if let errorMessage = viewModel.analysisErrorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(10)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            // 상시 고정된 영상 분석 패널
            analysisPanel
        }
        .padding(18)
        .background(.background)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isAnalyzing)
    }

    // MARK: - Subviews

    private var dependencyWarningBanner: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "terminal.fill")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("필수 Homebrew 엔진 확인 필요")
                    .font(.subheadline.weight(.semibold))
                Text(missingToolsDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("설치 명령어 복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew install yt-dlp ffmpeg", forType: .string)
            }
            .controlSize(.small)

            Button("다시 확인") {
                viewModel.refreshDependencyStatus()
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    private var missingToolsDescription: String {
        var missing: [String] = []
        if !viewModel.dependencyStatus.isYtDlpInstalled {
            missing.append("/opt/homebrew/bin/yt-dlp")
        }
        if !viewModel.dependencyStatus.isFfmpegInstalled {
            missing.append("/opt/homebrew/bin/ffmpeg")
        }
        return "누락된 경로: \(missing.joined(separator: ", ")) · 터미널에서 `brew install yt-dlp ffmpeg`를 실행해 주세요."
    }

    private var urlInputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("YouTube 8K Downloader", systemImage: "play.rectangle.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text("v1.3.2")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15), in: Capsule())
                    .foregroundStyle(.blue)

                Spacer()

                Text("저장 경로: ~/Downloads")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.5), in: Capsule())
            }

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)

                    TextField("유튜브 영상 또는 재생목록 링크 입력 (예: https://www.youtube.com/playlist?list=...)", text: $viewModel.urlInput)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .onSubmit {
                            if viewModel.canAnalyze {
                                Task { await viewModel.analyzeURL() }
                            }
                        }

                    if !viewModel.urlInput.isEmpty {
                        Button {
                            viewModel.urlInput = ""
                            viewModel.analysisErrorMessage = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("입력 지우기")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                )

                Button {
                    viewModel.pasteFromClipboard()
                } label: {
                    Label("붙여넣기", systemImage: "doc.on.clipboard")
                }
                .help("클립보드에서 링크 붙여넣기")

                Button {
                    Task {
                        await viewModel.analyzeURL()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if viewModel.isAnalyzing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                        Text(viewModel.isAnalyzing ? "분석 중..." : "분석(Analyze)")
                            .fontWeight(.semibold)
                    }
                    .frame(minWidth: 115)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canAnalyze)
            }
        }
    }

    private var analysisPanel: some View {
        Group {
            if let metadata = viewModel.analyzedMetadata {
                HStack(alignment: .top, spacing: 14) {
                    thumbnailPreview(url: metadata.thumbnailURL)
                    analyzedDetailContent(metadata: metadata)
                }
            } else if let playlist = viewModel.analyzedPlaylist {
                playlistAnalysisContent(playlist: playlist)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    placeholderThumbnail
                    placeholderDetailContent
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .overlay {
            if viewModel.isAnalyzing {
                analyzingOverlay
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func playlistAnalysisContent(playlist: PlaylistMetadata) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            playlistHeaderRow(playlist: playlist)
            playlistControlsRow(playlist: playlist)
            Divider()
            playlistChecklistScrollView(playlist: playlist)
            playlistFooterRow(playlist: playlist)
        }
    }

    private func playlistHeaderRow(playlist: PlaylistMetadata) -> some View {
        HStack(alignment: .top, spacing: 14) {
            thumbnailPreview(url: playlist.thumbnailURL)

            VStack(alignment: .leading, spacing: 6) {
                Text(playlist.title)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 10) {
                    if let uploader = playlist.uploader, !uploader.isEmpty {
                        Label(uploader, systemImage: "person.crop.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet.rectangle.portrait.fill")
                            .font(.caption2)
                        Text("재생목록: 총 \(playlist.totalCount)개 영상")
                            .font(.caption2.weight(.bold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.purple.opacity(0.15), in: Capsule())
                    .foregroundStyle(.purple)
                }

                if playlist.excludedCount == 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("모든 영상(\(playlist.totalCount)개)이 다운로드 대상으로 선택되어 있습니다.")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.orange)
                        Text("\(playlist.totalCount)개 중 \(playlist.selectedCount)개 선택됨 (\(playlist.excludedCount)개 제외)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()
        }
    }

    private func playlistControlsRow(playlist: PlaylistMetadata) -> some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 6) {
                Text("일괄 화질")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("일괄 화질", selection: $viewModel.selectedPlaylistQualityOption) {
                    ForEach(viewModel.availablePlaylistQualityOptions) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            HStack(spacing: 6) {
                Text("포맷")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("포맷", selection: $viewModel.selectedConversionMode) {
                    ForEach(DownloadConversionMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }

            Spacer()

            HStack(spacing: 6) {
                Button("전체 선택") {
                    viewModel.selectAllPlaylistItems()
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(playlist.selectedCount == playlist.totalCount)

                Button("전체 제외") {
                    viewModel.deselectAllPlaylistItems()
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(playlist.selectedCount == 0)
            }
        }
    }

    private func playlistChecklistScrollView(playlist: PlaylistMetadata) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("다운로드에서 제외할 영상은 체크박스를 해제하세요 (체크 해제 = 제외)", systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(playlist.items.enumerated()), id: \.element.id) { index, item in
                        playlistItemRow(index: index, item: item)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 170)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
    }

    private func playlistItemRow(index: Int, item: PlaylistItemMetadata) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { item.isSelected },
                set: { item.isSelected = $0 }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Text(String(format: "%d.", index + 1))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)

            Text(item.title)
                .font(.callout)
                .lineLimit(1)
                .strikethrough(!item.isSelected, color: .secondary.opacity(0.8))
                .foregroundStyle(item.isSelected ? Color.primary : Color.secondary.opacity(0.6))

            // 최고 해상도 뱃지 (실시간 감지)
            if let badge = item.qualityBadgeLabel {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(qualityBadgeColor(for: badge).opacity(0.15), in: Capsule())
                    .foregroundStyle(qualityBadgeColor(for: badge))
            } else {
                HStack(spacing: 3) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("화질 확인 중")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)
            }

            Spacer()

            if let duration = item.formattedDuration {
                Text(duration)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !item.isSelected {
                Text("제외됨")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.18), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            item.isSelected ? Color.clear : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    private func playlistFooterRow(playlist: PlaylistMetadata) -> some View {
        HStack(alignment: .center) {
            Text("선택된 영상: \(playlist.selectedCount)개 (\(playlist.excludedCount)개 제외)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                viewModel.addToQueue()
            } label: {
                Label(
                    playlist.selectedCount > 0 ? "선택한 \(playlist.selectedCount)개 영상 대기열에 추가" : "다운로드할 영상을 선택해 주세요",
                    systemImage: "arrow.down.circle.fill"
                )
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(!viewModel.canAddToQueue)
        }
    }

    private func qualityBadgeColor(for badge: String) -> Color {
        switch badge {
        case "8K", "4K":
            return .purple
        case "1440p", "1080p":
            return .blue
        case "720p":
            return .teal
        default:
            return .secondary
        }
    }

    private func analyzedDetailContent(metadata: VideoMetadata) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(metadata.title)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 10) {
                if let uploader = metadata.uploader, !uploader.isEmpty {
                    Label(uploader, systemImage: "person.crop.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let duration = metadata.formattedDuration {
                    Label(duration, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Codec & QuickTime status badges
            codecStatusBadgeRow

            Spacer(minLength: 4)

            HStack(alignment: .center, spacing: 12) {
                Picker("화질 선택", selection: $viewModel.selectedQuality) {
                    ForEach(viewModel.availableQualitiesForAnalyzedVideo) { quality in
                        Text(quality.displayName)
                            .tag(quality)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180)

                if let profile = viewModel.currentTierCodecProfile,
                   profile.quickTimeStatus == .needsConversion {
                    Picker("포맷 선택", selection: $viewModel.selectedConversionMode) {
                        ForEach(DownloadConversionMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 290)
                }

                Spacer()

                Button {
                    viewModel.addToQueue()
                } label: {
                    Label("대기열에 추가(Add to Queue)", systemImage: "plus.circle.fill")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!viewModel.canAddToQueue)
            }
        }
    }

    private var placeholderDetailContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("분석 대기 중")
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text("상단에 유튜브 영상 링크를 입력하고 [분석(Analyze)]을 누르면 상세 정보가 표시됩니다.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "film")
                        .font(.caption2)
                    Text("코덱: 대기")
                        .font(.caption2.weight(.medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .foregroundStyle(.tertiary)

                HStack(spacing: 4) {
                    Image(systemName: "questionmark.circle")
                        .font(.caption2)
                    Text("QuickTime: 대기")
                        .font(.caption2.weight(.medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            HStack(alignment: .center, spacing: 12) {
                Picker("화질 선택", selection: .constant(VideoQuality.uhd8K)) {
                    Text("화질 선택 대기").tag(VideoQuality.uhd8K)
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180)
                .disabled(true)

                Spacer()

                Button {
                } label: {
                    Label("대기열에 추가(Add to Queue)", systemImage: "plus.circle.fill")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(true)
            }
        }
    }

    private var placeholderThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))

            VStack(spacing: 6) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text("미리보기 대기")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 152, height: 86)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var analyzingOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)

                VStack(alignment: .leading, spacing: 2) {
                    Text("유튜브 영상 스트림 분석 중...")
                        .font(.subheadline.weight(.semibold))
                    Text("최고 화질(8K/4K) 및 코덱 정보를 확인하고 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            )
        }
        .allowsHitTesting(true)
    }

    private var codecStatusBadgeRow: some View {
        HStack(spacing: 8) {
            if let profile = viewModel.currentTierCodecProfile {
                // Codec badge: "비디오: H.264 · 오디오: AAC"
                HStack(spacing: 4) {
                    Image(systemName: "film")
                        .font(.caption2)
                    Text("비디오: \(profile.videoCodecDisplay) · 오디오: \(profile.audioCodecDisplay)")
                        .font(.caption2.weight(.medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: Capsule())

                // QuickTime compatibility badge
                quickTimeBadge(for: profile.quickTimeStatus)
            }
        }
    }

    @ViewBuilder
    private func quickTimeBadge(for status: QuickTimePlayableStatus) -> some View {
        switch status {
        case .nativePlayable:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(status.badgeText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.green.opacity(0.12), in: Capsule())

        case .needsConversion:
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .foregroundStyle(.orange)
                Text(status.badgeText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.12), in: Capsule())

        case .unsupported:
            HStack(spacing: 4) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.purple)
                Text(status.badgeText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.purple)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.purple.opacity(0.12), in: Capsule())
        }
    }

    private func thumbnailPreview(url: URL?) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .aspectRatio(16.0 / 9.0, contentMode: .fill)
            case .failure:
                thumbnailPlaceholder(icon: "film")
            case .empty:
                ZStack {
                    thumbnailPlaceholder(icon: "photo")
                    ProgressView()
                        .controlSize(.small)
                }
            @unknown default:
                thumbnailPlaceholder(icon: "film")
            }
        }
        .frame(width: 152, height: 86)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private func thumbnailPlaceholder(icon: String) -> some View {
        ZStack {
            Color.secondary.opacity(0.15)
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}
