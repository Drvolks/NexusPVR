//
//  RecordingsViewModel.swift
//  nextpvr-apple-client
//
//  View model for recordings list
//

import SwiftUI
import Combine
import AVFoundation

enum RecordingsFilter: String, Identifiable {
    case completed = "Completed"
    case recording = "Recording"
    case scheduled = "Scheduled"

    var id: String { rawValue }
}

@MainActor
final class RecordingsViewModel: ObservableObject {
    @Published var completedRecordings: [Recording] = []
    @Published var activeRecordings: [Recording] = []
    @Published var scheduledRecordings: [Recording] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var filter: RecordingsFilter = .completed
    @Published var durationMismatches: [Int: (expected: Int, detected: Int)] = [:]
    @Published var durationVerified: Set<Int> = []
    @Published var durationUnverifiable: Set<Int> = []

    private let client: PVRClient

    init(client: PVRClient) {
        self.client = client
    }

    var hasActiveRecordings: Bool {
        !activeRecordings.isEmpty
    }

    var filteredRecordings: [Recording] {
        switch filter {
        case .completed:
            return completedRecordings.sorted { r1, r2 in
                guard let d1 = r1.startDate, let d2 = r2.startDate else { return false }
                return d1 > d2
            }
        case .recording:
            return activeRecordings.sorted { r1, r2 in
                guard let d1 = r1.startDate, let d2 = r2.startDate else { return false }
                return d1 > d2
            }
        case .scheduled:
            return scheduledRecordings.sorted { r1, r2 in
                guard let d1 = r1.startDate, let d2 = r2.startDate else { return false }
                return d1 < d2
            }
        }
    }

    func loadRecordings() async {
        guard client.isConfigured else { return }

        isLoading = true
        error = nil

        do {
            if !client.isAuthenticated {
                try await client.authenticate()
            }

            let (completed, recording, scheduled) = try await client.getAllRecordings()
            completedRecordings = completed
            activeRecordings = recording
            scheduledRecordings = scheduled

            isLoading = false
            probeDurations()
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    // MARK: - Duration Probe Cache

    private static let probeCacheKey = "DurationProbeCache"
    private static let probeCache = NSUbiquitousKeyValueStore.default

    /// Load cached probe results: [recordingId: detectedDuration]
    private static func loadProbeCache() -> [String: Int] {
        probeCache.dictionary(forKey: probeCacheKey) as? [String: Int] ?? [:]
    }

    /// Save a probe result to the cache
    private func cacheProbeResult(recordingId: Int, detectedDuration: Int) {
        var cache = Self.loadProbeCache()
        cache[String(recordingId)] = detectedDuration
        Self.probeCache.set(cache, forKey: Self.probeCacheKey)
    }

    /// Remove stale or suspect cached probe results.
    private func removeProbeCache(recordingId: Int) {
        var cache = Self.loadProbeCache()
        cache.removeValue(forKey: String(recordingId))
        Self.probeCache.set(cache, forKey: Self.probeCacheKey)
    }

    private func isDurationLikelyValid(expected: Int, detected: Int) -> Bool {
        detected >= (expected * 90 / 100)
    }

    private func probeDurations() {
        durationMismatches.removeAll()
        durationVerified.removeAll()
        durationUnverifiable.removeAll()
        let cache = Self.loadProbeCache()

        #if DISPATCHERPVR
        for recording in completedRecordings {
            guard recording.recordingStatus.isCompleted,
                  let expectedDuration = recording.duration,
                  expectedDuration > 0 else { continue }
            if let cached = cache[String(recording.id)] {
                if isDurationLikelyValid(expected: expectedDuration, detected: cached) {
                    applyProbeResult(recording: recording, expectedDuration: expectedDuration, detectedSeconds: cached)
                    continue
                }
                // Don't trust cached mismatches; source files may be fixed later.
                removeProbeCache(recordingId: recording.id)
            }
            Task {
                await probeMKVDuration(recording, expectedDuration: expectedDuration)
            }
        }
        return
        #endif
        print("Duration probe: \(completedRecordings.count) completed recordings to check")
        for recording in completedRecordings {
            guard recording.recordingStatus.isCompleted,
                  let expectedDuration = recording.duration,
                  expectedDuration > 0 else {
                print("Duration probe: skipping '\(recording.name)' — status: \(recording.recordingStatus), duration: \(recording.duration ?? -1)")
                continue
            }
            if let cached = cache[String(recording.id)] {
                if isDurationLikelyValid(expected: expectedDuration, detected: cached) {
                    applyProbeResult(recording: recording, expectedDuration: expectedDuration, detectedSeconds: cached)
                    continue
                }
                // Don't trust cached mismatches; source files may be fixed later.
                removeProbeCache(recordingId: recording.id)
            }
            let fileExt = recording.file?.lowercased().components(separatedBy: ".").last
            Task {
                if fileExt == "mp4" || fileExt == "m4v" {
                    await probeMP4Duration(recording, expectedDuration: expectedDuration)
                } else {
                    await probeRecordingDuration(recording, expectedDuration: expectedDuration)
                }
            }
        }
    }

    private func applyProbeResult(recording: Recording, expectedDuration: Int, detectedSeconds: Int) {
        durationUnverifiable.remove(recording.id)
        if !isDurationLikelyValid(expected: expectedDuration, detected: detectedSeconds) {
            print("Duration probe: MISMATCH (cached) '\(recording.name)' — expected \(expectedDuration)s, detected \(detectedSeconds)s")
            durationMismatches[recording.id] = (expected: expectedDuration, detected: detectedSeconds)
        } else {
            //print("Duration probe: OK (cached) '\(recording.name)' — expected \(expectedDuration)s, detected \(detectedSeconds)s")
            durationVerified.insert(recording.id)
        }
    }

    private func probeRecordingDuration(_ recording: Recording, expectedDuration: Int) async {
        print("Duration probe: starting for '\(recording.name)' (id: \(recording.id), expected: \(expectedDuration)s)")
        do {
            let url = try await client.recordingStreamURL(recordingId: recording.id)
            let headers = client.streamAuthHeaders()

            // Download first and last chunks to extract TS timestamps
            var request = URLRequest(url: url)
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }

            // HEAD request to get content length; also try GET response header as fallback
            var contentLength: Int64?
            var headRequest = request
            headRequest.httpMethod = "HEAD"
            let (_, headResponse) = try await URLSession.shared.data(for: headRequest)
            if let httpResponse = headResponse as? HTTPURLResponse,
               let lengthStr = httpResponse.value(forHTTPHeaderField: "Content-Length") {
                contentLength = Int64(lengthStr)
            }

            // If HEAD didn't return Content-Length, try a range request and check Content-Range
            if contentLength == nil {
                var rangeProbe = request
                rangeProbe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                let (_, rangeResponse) = try await URLSession.shared.data(for: rangeProbe)
                if let httpResponse = rangeResponse as? HTTPURLResponse,
                   let rangeStr = httpResponse.value(forHTTPHeaderField: "Content-Range"),
                   let slashIndex = rangeStr.lastIndex(of: "/") {
                    let totalStr = rangeStr[rangeStr.index(after: slashIndex)...]
                    contentLength = Int64(totalStr)
                }
            }

            guard let fileSize = contentLength, fileSize > 4_000_000 else {
                print("Duration probe: '\(recording.name)' — could not determine file size or too small (Content-Length: \(contentLength ?? -1))")
                return
            }

            // Download first 2MB for first PTS
            request.setValue("bytes=0-2097151", forHTTPHeaderField: "Range")
            let (headData, headDataResponse) = try await URLSession.shared.data(for: request)
            let headHTTP = headDataResponse as? HTTPURLResponse
            let headStatus = headHTTP?.statusCode ?? 0
            let headContentType = headHTTP?.value(forHTTPHeaderField: "Content-Type") ?? "<none>"

            // If server ignores Range and returns full file, use that data directly
            let serverSupportsRange = headStatus == 206

            let firstSample = Self.extractFirstPTSSample(from: headData)
            let firstPTS = firstSample?.pts
            let firstPID = firstSample?.pid

            var lastPID: Int?
            var usedSamePIDTailPTS = false
            let lastPTS: UInt64?
            var tailStatus = 0
            var tailBytes = 0
            var tailContentType = "<none>"
            var tailDataForDiagnostics = Data()
            if serverSupportsRange {
                // Download last 2MB for last PTS
                let tailStart = fileSize - 2_097_152
                request.setValue("bytes=\(tailStart)-\(fileSize - 1)", forHTTPHeaderField: "Range")
                let (tailData, tailResponse) = try await URLSession.shared.data(for: request)
                let tailHTTP = tailResponse as? HTTPURLResponse
                tailStatus = tailHTTP?.statusCode ?? 0
                tailContentType = tailHTTP?.value(forHTTPHeaderField: "Content-Type") ?? "<none>"
                tailBytes = tailData.count
                tailDataForDiagnostics = tailData
                if let firstPID {
                    if let samePIDLast = Self.extractLastPTS(from: tailData, matchingPID: firstPID) {
                        lastPTS = samePIDLast
                        lastPID = firstPID
                        usedSamePIDTailPTS = true
                    } else {
                        let lastSample = Self.extractLastPTSSample(from: tailData)
                        lastPTS = lastSample?.pts
                        lastPID = lastSample?.pid
                    }
                } else {
                    let lastSample = Self.extractLastPTSSample(from: tailData)
                    lastPTS = lastSample?.pts
                    lastPID = lastSample?.pid
                }
            } else {
                // Server sent the whole file, extract last PTS from the end of what we got
                print("Duration probe: '\(recording.name)' — server doesn't support range requests, using full response (\(headData.count) bytes)")
                tailStatus = headStatus
                tailContentType = headContentType
                tailBytes = headData.count
                tailDataForDiagnostics = headData
                if let firstPID {
                    if let samePIDLast = Self.extractLastPTS(from: headData, matchingPID: firstPID) {
                        lastPTS = samePIDLast
                        lastPID = firstPID
                    } else {
                        let lastSample = Self.extractLastPTSSample(from: headData)
                        lastPTS = lastSample?.pts
                        lastPID = lastSample?.pid
                    }
                } else {
                    let lastSample = Self.extractLastPTSSample(from: headData)
                    lastPTS = lastSample?.pts
                    lastPID = lastSample?.pid
                }
            }

            // Handle a single PTS wrap (33-bit) only when it stays plausible vs expected duration.
            let wrapTicks = UInt64(1) << 33
            var adjustedLastPTS = lastPTS
            if let first = firstPTS, let last = lastPTS, last <= first, firstPID != nil, firstPID == lastPID {
                let wrapped = last + wrapTicks
                let wrappedSeconds = Int((wrapped - first) / 90000)
                if wrappedSeconds > 0, wrappedSeconds <= max(expectedDuration * 6, expectedDuration + 10_800) {
                    adjustedLastPTS = wrapped
                }
            }

            // If timeline still goes backward on same PID, try a robust estimate
            // using multiple PTS samples from head/tail chunks.
            if let first = firstPTS,
               let rawLast = lastPTS,
               rawLast <= first,
               let pid = firstPID {
                let headPTSValues = Self.extractPTSValues(from: headData, matchingPID: pid)
                let tailPTSValues = Self.extractPTSValues(from: tailDataForDiagnostics, matchingPID: pid)
                if let estimatedSeconds = Self.estimateDurationSecondsFromPTSWindows(
                    headPTSValues: headPTSValues,
                    tailPTSValues: tailPTSValues,
                    expectedSeconds: expectedDuration
                ) {
                    adjustedLastPTS = first + UInt64(estimatedSeconds) * 90_000
                    print(
                        "Duration probe: '\(recording.name)' — recovered duration from discontinuous PTS " +
                        "[pid=\(pid) estimated=\(estimatedSeconds)s expected=\(expectedDuration)s " +
                        "headPTSCount=\(headPTSValues.count) tailPTSCount=\(tailPTSValues.count)]"
                    )
                }
            }

            guard let first = firstPTS, let last = adjustedLastPTS, last > first else {
                if let crossPIDSeconds = Self.estimateDurationSecondsAcrossCommonPIDs(
                    headData: headData,
                    tailData: tailDataForDiagnostics,
                    expectedSeconds: expectedDuration
                ) {
                    print(
                        "Duration probe: '\(recording.name)' — recovered duration from cross-PID fallback " +
                        "[estimated=\(crossPIDSeconds)s expected=\(expectedDuration)s]"
                    )
                    if isDurationLikelyValid(expected: expectedDuration, detected: crossPIDSeconds) {
                        cacheProbeResult(recordingId: recording.id, detectedDuration: crossPIDSeconds)
                    } else {
                        removeProbeCache(recordingId: recording.id)
                    }
                    applyProbeResult(recording: recording, expectedDuration: expectedDuration, detectedSeconds: crossPIDSeconds)
                    return
                }
                if let firstPTS, let firstPID, let sampledSeconds = try await probeDurationFromSampledPTSWindows(
                    url: url,
                    headers: headers,
                    fileSize: fileSize,
                    pid: firstPID,
                    firstPTS: firstPTS,
                    expectedSeconds: expectedDuration
                ) {
                    print(
                        "Duration probe: '\(recording.name)' — recovered duration from sampled TS windows " +
                        "[pid=\(firstPID) estimated=\(sampledSeconds)s expected=\(expectedDuration)s]"
                    )
                    if isDurationLikelyValid(expected: expectedDuration, detected: sampledSeconds) {
                        cacheProbeResult(recordingId: recording.id, detectedDuration: sampledSeconds)
                    } else {
                        removeProbeCache(recordingId: recording.id)
                    }
                    applyProbeResult(recording: recording, expectedDuration: expectedDuration, detectedSeconds: sampledSeconds)
                    return
                }
                if let assetDuration = await probeAssetDuration(url: url, headers: headers) {
                    print("Duration probe: '\(recording.name)' — recovered duration via AVAsset fallback \(assetDuration)s")
                    if isDurationLikelyValid(expected: expectedDuration, detected: assetDuration) {
                        cacheProbeResult(recordingId: recording.id, detectedDuration: assetDuration)
                    } else {
                        removeProbeCache(recordingId: recording.id)
                    }
                    applyProbeResult(recording: recording, expectedDuration: expectedDuration, detectedSeconds: assetDuration)
                    return
                }
                let headStats = Self.tsProbeStats(from: headData)
                let tailStats = Self.tsProbeStats(from: tailDataForDiagnostics)
                let orderProblem = (firstPTS != nil && lastPTS != nil && (lastPTS ?? 0) <= (firstPTS ?? 0))
                print(
                    "Duration probe: '\(recording.name)' — could not extract PTS timestamps " +
                    "[firstPTS=\(firstPTS.map(String.init) ?? "nil") lastPTS=\(lastPTS.map(String.init) ?? "nil") " +
                    "firstPID=\(firstPID.map(String.init) ?? "nil") lastPID=\(lastPID.map(String.init) ?? "nil") samePIDTail=\(usedSamePIDTailPTS) " +
                    "orderProblem=\(orderProblem) discontinuitySamePID=\(orderProblem && firstPID != nil && firstPID == lastPID) range206=\(serverSupportsRange) " +
                    "headStatus=\(headStatus) headType=\(headContentType) headBytes=\(headData.count) " +
                    "tailStatus=\(tailStatus) tailType=\(tailContentType) tailBytes=\(tailBytes) " +
                    "headTS=\(headStats) tailTS=\(tailStats)]"
                )
                durationUnverifiable.insert(recording.id)
                return
            }

            let detectedSeconds = Int((last - first) / 90000) // PTS is in 90kHz ticks

            guard detectedSeconds > 0 else {
                print("Duration probe: '\(recording.name)' returned 0s, skipping")
                return
            }

            if isDurationLikelyValid(expected: expectedDuration, detected: detectedSeconds) {
                cacheProbeResult(recordingId: recording.id, detectedDuration: detectedSeconds)
            } else {
                removeProbeCache(recordingId: recording.id)
            }
            applyProbeResult(recording: recording, expectedDuration: expectedDuration, detectedSeconds: detectedSeconds)
        } catch {
            print("Duration probe: FAILED '\(recording.name)' — \(error.localizedDescription)")
        }
    }

    private func probeDurationFromSampledPTSWindows(
        url: URL,
        headers: [String: String],
        fileSize: Int64,
        pid: Int,
        firstPTS: UInt64,
        expectedSeconds: Int
    ) async throws -> Int? {
        let sampleSize = min(Int64(1_048_576), max(Int64(188 * 3000), fileSize / 20))
        let fractions: [Double] = [0.15, 0.30, 0.45, 0.60, 0.75, 0.90]
        let wrapTicks = UInt64(1) << 33
        let maxReasonableSeconds = max(expectedSeconds * 6, expectedSeconds + 10_800)
        let acceptableError = max(expectedSeconds / 2, 1_200)

        var candidates: [Int] = []
        for fraction in fractions {
            let approxStart = Int64(Double(fileSize - sampleSize) * fraction)
            let start = max(Int64(0), approxStart)
            let end = min(fileSize - 1, start + sampleSize - 1)
            guard end > start else { continue }

            var request = URLRequest(url: url)
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            let (chunk, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 206 else { continue }

            let ptsValues = Self.extractPTSValues(from: chunk, matchingPID: pid)
            guard !ptsValues.isEmpty else { continue }
            for pts in ptsValues {
                for wraps in 0...1 {
                    let adjusted = pts + UInt64(wraps) * wrapTicks
                    guard adjusted > firstPTS else { continue }
                    let seconds = Int((adjusted - firstPTS) / 90_000)
                    guard seconds > 0, seconds <= maxReasonableSeconds else { continue }
                    candidates.append(seconds)
                }
            }
        }

        guard !candidates.isEmpty else { return nil }
        let best = candidates.min(by: { abs($0 - expectedSeconds) < abs($1 - expectedSeconds) })
        guard let best, abs(best - expectedSeconds) <= acceptableError else { return nil }
        return best
    }

    private func probeAssetDuration(url: URL, headers: [String: String]) async -> Int? {
        var options: [String: Any] = [:]
        if !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: options.isEmpty ? nil : options)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else { return nil }
            return Int(seconds.rounded())
        } catch {
            return nil
        }
    }

    // MARK: - MKV Duration Probing

    private func probeMKVDuration(_ recording: Recording, expectedDuration: Int) async {
        print("Duration probe: starting MKV probe for '\(recording.name)' (id: \(recording.id), expected: \(expectedDuration)s)")
        do {
            let url = try await client.recordingStreamURL(recordingId: recording.id)
            let headers = client.streamAuthHeaders()

            var request = URLRequest(url: url)
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            // MKV duration is in Segment Info, typically within first 64KB
            request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
            let (data, _) = try await URLSession.shared.data(for: request)

            guard let detectedSeconds = Self.extractMKVDuration(from: data) else {
                print("Duration probe: '\(recording.name)' — could not extract MKV duration")
                return
            }

            if isDurationLikelyValid(expected: expectedDuration, detected: detectedSeconds) {
                cacheProbeResult(recordingId: recording.id, detectedDuration: detectedSeconds)
            } else {
                removeProbeCache(recordingId: recording.id)
            }
            applyProbeResult(recording: recording, expectedDuration: expectedDuration, detectedSeconds: detectedSeconds)
        } catch {
            print("Duration probe: FAILED '\(recording.name)' — \(error.localizedDescription)")
        }
    }

    // MARK: - MP4 Duration Probing

    private func probeMP4Duration(_ recording: Recording, expectedDuration: Int) async {
        print("Duration probe: starting MP4 probe for '\(recording.name)' (id: \(recording.id), expected: \(expectedDuration)s)")
        do {
            let url = try await client.recordingStreamURL(recordingId: recording.id)
            let headers = client.streamAuthHeaders()

            var request = URLRequest(url: url)
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            // mvhd is typically within the first 64KB (inside moov/mvhd)
            request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
            let (data, _) = try await URLSession.shared.data(for: request)

            guard let detectedSeconds = Self.extractMP4Duration(from: data) else {
                print("Duration probe: '\(recording.name)' — could not extract MP4 duration")
                return
            }

            if isDurationLikelyValid(expected: expectedDuration, detected: detectedSeconds) {
                cacheProbeResult(recordingId: recording.id, detectedDuration: detectedSeconds)
            } else {
                removeProbeCache(recordingId: recording.id)
            }
            applyProbeResult(recording: recording, expectedDuration: expectedDuration, detectedSeconds: detectedSeconds)
        } catch {
            print("Duration probe: FAILED '\(recording.name)' — \(error.localizedDescription)")
        }
    }

    /// Parse MP4 boxes to find mvhd and extract duration
    nonisolated private static func extractMP4Duration(from data: Data) -> Int? {
        var offset = 0

        func readUInt32(at pos: Int) -> UInt32? {
            guard pos + 4 <= data.count else { return nil }
            return UInt32(data[pos]) << 24 | UInt32(data[pos+1]) << 16 |
                   UInt32(data[pos+2]) << 8 | UInt32(data[pos+3])
        }

        func readUInt64(at pos: Int) -> UInt64? {
            guard pos + 8 <= data.count else { return nil }
            var value: UInt64 = 0
            for i in 0..<8 {
                value = (value << 8) | UInt64(data[pos + i])
            }
            return value
        }

        // Walk MP4 boxes, descending into moov
        while offset + 8 <= data.count {
            guard let boxSize = readUInt32(at: offset) else { break }
            let boxType = String(data: data[offset+4..<offset+8], encoding: .ascii) ?? ""

            if boxType == "mvhd" {
                // mvhd: version(1) + flags(3) + ...
                let versionOffset = offset + 8
                guard versionOffset < data.count else { break }
                let version = data[versionOffset]

                if version == 0 {
                    // v0: skip version(1) + flags(3) + creation(4) + modification(4) = 12
                    // then timescale(4) + duration(4)
                    guard let timescale = readUInt32(at: versionOffset + 12),
                          let duration = readUInt32(at: versionOffset + 16),
                          timescale > 0 else { break }
                    return Int(duration / timescale)
                } else {
                    // v1: skip version(1) + flags(3) + creation(8) + modification(8) = 20
                    // then timescale(4) + duration(8)
                    guard let timescale = readUInt32(at: versionOffset + 20),
                          let duration = readUInt64(at: versionOffset + 24),
                          timescale > 0 else { break }
                    return Int(duration / UInt64(timescale))
                }
            }

            // Descend into container boxes
            if boxType == "moov" || boxType == "trak" || boxType == "mdia" {
                offset += 8
                continue
            }

            // Skip non-container boxes
            let size = boxSize == 0 ? Int(data.count - offset) : Int(boxSize)
            guard size >= 8 else { break }
            offset += size
        }

        return nil
    }

    /// Parse MKV/WebM EBML to extract duration from Segment Info
    nonisolated private static func extractMKVDuration(from data: Data) -> Int? {
        var offset = 0
        var timestampScale: UInt64 = 1_000_000 // Default: 1ms
        var duration: Double?

        // Read EBML variable-size integer (VINT)
        func readVINT(at pos: inout Int) -> UInt64? {
            guard pos < data.count else { return nil }
            let first = data[pos]
            guard first != 0 else { return nil }
            let length = first.leadingZeroBitCount + 1
            guard pos + length <= data.count else { return nil }
            var value = UInt64(first)
            // Mask out the length bits
            value &= (0xFF >> length)
            for i in 1..<length {
                value = (value << 8) | UInt64(data[pos + i])
            }
            pos += length
            return value
        }

        // Read element ID (same encoding as VINT but keep the length bits)
        func readID(at pos: inout Int) -> UInt64? {
            guard pos < data.count else { return nil }
            let first = data[pos]
            guard first != 0 else { return nil }
            let length = first.leadingZeroBitCount + 1
            guard pos + length <= data.count else { return nil }
            var value = UInt64(first)
            for i in 1..<length {
                value = (value << 8) | UInt64(data[pos + i])
            }
            pos += length
            return value
        }

        func readUInt(at pos: Int, length: Int) -> UInt64 {
            var value: UInt64 = 0
            for i in 0..<length {
                value = (value << 8) | UInt64(data[pos + i])
            }
            return value
        }

        func readFloat(at pos: Int, length: Int) -> Double? {
            if length == 4 {
                let bits = UInt32(readUInt(at: pos, length: 4))
                return Double(Float(bitPattern: bits))
            } else if length == 8 {
                let bits = readUInt(at: pos, length: 8)
                return Double(bitPattern: bits)
            }
            return nil
        }

        // Scan through EBML elements looking for Segment Info
        while offset < data.count - 2 {
            let elementStart = offset
            guard let elementID = readID(at: &offset) else { break }
            guard let elementSize = readVINT(at: &offset) else { break }

            let dataStart = offset
            let dataEnd = dataStart + Int(elementSize)

            switch elementID {
            case 0x1A45DFA3: // EBML header — skip into it
                continue
            case 0x18538067: // Segment — descend into it
                continue
            case 0x1549A966: // Segment Info — descend into it
                continue
            case 0x2AD7B1: // TimestampScale
                guard dataEnd <= data.count else { break }
                timestampScale = readUInt(at: dataStart, length: Int(elementSize))
                offset = dataEnd
            case 0x4489: // Duration (float, in TimestampScale units)
                guard dataEnd <= data.count else { break }
                duration = readFloat(at: dataStart, length: Int(elementSize))
                offset = dataEnd
            default:
                // Unknown element size could mean we should skip
                if elementSize > 0 && elementSize < 0x100000000 && dataEnd <= data.count {
                    offset = dataEnd
                } else {
                    // Master element or unknown size — try to descend
                    offset = dataStart
                    continue
                }
            }

            if duration != nil {
                break // Got what we need
            }

            // Safety: don't go past data
            if offset >= data.count || offset <= elementStart {
                break
            }
        }

        guard let dur = duration else { return nil }
        // Duration is in TimestampScale units, convert to seconds
        let seconds = dur * Double(timestampScale) / 1_000_000_000.0
        return Int(seconds)
    }

    // MARK: - MPEG-TS PTS Extraction

    /// Compact TS diagnostics used when duration probing cannot find valid first/last PTS.
    nonisolated private static func tsProbeStats(from data: Data) -> String {
        guard !data.isEmpty else { return "empty" }

        var syncOffset: Int?
        for offset in 0..<188 where offset < data.count {
            if data[offset] == 0x47 {
                syncOffset = offset
                break
            }
        }
        guard let start = syncOffset else {
            return "no-sync bytes=\(data.count)"
        }

        var packetCount = 0
        var ptsCount = 0
        var i = start
        while i + 188 <= data.count {
            if data[i] != 0x47 {
                i += 1
                continue
            }
            packetCount += 1

            let payloadUnitStart = (data[i + 1] & 0x40) != 0
            let afc = (data[i + 3] >> 4) & 0x03
            var payloadOffset = i + 4
            if afc == 2 || afc == 3 {
                let adaptationLength = Int(data[payloadOffset])
                payloadOffset += 1 + adaptationLength
            }
            if payloadOffset + 14 <= i + 188, payloadUnitStart {
                if data[payloadOffset] == 0x00, data[payloadOffset + 1] == 0x00, data[payloadOffset + 2] == 0x01 {
                    let flags = data[payloadOffset + 7]
                    let hasPTS = (flags & 0x80) != 0
                    if hasPTS, parsePTS(from: data, at: payloadOffset + 9) != nil {
                        ptsCount += 1
                    }
                }
            }
            i += 188
        }

        return "sync=\(start) packets=\(packetCount) ptsPackets=\(ptsCount)"
    }

    /// Parse a 33-bit PTS/DTS value from 5 bytes in the PES header
    nonisolated private static func parsePTS(from data: Data, at offset: Int) -> UInt64? {
        guard offset + 5 <= data.count else { return nil }
        let b0 = UInt64(data[offset])
        let b1 = UInt64(data[offset + 1])
        let b2 = UInt64(data[offset + 2])
        let b3 = UInt64(data[offset + 3])
        let b4 = UInt64(data[offset + 4])

        // PTS is spread across 5 bytes with marker bits:
        // [4 bits flags][3 bits PTS][1 marker] [8 bits PTS][7 bits PTS][1 marker] [8 bits PTS][7 bits PTS][1 marker]
        let pts: UInt64 = ((b0 >> 1) & 0x07) << 30 |
                          (b1 << 22) |
                          ((b2 >> 1) << 15) |
                          (b3 << 7) |
                          (b4 >> 1)
        return pts
    }

    /// Extract the first PTS found in TS data
    nonisolated private static func extractFirstPTS(from data: Data) -> UInt64? {
        let packetSize = 188
        var offset = 0

        // Sync to first TS packet
        while offset < data.count - packetSize {
            if data[offset] == 0x47 { break }
            offset += 1
        }

        while offset + packetSize <= data.count {
            guard data[offset] == 0x47 else { offset += 1; continue }

            let payloadUnitStart = (data[offset + 1] & 0x40) != 0
            let hasPayload = (data[offset + 3] & 0x10) != 0
            let hasAdaptation = (data[offset + 3] & 0x20) != 0

            if payloadUnitStart && hasPayload {
                var payloadOffset = offset + 4
                if hasAdaptation {
                    let adaptLen = Int(data[payloadOffset])
                    payloadOffset += 1 + adaptLen
                }

                // Check for PES start code: 0x00 0x00 0x01
                if payloadOffset + 14 <= data.count &&
                   data[payloadOffset] == 0x00 &&
                   data[payloadOffset + 1] == 0x00 &&
                   data[payloadOffset + 2] == 0x01 {
                    let streamId = data[payloadOffset + 3]
                    // Video (0xE0-0xEF) or audio (0xC0-0xDF) streams
                    if (streamId >= 0xC0 && streamId <= 0xDF) || (streamId >= 0xE0 && streamId <= 0xEF) {
                        let flags = data[payloadOffset + 7]
                        let hasPTS = (flags & 0x80) != 0
                        if hasPTS {
                            if let pts = parsePTS(from: data, at: payloadOffset + 9) {
                                return pts
                            }
                        }
                    }
                }
            }
            offset += packetSize
        }
        return nil
    }

    /// Extract the first (PID, PTS) sample found in TS data.
    nonisolated private static func extractFirstPTSSample(from data: Data) -> (pid: Int, pts: UInt64)? {
        let packetSize = 188
        var offset = 0

        while offset < data.count - packetSize {
            if data[offset] == 0x47 { break }
            offset += 1
        }

        while offset + packetSize <= data.count {
            guard data[offset] == 0x47 else { offset += 1; continue }

            let pid = (Int(data[offset + 1] & 0x1F) << 8) | Int(data[offset + 2])
            let payloadUnitStart = (data[offset + 1] & 0x40) != 0
            let hasPayload = (data[offset + 3] & 0x10) != 0
            let hasAdaptation = (data[offset + 3] & 0x20) != 0

            if payloadUnitStart && hasPayload {
                var payloadOffset = offset + 4
                if hasAdaptation {
                    let adaptLen = Int(data[payloadOffset])
                    payloadOffset += 1 + adaptLen
                }

                if payloadOffset + 14 <= data.count &&
                    data[payloadOffset] == 0x00 &&
                    data[payloadOffset + 1] == 0x00 &&
                    data[payloadOffset + 2] == 0x01 {
                    let streamId = data[payloadOffset + 3]
                    if (streamId >= 0xC0 && streamId <= 0xDF) || (streamId >= 0xE0 && streamId <= 0xEF) {
                        let flags = data[payloadOffset + 7]
                        let hasPTS = (flags & 0x80) != 0
                        if hasPTS, let pts = parsePTS(from: data, at: payloadOffset + 9) {
                            return (pid, pts)
                        }
                    }
                }
            }
            offset += packetSize
        }
        return nil
    }

    /// Extract the last PTS found in TS data
    nonisolated private static func extractLastPTS(from data: Data) -> UInt64? {
        let packetSize = 188
        var lastPTS: UInt64?

        // Sync to first TS packet
        var offset = 0
        while offset < data.count - packetSize {
            if data[offset] == 0x47 { break }
            offset += 1
        }

        while offset + packetSize <= data.count {
            guard data[offset] == 0x47 else { offset += 1; continue }

            let payloadUnitStart = (data[offset + 1] & 0x40) != 0
            let hasPayload = (data[offset + 3] & 0x10) != 0
            let hasAdaptation = (data[offset + 3] & 0x20) != 0

            if payloadUnitStart && hasPayload {
                var payloadOffset = offset + 4
                if hasAdaptation {
                    let adaptLen = Int(data[payloadOffset])
                    payloadOffset += 1 + adaptLen
                }

                if payloadOffset + 14 <= data.count &&
                   data[payloadOffset] == 0x00 &&
                   data[payloadOffset + 1] == 0x00 &&
                   data[payloadOffset + 2] == 0x01 {
                    let streamId = data[payloadOffset + 3]
                    if (streamId >= 0xC0 && streamId <= 0xDF) || (streamId >= 0xE0 && streamId <= 0xEF) {
                        let flags = data[payloadOffset + 7]
                        let hasPTS = (flags & 0x80) != 0
                        if hasPTS {
                            if let pts = parsePTS(from: data, at: payloadOffset + 9) {
                                lastPTS = pts
                            }
                        }
                    }
                }
            }
            offset += packetSize
        }
        return lastPTS
    }

    /// Extract the last (PID, PTS) sample found in TS data.
    nonisolated private static func extractLastPTSSample(from data: Data) -> (pid: Int, pts: UInt64)? {
        let packetSize = 188
        var lastSample: (pid: Int, pts: UInt64)?

        var offset = 0
        while offset < data.count - packetSize {
            if data[offset] == 0x47 { break }
            offset += 1
        }

        while offset + packetSize <= data.count {
            guard data[offset] == 0x47 else { offset += 1; continue }

            let pid = (Int(data[offset + 1] & 0x1F) << 8) | Int(data[offset + 2])
            let payloadUnitStart = (data[offset + 1] & 0x40) != 0
            let hasPayload = (data[offset + 3] & 0x10) != 0
            let hasAdaptation = (data[offset + 3] & 0x20) != 0

            if payloadUnitStart && hasPayload {
                var payloadOffset = offset + 4
                if hasAdaptation {
                    let adaptLen = Int(data[payloadOffset])
                    payloadOffset += 1 + adaptLen
                }

                if payloadOffset + 14 <= data.count &&
                    data[payloadOffset] == 0x00 &&
                    data[payloadOffset + 1] == 0x00 &&
                    data[payloadOffset + 2] == 0x01 {
                    let streamId = data[payloadOffset + 3]
                    if (streamId >= 0xC0 && streamId <= 0xDF) || (streamId >= 0xE0 && streamId <= 0xEF) {
                        let flags = data[payloadOffset + 7]
                        let hasPTS = (flags & 0x80) != 0
                        if hasPTS, let pts = parsePTS(from: data, at: payloadOffset + 9) {
                            lastSample = (pid, pts)
                        }
                    }
                }
            }
            offset += packetSize
        }
        return lastSample
    }

    /// Extract the last PTS for a specific TS PID.
    nonisolated private static func extractLastPTS(from data: Data, matchingPID pid: Int) -> UInt64? {
        let packetSize = 188
        var lastPTS: UInt64?

        var offset = 0
        while offset < data.count - packetSize {
            if data[offset] == 0x47 { break }
            offset += 1
        }

        while offset + packetSize <= data.count {
            guard data[offset] == 0x47 else { offset += 1; continue }

            let currentPID = (Int(data[offset + 1] & 0x1F) << 8) | Int(data[offset + 2])
            guard currentPID == pid else {
                offset += packetSize
                continue
            }

            let payloadUnitStart = (data[offset + 1] & 0x40) != 0
            let hasPayload = (data[offset + 3] & 0x10) != 0
            let hasAdaptation = (data[offset + 3] & 0x20) != 0

            if payloadUnitStart && hasPayload {
                var payloadOffset = offset + 4
                if hasAdaptation {
                    let adaptLen = Int(data[payloadOffset])
                    payloadOffset += 1 + adaptLen
                }

                if payloadOffset + 14 <= data.count &&
                    data[payloadOffset] == 0x00 &&
                    data[payloadOffset + 1] == 0x00 &&
                    data[payloadOffset + 2] == 0x01 {
                    let streamId = data[payloadOffset + 3]
                    if (streamId >= 0xC0 && streamId <= 0xDF) || (streamId >= 0xE0 && streamId <= 0xEF) {
                        let flags = data[payloadOffset + 7]
                        let hasPTS = (flags & 0x80) != 0
                        if hasPTS, let pts = parsePTS(from: data, at: payloadOffset + 9) {
                            lastPTS = pts
                        }
                    }
                }
            }
            offset += packetSize
        }

        return lastPTS
    }

    /// Extract all (PID, PTS) PES samples in order of appearance.
    nonisolated private static func extractPTSSamples(from data: Data) -> [(pid: Int, pts: UInt64)] {
        let packetSize = 188
        var samples: [(pid: Int, pts: UInt64)] = []

        var offset = 0
        while offset < data.count - packetSize {
            if data[offset] == 0x47 { break }
            offset += 1
        }

        while offset + packetSize <= data.count {
            guard data[offset] == 0x47 else { offset += 1; continue }

            let pid = (Int(data[offset + 1] & 0x1F) << 8) | Int(data[offset + 2])
            let payloadUnitStart = (data[offset + 1] & 0x40) != 0
            let hasPayload = (data[offset + 3] & 0x10) != 0
            let hasAdaptation = (data[offset + 3] & 0x20) != 0

            if payloadUnitStart && hasPayload {
                var payloadOffset = offset + 4
                if hasAdaptation {
                    let adaptLen = Int(data[payloadOffset])
                    payloadOffset += 1 + adaptLen
                }

                if payloadOffset + 14 <= data.count &&
                    data[payloadOffset] == 0x00 &&
                    data[payloadOffset + 1] == 0x00 &&
                    data[payloadOffset + 2] == 0x01 {
                    let streamId = data[payloadOffset + 3]
                    if (streamId >= 0xC0 && streamId <= 0xDF) || (streamId >= 0xE0 && streamId <= 0xEF) {
                        let flags = data[payloadOffset + 7]
                        let hasPTS = (flags & 0x80) != 0
                        if hasPTS, let pts = parsePTS(from: data, at: payloadOffset + 9) {
                            samples.append((pid, pts))
                        }
                    }
                }
            }
            offset += packetSize
        }
        return samples
    }

    /// Extract all PTS values found for a specific TS PID in order of appearance.
    nonisolated private static func extractPTSValues(from data: Data, matchingPID pid: Int) -> [UInt64] {
        let packetSize = 188
        var ptsValues: [UInt64] = []

        var offset = 0
        while offset < data.count - packetSize {
            if data[offset] == 0x47 { break }
            offset += 1
        }

        while offset + packetSize <= data.count {
            guard data[offset] == 0x47 else { offset += 1; continue }

            let currentPID = (Int(data[offset + 1] & 0x1F) << 8) | Int(data[offset + 2])
            guard currentPID == pid else {
                offset += packetSize
                continue
            }

            let payloadUnitStart = (data[offset + 1] & 0x40) != 0
            let hasPayload = (data[offset + 3] & 0x10) != 0
            let hasAdaptation = (data[offset + 3] & 0x20) != 0

            if payloadUnitStart && hasPayload {
                var payloadOffset = offset + 4
                if hasAdaptation {
                    let adaptLen = Int(data[payloadOffset])
                    payloadOffset += 1 + adaptLen
                }

                if payloadOffset + 14 <= data.count &&
                    data[payloadOffset] == 0x00 &&
                    data[payloadOffset + 1] == 0x00 &&
                    data[payloadOffset + 2] == 0x01 {
                    let streamId = data[payloadOffset + 3]
                    if (streamId >= 0xC0 && streamId <= 0xDF) || (streamId >= 0xE0 && streamId <= 0xEF) {
                        let flags = data[payloadOffset + 7]
                        let hasPTS = (flags & 0x80) != 0
                        if hasPTS, let pts = parsePTS(from: data, at: payloadOffset + 9) {
                            ptsValues.append(pts)
                        }
                    }
                }
            }
            offset += packetSize
        }

        return ptsValues
    }

    /// Estimate a plausible recording duration from head/tail PTS windows in case of discontinuity.
    nonisolated private static func estimateDurationSecondsFromPTSWindows(
        headPTSValues: [UInt64],
        tailPTSValues: [UInt64],
        expectedSeconds: Int
    ) -> Int? {
        guard !headPTSValues.isEmpty, !tailPTSValues.isEmpty else { return nil }

        let wrapTicks = UInt64(1) << 33
        let maxReasonableSeconds = max(expectedSeconds * 6, expectedSeconds + 10_800)
        let acceptableError = max(expectedSeconds / 2, 1_200)

        var best: (score: Int, seconds: Int)?
        for headPTS in headPTSValues {
            for tailPTS in tailPTSValues {
                for wraps in 0...1 {
                    let adjustedTail = tailPTS + UInt64(wraps) * wrapTicks
                    guard adjustedTail > headPTS else { continue }
                    let seconds = Int((adjustedTail - headPTS) / 90_000)
                    guard seconds > 0, seconds <= maxReasonableSeconds else { continue }
                    let score = abs(seconds - expectedSeconds)
                    if best == nil || score < best!.score {
                        best = (score, seconds)
                    }
                }
            }
        }

        guard let best else { return nil }
        return best.score <= acceptableError ? best.seconds : nil
    }

    nonisolated private static func estimateDurationSecondsAcrossCommonPIDs(
        headData: Data,
        tailData: Data,
        expectedSeconds: Int
    ) -> Int? {
        let headSamples = extractPTSSamples(from: headData)
        let tailSamples = extractPTSSamples(from: tailData)
        guard !headSamples.isEmpty, !tailSamples.isEmpty else { return nil }

        var firstByPID: [Int: UInt64] = [:]
        for sample in headSamples where firstByPID[sample.pid] == nil {
            firstByPID[sample.pid] = sample.pts
        }
        var lastByPID: [Int: UInt64] = [:]
        for sample in tailSamples {
            lastByPID[sample.pid] = sample.pts
        }

        let commonPIDs = Set(firstByPID.keys).intersection(lastByPID.keys)
        guard !commonPIDs.isEmpty else { return nil }

        let wrapTicks = UInt64(1) << 33
        let maxReasonableSeconds = max(expectedSeconds * 6, expectedSeconds + 10_800)
        let acceptableError = max(expectedSeconds / 2, 1_200)

        var best: (score: Int, seconds: Int)?
        for pid in commonPIDs {
            guard let first = firstByPID[pid], let last = lastByPID[pid] else { continue }
            for wraps in 0...1 {
                let adjustedLast = last + UInt64(wraps) * wrapTicks
                guard adjustedLast > first else { continue }
                let seconds = Int((adjustedLast - first) / 90_000)
                guard seconds > 0, seconds <= maxReasonableSeconds else { continue }
                let score = abs(seconds - expectedSeconds)
                if best == nil || score < best!.score {
                    best = (score, seconds)
                }
            }
        }

        guard let best else { return nil }
        return best.score <= acceptableError ? best.seconds : nil
    }

    func deleteRecording(_ recording: Recording) async throws {
        try await client.cancelRecording(recordingId: recording.id)

        // Remove from local lists
        completedRecordings.removeAll { $0.id == recording.id }
        activeRecordings.removeAll { $0.id == recording.id }
        scheduledRecordings.removeAll { $0.id == recording.id }
    }

    func playRecording(_ recording: Recording) async throws -> URL {
        try await client.recordingStreamURL(recordingId: recording.id)
    }
}
