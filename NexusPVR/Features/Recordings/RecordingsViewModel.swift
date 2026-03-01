//
//  RecordingsViewModel.swift
//  nextpvr-apple-client
//
//  View model for recordings list
//

import SwiftUI
import Combine

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

            // Auto-select recording tab if there are active recordings, or switch away if empty
            if !activeRecordings.isEmpty && filter == .completed {
                filter = .recording
            } else if filter == .recording && activeRecordings.isEmpty {
                filter = .completed
            }

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

    private func probeDurations() {
        durationMismatches.removeAll()
        durationVerified.removeAll()
        let cache = Self.loadProbeCache()

        #if DISPATCHERPVR
        for recording in completedRecordings {
            guard recording.recordingStatus.isCompleted,
                  let expectedDuration = recording.duration,
                  expectedDuration > 0 else { continue }
            if let cached = cache[String(recording.id)] {
                applyProbeResult(recording: recording, expectedDuration: expectedDuration, detectedSeconds: cached)
                continue
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
                applyProbeResult(recording: recording, expectedDuration: expectedDuration, detectedSeconds: cached)
                continue
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
        if detectedSeconds < (expectedDuration * 90 / 100) {
            print("Duration probe: MISMATCH (cached) '\(recording.name)' — expected \(expectedDuration)s, detected \(detectedSeconds)s")
            durationMismatches[recording.id] = (expected: expectedDuration, detected: detectedSeconds)
        } else {
            print("Duration probe: OK (cached) '\(recording.name)' — expected \(expectedDuration)s, detected \(detectedSeconds)s")
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
            let headStatus = (headDataResponse as? HTTPURLResponse)?.statusCode ?? 0

            // If server ignores Range and returns full file, use that data directly
            let serverSupportsRange = headStatus == 206

            let firstPTS = Self.extractFirstPTS(from: headData)

            let lastPTS: UInt64?
            if serverSupportsRange {
                // Download last 2MB for last PTS
                let tailStart = fileSize - 2_097_152
                request.setValue("bytes=\(tailStart)-\(fileSize - 1)", forHTTPHeaderField: "Range")
                let (tailData, _) = try await URLSession.shared.data(for: request)
                lastPTS = Self.extractLastPTS(from: tailData)
            } else {
                // Server sent the whole file, extract last PTS from the end of what we got
                print("Duration probe: '\(recording.name)' — server doesn't support range requests, using full response (\(headData.count) bytes)")
                lastPTS = Self.extractLastPTS(from: headData)
            }

            guard let first = firstPTS, let last = lastPTS, last > first else {
                print("Duration probe: '\(recording.name)' — could not extract PTS timestamps")
                return
            }

            let detectedSeconds = Int((last - first) / 90000) // PTS is in 90kHz ticks

            guard detectedSeconds > 0 else {
                print("Duration probe: '\(recording.name)' returned 0s, skipping")
                return
            }

            cacheProbeResult(recordingId: recording.id, detectedDuration: detectedSeconds)
            applyProbeResult(recording: recording, expectedDuration: expectedDuration, detectedSeconds: detectedSeconds)
        } catch {
            print("Duration probe: FAILED '\(recording.name)' — \(error.localizedDescription)")
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

            cacheProbeResult(recordingId: recording.id, detectedDuration: detectedSeconds)
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

            cacheProbeResult(recordingId: recording.id, detectedDuration: detectedSeconds)
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
