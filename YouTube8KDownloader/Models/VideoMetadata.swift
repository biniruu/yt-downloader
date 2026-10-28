import Foundation

/// QuickTime playback compatibility status for a quality tier.
enum QuickTimePlayableStatus: Equatable, Sendable {
    case nativePlayable     // Both video (H.264) and audio (AAC) are natively available
    case needsConversion    // 1080p or below, but video or audio is non-native (e.g. VP9, Opus)
    case unsupported        // 1440p and above (native VP9/AV1 only, 3rd-party players recommended)

    var badgeText: String {
        switch self {
        case .nativePlayable: return "QuickTime: 가능"
        case .needsConversion: return "QuickTime: 변환 필요"
        case .unsupported: return "QuickTime: 불가 (서드파티 전용)"
        }
    }
}

/// User's choice when QuickTime native playback requires conversion.
enum DownloadConversionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case quickTimeMP4 = "quickTimeMP4"
    case keepOriginal = "keepOriginal"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .quickTimeMP4: return "🍎 MP4 변환 (QuickTime 호환)"
        case .keepOriginal: return "⚡️ 원본 유지 (WebM / IINA·VLC용)"
        }
    }
}

/// Detailed codec and stream IDs analyzed for a specific quality tier.
struct TierCodecProfile: Equatable, Sendable {
    let quality: VideoQuality
    let videoCodecDisplay: String
    let audioCodecDisplay: String
    let quickTimeStatus: QuickTimePlayableStatus
    let hasNativeH264: Bool
    let hasNativeAAC: Bool
    /// Resolved direct `format_id` pair (e.g., "137+140") to eliminate codec guessing.
    let targetFormatSelector: String
    let fallbackFormatSelector: String
}

/// Represents analyzed metadata for a YouTube video fetched via `yt-dlp`.
struct VideoMetadata: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let sourceURL: String
    let thumbnailURL: URL?
    let uploader: String?
    let durationSeconds: Int?
    let availableQualities: [VideoQuality]
    let tierCodecProfiles: [VideoQuality: TierCodecProfile]

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

    /// Highest available quality tier for this video.
    var highestAvailableQuality: VideoQuality {
        availableQualities.first ?? .fhd1080p
    }

    /// Retrieves the analyzed codec profile for a given tier.
    func profile(for quality: VideoQuality) -> TierCodecProfile? {
        tierCodecProfiles[quality]
    }
}

/// Raw JSON decoding payloads for `yt-dlp -J --no-playlist`.
struct YTDLPRawMetadata: Decodable, Sendable {
    struct RawFormat: Decodable, Sendable {
        let formatId: String?
        let ext: String?
        let vcodec: String?
        let acodec: String?
        let height: Int?
        let width: Int?
        let fps: Double?
        let tbr: Double?
        let vbr: Double?
        let abr: Double?
        let formatProtocol: String?
        let language: String?

        enum CodingKeys: String, CodingKey {
            case formatId = "format_id"
            case ext
            case vcodec
            case acodec
            case height
            case width
            case fps
            case tbr
            case vbr
            case abr
            case formatProtocol = "protocol"
            case language
        }

        var isM3U8: Bool {
            formatProtocol?.lowercased().contains("m3u8") ?? false
        }

        var isKoreanLanguage: Bool {
            language?.lowercased().contains("ko") ?? false
        }

        var isDRC: Bool {
            formatId?.lowercased().contains("drc") ?? false
        }

        var hasValidVideo: Bool {
            guard let v = vcodec?.lowercased(), !v.isEmpty, v != "none", v != "images" else { return false }
            return true
        }

        var hasValidAudio: Bool {
            guard let a = acodec?.lowercased(), !a.isEmpty, a != "none", a != "unknown" else { return false }
            return true
        }

        /// True only for dedicated audio-only streams (e.g., 140, 251).
        /// Excludes pre-merged video+audio streams like format 18 so `yt-dlp` `_merge` never drops audio.
        var isAudioOnly: Bool {
            hasValidAudio && !hasValidVideo
        }

        /// True only for dedicated video-only streams (e.g., 137, 248, 313).
        var isVideoOnly: Bool {
            hasValidVideo && !hasValidAudio
        }
    }

    let id: String?
    let title: String?
    let webpageUrl: String?
    let thumbnail: String?
    let uploader: String?
    let channel: String?
    let duration: Double?
    let formats: [RawFormat]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case webpageUrl = "webpage_url"
        case thumbnail
        case uploader
        case channel
        case duration
        case formats
    }

    func toDomainMetadata(originalURL: String) -> VideoMetadata {
        let videoID = id ?? UUID().uuidString
        let cleanTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "YouTube Video (\(videoID))"
        let resolvedURL = webpageUrl ?? originalURL

        var resolvedThumbnailURL: URL?
        if let thumbnail, let url = URL(string: thumbnail) {
            resolvedThumbnailURL = url
        } else if let id {
            resolvedThumbnailURL = URL(string: "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg")
        }

        var heights = Set<Int>()
        if let formats {
            for fmt in formats {
                if let height = fmt.height, height > 0, fmt.vcodec != "none" {
                    heights.insert(height)
                }
            }
        }

        let qualities = VideoQuality.availableTiers(fromHeights: heights)
        let resolvedUploader = uploader ?? channel
        let resolvedDuration = duration.map { Int($0.rounded()) }

        let codecProfiles = Self.buildTierCodecProfiles(qualities: qualities, formats: formats)

        return VideoMetadata(
            id: videoID,
            title: cleanTitle,
            sourceURL: resolvedURL,
            thumbnailURL: resolvedThumbnailURL,
            uploader: resolvedUploader,
            durationSeconds: resolvedDuration,
            availableQualities: qualities,
            tierCodecProfiles: codecProfiles
        )
    }

    private static func buildTierCodecProfiles(
        qualities: [VideoQuality],
        formats: [RawFormat]?
    ) -> [VideoQuality: TierCodecProfile] {
        guard let formats, !formats.isEmpty else {
            return Dictionary(uniqueKeysWithValues: qualities.map { quality in
                (quality, TierCodecProfile(
                    quality: quality,
                    videoCodecDisplay: quality.usesOriginalContainerMuxing ? "VP9 / AV1" : "H.264",
                    audioCodecDisplay: "AAC",
                    quickTimeStatus: quality.usesOriginalContainerMuxing ? .unsupported : .nativePlayable,
                    hasNativeH264: !quality.usesOriginalContainerMuxing,
                    hasNativeAAC: true,
                    targetFormatSelector: quality.formatSelector,
                    fallbackFormatSelector: quality.formatSelector
                ))
            })
        }

        var profiles: [VideoQuality: TierCodecProfile] = [:]

        let sortAudioStreams: (RawFormat, RawFormat) -> Bool = { f1, f2 in
            if f1.isM3U8 != f2.isM3U8 {
                return !f1.isM3U8
            }
            if f1.isKoreanLanguage != f2.isKoreanLanguage {
                return f1.isKoreanLanguage
            }
            let br1 = f1.abr ?? f1.tbr ?? 0
            let br2 = f2.abr ?? f2.tbr ?? 0
            if abs(br1 - br2) > 5.0 {
                return br1 > br2
            }
            if f1.isDRC != f2.isDRC {
                return !f1.isDRC
            }
            return br1 > br2
        }

        let sortVideoStreams: (RawFormat, RawFormat) -> Bool = { f1, f2 in
            if f1.isM3U8 != f2.isM3U8 {
                return !f1.isM3U8
            }
            if f1.isVideoOnly != f2.isVideoOnly {
                return f1.isVideoOnly
            }
            return (f1.vbr ?? f1.tbr ?? 0) > (f2.vbr ?? f2.tbr ?? 0)
        }

        // Best AAC audio-only stream: must be audio-only (excludes combined formats like 18)
        let aacStream = formats
            .filter { fmt in
                guard fmt.isAudioOnly else { return false }
                let acodec = fmt.acodec?.lowercased() ?? ""
                let ext = fmt.ext?.lowercased() ?? ""
                return acodec.contains("mp4a") || acodec.contains("aac") || ext == "m4a"
            }
            .sorted(by: sortAudioStreams)
            .first

        // Best general audio-only stream (Opus, AAC, etc.)
        let anyAudioStream = formats
            .filter { $0.isAudioOnly }
            .sorted(by: sortAudioStreams)
            .first

        let aacFormatId = (aacStream?.isM3U8 == false) ? aacStream?.formatId : nil
        let anyAudioFormatId = ((anyAudioStream?.isM3U8 == false) ? anyAudioStream?.formatId : nil) ?? aacFormatId

        for quality in qualities {
            if quality.usesOriginalContainerMuxing {
                profiles[quality] = TierCodecProfile(
                    quality: quality,
                    videoCodecDisplay: "VP9 / AV1",
                    audioCodecDisplay: anyAudioStream != nil ? (aacStream != nil ? "AAC/Opus" : "Opus") : "원본",
                    quickTimeStatus: .unsupported,
                    hasNativeH264: false,
                    hasNativeAAC: aacStream != nil,
                    targetFormatSelector: "bestvideo[protocol!*=m3u8]+bestaudio[protocol!*=m3u8]/bestvideo+bestaudio/best",
                    fallbackFormatSelector: "bestvideo+bestaudio/best"
                )
                continue
            }

            let maxHeight = quality.height
            let lowerBound: Int = {
                switch quality {
                case .fhd1080p: return 720
                case .hd720p: return 480
                case .sd480p: return 360
                default: return 0
                }
            }()

            let tierVideoStreams = formats.filter { fmt in
                guard fmt.hasValidVideo else { return false }
                let h = fmt.height ?? 0
                return h <= maxHeight && h > lowerBound
            }

            let fallbackVideoStreams = formats.filter { fmt in
                guard fmt.hasValidVideo else { return false }
                let h = fmt.height ?? 0
                return h <= maxHeight && h > 0
            }

            let effectiveVideoStreams = tierVideoStreams.isEmpty ? fallbackVideoStreams : tierVideoStreams

            // Find H.264 stream: prioritize standard DASH video-only https streams over m3u8
            let h264Stream = effectiveVideoStreams
                .filter { fmt in
                    let vcodec = fmt.vcodec?.lowercased() ?? ""
                    return vcodec.contains("avc1") || vcodec.contains("avc") || vcodec.contains("h264")
                }
                .sorted(by: sortVideoStreams)
                .first

            let vp9Stream = effectiveVideoStreams
                .filter { fmt in
                    let vcodec = fmt.vcodec?.lowercased() ?? ""
                    return !vcodec.contains("av01") && !vcodec.contains("av1")
                }
                .sorted(by: sortVideoStreams)
                .first

            let bestVideoStream = effectiveVideoStreams
                .sorted(by: sortVideoStreams)
                .first

            let hasNativeH264 = (h264Stream != nil)
            let hasNativeAAC = (aacStream != nil)
            let isQuickTimeNative = hasNativeH264 && hasNativeAAC

            let videoDisplay: String = {
                if hasNativeH264 { return "H.264" }
                if let vcodec = bestVideoStream?.vcodec?.lowercased() {
                    if vcodec.contains("vp9") || vcodec.contains("vp09") { return "VP9" }
                    if vcodec.contains("av01") || vcodec.contains("av1") { return "AV1" }
                }
                return "VP9"
            }()

            let audioDisplay: String = {
                if hasNativeAAC { return "AAC" }
                if let acodec = anyAudioStream?.acodec?.lowercased() {
                    if acodec.contains("opus") { return "Opus" }
                }
                return "기타"
            }()

            let fallbackSelector = quality.formatSelector
            let targetSelector: String = {
                if isQuickTimeNative,
                   let vStream = h264Stream, vStream.isVideoOnly, !vStream.isM3U8,
                   let vId = vStream.formatId, let aId = aacFormatId {
                    return "\(vId)+\(aId)/\(fallbackSelector)"
                } else if let vStream = (h264Stream ?? vp9Stream ?? bestVideoStream),
                          vStream.isVideoOnly, !vStream.isM3U8,
                          let vId = vStream.formatId,
                          let aId = (aacFormatId ?? anyAudioFormatId) {
                    return "\(vId)+\(aId)/\(fallbackSelector)"
                } else {
                    return fallbackSelector
                }
            }()

            profiles[quality] = TierCodecProfile(
                quality: quality,
                videoCodecDisplay: videoDisplay,
                audioCodecDisplay: audioDisplay,
                quickTimeStatus: isQuickTimeNative ? .nativePlayable : .needsConversion,
                hasNativeH264: hasNativeH264,
                hasNativeAAC: hasNativeAAC,
                targetFormatSelector: targetSelector,
                fallbackFormatSelector: quality.formatSelector
            )
        }

        return profiles
    }
}
