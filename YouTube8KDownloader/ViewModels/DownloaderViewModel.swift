import AppKit
import Foundation
import Observation

/// Primary ViewModel driving the YouTube 8K Downloader interface using macOS 14 `@Observable`.
@MainActor
@Observable
final class DownloaderViewModel {
    // MARK: - Top Control State
    var urlInput: String = ""
    var isAnalyzing: Bool = false
    var analysisErrorMessage: String?
    var analyzedMetadata: VideoMetadata?
    var analyzedPlaylist: PlaylistMetadata?
    var selectedQuality: VideoQuality = .uhd8K
    var selectedPlaylistQualityOption: PlaylistQualityOption = .sourceBest
    var selectedConversionMode: DownloadConversionMode = .quickTimeMP4

    // MARK: - Queue State
    var queueItems: [DownloadQueueItem] = []

    // MARK: - System Dependency Status
    var dependencyStatus: EngineDependencyStatus

    // MARK: - Private Services
    private let ytDlpService: YTDLPService
    private let queueActor: DownloadQueueActor

    init(
        ytDlpService: YTDLPService = YTDLPService(),
        queueActor: DownloadQueueActor = DownloadQueueActor()
    ) {
        self.ytDlpService = ytDlpService
        self.queueActor = queueActor
        self.dependencyStatus = YTDLPService.checkDependencies()
    }

    // MARK: - Computed Properties

    var isPlaylistMode: Bool {
        analyzedPlaylist != nil
    }

    var canAnalyze: Bool {
        !urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isAnalyzing
    }

    var canAddToQueue: Bool {
        if isPlaylistMode {
            return canAddPlaylistToQueue
        }
        return analyzedMetadata != nil && !isAnalyzing
    }

    var canAddPlaylistToQueue: Bool {
        guard let playlist = analyzedPlaylist, !isAnalyzing else { return false }
        return playlist.selectedCount > 0
    }

    var availableQualitiesForAnalyzedVideo: [VideoQuality] {
        if let playlist = analyzedPlaylist {
            return playlist.supportedQualities
        }
        return analyzedMetadata?.availableQualities ?? VideoQuality.allCases
    }

    /// Supported quality choices for playlist downloads, led by `⭐️ 원본 최고 화질 (각각 자동)`
    /// followed strictly by the actual available resolution tiers in this playlist.
    var availablePlaylistQualityOptions: [PlaylistQualityOption] {
        guard let playlist = analyzedPlaylist else {
            return [.sourceBest, .tier(.fhd1080p), .tier(.hd720p), .tier(.sd480p)]
        }
        return [.sourceBest] + playlist.supportedQualities.map { .tier($0) }
    }

    /// The detected codec and QuickTime compatibility profile for the currently selected quality.
    var currentTierCodecProfile: TierCodecProfile? {
        analyzedMetadata?.profile(for: selectedQuality)
    }

    var activeDownloadCount: Int {
        queueItems.filter { $0.status.isActive }.count
    }

    var waitingDownloadCount: Int {
        queueItems.filter { $0.status == .waiting }.count
    }

    var completedDownloadCount: Int {
        queueItems.filter { $0.status.isCompleted }.count
    }

    // MARK: - Actions

    /// Refreshes the status of `/opt/homebrew/bin/yt-dlp` and `/opt/homebrew/bin/ffmpeg`.
    func refreshDependencyStatus() {
        dependencyStatus = YTDLPService.checkDependencies()
    }

    /// Pastes text from the macOS general pasteboard into `urlInput`.
    func pasteFromClipboard() {
        if let pasted = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pasted.isEmpty {
            urlInput = pasted
            analysisErrorMessage = nil
        }
    }

    /// Analyzes the entered YouTube URL and populates available quality options.
    func analyzeURL() async {
        refreshDependencyStatus()
        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            analysisErrorMessage = "유튜브 영상 또는 재생목록 링크를 입력해 주세요."
            return
        }

        isAnalyzing = true
        analysisErrorMessage = nil
        analyzedMetadata = nil
        analyzedPlaylist = nil

        do {
            let content = try await ytDlpService.analyzeContent(url: trimmed)
            switch content {
            case let .video(metadata):
                analyzedMetadata = metadata
                analyzedPlaylist = nil
                selectedQuality = metadata.highestAvailableQuality
            case let .playlist(playlistData):
                let playlist = PlaylistMetadata(data: playlistData)
                analyzedPlaylist = playlist
                analyzedMetadata = nil
                selectedPlaylistQualityOption = .sourceBest

                // Start real-time resolution probing in the background
                startStreamingPlaylistResolutions(playlistURL: trimmed)
            }
        } catch {
            analysisErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        isAnalyzing = false
    }

    /// Appends the currently analyzed single video or playlist to the download queue.
    func addToQueue() {
        if isPlaylistMode {
            addPlaylistToQueue()
        } else {
            addSingleVideoToQueue()
        }
    }

    /// Appends the analyzed single video and selected quality to the download queue.
    private func addSingleVideoToQueue() {
        guard let metadata = analyzedMetadata else { return }

        let newItem = DownloadQueueItem(
            metadata: metadata,
            selectedQuality: selectedQuality,
            conversionMode: selectedConversionMode
        )
        queueItems.insert(newItem, at: 0)

        enqueueJob(for: newItem)
    }

    /// Appends all selected items in the playlist to the download queue and starts processing.
    func addPlaylistToQueue() {
        guard let playlist = analyzedPlaylist else { return }
        let selectedItems = playlist.items.filter { $0.isSelected }
        guard !selectedItems.isEmpty else { return }

        var newQueueItems: [DownloadQueueItem] = []
        for item in selectedItems {
            let targetQuality: VideoQuality
            switch selectedPlaylistQualityOption {
            case .sourceBest:
                targetQuality = item.qualityTier
            case let .tier(cap):
                targetQuality = min(item.qualityTier, cap)
            }

            let queueItem = DownloadQueueItem(
                videoID: item.id,
                sourceURL: item.sourceURL,
                title: item.title,
                thumbnailURL: item.thumbnailURL,
                uploader: item.uploader,
                durationText: item.formattedDuration,
                selectedQuality: targetQuality,
                conversionMode: selectedConversionMode
            )
            newQueueItems.append(queueItem)
        }

        // Insert playlist items as a block at the top so item 1 is at the top of the UI
        queueItems.insert(contentsOf: newQueueItems, at: 0)

        // Enqueue sequentially in FIFO order (Item 1 first, Item 2 next, ...)
        for item in newQueueItems {
            enqueueJob(for: item)
        }
    }

    /// Launches background real-time resolution probing for the playlist videos.
    private func startStreamingPlaylistResolutions(playlistURL: String) {
        Task { [weak self] in
            guard let self else { return }
            await self.ytDlpService.streamPlaylistResolutions(playlistURL: playlistURL) { [weak self] videoID, height in
                Task { @MainActor [weak self] in
                    guard let self, let currentPlaylist = self.analyzedPlaylist else { return }
                    if let item = currentPlaylist.items.first(where: { $0.id == videoID }) {
                        item.maxResolutionHeight = height
                    }
                }
            }
        }
    }

    /// Selects all videos in the analyzed playlist.
    func selectAllPlaylistItems() {
        analyzedPlaylist?.selectAll()
    }

    /// Excludes (deselects) all videos in the analyzed playlist.
    func deselectAllPlaylistItems() {
        analyzedPlaylist?.deselectAll()
    }

    /// Toggles the download selection state for a playlist item.
    func togglePlaylistItem(_ item: PlaylistItemMetadata) {
        item.isSelected.toggle()
    }

    /// Retries a failed queue item by resetting its state and re-submitting it to the serial queue actor.
    func retryItem(_ item: DownloadQueueItem) {
        item.status = .waiting
        item.progress = 0.0
        item.speedText = nil
        item.etaText = nil
        item.errorDetail = nil
        enqueueJob(for: item)
    }

    /// Removes an item from the queue list. If it is actively downloading or waiting,
    /// it cancels the background job, terminates active download processes, and deletes incomplete/downloaded files from ~/Downloads.
    func removeItem(_ item: DownloadQueueItem) {
        let itemID = item.id
        let videoID = item.videoID
        let quality = item.selectedQuality
        var recordedPaths: Set<String> = []
        if let savedURL = item.savedFileURL {
            recordedPaths.insert(savedURL.path)
        }

        let isCurrentlyActive = item.status.isActive

        // 1. 대기열 목록에서 즉시 제거
        queueItems.removeAll { $0.id == itemID }

        // 2. 백그라운드 큐 액터 취소 및 다운로드 중이던 파일 디스크 삭제
        Task {
            let (wasActive, _, actorPaths) = await queueActor.cancelJob(itemID: itemID)
            if isCurrentlyActive || wasActive {
                recordedPaths.formUnion(actorPaths)
                YTDLPService.cleanupIncompleteFiles(
                    videoID: videoID,
                    quality: quality,
                    recordedPaths: recordedPaths
                )

                // 프로세스 완전 종료 후 잔류 파일 2차 검사 및 청소
                try? await Task.sleep(nanoseconds: 300_000_000)
                YTDLPService.cleanupIncompleteFiles(
                    videoID: videoID,
                    quality: quality,
                    recordedPaths: recordedPaths
                )
            }
        }
    }

    /// Clears all completed items from the queue list.
    func clearCompletedItems() {
        queueItems.removeAll { $0.status.isCompleted }
    }

    /// Opens `~/Downloads` in Finder and selects the downloaded video file if it exists on disk.
    func openInDownloadsFolder(for item: DownloadQueueItem) {
        let downloadsFolderURL = YTDLPService.downloadsDirectoryURL
        if let savedURL = item.savedFileURL,
           FileManager.default.fileExists(atPath: savedURL.path),
           savedURL.path != downloadsFolderURL.path {
            NSWorkspace.shared.activateFileViewerSelecting([savedURL])
        } else {
            NSWorkspace.shared.open(downloadsFolderURL)
        }
    }

    /// Opens the `~/Downloads` folder directly in Finder.
    func openDownloadsDirectory() {
        NSWorkspace.shared.open(YTDLPService.downloadsDirectoryURL)
    }

    // MARK: - Internal Queue Handling

    private func enqueueJob(for item: DownloadQueueItem) {
        let job = QueuedDownloadJob(
            itemID: item.id,
            videoID: item.videoID,
            sourceURL: item.sourceURL,
            quality: item.selectedQuality,
            customFormatSelector: item.targetFormatSelector,
            customAdditionalArguments: item.targetAdditionalArguments
        )

        Task {
            await queueActor.enqueue(job: job) { [weak self] itemID, update in
                self?.handleQueueUpdate(itemID: itemID, update: update)
            }
        }
    }

    private func handleQueueUpdate(itemID: UUID, update: QueueTaskUpdate) {
        guard let item = queueItems.first(where: { $0.id == itemID }) else { return }

        switch update {
        case .started:
            item.status = .downloading
            item.errorDetail = nil

        case let .progress(percent, speed, eta):
            if item.status != .muxing {
                item.status = .downloading
            }
            item.progress = max(item.progress, percent)
            if let speed {
                item.speedText = speed
            }
            if let eta {
                item.etaText = eta
            }

        case let .destinationDetected(url):
            item.savedFileURL = url

        case let .muxing(outputURL):
            item.status = .muxing
            item.progress = 100.0
            item.speedText = nil
            item.etaText = nil
            if let outputURL {
                item.savedFileURL = outputURL
            }

        case let .completed(outputURL, verifiedCodecs):
            item.status = .completed
            item.progress = 100.0
            item.speedText = nil
            item.etaText = nil
            if let verifiedCodecs {
                item.verifiedCodecsText = verifiedCodecs
            }
            if item.savedFileURL == nil || outputURL.path != YTDLPService.downloadsDirectoryURL.path {
                item.savedFileURL = outputURL
            }

        case let .failed(message):
            item.status = .error(message)
            item.errorDetail = message
            item.speedText = nil
            item.etaText = nil
        }
    }
}
