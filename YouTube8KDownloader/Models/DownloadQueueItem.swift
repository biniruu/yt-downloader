import Foundation
import Observation

/// Lifecycle states for a queued download item.
enum DownloadItemStatus: Equatable, Sendable {
    case waiting
    case downloading
    case muxing
    case completed
    case error(String)

    /// Localized Korean display label matching the specification.
    var displayText: String {
        switch self {
        case .waiting:
            return "대기 중"
        case .downloading:
            return "다운로드 중"
        case .muxing:
            return "병합 및 변환 중"
        case .completed:
            return "완료"
        case .error:
            return "에러"
        }
    }

    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }

    var isActive: Bool {
        switch self {
        case .downloading, .muxing:
            return true
        default:
            return false
        }
    }
}

/// Observable model representing a single video in the download queue.
@MainActor
@Observable
final class DownloadQueueItem: Identifiable {
    let id: UUID
    let videoID: String
    let sourceURL: String
    let title: String
    let thumbnailURL: URL?
    let uploader: String?
    let durationText: String?
    let selectedQuality: VideoQuality
    let conversionMode: DownloadConversionMode?
    let targetFormatSelector: String
    let targetAdditionalArguments: [String]
    let quickTimeStatus: QuickTimePlayableStatus
    let expectedCodecsText: String
    let createdAt: Date

    var status: DownloadItemStatus
    /// Download progress percentage from 0.0 to 100.0.
    var progress: Double
    /// Optional transfer speed string parsed from `yt-dlp` (e.g., "38.2MiB/s").
    var speedText: String?
    /// Optional ETA string parsed from `yt-dlp` (e.g., "00:14").
    var etaText: String?
    /// Final saved file URL inside `~/Downloads`.
    var savedFileURL: URL?
    /// Verified codec string measured via `ffprobe` after download finishes (e.g., "H.264 / AAC").
    var verifiedCodecsText: String?
    /// Detailed error message when `status` is `.error`.
    var errorDetail: String?

    init(
        id: UUID = UUID(),
        metadata: VideoMetadata,
        selectedQuality: VideoQuality,
        conversionMode: DownloadConversionMode? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.videoID = metadata.id
        self.sourceURL = metadata.sourceURL
        self.title = metadata.title
        self.thumbnailURL = metadata.thumbnailURL
        self.uploader = metadata.uploader
        self.durationText = metadata.formattedDuration
        self.selectedQuality = selectedQuality
        self.conversionMode = conversionMode
        self.createdAt = createdAt
        self.status = .waiting
        self.progress = 0.0

        let profile = metadata.profile(for: selectedQuality)
        self.quickTimeStatus = profile?.quickTimeStatus ?? (selectedQuality.usesOriginalContainerMuxing ? .unsupported : .nativePlayable)
        self.expectedCodecsText = "\(profile?.videoCodecDisplay ?? "기본") / \(profile?.audioCodecDisplay ?? "기본")"

        // Use direct format_id selector if available, eliminating mismatch
        if let profile {
            if profile.quickTimeStatus == .nativePlayable {
                self.targetFormatSelector = profile.targetFormatSelector
                self.targetAdditionalArguments = selectedQuality.buildAdditionalArguments(profile: profile, conversionMode: .quickTimeMP4)
            } else if profile.quickTimeStatus == .needsConversion {
                let mode = conversionMode ?? .quickTimeMP4
                self.targetFormatSelector = profile.targetFormatSelector
                self.targetAdditionalArguments = selectedQuality.buildAdditionalArguments(profile: profile, conversionMode: mode)
            } else {
                self.targetFormatSelector = profile.targetFormatSelector
                self.targetAdditionalArguments = selectedQuality.buildAdditionalArguments(profile: profile, conversionMode: .keepOriginal)
            }
        } else {
            self.targetFormatSelector = selectedQuality.formatSelector
            let mode = conversionMode ?? .quickTimeMP4
            self.targetAdditionalArguments = selectedQuality.buildAdditionalArguments(profile: nil, conversionMode: mode)
        }
    }

    /// Convenience initializer for playlist items or standalone items without pre-probed format profiles.
    init(
        id: UUID = UUID(),
        videoID: String,
        sourceURL: String,
        title: String,
        thumbnailURL: URL?,
        uploader: String?,
        durationText: String?,
        selectedQuality: VideoQuality,
        conversionMode: DownloadConversionMode? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.videoID = videoID
        self.sourceURL = sourceURL
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.uploader = uploader
        self.durationText = durationText
        self.selectedQuality = selectedQuality
        self.conversionMode = conversionMode
        self.createdAt = createdAt
        self.status = .waiting
        self.progress = 0.0

        let effectiveMode = conversionMode ?? .quickTimeMP4
        self.targetFormatSelector = selectedQuality.formatSelector
        self.targetAdditionalArguments = selectedQuality.buildAdditionalArguments(profile: nil, conversionMode: effectiveMode)

        if selectedQuality.usesOriginalContainerMuxing {
            self.quickTimeStatus = .unsupported
            self.expectedCodecsText = "WebM 원본"
        } else {
            switch effectiveMode {
            case .quickTimeMP4:
                self.quickTimeStatus = .nativePlayable
                self.expectedCodecsText = "H.264 / AAC (MP4)"
            case .keepOriginal:
                self.quickTimeStatus = .needsConversion
                self.expectedCodecsText = "WebM / Opus"
            }
        }
    }

    /// Formatted percentage string (e.g., "68.4%").
    var formattedProgressPercentage: String {
        String(format: "%.1f%%", min(max(progress, 0.0), 100.0))
    }

    /// Normalized progress value between 0.0 and 1.0 for SwiftUI `ProgressView`.
    var normalizedProgress: Double {
        min(max(progress / 100.0, 0.0), 1.0)
    }
}
