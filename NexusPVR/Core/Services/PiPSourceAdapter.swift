import Foundation
import Network

struct PiPPreparedSource {
    let url: URL
    let headers: [String: String]
}

final class PiPSourceAdapter {
    static let shared = PiPSourceAdapter()

    private init() {}

    func prepare(url: URL, headers: [String: String]) async -> PiPPreparedSource {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return PiPPreparedSource(url: url, headers: headers)
        }

        var preparedURL = url
        var preparedHeaders = headers

        if let resolved = await resolveWrappedPlaylistIfNeeded(url: url, headers: headers) {
            preparedURL = resolved.url
            preparedHeaders = resolved.headers
        }

        // Local URLs are already app-controlled.
        if let host = preparedURL.host?.lowercased(), host == "127.0.0.1" || host == "localhost" {
            return PiPPreparedSource(url: preparedURL, headers: [:])
        }

        let hasRange = await supportsByteRange(url: preparedURL, headers: preparedHeaders)
        if hasRange {
            return PiPPreparedSource(url: preparedURL, headers: preparedHeaders)
        }

        // AVPlayer PiP rejects some live TS endpoints that ignore Range and always return 200 chunked.
        if let proxyURL = PiPLocalStreamProxy.shared.proxyURL(for: preparedURL, headers: preparedHeaders) {
            print("PiPAdapter: using local range proxy url=\(proxyURL.absoluteString)")
            return PiPPreparedSource(url: proxyURL, headers: [:])
        }

        return PiPPreparedSource(url: preparedURL, headers: preparedHeaders)
    }

    func release(url: URL) {
        PiPLocalStreamProxy.shared.release(url: url)
    }

    private func resolveWrappedPlaylistIfNeeded(url: URL, headers: [String: String]) async -> PiPPreparedSource? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.setValue("application/vnd.apple.mpegurl,application/x-mpegURL,text/plain,*/*", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse {
                print("PiPAdapter: probe status=\(http.statusCode) type=\(http.value(forHTTPHeaderField: "Content-Type") ?? "<none>") url=\(url.absoluteString)")
            }

            var collected = Data()
            for try await byte in bytes {
                collected.append(byte)
                if collected.count >= 64 * 1024 { break }
            }

            guard let text = String(data: collected, encoding: .utf8),
                  text.contains("#EXTM3U") else {
                return nil
            }

            let hasHLSTags = text.contains("#EXTINF") || text.contains("#EXT-X-TARGETDURATION") || text.contains("#EXT-X-STREAM-INF")
            if hasHLSTags {
                print("PiPAdapter: source is HLS manifest, keeping original URL")
                return PiPPreparedSource(url: url, headers: headers)
            }

            if let resolvedURL = resolveFirstMediaEntry(in: text, relativeTo: url) {
                var resolvedHeaders = headers
                if resolvedURL.host?.lowercased() != url.host?.lowercased() {
                    resolvedHeaders.removeValue(forKey: "Authorization")
                }
                print("PiPAdapter: resolved wrapped media URL=\(resolvedURL.absoluteString)")
                return PiPPreparedSource(url: resolvedURL, headers: resolvedHeaders)
            }

            print("PiPAdapter: wrapper playlist had no playable entry")
            return nil
        } catch {
            print("PiPAdapter: probe failed error=\(error.localizedDescription)")
            return nil
        }
    }

    private func supportsByteRange(url: URL, headers: [String: String]) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 4
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            // Consume a tiny amount so the request validates quickly on live streams.
            var consumed = 0
            for try await _ in bytes {
                consumed += 1
                if consumed >= 2 { break }
            }
            guard let http = response as? HTTPURLResponse else { return false }
            let contentRange = http.value(forHTTPHeaderField: "Content-Range") ?? "<none>"
            let supports = http.statusCode == 206 && contentRange.lowercased().hasPrefix("bytes ")
            print("PiPAdapter: range probe status=\(http.statusCode) contentRange=\(contentRange) supports=\(supports)")
            return supports
        } catch {
            print("PiPAdapter: range probe failed error=\(error.localizedDescription)")
            return false
        }
    }

    private func resolveFirstMediaEntry(in m3uText: String, relativeTo baseURL: URL) -> URL? {
        for rawLine in m3uText.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let absolute = URL(string: line), absolute.scheme != nil {
                return absolute
            }
            if let relative = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                return relative
            }
        }
        return nil
    }
}

private struct PiPProxyRoute {
    let upstreamURL: URL
    let headers: [String: String]
    let stream: PiPBufferedUpstream
}

private struct PiPHLSRouteState {
    var lastTargetDurationMPV: Int
    var lastMediaSequenceMPV: Int
    var lastTargetDurationPiP: Int
    var lastMediaSequencePiP: Int
}

private enum PiPHLSManifestProfile {
    case mpv
    case pip

    var windowSegments: Int {
        switch self {
        case .mpv: return 14
        case .pip: return 18
        }
    }

    var tailReserveSegments: Int {
        switch self {
        case .mpv: return 0
        case .pip: return 4
        }
    }

    var minimumPlaylistSegments: Int {
        switch self {
        case .mpv: return 2
        case .pip: return 8
        }
    }

    var fixedTargetDuration: Int? {
        switch self {
        case .mpv:
            return nil
        case .pip:
            return nil
        }
    }

    var minimumTargetDuration: Int {
        switch self {
        case .mpv:
            return 2
        case .pip:
            // Slightly higher floor for PiP to avoid overly aggressive reload cadence.
            return 4
        }
    }

    func effectiveTailReserve(totalSegments: Int) -> Int {
        switch self {
        case .mpv:
            return tailReserveSegments
        case .pip:
            // Startup: keep edge distance small so the initial playlist isn't too short.
            if totalSegments < 14 { return 1 }
            if totalSegments < 20 { return 2 }
            if totalSegments < 28 { return 3 }
            return tailReserveSegments
        }
    }

    func effectiveMinimumPlaylistSegments(totalSegments: Int) -> Int {
        switch self {
        case .mpv:
            return minimumPlaylistSegments
        case .pip:
            // Startup: allow earlier PiP start; once stream matures require deeper list.
            if totalSegments < 10 { return 4 }
            if totalSegments < 16 { return 6 }
            if totalSegments < 24 { return 7 }
            return minimumPlaylistSegments
        }
    }
}

private struct PiPHLSSegment {
    let sequence: Int
    let start: Int
    let length: Int
    let duration: Double
}

private final class PiPLocalStreamProxy {
    static let shared = PiPLocalStreamProxy()

    private static let fixedPort: UInt16 = 19091
    private static let maxRouteCount = 256
    private static let hlsFallbackSegmentDurationSeconds = 2.0
    private static let hlsFallbackTargetDuration = 2
    // Keep a finite pseudo-length so AVPlayer issues sane follow-up ranges
    // (e.g. 0-1, 0-999999, 40000-999999) instead of giant offsets.
    private static let syntheticTotalLength = 1_000_000

    private let queue = DispatchQueue(label: "nexuspvr.pip.local-proxy")
    private var listener: NWListener?
    private var port: NWEndpoint.Port?
    private var routes: [String: PiPProxyRoute] = [:]
    private var hlsRouteState: [String: PiPHLSRouteState] = [:]

    private init() {
        startIfNeeded()
    }

    func proxyURL(for upstreamURL: URL, headers: [String: String]) -> URL? {
        guard let scheme = upstreamURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        if let host = upstreamURL.host?.lowercased(), host == "127.0.0.1" || host == "localhost" {
            return upstreamURL
        }

        startIfNeeded()
        guard let port else {
            print("LocalProxy: no local port available, using upstream directly")
            return nil
        }

        let routeId = UUID().uuidString.lowercased()
        let stream = PiPBufferedUpstream(upstreamURL: upstreamURL, headers: headers)
        queue.sync {
            routes[routeId] = PiPProxyRoute(upstreamURL: upstreamURL, headers: headers, stream: stream)
            hlsRouteState[routeId] = PiPHLSRouteState(
                lastTargetDurationMPV: Self.hlsFallbackTargetDuration,
                lastMediaSequenceMPV: 0,
                lastTargetDurationPiP: Self.hlsFallbackTargetDuration,
                lastMediaSequencePiP: 0
            )
            if routes.count > Self.maxRouteCount {
                let firstKey = routes.keys.first
                if let firstKey, let evicted = routes.removeValue(forKey: firstKey) {
                    Task { await evicted.stream.stop() }
                }
                if let firstKey {
                    hlsRouteState.removeValue(forKey: firstKey)
                }
            }
        }
        Task { await stream.startIfNeeded() }
        let localURL = URL(string: "http://127.0.0.1:\(port.rawValue)/hls/\(routeId)/index.m3u8")
        if let localURL {
            print("LocalProxy: mapped \(upstreamURL.absoluteString) -> \(localURL.absoluteString)")
        }
        return localURL
    }

    func release(url: URL) {
        guard let routeId = routeId(from: url) else { return }
        let removed: PiPProxyRoute? = queue.sync {
            hlsRouteState.removeValue(forKey: routeId)
            return routes.removeValue(forKey: routeId)
        }
        if let removed {
            Task { await removed.stream.stop() }
            print("LocalProxy: released route \(routeId)")
        }
    }

    private func startIfNeeded() {
        queue.sync {
            guard listener == nil else { return }
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                guard let fixedPort = NWEndpoint.Port(rawValue: Self.fixedPort) else {
                    print("LocalProxy: invalid fixed port \(Self.fixedPort)")
                    return
                }
                let listener = try NWListener(using: params, on: fixedPort)
                self.port = fixedPort
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection: connection)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        print("LocalProxy: listening on 127.0.0.1:\(fixedPort.rawValue)")
                    case .failed(let error):
                        print("LocalProxy: listener failed \(error)")
                        self.listener = nil
                        self.port = nil
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                print("LocalProxy: failed to start \(error)")
            }
        }
    }

    private func handle(connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("LocalProxy: connection failed \(error)")
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                print("LocalProxy: receive error \(error)")
                connection.cancel()
                return
            }
            var nextBuffer = buffer
            if let data { nextBuffer.append(data) }
            if let range = nextBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = nextBuffer[..<range.lowerBound]
                let headerText = String(data: headerData, encoding: .utf8) ?? ""
                self.handleHTTPHeader(headerText, on: connection)
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receiveRequest(on: connection, buffer: nextBuffer)
        }
    }

    private func handleHTTPHeader(_ headerText: String, on connection: NWConnection) {
        let lines = headerText.components(separatedBy: .newlines)
        guard let firstLine = lines.first else {
            Task { await sendHTTPError(status: "400 Bad Request", on: connection) }
            return
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            Task { await sendHTTPError(status: "400 Bad Request", on: connection) }
            return
        }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1])
        let pathOnly = String(path.split(separator: "?").first ?? "")
        let pathParts = pathOnly.split(separator: "/").map(String.init)

        guard !pathParts.isEmpty else {
            Task { await sendHTTPError(status: "404 Not Found", on: connection) }
            return
        }

        // HLS endpoints
        if pathParts.count >= 3 && pathParts[0] == "hls" {
            let routeId = pathParts[1]
            guard let route = routes[routeId] else {
                Task { await sendHTTPError(status: "404 Not Found", on: connection) }
                return
            }

            if pathParts[2] == "index.m3u8" {
                print("LocalProxy: \(method) /hls/\(routeId)/index.m3u8")
                Task { await serveHLSManifest(routeId: routeId, route: route, method: method, on: connection, profile: .mpv) }
                return
            }

            if pathParts[2] == "pip.m3u8" {
                print("LocalProxy: \(method) /hls/\(routeId)/pip.m3u8")
                Task { await serveHLSManifest(routeId: routeId, route: route, method: method, on: connection, profile: .pip) }
                return
            }

            if pathParts.count >= 4, pathParts[2] == "seg" {
                let token = pathParts[3]
                let seqText = token.replacingOccurrences(of: ".ts", with: "")
                guard let seq = Int(seqText), seq >= 0 else {
                    Task { await sendHTTPError(status: "404 Not Found", on: connection) }
                    return
                }
                print("LocalProxy: \(method) /hls/\(routeId)/seg/\(seq).ts")
                Task { await serveHLSSegment(route: route, segmentIndex: seq, method: method, on: connection) }
                return
            }

            Task { await sendHTTPError(status: "404 Not Found", on: connection) }
            return
        }

        // Legacy stream endpoint (fallback)
        guard pathOnly.hasPrefix("/stream/") else {
            Task { await sendHTTPError(status: "404 Not Found", on: connection) }
            return
        }
        let routeToken = String(pathOnly.dropFirst("/stream/".count))
        let routeId = routeToken.split(separator: ".").first.map(String.init) ?? ""
        guard !routeId.isEmpty else {
            Task { await sendHTTPError(status: "404 Not Found", on: connection) }
            return
        }
        guard let route = routes[routeId] else {
            Task { await sendHTTPError(status: "404 Not Found", on: connection) }
            return
        }

        var incomingHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let sep = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<sep]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: sep)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                incomingHeaders[key] = value
            }
        }
        let rangeHeader = headerValue("Range", in: incomingHeaders) ?? "<none>"
        print("LocalProxy: \(method) \(path) range=\(rangeHeader)")
        Task {
            await streamUpstream(route: route, method: method, incomingHeaders: incomingHeaders, on: connection)
        }
    }

    private func routeId(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count >= 3, parts[0] == "hls" {
            return parts[1]
        }
        if parts.count >= 2, parts[0] == "stream" {
            return parts[1].split(separator: ".").first.map(String.init)
        }
        return nil
    }

    private func serveHLSManifest(routeId: String, route: PiPProxyRoute, method: String, on connection: NWConnection, profile: PiPHLSManifestProfile) async {
        guard method == "GET" || method == "HEAD" else {
            await sendHTTPError(status: "405 Method Not Allowed", on: connection)
            return
        }

        await route.stream.startIfNeeded()

        var segments: [PiPHLSSegment] = []
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let window = profile.windowSegments
            segments = await route.stream.hlsSegments(window: window)
            if segments.count >= 2 {
                break
            }
            try? await Task.sleep(for: .milliseconds(120))
        }

        guard !segments.isEmpty else {
            print("LocalProxy: HLS manifest unavailable route=\(routeId)")
            await sendHTTPError(status: "503 Service Unavailable", on: connection)
            return
        }

        let effectiveTailReserve = profile.effectiveTailReserve(totalSegments: segments.count)
        let effectiveMinimumPlaylistSegments = profile.effectiveMinimumPlaylistSegments(totalSegments: segments.count)

        let publishable: [PiPHLSSegment]
        if segments.count > effectiveTailReserve {
            publishable = Array(segments.dropLast(effectiveTailReserve))
        } else {
            publishable = segments
        }
        let finalPublishable: [PiPHLSSegment]
        if publishable.count >= effectiveMinimumPlaylistSegments {
            finalPublishable = publishable
        } else {
            // Never fail live startup for clients like mpv; expose partial window
            // and let the player continue polling while prebuffer grows.
            finalPublishable = publishable
            print("LocalProxy: HLS manifest warming route=\(routeId) profile=\(profile == .pip ? "pip" : "mpv") have=\(publishable.count) need=\(effectiveMinimumPlaylistSegments)")
        }

        var state = queue.sync {
            hlsRouteState[routeId] ?? PiPHLSRouteState(
                lastTargetDurationMPV: Self.hlsFallbackTargetDuration,
                lastMediaSequenceMPV: finalPublishable.first?.sequence ?? 0,
                lastTargetDurationPiP: Self.hlsFallbackTargetDuration,
                lastMediaSequencePiP: finalPublishable.first?.sequence ?? 0
            )
        }

        let previousTargetDuration: Int
        let previousMediaSequence: Int
        switch profile {
        case .mpv:
            previousTargetDuration = state.lastTargetDurationMPV
            previousMediaSequence = state.lastMediaSequenceMPV
        case .pip:
            previousTargetDuration = state.lastTargetDurationPiP
            previousMediaSequence = state.lastMediaSequencePiP
        }

        let maxDuration = finalPublishable.map(\.duration).max() ?? Self.hlsFallbackSegmentDurationSeconds
        let rawTarget = profile.fixedTargetDuration ?? max(profile.minimumTargetDuration, Int(ceil(maxDuration)))
        let targetDuration: Int
        if rawTarget >= previousTargetDuration {
            targetDuration = rawTarget
        } else {
            targetDuration = max(rawTarget, previousTargetDuration - 1)
        }

        let minPublishedSequence = max(previousMediaSequence, finalPublishable.first?.sequence ?? 0)
        let filtered = finalPublishable.filter { $0.sequence >= minPublishedSequence }
        let finalSegments = filtered.isEmpty ? finalPublishable : filtered
        let firstShown = finalSegments.first?.sequence ?? 0
        let lastShown = finalSegments.last?.sequence ?? 0
        let estimatedBytesPerSecond = await route.stream.estimatedBytesPerSecond()
        print("LocalProxy: HLS manifest route=\(routeId) profile=\(profile == .pip ? "pip" : "mpv") bps=\(Int(estimatedBytesPerSecond)) target=\(targetDuration) window=\(firstShown)-\(lastShown) segCount=\(finalSegments.count)")

        switch profile {
        case .mpv:
            state.lastTargetDurationMPV = targetDuration
            state.lastMediaSequenceMPV = firstShown
        case .pip:
            state.lastTargetDurationPiP = targetDuration
            state.lastMediaSequencePiP = firstShown
        }
        queue.sync {
            hlsRouteState[routeId] = state
        }

        var playlist = "#EXTM3U\n"
        playlist += "#EXT-X-VERSION:3\n"
        playlist += "#EXT-X-INDEPENDENT-SEGMENTS\n"
        playlist += "#EXT-X-TARGETDURATION:\(targetDuration)\n"
        playlist += "#EXT-X-MEDIA-SEQUENCE:\(firstShown)\n"
        if profile == .pip {
            // Hint AVPlayer to stay close to the live edge after stalls instead of
            // resuming from the beginning of the published window.
            let holdBackSeconds = max(Double(targetDuration) * 3.0, 8.0)
            playlist += String(format: "#EXT-X-START:TIME-OFFSET=-%.3f,PRECISE=NO\n", holdBackSeconds)
        }
        for segment in finalSegments {
            playlist += String(format: "#EXTINF:%.3f,\n", segment.duration)
            playlist += "seg/\(segment.sequence).ts\n"
        }

        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: application/vnd.apple.mpegurl\r\n"
        header += "Cache-Control: no-cache\r\n"
        header += "Connection: close\r\n"
        header += "Content-Length: \(playlist.utf8.count)\r\n\r\n"
        _ = try? await send(Data(header.utf8), on: connection)
        if method == "GET" {
            _ = try? await send(Data(playlist.utf8), on: connection)
        }
        connection.cancel()
    }

    private func serveHLSSegment(route: PiPProxyRoute, segmentIndex: Int, method: String, on connection: NWConnection) async {
        guard method == "GET" || method == "HEAD" else {
            await sendHTTPError(status: "405 Method Not Allowed", on: connection)
            return
        }
        await route.stream.startIfNeeded()

        guard let segment = await route.stream.hlsSegment(sequence: segmentIndex) else {
            print("LocalProxy: HLS segment missing seq=\(segmentIndex)")
            await sendHTTPError(status: "404 Not Found", on: connection)
            return
        }
        let start = segment.start
        let length = segment.length
        if method == "HEAD" {
            var header = "HTTP/1.1 200 OK\r\n"
            header += "Content-Type: video/mp2t\r\n"
            header += "Cache-Control: no-cache\r\n"
            header += "Connection: close\r\n"
            header += "Content-Length: \(length)\r\n\r\n"
            _ = try? await send(Data(header.utf8), on: connection)
            connection.cancel()
            return
        }

        guard let data = await route.stream.read(start: start, length: length, timeout: 30) else {
            let debug = await route.stream.debugState(forStart: start, end: start + length - 1)
            print("LocalProxy: HLS segment unavailable seq=\(segmentIndex) state=\(debug)")
            await sendHTTPError(status: "503 Service Unavailable", on: connection)
            return
        }

        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: video/mp2t\r\n"
        header += "Cache-Control: no-cache\r\n"
        header += "Connection: close\r\n"
        header += "Content-Length: \(data.count)\r\n\r\n"
        _ = try? await send(Data(header.utf8), on: connection)

        if data.isEmpty {
            print("LocalProxy: HLS segment empty seq=\(segmentIndex)")
            connection.cancel()
            return
        }
        _ = try? await send(data, on: connection)
        print("LocalProxy: HLS segment served seq=\(segmentIndex) bytes=\(data.count)")
        connection.cancel()
    }

    private func streamUpstream(route: PiPProxyRoute, method: String, incomingHeaders: [String: String], on connection: NWConnection) async {
        guard method == "GET" || method == "HEAD" else {
            await sendHTTPError(status: "405 Method Not Allowed", on: connection)
            return
        }

        await route.stream.startIfNeeded()
        let contentType = await route.stream.currentContentType()
        let requestRange = headerValue("Range", in: incomingHeaders) ?? "<none>"
        let upstreamStatus = await route.stream.currentStatusCode()
        print("LocalProxy: upstream status=\(upstreamStatus) type=\(contentType) requestRange=\(requestRange)")

        if method == "HEAD" {
            var header = "HTTP/1.1 200 OK\r\n"
            header += "Content-Type: \(contentType)\r\n"
            header += "Accept-Ranges: bytes\r\n"
            header += "Connection: close\r\n\r\n"
            _ = try? await send(Data(header.utf8), on: connection)
            connection.cancel()
            return
        }

        guard let rangeHeader = headerValue("Range", in: incomingHeaders),
              let requested = parseByteRange(rangeHeader) else {
            var header = "HTTP/1.1 416 Range Not Satisfiable\r\n"
            header += "Content-Range: bytes */\(Self.syntheticTotalLength)\r\n"
            header += "Connection: close\r\n\r\n"
            _ = try? await send(Data(header.utf8), on: connection)
            print("LocalProxy: rejected missing/invalid range range=\(requestRange)")
            connection.cancel()
            return
        }

        let ranged = normalizeRange(requested)
        var header = "HTTP/1.1 206 Partial Content\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Accept-Ranges: bytes\r\n"
        header += "Content-Range: bytes \(ranged.start)-\(ranged.end)/\(Self.syntheticTotalLength)\r\n"
        header += "Content-Length: \(ranged.length)\r\n"
        header += "Connection: close\r\n\r\n"

        do {
            try await send(Data(header.utf8), on: connection)
            print("LocalProxy: synthesized 206 start=\(ranged.start) end=\(ranged.end) length=\(ranged.length)")

            let waitSeconds: TimeInterval = ranged.length <= 2 ? 4 : 20
            guard let data = await route.stream.read(start: ranged.start, length: ranged.length, timeout: waitSeconds) else {
                let debug = await route.stream.debugState(forStart: ranged.start, end: ranged.end)
                print("LocalProxy: range unavailable start=\(ranged.start) end=\(ranged.end) state=\(debug)")
                await sendHTTPError(status: "503 Service Unavailable", on: connection)
                return
            }
            try await send(data, on: connection)
            if ranged.start == 0 && ranged.end <= 1 {
                print("LocalProxy: synthesized 206 for probe range=\(rangeHeader)")
            } else {
                print("LocalProxy: synthesized 206 window start=\(ranged.start) end=\(ranged.end) sent=\(data.count)")
            }
        } catch {
            if isClientDisconnect(error) {
                print("LocalProxy: client disconnected during range=\(rangeHeader)")
            } else {
                print("LocalProxy: proxy send failed error=\(error.localizedDescription) url=\(route.upstreamURL.absoluteString)")
            }
        }
        connection.cancel()
    }

    private func normalizeRange(_ requested: (start: Int, end: Int)) -> (start: Int, end: Int, length: Int) {
        let maxIndex = Self.syntheticTotalLength - 1
        let clampedStart = min(max(0, requested.start), maxIndex)
        let clampedEnd = min(max(clampedStart, requested.end), maxIndex)
        let length = clampedEnd - clampedStart + 1
        return (clampedStart, clampedEnd, length)
    }

    private func sendHTTPError(status: String, on connection: NWConnection) async {
        let body = status
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        _ = try? await send(Data(response.utf8), on: connection)
        connection.cancel()
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    private func parseByteRange(_ header: String) -> (start: Int, end: Int)? {
        let lower = header.lowercased()
        guard lower.hasPrefix("bytes=") else { return nil }
        // If multiple ranges are requested, use the first one.
        let value = lower.dropFirst("bytes=".count).split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let comps = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard comps.count == 2 else { return nil }
        let left = comps[0].trimmingCharacters(in: .whitespaces)
        let right = comps[1].trimmingCharacters(in: .whitespaces)
        if left.isEmpty {
            // Suffix range: bytes=-N
            guard let suffixLen = Int(right), suffixLen > 0 else { return nil }
            let end = Self.syntheticTotalLength - 1
            let start = max(0, end - suffixLen + 1)
            return (start, end)
        }
        guard let start = Int(left), start >= 0 else { return nil }
        if right.isEmpty {
            // Open ended: bytes=N-
            return (start, Self.syntheticTotalLength - 1)
        }
        guard let end = Int(right), end >= start else { return nil }
        return (start, end)
    }

    private func headerValue(_ key: String, in headers: [String: String]) -> String? {
        if let direct = headers[key] { return direct }
        let target = key.lowercased()
        return headers.first(where: { $0.key.lowercased() == target })?.value
    }

    private func isClientDisconnect(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSPOSIXErrorDomain else { return false }
        return ns.code == Int(ECONNRESET) || ns.code == Int(ENOTCONN) || ns.code == Int(EPIPE)
    }
}

private actor PiPBufferedUpstream {
    private static let enableForcedPATBoundaries = false
    private let upstreamURL: URL
    private let headers: [String: String]

    private var task: Task<Void, Never>?
    private var baseOffset = 0
    private var buffer = Data()
    private var ended = false
    private var lastError: String?
    private var contentType = "video/mp2t"
    private var statusCode = 200
    private var transportAligned = false
    private var virtualOriginOffset: Int?
    private var waitingForKeyframeLogged = false
    private var throughputWindowStart = Date()
    private var throughputWindowBytes = 0
    private var lastEstimatedBytesPerSecond = 1_200_000.0
    private var hlsSegmentStartsAbsolute: [Int] = []
    private var hlsSequenceBase = 0
    private var scannedForKeyframesAbsolute = 0

    private let maxBufferBytes = 96_000_000
    private let minHLSSegmentBytesFloor = 600_000
    private let minHLSSegmentBytesCeiling = 1_200_000
    private let minHLSSegmentDurationSeconds = 0.6
    private let maxHLSSegmentBytesFloor = 1_500_000
    private let maxHLSSegmentBytesCeiling = 2_500_000
    private let maxHLSSegmentDurationSeconds = 1.8
    private let patLookbackPackets = 1600
    private let estimatedSegmentDurationMin = 0.5
    private let estimatedSegmentDurationMax = 8.0

    init(upstreamURL: URL, headers: [String: String]) {
        self.upstreamURL = upstreamURL
        self.headers = headers
    }

    func startIfNeeded() {
        guard task == nil else { return }
        ended = false
        task = Task { [weak self] in
            await self?.pump()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        ended = true
    }

    func currentContentType() -> String {
        contentType
    }

    func currentStatusCode() -> Int {
        statusCode
    }

    func estimatedBytesPerSecond() -> Double {
        let elapsed = Date().timeIntervalSince(throughputWindowStart)
        if elapsed > 0.35, throughputWindowBytes > 0 {
            return Double(throughputWindowBytes) / elapsed
        }
        return lastEstimatedBytesPerSecond
    }

    func availableRelativeWindow() -> (start: Int, end: Int)? {
        guard transportAligned else { return nil }
        let origin = virtualOriginOffset ?? baseOffset
        let start = max(0, baseOffset - origin)
        let end = max(start, baseOffset + max(0, buffer.count - 1) - origin)
        return (start, end)
    }

    func hlsSegments(window: Int) -> [PiPHLSSegment] {
        guard transportAligned, hlsSegmentStartsAbsolute.count >= 2 else { return [] }
        let availableStart = baseOffset
        let availableEnd = baseOffset + max(0, buffer.count - 1)
        var segments: [PiPHLSSegment] = []
        for idx in 0..<(hlsSegmentStartsAbsolute.count - 1) {
            let absStart = hlsSegmentStartsAbsolute[idx]
            let absEnd = hlsSegmentStartsAbsolute[idx + 1] - 1
            if absStart < availableStart || absEnd > availableEnd || absEnd < absStart {
                continue
            }
            let sequence = hlsSequenceBase + idx
            let length = absEnd - absStart + 1
            let duration = estimatedSegmentDuration(forLength: length)
            segments.append(PiPHLSSegment(
                sequence: sequence,
                start: relativeOffset(forAbsolute: absStart),
                length: length,
                duration: duration
            ))
        }
        if segments.count > window {
            return Array(segments.suffix(window))
        }
        return segments
    }

    func hlsSegment(sequence: Int) -> PiPHLSSegment? {
        guard transportAligned else { return nil }
        let idx = sequence - hlsSequenceBase
        guard idx >= 0, idx + 1 < hlsSegmentStartsAbsolute.count else { return nil }
        let absStart = hlsSegmentStartsAbsolute[idx]
        let absEnd = hlsSegmentStartsAbsolute[idx + 1] - 1
        let availableStart = baseOffset
        let availableEnd = baseOffset + max(0, buffer.count - 1)
        guard absStart >= availableStart, absEnd <= availableEnd, absEnd >= absStart else { return nil }
        let length = absEnd - absStart + 1
        let duration = estimatedSegmentDuration(forLength: length)
        return PiPHLSSegment(
            sequence: sequence,
            start: relativeOffset(forAbsolute: absStart),
            length: length,
            duration: duration
        )
    }

    func debugState(forStart start: Int, end: Int) -> String {
        let availableEnd = baseOffset + max(0, buffer.count - 1)
        let origin = virtualOriginOffset ?? -1
        return "need=\(start)-\(end) origin=\(origin) available=\(baseOffset)-\(availableEnd) buffered=\(buffer.count) aligned=\(transportAligned) ended=\(ended) error=\(lastError ?? "<none>")"
    }

    func read(start: Int, length: Int, timeout: TimeInterval) async -> Data? {
        guard length > 0 else { return Data() }
        startIfNeeded()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let origin = virtualOriginOffset ?? baseOffset
            let absoluteStart = origin + start
            let absoluteEnd = absoluteStart + length - 1
            if absoluteStart < baseOffset {
                return nil
            }
            if !transportAligned {
                if ended { return nil }
                if Date() >= deadline { return nil }
                try? await Task.sleep(for: .milliseconds(40))
                continue
            }
            let availableEnd = baseOffset + max(0, buffer.count - 1)
            if availableEnd >= absoluteEnd {
                let localStart = absoluteStart - baseOffset
                let snapshot = buffer
                guard localStart >= 0, localStart <= snapshot.count else { return nil }
                let (localEnd, overflow) = localStart.addingReportingOverflow(length)
                guard !overflow, localEnd >= localStart, localEnd <= snapshot.count else {
                    print("LocalProxy: invalid local range localStart=\(localStart) localEnd=\(localEnd) overflow=\(overflow) snapshot=\(snapshot.count)")
                    return nil
                }
                let lower = snapshot.index(snapshot.startIndex, offsetBy: localStart)
                let upper = snapshot.index(lower, offsetBy: length)
                return Data(snapshot[lower..<upper])
            }
            if ended {
                return nil
            }
            if Date() >= deadline {
                return nil
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    private func pump() async {
        var request = URLRequest(url: upstreamURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse {
                statusCode = http.statusCode
                contentType = http.value(forHTTPHeaderField: "Content-Type") ?? contentType
            }
            print("LocalProxy: pump connected status=\(statusCode) type=\(contentType)")

            var chunk: [UInt8] = []
            chunk.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                if Task.isCancelled { break }
                chunk.append(byte)
                if chunk.count >= 64 * 1024 {
                    append(Data(chunk))
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty {
                append(Data(chunk))
            }
        } catch {
            if !Task.isCancelled {
                lastError = error.localizedDescription
                print("LocalProxy: pump failed \(error.localizedDescription) url=\(upstreamURL.absoluteString)")
            }
        }
        ended = true
    }

    private func append(_ chunk: Data) {
        updateThroughput(bytes: chunk.count)
        buffer.append(chunk)
        if !transportAligned {
            alignTransportIfPossible()
        }
        if transportAligned {
            discoverHLSSegmentBoundaries()
        }
        if buffer.count > maxBufferBytes {
            var drop = buffer.count - maxBufferBytes
            if transportAligned {
                let rem = drop % 188
                if rem != 0 {
                    drop += (188 - rem)
                }
            }
            if drop > 0 {
                drop = min(drop, buffer.count)
                buffer.removeFirst(drop)
                baseOffset += drop
                if scannedForKeyframesAbsolute < baseOffset {
                    scannedForKeyframesAbsolute = baseOffset
                }
                pruneExpiredSegments()
            }
        }
    }

    private func updateThroughput(bytes: Int) {
        throughputWindowBytes += bytes
        let now = Date()
        let elapsed = now.timeIntervalSince(throughputWindowStart)
        guard elapsed >= 1.0 else { return }
        let instantaneous = Double(throughputWindowBytes) / elapsed
        // Smooth estimate so target duration does not jump too much between manifests.
        lastEstimatedBytesPerSecond = (lastEstimatedBytesPerSecond * 0.7) + (instantaneous * 0.3)
        throughputWindowStart = now
        throughputWindowBytes = 0
    }

    private func alignTransportIfPossible() {
        guard buffer.count >= 188 * 120 else { return }
        guard let syncOffset = detectTSSyncOffset(in: buffer) else { return }
        let firstPAT = firstPATPacketOffset(in: buffer, syncOffset: syncOffset)
        let keyframeOffset = firstH264StartupOffset(in: buffer, syncOffset: syncOffset)

        // AVPlayer is much stricter than mpv on startup access units.
        // Wait for SPS/IDR when possible so the first served bytes are decodable.
        if keyframeOffset == nil && !ended {
            if buffer.count < 2_000_000 {
                if !waitingForKeyframeLogged {
                    waitingForKeyframeLogged = true
                    print("LocalProxy: waiting for startup keyframe buffered=\(buffer.count) syncOffset=\(syncOffset) patOffset=\(firstPAT ?? -1)")
                }
                return
            }
        }

        var trimOffset = syncOffset
        if let keyframeOffset {
            if let patBeforeKeyframe = lastPATPacketOffset(in: buffer, syncOffset: syncOffset, beforeOrAt: keyframeOffset) {
                trimOffset = patBeforeKeyframe
            } else {
                trimOffset = keyframeOffset
            }
        } else if let firstPAT {
            trimOffset = firstPAT
        }
        if trimOffset > 0 {
            buffer.removeFirst(trimOffset)
            baseOffset += trimOffset
        }
        if virtualOriginOffset == nil {
            virtualOriginOffset = baseOffset
        }
        transportAligned = true
        waitingForKeyframeLogged = false
        if let origin = virtualOriginOffset, hlsSegmentStartsAbsolute.isEmpty {
            hlsSegmentStartsAbsolute = [origin]
            scannedForKeyframesAbsolute = origin
        }
        print("LocalProxy: pump aligned stream syncOffset=\(syncOffset) patOffset=\(firstPAT ?? -1) keyframeOffset=\(keyframeOffset ?? -1) trim=\(trimOffset) origin=\(virtualOriginOffset ?? -1)")
    }

    private func discoverHLSSegmentBoundaries() {
        guard transportAligned, buffer.count >= 188 else { return }
        guard let origin = virtualOriginOffset else { return }
        if hlsSegmentStartsAbsolute.isEmpty {
            hlsSegmentStartsAbsolute = [origin]
        }

        let snapshot = buffer
        let base = baseOffset
        let availableEnd = base + snapshot.count - 188
        var abs = max(scannedForKeyframesAbsolute, base)
        let rem = (abs - base) % 188
        if rem != 0 {
            abs += (188 - rem)
        }
        guard abs <= availableEnd else { return }

        while abs <= availableEnd {
            let localOffset = abs - base
            let (packetEnd, packetEndOverflow) = localOffset.addingReportingOverflow(188)
            guard !packetEndOverflow,
                  localOffset >= 0,
                  packetEnd <= snapshot.count else {
                abs += 188
                continue
            }
            if Self.enableForcedPATBoundaries, isPATPacket(in: snapshot, packetOffset: localOffset) {
                appendForcedBoundaryIfOversized(atAbsoluteOffset: abs)
            }
            if byte(at: localOffset, in: snapshot) == 0x47,
               let payload = tsPayloadRange(in: snapshot, packetOffset: localOffset),
               containsNALType(5, in: snapshot, range: payload) {
                var candidate = abs
                if let pat = lastPATPacketAbsolute(in: snapshot, baseOffset: base, beforeOrAt: abs) {
                    candidate = pat
                }
                appendSegmentBoundaryIfNeeded(candidate)
            }
            abs += 188
        }
        scannedForKeyframesAbsolute = abs
    }

    private func appendSegmentBoundaryIfNeeded(_ absoluteStart: Int) {
        guard absoluteStart >= 0 else { return }
        if hlsSegmentStartsAbsolute.isEmpty {
            hlsSegmentStartsAbsolute.append(absoluteStart)
            return
        }
        let last = hlsSegmentStartsAbsolute[hlsSegmentStartsAbsolute.count - 1]
        guard absoluteStart > last else { return }
        let minSegmentBytes = clampedMinSegmentBytes()
        guard absoluteStart - last >= minSegmentBytes else { return }
        hlsSegmentStartsAbsolute.append(absoluteStart)
        let sequence = hlsSequenceBase + (hlsSegmentStartsAbsolute.count - 2)
        print("LocalProxy: HLS boundary added seq=\(sequence) start=\(absoluteStart) delta=\(absoluteStart - last) minBytes=\(minSegmentBytes)")
    }

    private func appendForcedBoundaryIfOversized(atAbsoluteOffset absoluteStart: Int) {
        guard absoluteStart >= 0 else { return }
        guard !hlsSegmentStartsAbsolute.isEmpty else { return }
        let last = hlsSegmentStartsAbsolute[hlsSegmentStartsAbsolute.count - 1]
        guard absoluteStart > last else { return }
        let maxSegmentBytes = clampedMaxSegmentBytes()
        guard absoluteStart - last >= maxSegmentBytes else { return }
        hlsSegmentStartsAbsolute.append(absoluteStart)
        let sequence = hlsSequenceBase + (hlsSegmentStartsAbsolute.count - 2)
        print("LocalProxy: HLS boundary forced seq=\(sequence) start=\(absoluteStart) delta=\(absoluteStart - last) maxBytes=\(maxSegmentBytes)")
    }

    private func clampedMinSegmentBytes() -> Int {
        let dynamic = Int(max(estimatedBytesPerSecond(), 1.0) * minHLSSegmentDurationSeconds)
        return min(minHLSSegmentBytesCeiling, max(minHLSSegmentBytesFloor, dynamic))
    }

    private func clampedMaxSegmentBytes() -> Int {
        let dynamic = Int(max(estimatedBytesPerSecond(), 1.0) * maxHLSSegmentDurationSeconds)
        return min(maxHLSSegmentBytesCeiling, max(maxHLSSegmentBytesFloor, dynamic))
    }

    private func pruneExpiredSegments() {
        guard hlsSegmentStartsAbsolute.count >= 2 else { return }
        while hlsSegmentStartsAbsolute.count >= 3, hlsSegmentStartsAbsolute[1] < baseOffset {
            hlsSegmentStartsAbsolute.removeFirst()
            hlsSequenceBase += 1
        }
    }

    private func relativeOffset(forAbsolute absolute: Int) -> Int {
        let origin = virtualOriginOffset ?? baseOffset
        return max(0, absolute - origin)
    }

    private func estimatedSegmentDuration(forLength length: Int) -> Double {
        let bps = max(estimatedBytesPerSecond(), 1.0)
        let raw = Double(length) / bps
        return min(estimatedSegmentDurationMax, max(estimatedSegmentDurationMin, raw))
    }

    private func lastPATPacketAbsolute(in data: Data, baseOffset: Int, beforeOrAt absolute: Int) -> Int? {
        guard absolute >= baseOffset else { return nil }
        var abs = absolute
        let rem = (abs - baseOffset) % 188
        abs -= rem
        let minAbs = max(baseOffset, abs - (patLookbackPackets * 188))
        var result: Int?
        while abs >= minAbs {
            let local = abs - baseOffset
            let (headerEnd, headerOverflow) = local.addingReportingOverflow(4)
            if !headerOverflow,
               local >= 0,
               headerEnd <= data.count,
               byte(at: local, in: data) == 0x47,
               let b1 = byte(at: local + 1, in: data),
               let b2 = byte(at: local + 2, in: data) {
                let pid = (Int(b1 & 0x1F) << 8) | Int(b2)
                if pid == 0 {
                    result = abs
                    break
                }
            }
            abs -= 188
        }
        return result
    }

    private func isPATPacket(in data: Data, packetOffset: Int) -> Bool {
        let (headerEnd, headerOverflow) = packetOffset.addingReportingOverflow(4)
        guard !headerOverflow, packetOffset >= 0, headerEnd <= data.count else { return false }
        guard byte(at: packetOffset, in: data) == 0x47,
              let b1 = byte(at: packetOffset + 1, in: data),
              let b2 = byte(at: packetOffset + 2, in: data) else {
            return false
        }
        let pid = (Int(b1 & 0x1F) << 8) | Int(b2)
        return pid == 0
    }

    private func byte(at offset: Int, in data: Data) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return base[offset]
        }
    }

    private func detectTSSyncOffset(in data: Data) -> Int? {
        let maxCheck = min(data.count, 188 * 400)
        guard maxCheck >= 188 * 8 else { return nil }

        var bestOffset: Int?
        var bestScore = 0
        for offset in 0..<188 {
            var score = 0
            var position = offset
            while position < maxCheck {
                if data[position] == 0x47 {
                    score += 1
                } else {
                    break
                }
                position += 188
            }
            if score > bestScore {
                bestScore = score
                bestOffset = offset
            }
        }
        guard let bestOffset, bestScore >= 8 else { return nil }
        return bestOffset
    }

    private func firstPATPacketOffset(in data: Data, syncOffset: Int) -> Int? {
        var position = syncOffset
        while position + 4 < data.count {
            guard data[position] == 0x47 else {
                position += 188
                continue
            }
            let pid = (Int(data[position + 1] & 0x1F) << 8) | Int(data[position + 2])
            if pid == 0 {
                return position
            }
            position += 188
        }
        return nil
    }

    private func lastPATPacketOffset(in data: Data, syncOffset: Int, beforeOrAt offset: Int) -> Int? {
        var result: Int?
        var position = syncOffset
        while position + 4 < data.count, position <= offset {
            guard data[position] == 0x47 else {
                position += 188
                continue
            }
            let pid = (Int(data[position + 1] & 0x1F) << 8) | Int(data[position + 2])
            if pid == 0 {
                result = position
            }
            position += 188
        }
        return result
    }

    private func firstH264StartupOffset(in data: Data, syncOffset: Int) -> Int? {
        var position = syncOffset
        var firstSPSPacket: Int?
        var firstIDRPacket: Int?

        while position + 188 <= data.count {
            guard data[position] == 0x47 else {
                position += 188
                continue
            }
            guard let payload = tsPayloadRange(in: data, packetOffset: position) else {
                position += 188
                continue
            }

            let hasSPS = containsNALType(7, in: data, range: payload)
            let hasIDR = containsNALType(5, in: data, range: payload)

            if hasSPS, firstSPSPacket == nil {
                firstSPSPacket = position
            }
            if hasIDR, firstIDRPacket == nil {
                firstIDRPacket = position
            }
            if let sps = firstSPSPacket, hasIDR {
                return sps
            }

            position += 188
        }

        if let sps = firstSPSPacket { return sps }
        return firstIDRPacket
    }

    private func tsPayloadRange(in data: Data, packetOffset: Int) -> Range<Int>? {
        let (packetEnd, packetEndOverflow) = packetOffset.addingReportingOverflow(188)
        guard !packetEndOverflow, packetOffset >= 0, packetEnd <= data.count else { return nil }
        let headerIndex = packetOffset + 3
        guard let headerByte = byte(at: headerIndex, in: data) else { return nil }
        let afc = (headerByte >> 4) & 0x03
        // 1: payload only, 3: adaptation + payload
        guard afc == 1 || afc == 3 else { return nil }
        let (payloadHeaderStart, payloadHeaderOverflow) = packetOffset.addingReportingOverflow(4)
        guard !payloadHeaderOverflow else { return nil }
        var payloadStart = payloadHeaderStart
        if afc == 3 {
            guard let adaptationLengthByte = byte(at: payloadStart, in: data) else { return nil }
            let adaptationLength = Int(adaptationLengthByte)
            let (afterLengthByte, addOneOverflow) = payloadStart.addingReportingOverflow(1)
            guard !addOneOverflow else { return nil }
            let (nextPayloadStart, addAdaptOverflow) = afterLengthByte.addingReportingOverflow(adaptationLength)
            guard !addAdaptOverflow else { return nil }
            payloadStart = nextPayloadStart
        }
        guard payloadStart < packetEnd else { return nil }
        return payloadStart..<packetEnd
    }

    private func containsNALType(_ wanted: UInt8, in data: Data, range: Range<Int>) -> Bool {
        guard range.lowerBound >= 0,
              range.upperBound >= range.lowerBound,
              range.upperBound <= data.count else {
            return false
        }
        let start = range.lowerBound
        let end = range.upperBound
        guard end - start > 4 else { return false }

        var i = start
        while i + 4 <= end {
            // Annex B start code: 00 00 01 or 00 00 00 01
            if i + 3 < end,
               byte(at: i, in: data) == 0,
               byte(at: i + 1, in: data) == 0,
               byte(at: i + 2, in: data) == 1,
               let nalByte = byte(at: i + 3, in: data) {
                let nalType = nalByte & 0x1F
                if nalType == wanted { return true }
                i += 4
                continue
            }
            if i + 4 < end,
               byte(at: i, in: data) == 0,
               byte(at: i + 1, in: data) == 0,
               byte(at: i + 2, in: data) == 0,
               byte(at: i + 3, in: data) == 1,
               let nalByte = byte(at: i + 4, in: data) {
                let nalType = nalByte & 0x1F
                if nalType == wanted { return true }
                i += 5
                continue
            }
            i += 1
        }
        return false
    }
}
