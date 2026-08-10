import Foundation
import os

/// HTTP downloader for the (open) Lottie asset CDN.
///
/// Uses a realistic browser identity because the *asset* CDN happily serves
/// direct requests, while mirroring real-client headers keeps us off naive
/// bot heuristics. Concurrency is bounded by an injected `AsyncSemaphore`.
public actor Downloader {

    public enum Failure: Error, Sendable, Equatable {
        case noResponse
        case status(Int)
        case empty
        case timeout
        case message(String)
    }

    private let session: URLSession
    private let semaphore: AsyncSemaphore

    public init(concurrency: Int = 8, timeout: TimeInterval = 60) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.waitsForConnectivity = true
        config.httpAdditionalHeaders = [
            "User-Agent": Self.browserUA,
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": "https://lottiefiles.com/",
            "Origin": "https://lottiefiles.com",
        ]
        self.session = URLSession(configuration: config)
        self.semaphore = AsyncSemaphore(permits: max(1, concurrency))
    }

    public func data(for asset: LottieAsset) async throws -> Data {
        try await semaphore.withPermit { [session] in
            Logger.download.debug("⬇️ \(asset.url.absoluteString, privacy: .public)")
            do {
                let (data, response) = try await session.data(from: asset.url)
                guard let http = response as? HTTPURLResponse else {
                    throw Failure.noResponse
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw Failure.status(http.statusCode)
                }
                guard !data.isEmpty else { throw Failure.empty }
                return data
            } catch let failure as Failure {
                throw failure
            } catch let urlError as URLError where urlError.code == .timedOut {
                throw Failure.timeout
            } catch {
                throw Failure.message(error.localizedDescription)
            }
        }
    }

    nonisolated static let browserUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
}
