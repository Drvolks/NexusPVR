import Foundation

/// Estimates the growing duration of an in-progress recording via HTTP HEAD
/// requests, without disrupting playback.
///
/// EOF handling (reload at current position) is done by `MPVPlayerCore`'s
/// position-polling timer via `checkRecordingEOF()`. This class provides
/// updated duration estimates so the player can reload proactively before
/// EOF when possible.
final class MPVRecordingMonitor {
    private(set) var currentURL: String?

    private var baselineDuration: Double = 0
    private var baselineContentLength: Int64 = 0
    private var baselineCaptured = false
    private var _estimatedDuration: Double = 0
    private var lastRefreshTime: Date = .distantPast
    private var refreshInFlight = false

    /// How often to poll the server (seconds). HEAD requests are just headers
    /// (few hundred bytes), so polling frequently is fine.
    var refreshInterval: TimeInterval = 2

    /// Called periodically with the estimated total duration (seconds).
    var onDurationEstimate: ((Double) -> Void)?

    /// Called when the recording finishes (detected by MPVPlayerCore when
    /// two consecutive EOFs yield the same duration).
    var onRecordingFinished: (() -> Void)?

    /// The latest estimated duration. Returns 0 if no estimate is available.
    var estimatedDuration: Double { _estimatedDuration }

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    /// No-op kept for call-site compatibility.
    func configure(mpv: OpaquePointer) {}

    /// Start duration estimation. Call after `mpv_initialize()` and `loadfile`.
    func start(mpv: OpaquePointer, url: String) {
        stop()
        self.currentURL = url
        baselineCaptured = false
        _estimatedDuration = 0
        lastRefreshTime = .distantPast
        print("RecordingMonitor: started for \(url)")
    }

    /// Stop estimation.
    func stop() {
        currentURL = nil
        baselineCaptured = false
        _estimatedDuration = 0
    }

    /// Call periodically (e.g. from the position-polling timer) with the
    /// current mpv duration so the monitor can capture its baseline.
    func updateBaseline(duration: Double) {
        guard !baselineCaptured, duration > 0 else { return }
        baselineDuration = duration
        _estimatedDuration = duration
        baselineCaptured = true

        fetchContentLength { [weak self] size in
            guard let self else { return }
            self.baselineContentLength = size
            print("RecordingMonitor: baseline captured — "
                + "duration=\(String(format: "%.1f", duration))s, "
                + "size=\(size) bytes")
        }
    }

    /// Reset the baseline so it gets recaptured on the next `updateBaseline`
    /// call (e.g. after a stream reload).
    func resetBaseline() {
        baselineCaptured = false
    }

    /// Called every position-polling tick (~0.5s). Fires a HEAD request if
    /// enough time has elapsed based on whether we're at the live edge.
    func refreshIfNeeded() {
        guard baselineContentLength > 0, baselineDuration > 0, !refreshInFlight else { return }

        guard Date().timeIntervalSince(lastRefreshTime) >= refreshInterval else { return }

        lastRefreshTime = Date()
        refreshInFlight = true

        fetchContentLength { [weak self] newSize in
            guard let self, newSize > 0 else {
                self?.refreshInFlight = false
                return
            }
            let estimated = self.baselineDuration * Double(newSize) / Double(self.baselineContentLength)
            self._estimatedDuration = estimated
            self.refreshInFlight = false
            self.onDurationEstimate?(estimated)
        }
    }

    // MARK: - Private

    private func fetchContentLength(completion: @escaping (Int64) -> Void) {
        guard let urlString = currentURL, let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        urlSession.dataTask(with: request) { _, response, _ in
            guard let http = response as? HTTPURLResponse,
                  let clStr = http.value(forHTTPHeaderField: "Content-Length"),
                  let cl = Int64(clStr), cl > 0 else { return }
            completion(cl)
        }.resume()
    }
}
