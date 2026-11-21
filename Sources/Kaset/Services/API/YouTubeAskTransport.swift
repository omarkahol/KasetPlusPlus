import Foundation
import YouTubeAskCore

// MARK: - YouTubeAskHTTPResponse

struct YouTubeAskHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
}

// MARK: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable

extension YouTubeAskHTTPResponse: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "<redacted YouTube Ask HTTP response>"
    }

    var debugDescription: String {
        self.description
    }

    var customMirror: Mirror {
        Mirror(reflecting: self.description)
    }
}

// MARK: - YouTubeAskTransportError

enum YouTubeAskTransportError: Error, Sendable {
    case responseTooLarge
    case invalidResponse
}

// MARK: - YouTubeAskTransport

final class YouTubeAskTransport: @unchecked Sendable {
    private let session: URLSession
    private let delegate: YouTubeAskSessionDelegate

    init(configuration: URLSessionConfiguration) {
        let sanitizedConfiguration = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        sanitizedConfiguration.urlCache = nil
        sanitizedConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sanitizedConfiguration.httpCookieStorage = nil
        sanitizedConfiguration.httpShouldSetCookies = false

        let delegate = YouTubeAskSessionDelegate()
        self.delegate = delegate
        self.session = URLSession(
            configuration: sanitizedConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    deinit {
        self.session.finishTasksAndInvalidate()
    }

    func send(_ request: URLRequest) async throws -> YouTubeAskHTTPResponse {
        guard let originURL = request.url else {
            throw YouTubeAskTransportError.invalidResponse
        }
        let task = self.session.dataTask(with: request)
        let taskIdentifier = task.taskIdentifier
        let delegate = self.delegate
        let loader = YouTubeAskBoundedResponseLoader(
            originURL: originURL,
            maximumBytes: YouTubeAskLimits.maximumResponseBytes,
            task: task,
            onFinish: {
                delegate.unregister(taskIdentifier: taskIdentifier)
            }
        )
        delegate.register(loader, forTaskIdentifier: taskIdentifier)
        let (data, response) = try await loader.load()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw YouTubeAskTransportError.invalidResponse
        }
        return YouTubeAskHTTPResponse(
            data: data,
            statusCode: httpResponse.statusCode
        )
    }
}

// MARK: - YouTubeAskSessionDelegate

private final class YouTubeAskSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var loaders: [Int: YouTubeAskBoundedResponseLoader] = [:]

    func register(_ loader: YouTubeAskBoundedResponseLoader, forTaskIdentifier taskIdentifier: Int) {
        self.lock.lock()
        self.loaders[taskIdentifier] = loader
        self.lock.unlock()
    }

    func unregister(taskIdentifier: Int) {
        self.lock.lock()
        self.loaders.removeValue(forKey: taskIdentifier)
        self.lock.unlock()
    }

    private func loader(for task: URLSessionTask) -> YouTubeAskBoundedResponseLoader? {
        self.lock.lock()
        let loader = self.loaders[task.taskIdentifier]
        self.lock.unlock()
        return loader
    }

    private func takeLoader(for task: URLSessionTask) -> YouTubeAskBoundedResponseLoader? {
        self.lock.lock()
        let loader = self.loaders.removeValue(forKey: task.taskIdentifier)
        self.lock.unlock()
        return loader
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let loader = self.loader(for: task) else {
            completionHandler(nil)
            return
        }
        loader.handleRedirect(newRequest: request, completionHandler: completionHandler)
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let loader = self.loader(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        loader.handleResponse(response, completionHandler: completionHandler)
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        self.loader(for: dataTask)?.handleData(data)
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        self.takeLoader(for: task)?.handleCompletion(error: error)
    }
}

// MARK: - YouTubeAskBoundedResponseLoader

private final class YouTubeAskBoundedResponseLoader: @unchecked Sendable {
    private let scheme: String?
    private let host: String?
    private let port: Int?
    private let maximumBytes: Int
    private let task: URLSessionDataTask
    private let onFinish: () -> Void
    private let lock = NSLock()

    private var continuation: CheckedContinuation<(Data, URLResponse), any Error>?
    private var response: URLResponse?
    private var responseData = Data()
    private var isFinished = false
    private var cancellationRequested = false

    init(
        originURL: URL,
        maximumBytes: Int,
        task: URLSessionDataTask,
        onFinish: @escaping () -> Void
    ) {
        self.scheme = originURL.scheme?.lowercased()
        self.host = originURL.host?.lowercased()
        self.port = Self.effectivePort(for: originURL)
        self.maximumBytes = maximumBytes
        self.task = task
        self.onFinish = onFinish
    }

    func load() async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.lock.lock()
                if self.cancellationRequested {
                    self.isFinished = true
                    self.lock.unlock()
                    self.onFinish()
                    self.task.cancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.lock.unlock()

                self.task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func handleRedirect(
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == self.scheme,
              url.host?.lowercased() == self.host,
              Self.effectivePort(for: url) == self.port
        else {
            completionHandler(nil)
            self.finish(
                .failure(YouTubeAskTransportError.invalidResponse),
                cancelTask: true
            )
            return
        }
        completionHandler(request)
    }

    func handleResponse(
        _ response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let exceedsLimit = response.expectedContentLength > 0
            && response.expectedContentLength > Int64(self.maximumBytes)
        guard !exceedsLimit else {
            completionHandler(.cancel)
            self.finish(
                .failure(YouTubeAskTransportError.responseTooLarge),
                cancelTask: true
            )
            return
        }

        self.lock.lock()
        if !self.isFinished {
            self.response = response
            if response.expectedContentLength > 0 {
                self.responseData.reserveCapacity(
                    min(Int(response.expectedContentLength), self.maximumBytes)
                )
            }
        }
        self.lock.unlock()
        completionHandler(.allow)
    }

    func handleData(_ data: Data) {
        var exceedsLimit = false
        self.lock.lock()
        if !self.isFinished {
            if data.count > self.maximumBytes - self.responseData.count {
                exceedsLimit = true
            } else {
                self.responseData.append(data)
            }
        }
        self.lock.unlock()

        if exceedsLimit {
            self.finish(
                .failure(YouTubeAskTransportError.responseTooLarge),
                cancelTask: true
            )
        }
    }

    func handleCompletion(error: (any Error)?) {
        if let error {
            if (error as? URLError)?.code == .cancelled {
                self.finish(.failure(CancellationError()), cancelTask: true)
            } else {
                self.finish(.failure(error), cancelTask: true)
            }
            return
        }

        self.lock.lock()
        let response = self.response
        let data = self.responseData
        self.lock.unlock()

        guard let response else {
            self.finish(
                .failure(YouTubeAskTransportError.invalidResponse),
                cancelTask: true
            )
            return
        }
        self.finish(.success((data, response)), cancelTask: false)
    }

    private func cancel() {
        self.lock.lock()
        self.cancellationRequested = true
        let shouldFinish = self.continuation != nil && !self.isFinished
        self.lock.unlock()
        if shouldFinish {
            self.finish(.failure(CancellationError()), cancelTask: true)
        }
    }

    private func finish(
        _ result: Result<(Data, URLResponse), any Error>,
        cancelTask: Bool
    ) {
        self.lock.lock()
        guard !self.isFinished else {
            self.lock.unlock()
            return
        }
        self.isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()

        self.onFinish()
        if cancelTask {
            self.task.cancel()
        }
        continuation?.resume(with: result)
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "https":
            return 443
        case "http":
            return 80
        default:
            return nil
        }
    }
}
