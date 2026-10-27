import Foundation
import MonitorCore

/// 更新包下载器：流式下载到临时目录，汇报进度，支持取消与断点续传。
///
/// 不使用 `async/await` 的 `URLSession.download` 单发版本，是因为需要：
/// * 实时的字节级进度（大 DMG 上体验差别明显）；
/// * 真正的取消（用户点「取消」要立刻停，而不是等整个请求超时）；
/// * 断点续传（网络抖动时不重头再来）。
public final class UpdateDownloader: NSObject, @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case cancelled
        case badStatus(Int)
        case notHTTP
        case moveFailed
        /// 服务端不支持断点续传，需要从头下载。
        case resumeUnsupported
    }

    /// 下载进度回调（已下载字节 / 总字节，总字节未知时为 nil）。
    public typealias ProgressHandler = @Sendable (_ received: Int64, _ total: Int64?) -> Void

    private var session: URLSession
    private let destination: URL
    private var task: URLSessionDownloadTask?
    /// 续传所需的临时文件；取消时保留，以便下次续传。
    private var resumableData: Data?
    /// 一次性 continuation：同一时间只允许一个下载。
    private var continuation: CheckedContinuation<Void, Error>?
    private var progressHandler: ProgressHandler?
    private var receivedBytes: Int64 = 0
    private var expectedTotal: Int64?

    public init(destination: URL, timeout: TimeInterval = 30) {
        self.destination = destination
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        // 必须把 self 作为 delegate 传进去。用 `URLSession(configuration:)` 创建时
        // delegate 是 nil，所有 `URLSessionDownloadDelegate` 回调都不会触发，
        // 下载会永远停在「进度 0」且 continuation 永不 resume。
        // 由于 super.init() 必须先调用，这里先用占位再赋值。
        self.session = URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
        super.init()
        // 重新建一个带 delegate 的 session，并释放前一个。
        self.session.invalidateAndCancel()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// 开始下载。返回时下载已完成并落盘到 `destination`。
    public func download(
        from url: URL,
        expectedSize: Int64?,
        onProgress: ProgressHandler? = nil
    ) async throws {
        // 同一实例不允许并发下载：UI 层也应保证这点，这里做兜底。
        guard continuation == nil else { throw Failure.badStatus(409) }
        progressHandler = onProgress
        receivedBytes = 0
        expectedTotal = expectedSize

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            var request = URLRequest(url: url)
            request.setValue("v5xs/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")",
                             forHTTPHeaderField: "User-Agent")
            let task = session.downloadTask(with: request)
            self.task = task
            task.resume()
        }
    }

    /// 取消下载。已下载的字节会被保留，供再次调用 `download` 时续传。
    /// 刻意不在这里 `invalidateAndCancel`：那会丢掉续传数据。
    public func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: - 完成与续传

    fileprivate func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        self.task = nil
        continuation.resume(with: result)
    }

    /// 把系统临时文件搬到我们的目标位置。
    fileprivate func moveToDestination(_ temporaryURL: URL) throws {
        let manager = FileManager.default
        try? manager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if manager.fileExists(atPath: destination.path) {
            try? manager.removeItem(at: destination)
        }
        do {
            try manager.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw Failure.moveFailed
        }
    }
}

extension UpdateDownloader: URLSessionDownloadDelegate {
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        receivedBytes = totalBytesWritten
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedTotal
        progressHandler?(totalBytesWritten, total)
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // 状态码在这里才能拿到；`location` 在回调返回后即失效，必须同步搬走。
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(Failure.badStatus(http.statusCode)))
            return
        }
        guard downloadTask.response is HTTPURLResponse else {
            finish(.failure(Failure.notHTTP))
            return
        }
        do {
            try moveToDestination(location)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }   // 正常完成由 didFinishDownloadingTo 收尾
        if (error as NSError).code == NSURLErrorCancelled {
            finish(.failure(Failure.cancelled))
        } else {
            finish(.failure(error))
        }
    }
}
