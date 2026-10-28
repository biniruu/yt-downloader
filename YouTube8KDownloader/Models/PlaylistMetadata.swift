import Foundation
import Observation

/// Transfer DTO for playlist items across actor/task boundaries.
struct PlaylistVideoData: Sendable {
    let id: String
    let title: String
    let sourceURL: String
    let durationSeconds: Int?
    let thumbnailURL: URL?
    let uploader: String?
}

/// Transfer DTO for whole playlist metadata across actor/task boundaries.
struct PlaylistData: Sendable {
    let id: String
    let title: String
    let uploader: String?
    let sourceURL: String
    let thumbnailURL: URL?
    let items: [PlaylistVideoData]
}

/// Result of analyzing an arbitrary YouTube URL.
enum AnalyzedContent: Sendable {
    case video(VideoMetadata)
    case playlist(PlaylistData)
}

/// Quality target choice for whole playlist downloads.
enum PlaylistQualityOption: Hashable, Identifiable, Sendable {
    case sourceBest              // ⭐️ 각 영상의 원본 최고 화질 (자동)
    case tier(VideoQuality)      // 실제 지원 화질 이하 (예: 1080p FHD 이하)

    var id: String {
        switch self {
        case .sourceBest: return "sourceBest"
        case let .tier(q): return q.id
        }
    }

    var displayName: String {
        switch self {
        case .sourceBest:
            return "⭐️ 원본 최고 화질 (각각 자동)"
        case let .tier(q):
            return "\(q.displayName) 이하"
        }
    }
}

/// Represents an individual video item within a YouTube playlist.
@MainActor
@Observable
final class PlaylistItemMetadata: Identifiable {
    let id: String
    let title: String
    let sourceURL: String
    let durationSeconds: Int?
    let thumbnailURL: URL?
    let uploader: String?

    /// User selection state. Defaults to `true` (all videos included by default).
    /// Users uncheck items they wish to exclude from download.
    var isSelected: Bool = true

    /// Detected maximum vertical resolution height (e.g. 1080, 2160), fetched in real time.
    var maxResolutionHeight: Int?

    init(
        id: String,
        title: String,
        sourceURL: String,
        durationSeconds: Int? = nil,
        thumbnailURL: URL? = nil,
        uploader: String? = nil,
        isSelected: Bool = true,
        maxResolutionHeight: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.sourceURL = sourceURL
        self.durationSeconds = durationSeconds
        self.thumbnailURL = thumbnailURL
        self.uploader = uploader
        self.isSelected = isSelected
        self.maxResolutionHeight = maxResolutionHeight
    }

    /// Formatted duration string (e.g., "04:15" or "1:12:30").
    var formattedDuration: String? {
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        let hours = durationSeconds / 3600
        let minutes = (durationSeconds % 3600) / 60
        let seconds = durationSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    /// Formatted badge label (e.g., "4K", "1080p", "720p").
    var qualityBadgeLabel: String? {
        guard let h = maxResolutionHeight, h > 0 else { return nil }
        if h >= 4320 { return "8K" }
        if h >= 2160 { return "4K" }
        if h >= 1440 { return "1440p" }
        if h >= 1080 { return "1080p" }
        if h >= 720 { return "720p" }
        if h >= 480 { return "480p" }
        return "\(h)p"
    }

    /// Corresponding `VideoQuality` tier for this item's native maximum resolution.
    var qualityTier: VideoQuality {
        guard let h = maxResolutionHeight, h > 0 else { return .fhd1080p }
        if h >= 4320 { return .uhd8K }
        if h >= 2160 { return .uhd4K }
        if h >= 1440 { return .qhd1440p }
        if h >= 1080 { return .fhd1080p }
        if h >= 720 { return .hd720p }
        return .sd480p
    }
}

/// Represents analyzed metadata for an entire YouTube playlist.
@MainActor
@Observable
final class PlaylistMetadata: Identifiable {
    let id: String
    let title: String
    let uploader: String?
    let sourceURL: String
    let thumbnailURL: URL?
    var items: [PlaylistItemMetadata]

    init(
        id: String,
        title: String,
        uploader: String? = nil,
        sourceURL: String,
        thumbnailURL: URL? = nil,
        items: [PlaylistItemMetadata] = []
    ) {
        self.id = id
        self.title = title
        self.uploader = uploader
        self.sourceURL = sourceURL
        self.thumbnailURL = thumbnailURL
        self.items = items
    }

    convenience init(data: PlaylistData) {
        let domainItems = data.items.map { item in
            PlaylistItemMetadata(
                id: item.id,
                title: item.title,
                sourceURL: item.sourceURL,
                durationSeconds: item.durationSeconds,
                thumbnailURL: item.thumbnailURL,
                uploader: item.uploader,
                isSelected: true
            )
        }
        self.init(
            id: data.id,
            title: data.title,
            uploader: data.uploader,
            sourceURL: data.sourceURL,
            thumbnailURL: data.thumbnailURL,
            items: domainItems
        )
    }

    var totalCount: Int {
        items.count
    }

    var selectedCount: Int {
        items.filter { $0.isSelected }.count
    }

    var excludedCount: Int {
        items.filter { !$0.isSelected }.count
    }

    /// Maximum vertical resolution detected across all probed items so far.
    var detectedMaxHeight: Int? {
        items.compactMap { $0.maxResolutionHeight }.max()
    }

    /// Supported quality tiers filtered strictly by actual available video resolutions in this playlist.
    /// If highest detected is 1080p, 4K and 8K will NOT be included.
    var supportedQualities: [VideoQuality] {
        if let maxH = detectedMaxHeight, maxH > 0 {
            return VideoQuality.availableTiers(fromHeights: [maxH])
        }
        // Default conservative baseline before background resolution probing finishes
        return [.fhd1080p, .hd720p, .sd480p]
    }

    /// Selects all videos in the playlist.
    func selectAll() {
        for item in items {
            item.isSelected = true
        }
    }

    /// Deselects (excludes) all videos in the playlist.
    func deselectAll() {
        for item in items {
            item.isSelected = false
        }
    }
}

/// Raw JSON payload decoders for `yt-dlp --flat-playlist -J`.
struct YTDLPPlaylistRawMetadata: Decodable, Sendable {
    let id: String?
    let title: String?
    let uploader: String?
    let channel: String?
    let type: String?
    let entries: [RawPlaylistEntry]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case uploader
        case channel
        case type = "_type"
        case entries
    }

    struct RawPlaylistEntry: Decodable, Sendable {
        let id: String?
        let title: String?
        let url: String?
        let duration: Double?
        let uploader: String?
        let channel: String?
        let thumbnails: [RawThumbnail]?

        struct RawThumbnail: Decodable, Sendable {
            let url: String?
            let height: Int?
            let width: Int?
        }
    }
}
