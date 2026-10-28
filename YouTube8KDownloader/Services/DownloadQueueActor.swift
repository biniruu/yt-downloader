import Foundation

/// Immutable value type describing a single queued download task submitted to `DownloadQueueActor`.
struct QueuedDownloadJob: Sendable {
    let itemID: UUID
    let videoID: String
    let sourceURL: String
    let quality: VideoQuality
    let customFormatSelector: String?
    let customAdditionalArguments: [String]?
}

/// Lifecycle updates emitted by `DownloadQueueActor` for UI consumption.
enum QueueTaskUpdate: Sendable {
    case started
    case progress(percent: Double, speed: String?, eta: String?)
    case destinationDetected(URL)
    case muxing(outputURL: URL?)
    case completed(outputURL: URL, verifiedCodecs: String?)
    case failed(message: String)
}

/// Dedicated Swift Concurrency `Actor` that serializes video downloads so that only 1 item
/// is downloaded and muxed at a time, preventing CPU, disk I/O, and network contention.
actor DownloadQueueActor {
    private let service: YTDLPService
    private var pendingJobs: [QueuedDownloadJob] = []
    private var isRunningLoop: Bool = false

    private var currentJob: QueuedDownloadJob?
    private var activeProcess: Process?
    private var activeRecordedPaths: Set<String> = []
    private var isCancelledCurrentJob: Bool = false

    init(service: YTDLPService = YTDLPService()) {
        self.service = service
    }

    /// Enqueues a new download job and starts the serial worker loop if it is currently idle.
    func enqueue(
        job: QueuedDownloadJob,
        onUpdate: @escaping @MainActor @Sendable (UUID, QueueTaskUpdate) -> Void
    ) {
        pendingJobs.append(job)
        guard !isRunningLoop else { return }
        isRunningLoop = true

        Task {
            await processQueueSerially(onUpdate: onUpdate)
        }
    }

    /// Cancels a job by ID. If it is waiting, removes it from the queue.
    /// If it is actively downloading, terminates its process immediately and returns the job and recorded paths for file cleanup.
    func cancelJob(itemID: UUID) -> (wasActive: Bool, cancelledJob: QueuedDownloadJob?, recordedPaths: Set<String>) {
        // 1. Check waiting pending jobs
        if let index = pendingJobs.firstIndex(where: { $0.itemID == itemID }) {
            let removedJob = pendingJobs.remove(at: index)
            YTDLPService.appLog("Cancelled waiting job: \(removedJob.videoID) (\(itemID))")
            return (false, removedJob, [])
        }

        // 2. Check currently running job
        if let current = currentJob, current.itemID == itemID {
            YTDLPService.appLog("Cancelling actively running job: \(current.videoID) (\(itemID))")
            isCancelledCurrentJob = true
            let paths = activeRecordedPaths
            if let proc = activeProcess {
                YTDLPService.terminateProcessTree(proc)
            }
            activeProcess = nil
            return (true, current, paths)
        }

        return (false, nil, [])
    }

    /// Removes a waiting job from the queue if it has not started downloading yet.
    func cancelWaitingJob(itemID: UUID) -> Bool {
        cancelJob(itemID: itemID).cancelledJob != nil
    }

    private func setActiveProcess(_ process: Process) {
        if isCancelledCurrentJob {
            YTDLPService.terminateProcessTree(process)
        } else {
            self.activeProcess = process
        }
    }

    private func recordPath(_ path: String) {
        activeRecordedPaths.insert(path)
    }

    /// Serial worker loop that processes queued jobs strictly one by one in FIFO order.
    private func processQueueSerially(
        onUpdate: @escaping @MainActor @Sendable (UUID, QueueTaskUpdate) -> Void
    ) async {
        while !pendingJobs.isEmpty {
            let current = pendingJobs.removeFirst()
            let itemID = current.itemID

            self.currentJob = current
            self.activeProcess = nil
            self.activeRecordedPaths = []
            self.isCancelledCurrentJob = false

            await onUpdate(itemID, .started)

            do {
                let downloadResult = try await service.downloadVideo(
                    videoID: current.videoID,
                    sourceURL: current.sourceURL,
                    quality: current.quality,
                    customFormatSelector: current.customFormatSelector,
                    customAdditionalArguments: current.customAdditionalArguments,
                    onProcessSpawned: { [weak self] process in
                        Task { [weak self] in
                            await self?.setActiveProcess(process)
                        }
                    },
                    onEvent: { [weak self] event in
                        Task { [weak self] in
                            guard let self else { return }
                            switch event {
                            case .started:
                                await onUpdate(itemID, .started)
                            case let .progress(percent, speed, eta):
                                await onUpdate(itemID, .progress(percent: percent, speed: speed, eta: eta))
                            case let .destinationDetected(path):
                                await self.recordPath(path)
                                await onUpdate(itemID, .destinationDetected(URL(fileURLWithPath: path)))
                            case let .muxing(outputPath):
                                if let outputPath {
                                    await self.recordPath(outputPath)
                                }
                                let url = outputPath.map { URL(fileURLWithPath: $0) }
                                await onUpdate(itemID, .muxing(outputURL: url))
                            }
                        }
                    }
                )

                if isCancelledCurrentJob {
                    YTDLPService.appLog("Job \(itemID) was cancelled before completion. Cleaning up files.")
                    YTDLPService.cleanupIncompleteFiles(
                        videoID: current.videoID,
                        quality: current.quality,
                        recordedPaths: activeRecordedPaths
                    )
                } else {
                    await onUpdate(itemID, .completed(outputURL: downloadResult.fileURL, verifiedCodecs: downloadResult.verifiedCodecsText))
                }
            } catch {
                if isCancelledCurrentJob {
                    YTDLPService.appLog("Job \(itemID) caught cancellation error. Cleaning up files.")
                    YTDLPService.cleanupIncompleteFiles(
                        videoID: current.videoID,
                        quality: current.quality,
                        recordedPaths: activeRecordedPaths
                    )
                } else {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    await onUpdate(itemID, .failed(message: message))
                }
            }

            self.currentJob = nil
            self.activeProcess = nil
            self.activeRecordedPaths = []
            self.isCancelledCurrentJob = false
        }

        isRunningLoop = false
    }
}
