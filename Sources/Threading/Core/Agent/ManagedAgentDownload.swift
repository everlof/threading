import Foundation

/// URLSession streams into a temporary file. The delegate caps both advertised and received
/// bytes, accepts only HTTPS on the pinned publisher host, and removes cookies from the request.
final class ManagedAgentDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let host: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var failure: Error?

    private init(destination: URL, host: String) {
        self.destination = destination
        self.host = host
    }

    static func fetch(_ url: URL, to destination: URL) async throws {
        guard url.scheme == "https", let host = url.host else { throw ManagedAgentError.invalidArchive }
        let download = ManagedAgentDownload(destination: destination, host: host)
        try await withTaskCancellationHandler {
            try await download.start(url)
        } onCancel: { download.cancel() }
    }

    private func start(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 600
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.httpAdditionalHeaders = ["User-Agent": "Threading-AgentTools/1.0"]
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            let task = session.downloadTask(with: url)
            let wasCancelled = lock.withLock {
                self.continuation = continuation
                self.task = task
                return cancelled
            }
            task.resume()
            if wasCancelled { task.cancel() }
            session.finishTasksAndInvalidate()
        }
    }

    private func cancel() {
        let task = lock.withLock { cancelled = true; return self.task }
        task?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", request.url?.host == host else {
            lock.withLock { failure = ManagedAgentError.downloadFailed(response.statusCode) }
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > ManagedAgentCatalog.maximumDownloadBytes
            || totalBytesExpectedToWrite > ManagedAgentCatalog.maximumDownloadBytes {
            lock.withLock { failure = ManagedAgentError.invalidArchive }
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  response.statusCode == 200 else {
                throw ManagedAgentError.downloadFailed(
                    (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
                )
            }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= ManagedAgentCatalog.maximumDownloadBytes else { throw ManagedAgentError.invalidArchive }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { lock.withLock { failure = error } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Error?) in
            defer { continuation = nil; self.task = nil }
            return (continuation, cancelled ? CancellationError() : failure ?? error)
        }
        if let error = result.1 { result.0?.resume(throwing: error) }
        else { result.0?.resume() }
    }
}
