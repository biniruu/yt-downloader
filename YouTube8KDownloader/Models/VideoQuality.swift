import Foundation

/// Supported video quality tiers and their corresponding yt-dlp format selection strategies.
enum VideoQuality: String, CaseIterable, Identifiable, Codable, Sendable {
    case uhd8K = "8K"
    case uhd4K = "4K"
    case qhd1440p = "1440p"
    case fhd1080p = "1080p"
    case hd720p = "720p"
    case sd480p = "480p"

    var id: String { rawValue }

    /// Numeric vertical resolution (height in pixels).
    var height: Int {
        switch self {
        case .uhd8K: return 4320
        case .uhd4K: return 2160
        case .qhd1440p: return 1440
        case .fhd1080p: return 1080
        case .hd720p: return 720
        case .sd480p: return 480
        }
    }

    /// User-facing title shown in the quality picker dropdown.
    var displayName: String {
        switch self {
        case .uhd8K: return "8K UHD (4320p)"
        case .uhd4K: return "4K UHD (2160p)"
        case .qhd1440p: return "1440p QHD"
        case .fhd1080p: return "1080p FHD"
        case .hd720p: return "720p HD"
        case .sd480p: return "480p SD"
        }
    }

    /// Short badge label for queue items.
    var badgeLabel: String {
        switch self {
        case .uhd8K: return "8K"
        case .uhd4K: return "4K"
        case .qhd1440p: return "1440p"
        case .fhd1080p: return "1080p"
        case .hd720p: return "720p"
        case .sd480p: return "480p"
        }
    }

    /// Indicates whether this tier uses stream-copy muxing without MP4 transcoding.
    var usesOriginalContainerMuxing: Bool {
        height > 1080
    }

    /// Container policy badge description.
    var containerPolicyDescription: String {
        if usesOriginalContainerMuxing {
            return "WebM/MKV 원본 병합"
        } else {
            return "MP4 컨테이너"
        }
    }

    /// Format selector string passed to `yt-dlp -f`.
    /// - 1080p and below: Prioritizes native H.264 (avc1) + AAC (m4a) for fastest lossless MP4 muxing.
    ///   If the tier only provides VP9/AV1, it selects the tier's best VP9 (avoiding AV1) and transcodes to QuickTime-compliant H.264/AAC via ffmpeg.
    /// - 1440p, 4K, 8K: Uses `bestvideo+bestaudio/best` and muxes directly into original container (WebM/MKV) without transcoding.
    var formatSelector: String {
        switch self {
        case .uhd8K, .uhd4K, .qhd1440p:
            return "bestvideo[protocol!*=m3u8]+bestaudio[protocol!*=m3u8]/bestvideo+bestaudio/best"
        case .fhd1080p:
            return mp4TierFormatSelector(maxHeight: 1080, lowerBound: 720)
        case .hd720p:
            return mp4TierFormatSelector(maxHeight: 720, lowerBound: 480)
        case .sd480p:
            return mp4TierFormatSelector(maxHeight: 480, lowerBound: 360)
        }
    }

    private func mp4TierFormatSelector(maxHeight: Int, lowerBound: Int) -> String {
        [
            // 1순위: 해당 해상도 구간의 DASH H.264 (avc1) + AAC (mp4a) (m3u8 배제) -> 무손실 초고속 MP4 병합
            "bestvideo[height<=\(maxHeight)][height>\(lowerBound)][vcodec^=avc1][protocol!*=m3u8]+bestaudio[acodec^=mp4a][protocol!*=m3u8]",
            // 2순위: 해당 해상도 구간의 DASH H.264 + 임의 오디오 (m3u8 배제)
            "bestvideo[height<=\(maxHeight)][height>\(lowerBound)][vcodec^=avc1][protocol!*=m3u8]+bestaudio[protocol!*=m3u8]",
            // 3순위: 해당 해상도 구간의 VP9 (AV1 제외) + AAC (m3u8 배제) -> ffmpeg로 QuickTime H.264 MP4 자동 변환
            "bestvideo[height<=\(maxHeight)][height>\(lowerBound)][vcodec!*='av01'][protocol!*=m3u8]+bestaudio[acodec^=mp4a][protocol!*=m3u8]",
            // 4순위: 해당 해상도 구간의 VP9 (AV1 제외) + 임의 오디오 (m3u8 배제)
            "bestvideo[height<=\(maxHeight)][height>\(lowerBound)][vcodec!*='av01'][protocol!*=m3u8]+bestaudio[protocol!*=m3u8]",
            // 5순위: 이하 해상도 DASH H.264 + AAC fallback (m3u8 배제)
            "bestvideo[height<=\(maxHeight)][vcodec^=avc1][protocol!*=m3u8]+bestaudio[acodec^=mp4a][protocol!*=m3u8]",
            // 6순위: 일반 fallback
            "bestvideo[height<=\(maxHeight)][protocol!*=m3u8]+bestaudio[protocol!*=m3u8]",
            "bestvideo[height<=\(maxHeight)]+bestaudio",
            "best[height<=\(maxHeight)]"
        ].joined(separator: "/")
    }

    /// Generates additional `yt-dlp` arguments tailored to the tier's profile and user conversion choice.
    func buildAdditionalArguments(
        profile: TierCodecProfile?,
        conversionMode: DownloadConversionMode
    ) -> [String] {
        if usesOriginalContainerMuxing {
            return ["-S", "res:\(height)"]
        }

        if let profile, profile.quickTimeStatus == .nativePlayable {
            // Native H.264 + AAC available: merge losslessly into MP4 with zero re-encoding
            return ["--merge-output-format", "mp4"]
        }

        // Tier needs conversion (non-H.264 video or non-AAC audio)
        switch conversionMode {
        case .quickTimeMP4:
            return [
                "--recode-video", "mp4",
                "--postprocessor-args", "VideoConvertor:-c:v libx264 -pix_fmt yuv420p -c:a aac"
            ]
        case .keepOriginal:
            return ["-S", "res:\(height)"]
        }
    }

    /// Additional `yt-dlp` arguments specific to this quality tier (fallback default).
    var additionalArguments: [String] {
        buildAdditionalArguments(profile: nil, conversionMode: .quickTimeMP4)
    }

    /// Maps an array of detected format heights from `yt-dlp -J` to supported `VideoQuality` tiers.
    static func availableTiers(fromHeights heights: Set<Int>) -> [VideoQuality] {
        guard let maxHeight = heights.max(), maxHeight > 0 else {
            return VideoQuality.allCases
        }

        let matched = VideoQuality.allCases.filter { quality in
            // Include a tier if the video has streams at or near that tier, or if it's <= maxHeight
            heights.contains(where: { $0 >= quality.height }) || quality == .sd480p
        }

        return matched.isEmpty ? [.fhd1080p, .hd720p, .sd480p] : matched
    }
}

extension VideoQuality: Comparable {
    static func < (lhs: VideoQuality, rhs: VideoQuality) -> Bool {
        lhs.height < rhs.height
    }
}
