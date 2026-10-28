import Foundation

/// Events emitted in real time while `yt-dlp` is executing a download task.
enum DownloadEngineEvent: Sendable {
    case started
    case progress(percent: Double, speed: String?, eta: String?)
    case destinationDetected(String)
    case muxing(outputPath: String?)
}

/// Errors produced by `YTDLPService`.
enum YTDLPError: LocalizedError, Sendable {
    case invalidURL
    case binaryNotFound(path: String, toolName: String)
    case processLaunchFailed(String)
    case executionFailed(exitCode: Int32, stderr: String)
    case metadataDecodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "유효한 유튜브(YouTube) URL을 입력해 주세요."
        case let .binaryNotFound(path, toolName):
            return "\(toolName) 실행 파일을 찾을 수 없습니다 (\(path)). Homebrew로 설치되어 있는지 확인해 주세요."
        case let .processLaunchFailed(reason):
            return "프로세스 실행에 실패했습니다: \(reason)"
        case let .executionFailed(exitCode, stderr):
            let cleanErr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanErr.isEmpty {
                return "yt-dlp 작업이 비정상 종료되었습니다 (종료 코드: \(exitCode))."
            }
            return "yt-dlp 오류 (\(exitCode)): \(cleanErr)"
        case let .metadataDecodingFailed(reason):
            return "영상 메타데이터 파싱에 실패했습니다: \(reason)"
        }
    }
}

/// Checks whether required external Homebrew binaries (`yt-dlp` and `ffmpeg`) are installed.
struct EngineDependencyStatus: Equatable, Sendable {
    let ytDlpPath: String
    let ffmpegPath: String
    let isYtDlpInstalled: Bool
    let isFfmpegInstalled: Bool

    var isReady: Bool {
        isYtDlpInstalled && isFfmpegInstalled
    }
}

/// Thread-safe byte buffer that splits incoming `Process` stdout/stderr chunks on `\n` and `\r`.
private final class StreamLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var collectedText = ""

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        guard !data.isEmpty else { return [] }
        buffer.append(data)

        var lines: [String] = []
        let newlineBytes: [UInt8] = [0x0A, 0x0D] // \n and \r

        while let splitIndex = buffer.firstIndex(where: { newlineBytes.contains($0) }) {
            let lineData = buffer.subdata(in: 0..<splitIndex)
            buffer.removeSubrange(0...splitIndex)

            if let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty {
                lines.append(line)
                collectedText += line + "\n"
            }
        }
        return lines
    }

    func flushRemaining() -> [String] {
        lock.lock()
        defer { lock.unlock() }

        guard !buffer.isEmpty else { return [] }
        let remainingData = buffer
        buffer.removeAll()

        if let line = String(data: remainingData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !line.isEmpty {
            collectedText += line + "\n"
            return [line]
        }
        return []
    }

    func fullText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return collectedText
    }
}

/// Thread-safe tracker for the resolved output file path during a single `yt-dlp` session.
private final class OutputPathTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastDetectedPath: String?

    func update(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        lastDetectedPath = path
    }

    func currentPath() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastDetectedPath
    }
}

/// Result returned when a video finishes downloading and muxing.
struct DownloadResult: Sendable {
    let fileURL: URL
    let verifiedCodecsText: String?
}

/// Service responsible for invoking `/opt/homebrew/bin/yt-dlp` and `/opt/homebrew/bin/ffmpeg` via `Process`.
struct YTDLPService: Sendable {
    static let primaryYtDlpPath = "/opt/homebrew/bin/yt-dlp"
    static let primaryFfmpegPath = "/opt/homebrew/bin/ffmpeg"
    static let primaryFfprobePath = "/opt/homebrew/bin/ffprobe"
    static let homebrewBinDirectory = "/opt/homebrew/bin"

    /// Fixed user Downloads folder (`~/Downloads`).
    static var downloadsDirectoryURL: URL {
        if let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            return url
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Checks installation status of `yt-dlp` and `ffmpeg` in `/opt/homebrew/bin`.
    static func checkDependencies() -> EngineDependencyStatus {
        let fm = FileManager.default
        let hasYtDlp = fm.isExecutableFile(atPath: primaryYtDlpPath)
        let hasFfmpeg = fm.isExecutableFile(atPath: primaryFfmpegPath)
        return EngineDependencyStatus(
            ytDlpPath: primaryYtDlpPath,
            ffmpegPath: primaryFfmpegPath,
            isYtDlpInstalled: hasYtDlp,
            isFfmpegInstalled: hasFfmpeg
        )
    }

    /// Safely terminates a process and any child processes it spawned (e.g., ffmpeg spawned by yt-dlp).
    static func terminateProcessTree(_ process: Process) {
        let pid = process.processIdentifier
        if pid > 0 {
            appLog("Terminating process tree for PID \(pid)")
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-TERM", "-P", "\(pid)"]
            try? pkill.run()
            pkill.waitUntilExit()
        }
        process.terminate()
    }

    /// Cleans up any partially downloaded, temporary, or output files associated with a video ID and quality tier.
    static func cleanupIncompleteFiles(
        videoID: String,
        quality: VideoQuality? = nil,
        recordedPaths: Set<String> = [],
        downloadsURL: URL = downloadsDirectoryURL
    ) {
        let fm = FileManager.default
        appLog("Starting incomplete files cleanup for videoID: \(videoID)")

        // 1. Delete explicitly recorded paths and their .part / .ytdl / .temp variants
        for rawPath in recordedPaths {
            deleteFileIfExists(URL(fileURLWithPath: rawPath))
            deleteFileIfExists(URL(fileURLWithPath: rawPath + ".part"))
            deleteFileIfExists(URL(fileURLWithPath: rawPath + ".ytdl"))
            deleteFileIfExists(URL(fileURLWithPath: rawPath + ".temp"))
        }

        // 2. Scan downloads directory for related files created/modified recently
        guard let fileNames = try? fm.contentsOfDirectory(atPath: downloadsURL.path) else { return }

        let idMarker = "[\(videoID)]"
        let qualityMarker = quality.map { "[\($0.rawValue)]" }
        let recentThreshold = Date().addingTimeInterval(-600) // Modified within last 10 minutes

        for name in fileNames {
            guard name.contains(idMarker) else { continue }
            if let qualityMarker, !name.contains(qualityMarker) {
                continue
            }

            let fileURL = downloadsURL.appendingPathComponent(name)

            // Always remove obvious temporary download artifacts
            let isTempArtifact = name.hasSuffix(".part") ||
                                 name.hasSuffix(".ytdl") ||
                                 name.hasSuffix(".temp") ||
                                 name.contains(".f")

            if isTempArtifact {
                deleteFileIfExists(fileURL)
                continue
            }

            // For completed video container files matching this video/quality, check modification time
            if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
               let modDate = attrs[.modificationDate] as? Date,
               modDate >= recentThreshold {
                deleteFileIfExists(fileURL)
            }
        }
    }

    private static func deleteFileIfExists(_ url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
                appLog("Successfully deleted: \(url.path)")
            } catch {
                appLog("Failed to delete \(url.path): \(error.localizedDescription)")
            }
        }
    }

    /// Diagnostics file logger writing to `/tmp/ytdlp_app.log`.
    static func appLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        let logURL = URL(fileURLWithPath: "/tmp/ytdlp_app.log")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    /// Checks whether the raw URL looks like a YouTube playlist or contains a `list=` parameter.
    static func isLikelyPlaylistURL(_ rawURL: String) -> Bool {
        let lower = rawURL.lowercased()
        return lower.contains("list=") || lower.contains("/playlist")
    }

    /// Analyzes an entire YouTube playlist using `yt-dlp --flat-playlist -J --no-warnings`.
    func analyzePlaylist(url rawURL: String) async throws -> PlaylistData {
        Self.appLog("Analyzing Playlist URL: \(rawURL)")
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let parsedURL = URL(string: trimmed),
              let scheme = parsedURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw YTDLPError.invalidURL
        }

        let status = Self.checkDependencies()
        guard status.isYtDlpInstalled else {
            throw YTDLPError.binaryNotFound(path: status.ytDlpPath, toolName: "yt-dlp")
        }

        let arguments = [
            "--flat-playlist",
            "--dump-single-json",
            "--no-warnings",
            trimmed
        ]

        let stdoutData = try await runOneShotProcess(
            executablePath: status.ytDlpPath,
            arguments: arguments
        )

        do {
            let decoder = JSONDecoder()
            let rawPlaylist = try decoder.decode(YTDLPPlaylistRawMetadata.self, from: stdoutData)
            let rawEntries = rawPlaylist.entries ?? []
            guard !rawEntries.isEmpty || rawPlaylist.type == "playlist" else {
                throw YTDLPError.metadataDecodingFailed("재생목록에 유효한 영상이 없습니다.")
            }

            var videoItems: [PlaylistVideoData] = []
            for entry in rawEntries {
                guard let id = entry.id, !id.isEmpty else { continue }
                let title = entry.title ?? "제목 없는 영상"
                let durationSeconds = entry.duration.map { Int($0) }
                let videoURL = entry.url ?? "https://www.youtube.com/watch?v=\(id)"
                let uploader = entry.uploader ?? entry.channel ?? rawPlaylist.uploader ?? rawPlaylist.channel

                var thumbURL: URL? = nil
                if let thumbs = entry.thumbnails, !thumbs.isEmpty {
                    if let lastThumb = thumbs.last?.url {
                        thumbURL = URL(string: lastThumb)
                    }
                }

                videoItems.append(PlaylistVideoData(
                    id: id,
                    title: title,
                    sourceURL: videoURL,
                    durationSeconds: durationSeconds,
                    thumbnailURL: thumbURL,
                    uploader: uploader
                ))
            }

            let playlistID = rawPlaylist.id ?? UUID().uuidString
            let playlistTitle = rawPlaylist.title ?? "YouTube 재생목록"
            let playlistUploader = rawPlaylist.uploader ?? rawPlaylist.channel
            let firstThumbURL = videoItems.first?.thumbnailURL

            let playlistData = PlaylistData(
                id: playlistID,
                title: playlistTitle,
                uploader: playlistUploader,
                sourceURL: trimmed,
                thumbnailURL: firstThumbURL,
                items: videoItems
            )

            Self.appLog("Playlist analysis successful: '\(playlistTitle)' with \(videoItems.count) items.")
            return playlistData
        } catch {
            Self.appLog("Playlist decoding failed: \(error.localizedDescription)")
            throw YTDLPError.metadataDecodingFailed(error.localizedDescription)
        }
    }

    /// Automatically detects whether the URL is a playlist or a single video and returns the analyzed domain representation.
    func analyzeContent(url rawURL: String) async throws -> AnalyzedContent {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isLikelyPlaylistURL(trimmed) {
            do {
                let playlist = try await analyzePlaylist(url: trimmed)
                if !playlist.items.isEmpty {
                    return .playlist(playlist)
                }
            } catch {
                Self.appLog("Playlist analysis failed or fallback needed: \(error.localizedDescription), trying single video fallback.")
            }
        }

        let video = try await analyzeVideo(url: trimmed)
        return .video(video)
    }

    /// Runs `yt-dlp --print "%(id)s %(height)s"` to stream detected maximum video heights for playlist items in real time.
    func streamPlaylistResolutions(
        playlistURL: String,
        onResolution: @escaping @Sendable (String, Int) -> Void
    ) async {
        let status = Self.checkDependencies()
        guard status.isYtDlpInstalled else { return }

        let arguments = [
            "--print", "%(id)s %(height)s",
            "--no-warnings",
            playlistURL
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: status.ytDlpPath)
        process.arguments = arguments
        process.environment = Self.buildProcessEnvironment()

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe() // Silence stderr

        let stdoutBuffer = StreamLineBuffer()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let lines = stdoutBuffer.append(data)
            for line in lines {
                Self.parseResolutionLine(line, onResolution: onResolution)
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                let remaining = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                for line in stdoutBuffer.append(remaining) + stdoutBuffer.flushRemaining() {
                    Self.parseResolutionLine(line, onResolution: onResolution)
                }
                continuation.resume()
            }

            do {
                try process.run()
            } catch {
                continuation.resume()
            }
        }
    }

    private static func parseResolutionLine(
        _ line: String,
        onResolution: @escaping @Sendable (String, Int) -> Void
    ) {
        let parts = line.split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 2 else { return }
        let videoID = String(parts[0])
        guard let height = Int(parts[1]), height > 0 else { return }
        onResolution(videoID, height)
    }

    /// Analyzes a YouTube video link using `yt-dlp --dump-single-json --no-playlist`.
    func analyzeVideo(url rawURL: String) async throws -> VideoMetadata {
        Self.appLog("Analyzing URL: \(rawURL)")
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let parsedURL = URL(string: trimmed),
              let scheme = parsedURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw YTDLPError.invalidURL
        }

        let status = Self.checkDependencies()
        guard status.isYtDlpInstalled else {
            throw YTDLPError.binaryNotFound(path: status.ytDlpPath, toolName: "yt-dlp")
        }

        let arguments = [
            "--dump-single-json",
            "--no-playlist",
            "--no-warnings",
            trimmed
        ]

        let stdoutData = try await runOneShotProcess(
            executablePath: status.ytDlpPath,
            arguments: arguments
        )

        do {
            let decoder = JSONDecoder()
            let rawMetadata = try decoder.decode(YTDLPRawMetadata.self, from: stdoutData)
            let domainMeta = rawMetadata.toDomainMetadata(originalURL: trimmed)
            Self.appLog("Analysis successful for '\(domainMeta.title)' (ID: \(domainMeta.id)). Available qualities: \(domainMeta.availableQualities.map { $0.rawValue })")
            return domainMeta
        } catch {
            Self.appLog("Metadata decoding failed: \(error.localizedDescription)")
            throw YTDLPError.metadataDecodingFailed(error.localizedDescription)
        }
    }

    /// Determines the expected video container extension based on quality tier and conversion arguments.
    static func inferExpectedExtension(
        quality: VideoQuality,
        additionalArguments: [String]
    ) -> String? {
        if let recodeIdx = additionalArguments.firstIndex(of: "--recode-video"),
           recodeIdx + 1 < additionalArguments.count {
            return additionalArguments[recodeIdx + 1].lowercased()
        }
        if let mergeIdx = additionalArguments.firstIndex(of: "--merge-output-format"),
           mergeIdx + 1 < additionalArguments.count {
            return additionalArguments[mergeIdx + 1].lowercased()
        }
        if !quality.usesOriginalContainerMuxing {
            return "mp4"
        }
        return nil
    }

    /// Computes the duplicate filename suffix following macOS Finder's exact paste/duplicate convention
    /// ("" for initial file, " 2" for second copy, " 3" for third, etc.) so existing files in `~/Downloads`
    /// are never overwritten and both/all files are kept.
    static func nextAvailableOutputSuffix(
        videoID: String,
        quality: VideoQuality,
        expectedExtension: String?,
        downloadsURL: URL = downloadsDirectoryURL
    ) -> String {
        guard let fileNames = try? FileManager.default.contentsOfDirectory(atPath: downloadsURL.path) else {
            return ""
        }

        let marker = "[\(videoID)][\(quality.rawValue)]"
        var takenIndices = Set<Int>()

        for name in fileNames {
            guard name.contains(marker) else { continue }
            // Ignore temporary / incomplete download files
            if name.hasSuffix(".part") || name.hasSuffix(".ytdl") || name.hasSuffix(".temp") {
                continue
            }

            guard let markerRange = name.range(of: marker) else { continue }
            let remainder = String(name[markerRange.upperBound...])

            // A completed video file should have only one extension dot in the remainder after marker
            // (e.g. ".mp4", " 2.mp4", " 3.webm") and not intermediate streams like ".f137.mp4"
            let dotCount = remainder.filter { $0 == "." }.count
            guard dotCount == 1, let dotIndex = remainder.lastIndex(of: ".") else {
                continue
            }

            let suffixPart = String(remainder[..<dotIndex])
            let ext = String(remainder[remainder.index(after: dotIndex)...]).lowercased()

            if let expectedExtension = expectedExtension?.lowercased() {
                guard ext == expectedExtension else { continue }
            } else {
                let validVideoExts: Set<String> = ["mp4", "webm", "mkv", "mov", "m4v"]
                guard validVideoExts.contains(ext) else { continue }
            }

            if suffixPart.isEmpty {
                takenIndices.insert(1)
            } else if suffixPart.hasPrefix(" ") {
                let numStr = suffixPart.dropFirst()
                if let num = Int(numStr), num >= 2 {
                    takenIndices.insert(num)
                }
            }
        }

        guard takenIndices.contains(1) else {
            return ""
        }

        var candidate = 2
        while takenIndices.contains(candidate) {
            candidate += 1
        }
        return " \(candidate)"
    }

    /// Downloads and muxes a video into `~/Downloads` according to the quality tier's format rules,
    /// streaming progress percentages and muxing states from stdout in real time.
    func downloadVideo(
        videoID: String,
        sourceURL: String,
        quality: VideoQuality,
        customFormatSelector: String? = nil,
        customAdditionalArguments: [String]? = nil,
        onProcessSpawned: (@Sendable (Process) -> Void)? = nil,
        onEvent: @escaping @Sendable (DownloadEngineEvent) -> Void
    ) async throws -> DownloadResult {
        let status = Self.checkDependencies()
        guard status.isYtDlpInstalled else {
            throw YTDLPError.binaryNotFound(path: status.ytDlpPath, toolName: "yt-dlp")
        }
        guard status.isFfmpegInstalled else {
            throw YTDLPError.binaryNotFound(path: status.ffmpegPath, toolName: "ffmpeg")
        }

        let downloadsURL = Self.downloadsDirectoryURL
        try? FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)

        let selectedFormat = customFormatSelector ?? quality.formatSelector
        let selectedAdditionalArgs = customAdditionalArguments ?? quality.additionalArguments

        let expectedExt = Self.inferExpectedExtension(quality: quality, additionalArguments: selectedAdditionalArgs)
        let outputSuffix = Self.nextAvailableOutputSuffix(
            videoID: videoID,
            quality: quality,
            expectedExtension: expectedExt,
            downloadsURL: downloadsURL
        )

        var arguments: [String] = [
            "--no-playlist",
            "--newline",
            "--progress",
            "--force-overwrites",
            "--ffmpeg-location", Self.homebrewBinDirectory,
            "-f", selectedFormat
        ]
        arguments.append(contentsOf: selectedAdditionalArgs)
        arguments.append(contentsOf: [
            "-P", downloadsURL.path,
            "-o", "%(title).180B [%(id)s][\(quality.rawValue)]\(outputSuffix).%(ext)s",
            sourceURL
        ])

        Self.appLog("Executing yt-dlp: videoID=\(videoID), format=\(selectedFormat), suffix='\(outputSuffix)', args=\(selectedAdditionalArgs.joined(separator: " "))")
        onEvent(.started)

        let process = Process()
        let resolvedURL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.executableURL = URL(fileURLWithPath: status.ytDlpPath)
                process.arguments = arguments
                process.environment = Self.buildProcessEnvironment()

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let stdoutBuffer = StreamLineBuffer()
                let stderrBuffer = StreamLineBuffer()
                let pathTracker = OutputPathTracker()

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    let lines = stdoutBuffer.append(data)
                    for line in lines {
                        Self.parseStdoutLine(line, pathTracker: pathTracker, onEvent: onEvent)
                    }
                }

                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    _ = stderrBuffer.append(data)
                }

                process.terminationHandler = { terminatedProcess in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    let remainingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    for line in stdoutBuffer.append(remainingOut) + stdoutBuffer.flushRemaining() {
                        Self.parseStdoutLine(line, pathTracker: pathTracker, onEvent: onEvent)
                    }

                    let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    _ = stderrBuffer.append(remainingErr)
                    _ = stderrBuffer.flushRemaining()

                    let exitCode = terminatedProcess.terminationStatus
                    if exitCode == 0 {
                        let finalURL = Self.resolveFinalURL(
                            detectedPath: pathTracker.currentPath(),
                            videoID: videoID,
                            quality: quality,
                            downloadsURL: downloadsURL
                        )
                        Self.appLog("yt-dlp process completed (exit code 0). Resolved file: \(finalURL.path)")
                        continuation.resume(returning: finalURL)
                    } else {
                        let errOutput = stderrBuffer.fullText()
                        let fallbackOutput = stdoutBuffer.fullText()
                        let message = errOutput.isEmpty ? fallbackOutput : errOutput
                        Self.appLog("yt-dlp failed (exit code \(exitCode)): \(message)")
                        continuation.resume(
                            throwing: YTDLPError.executionFailed(
                                exitCode: exitCode,
                                stderr: Self.extractLastMeaningfulError(from: message)
                            )
                        )
                    }
                }

                do {
                    try process.run()
                    onProcessSpawned?(process)
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    Self.appLog("yt-dlp process launch failed: \(error.localizedDescription)")
                    continuation.resume(throwing: YTDLPError.processLaunchFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            Self.terminateProcessTree(process)
        }

        // Verify codecs of the actual downloaded file on disk using ffprobe
        let verifiedCodecs = await Self.probeFileCodecs(fileURL: resolvedURL)
        return DownloadResult(fileURL: resolvedURL, verifiedCodecsText: verifiedCodecs)
    }

    /// Resolves the final downloaded and muxed file URL, falling back to scanning ~/Downloads by video ID if pathTracker lost the merger line.
    private static func resolveFinalURL(
        detectedPath: String?,
        videoID: String,
        quality: VideoQuality,
        downloadsURL: URL
    ) -> URL {
        let fm = FileManager.default
        if let detectedPath, fm.fileExists(atPath: detectedPath) {
            return URL(fileURLWithPath: detectedPath)
        }

        // If detectedPath doesn't exist on disk, look for any file in ~/Downloads matching the videoID and quality tier
        if let contents = try? fm.contentsOfDirectory(atPath: downloadsURL.path) {
            let matches = contents.filter {
                $0.contains("[\(videoID)]") &&
                $0.contains("[\(quality.rawValue)]") &&
                !$0.hasSuffix(".part") &&
                !$0.hasSuffix(".ytdl") &&
                !$0.hasSuffix(".temp")
            }
            var bestURL: URL?
            var latestDate: Date = .distantPast
            for name in matches {
                let candidateURL = downloadsURL.appendingPathComponent(name)
                if let attrs = try? fm.attributesOfItem(atPath: candidateURL.path),
                   let modDate = attrs[.modificationDate] as? Date,
                   modDate > latestDate {
                    latestDate = modDate
                    bestURL = candidateURL
                }
            }
            if let bestURL {
                Self.appLog("Located file via directory scan: \(bestURL.path)")
                return bestURL
            }
        }

        if let detectedPath {
            return URL(fileURLWithPath: detectedPath)
        }
        return downloadsURL
    }

    /// Probes the downloaded file using `/opt/homebrew/bin/ffprobe` to accurately verify actual video and audio codecs.
    static func probeFileCodecs(fileURL: URL) async -> String? {
        appLog("ffprobe probing file: \(fileURL.path)")
        guard FileManager.default.isExecutableFile(atPath: primaryFfprobePath) else {
            appLog("ffprobe executable not found at: \(primaryFfprobePath)")
            return nil
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            appLog("File for ffprobe does not exist at: \(fileURL.path)")
            return nil
        }

        let arguments = [
            "-v", "error",
            "-show_entries", "stream=codec_name,codec_type",
            "-of", "json",
            fileURL.path
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: primaryFfprobePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                appLog("ffprobe exited with status \(process.terminationStatus)")
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            struct ProbeOutput: Decodable {
                struct Stream: Decodable {
                    let codecName: String?
                    let codecType: String?
                    enum CodingKeys: String, CodingKey {
                        case codecName = "codec_name"
                        case codecType = "codec_type"
                    }
                }
                let streams: [Stream]?
            }

            let decoded = try JSONDecoder().decode(ProbeOutput.self, from: data)
            guard let streams = decoded.streams else {
                appLog("ffprobe returned no streams array")
                return nil
            }

            var videoCodec: String?
            var audioCodec: String?

            for stream in streams {
                if stream.codecType == "video", videoCodec == nil, let name = stream.codecName {
                    videoCodec = formatCodecDisplayName(name)
                } else if stream.codecType == "audio", audioCodec == nil, let name = stream.codecName {
                    audioCodec = formatCodecDisplayName(name)
                }
            }

            guard videoCodec != nil || audioCodec != nil else {
                appLog("ffprobe found neither video nor audio streams")
                return nil
            }
            let result = "\(videoCodec ?? "알 수 없음") / \(audioCodec ?? "알 수 없음")"
            appLog("ffprobe verified codecs: [\(result)] for '\(fileURL.lastPathComponent)'")
            return result
        } catch {
            appLog("ffprobe failed with error: \(error.localizedDescription)")
            return nil
        }
    }

    private static func formatCodecDisplayName(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("h264") || lower.contains("avc") { return "H.264" }
        if lower.contains("hevc") || lower.contains("h265") { return "HEVC" }
        if lower.contains("vp9") || lower.contains("vp09") { return "VP9" }
        if lower.contains("av01") || lower.contains("av1") { return "AV1" }
        if lower.contains("aac") || lower.contains("mp4a") { return "AAC" }
        if lower.contains("opus") { return "Opus" }
        return raw.uppercased()
    }

    // MARK: - Private Helpers

    private func runOneShotProcess(executablePath: String, arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.environment = Self.buildProcessEnvironment()

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Accumulate stdout/stderr asynchronously to avoid pipe buffer deadlocks on large JSON outputs (>64KB).
            let stdoutAccumulator = DataAccumulator()
            let stderrAccumulator = DataAccumulator()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty {
                    stdoutAccumulator.append(chunk)
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty {
                    stderrAccumulator.append(chunk)
                }
            }

            process.terminationHandler = { terminatedProcess in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                stdoutAccumulator.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                stderrAccumulator.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

                let exitCode = terminatedProcess.terminationStatus
                if exitCode == 0 {
                    continuation.resume(returning: stdoutAccumulator.data())
                } else {
                    let stderrString = String(data: stderrAccumulator.data(), encoding: .utf8) ?? ""
                    continuation.resume(
                        throwing: YTDLPError.executionFailed(
                            exitCode: exitCode,
                            stderr: Self.extractLastMeaningfulError(from: stderrString)
                        )
                    )
                }
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: YTDLPError.processLaunchFailed(error.localizedDescription))
            }
        }
    }

    private static func buildProcessEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !existingPath.contains(homebrewBinDirectory) {
            env["PATH"] = "\(homebrewBinDirectory):/usr/local/bin:\(existingPath)"
        }
        env["PYTHONIOENCODING"] = "utf-8"
        env["LANG"] = "en_US.UTF-8"
        return env
    }

    /// Parses a single stdout line from `yt-dlp` to extract progress percentage, transfer speed, ETA,
    /// destination path, and muxing transitions.
    private static func parseStdoutLine(
        _ line: String,
        pathTracker: OutputPathTracker,
        onEvent: @escaping @Sendable (DownloadEngineEvent) -> Void
    ) {
        // 1. Detect Muxing or Re-encoding stage (`[Merger]`, `[Fixup...]`, `[VideoConvertor]`)
        if line.contains("[Merger]") || line.contains("Merging formats into") || line.contains("[Fixup") || line.contains("[VideoConvertor]") {
            var extractedPath = extractQuotedPath(from: line)
            if extractedPath == nil, let destRange = line.range(of: "Destination:") {
                let candidate = line[destRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    extractedPath = candidate
                }
            }
            if let extractedPath {
                pathTracker.update(extractedPath)
            }
            onEvent(.muxing(outputPath: extractedPath))
            return
        }

        // 2. Detect `[download]` lines
        guard line.contains("[download]") else { return }

        // 2a. Destination path line: `[download] Destination: /Users/.../Downloads/...`
        if let destRange = line.range(of: "Destination:") {
            let path = line[destRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                pathTracker.update(path)
                onEvent(.destinationDetected(path))
            }
            return
        }

        // 2b. Already downloaded line: `[download] /Users/.../Downloads/... has already been downloaded`
        if let alreadyRange = line.range(of: " has already been downloaded"),
           let prefixRange = line.range(of: "[download]") {
            let path = line[prefixRange.upperBound..<alreadyRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                pathTracker.update(path)
                onEvent(.destinationDetected(path))
            }
            onEvent(.progress(percent: 100.0, speed: nil, eta: nil))
            return
        }

        // 2c. Progress percentage line: `[download]  45.2% of  240.10MiB at   28.14MiB/s ETA 00:05`
        if let percent = extractPercentage(from: line) {
            let speed = extractToken(after: "at", in: line)
            let eta = extractToken(after: "ETA", in: line)
            onEvent(.progress(percent: percent, speed: speed, eta: eta))
        }
    }

    private static func extractPercentage(from line: String) -> Double? {
        guard let percentIndex = line.firstIndex(of: "%") else { return nil }
        let prefix = line[..<percentIndex]
        let numberSubstring = prefix.split(whereSeparator: { $0.isWhitespace }).last
        guard let token = numberSubstring, let value = Double(token) else { return nil }
        return min(max(value, 0.0), 100.0)
    }

    private static func extractToken(after keyword: String, in line: String) -> String? {
        let components = line.split(whereSeparator: { $0.isWhitespace })
        guard let idx = components.firstIndex(of: Substring(keyword)),
              components.index(after: idx) < components.endIndex else {
            return nil
        }
        let value = String(components[components.index(after: idx)])
        if value.contains("Unknown") || value == "N/A" {
            return nil
        }
        return value
    }

    private static func extractQuotedPath(from line: String) -> String? {
        guard let firstQuote = line.firstIndex(of: "\""),
              let lastQuote = line.lastIndex(of: "\""),
              firstQuote < lastQuote else {
            return nil
        }
        let start = line.index(after: firstQuote)
        let path = String(line[start..<lastQuote])
        return path.isEmpty ? nil : path
    }

    private static func extractLastMeaningfulError(from rawText: String) -> String {
        let lines = rawText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let errorLine = lines.last(where: { $0.uppercased().contains("ERROR:") }) {
            return errorLine
        }
        return lines.last ?? rawText
    }
}

/// Thread-safe data accumulator for one-shot process execution (`yt-dlp -J`).
private final class DataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
