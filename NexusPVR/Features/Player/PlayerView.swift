//
//  PlayerView.swift
//  nextpvr-apple-client
//
//  Video player view using MPV for MPEG-TS support
//

import SwiftUI
import Libmpv
#if !os(macOS)
import GLKit
import OpenGLES
#endif
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct PlayerView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var client: PVRClient

    let url: URL
    let title: String
    let recordingId: Int?
    let resumePosition: Int?

    @State private var showControls = true
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var isPlaying = true
    @State private var errorMessage: String?
    @State private var currentPosition: Double = 0
    @State private var duration: Double = 0
    @State private var isSeeking = false
    @State private var seekPosition: Double = 0
    @State private var seekBackwardTime: Int = UserPreferences.load().seekBackwardSeconds
    @State private var seekForwardTime: Int = UserPreferences.load().seekForwardSeconds
    @State private var seekForward: (() -> Void)?
    @State private var seekBackward: (() -> Void)?
    @State private var seekToPositionFunc: ((Double) -> Void)?
    @State private var hasResumed = false
    @State private var isPlayerReady = false
    @State private var startTimeOffset: Double = 0
    @State private var videoCodec: String?
    @State private var videoHeight: Int?
    @State private var hwDecoder: String?
    @State private var audioChannelLayout: String?

    init(url: URL, title: String, recordingId: Int? = nil, resumePosition: Int? = nil) {
        self.url = url
        self.title = title
        self.recordingId = recordingId
        self.resumePosition = resumePosition
    }

    var body: some View {
        ZStack {
            // MPV Video player
            #if os(tvOS)
            MPVContainerView(
                url: url,
                isPlaying: $isPlaying,
                errorMessage: $errorMessage,
                currentPosition: $currentPosition,
                duration: $duration,
                seekForward: $seekForward,
                seekBackward: $seekBackward,
                seekToPosition: $seekToPositionFunc,
                seekBackwardTime: seekBackwardTime,
                seekForwardTime: seekForwardTime,
                onPlaybackEnded: {
                    savePlaybackPosition()
                    markAsWatched()
                },
                onTogglePlayPause: {
                    isPlaying.toggle()
                    showControls = true
                    scheduleHideControls()
                },
                onToggleControls: {
                    toggleControls()
                },
                onShowControls: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls = true
                    }
                    scheduleHideControls()
                },
                onDismiss: {
                    savePlaybackPosition()
                    appState.stopPlayback()
                },
                onVideoInfoUpdate: { codec, height, hwdec, audioChannels in
                    videoCodec = codec
                    videoHeight = height
                    hwDecoder = hwdec
                    audioChannelLayout = audioChannels
                }
            )
                .ignoresSafeArea()
            #else
            MPVContainerView(
                url: url,
                isPlaying: $isPlaying,
                errorMessage: $errorMessage,
                currentPosition: $currentPosition,
                duration: $duration,
                seekForward: $seekForward,
                seekBackward: $seekBackward,
                seekToPosition: $seekToPositionFunc,
                seekBackwardTime: seekBackwardTime,
                seekForwardTime: seekForwardTime,
                onPlaybackEnded: {
                    savePlaybackPosition()
                    markAsWatched()
                },
                onVideoInfoUpdate: { codec, height, hwdec, audioChannels in
                    videoCodec = codec
                    videoHeight = height
                    hwDecoder = hwdec
                    audioChannelLayout = audioChannels
                }
            )
                .ignoresSafeArea()
                .onTapGesture {
                    toggleControls()
                }
            #endif

            // Loading overlay - hide video until ready (prevents seeing start before resume)
            if !isPlayerReady {
                ZStack {
                    Color.black
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    #if !os(tvOS)
                    // Close button always available, even while loading
                    VStack {
                        HStack {
                            Button {
                                savePlaybackPosition()
                                appState.stopPlayback()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                    .padding()
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("player-close-button")
                            Spacer()
                        }
                        .padding(.top, 8)
                        .padding(.leading, 8)
                        Spacer()
                    }
                    #endif
                }
                .ignoresSafeArea()
            }

            // Custom controls overlay
            if showControls && isPlayerReady {
                controlsOverlay
            }

            // Error message — auto-dismisses player after 3 seconds
            if let error = errorMessage {
                VStack {
                    Spacer()
                    VStack(spacing: Theme.spacingSM) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title2)
                        Text(error)
                    }
                    .foregroundStyle(.white)
                    .padding()
                    .background(Color.red.opacity(0.8))
                    .cornerRadius(Theme.cornerRadiusSM)
                    .padding()
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        appState.stopPlayback()
                    }
                }
            }

            #if os(macOS)
            // Hidden buttons for keyboard shortcuts
            // Hidden buttons for keyboard shortcuts — must have non-zero frame to receive events
            VStack {
                Button("") {
                    savePlaybackPosition()
                    appState.stopPlayback()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("") {
                    isPlaying.toggle()
                }
                .keyboardShortcut(.space, modifiers: [])

                if !isLiveStream {
                    Button("") {
                        seekBackward?()
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [])

                    Button("") {
                        seekForward?()
                    }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                }
            }
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
            #endif
        }
        .background(Color.black)
        .accessibilityIdentifier("player-view")
        .onAppear {
            scheduleHideControls()
            #if !os(macOS)
            // Prevent screen from sleeping during video playback
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
        }
        .onDisappear {
            // Only save if not already stopped by an explicit exit path
            if appState.isShowingPlayer {
                savePlaybackPosition()
                appState.stopPlayback()
            }
            // Notify recordings list to refresh with updated progress
            if recordingId != nil {
                NotificationCenter.default.post(name: .recordingsDidChange, object: nil)
            }
            #if !os(macOS)
            // Re-enable screen sleeping
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
        .onChange(of: duration) {
            // Resume playback position once duration is known (playback has started)
            if !hasResumed && duration > 0 {
                hasResumed = true
                // Capture initial position as display offset for streams with non-zero
                // start times (e.g., in-progress recordings with PTS offset)
                if currentPosition > 1 {
                    startTimeOffset = currentPosition
                }
                if let resumePos = resumePosition, resumePos > 0 {
                    // Has resume position - seek then show player
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        seekToPositionFunc?(Double(resumePos))
                        // Show player after seek completes
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            isPlayerReady = true
                        }
                    }
                } else {
                    // No resume position - show player immediately
                    isPlayerReady = true
                }
            }
        }
        .onChange(of: isPlaying) {
            // Save position to NextPVR when paused
            if !isPlaying {
                savePlaybackPosition()
            }
        }
    }

    private func savePlaybackPosition() {
        guard let recordingId = recordingId else { return }
        let position = Int(currentPosition)
        // Don't save if we're at the very beginning
        guard position > 10 else { return }
        // If near the end, mark as fully watched instead
        if duration > 0 && currentPosition > duration - 30 {
            markAsWatched()
            return
        }

        Task {
            try? await client.setRecordingPosition(recordingId: recordingId, positionSeconds: position)
        }
    }

    private func markAsWatched() {
        guard let recordingId = recordingId else { return }
        // Set position to full duration to mark as watched
        let watchedPosition = Int(duration > 0 ? duration : currentPosition)
        Task {
            try? await client.setRecordingPosition(recordingId: recordingId, positionSeconds: watchedPosition)
            print("NextPVR: Marked recording \(recordingId) as watched")
            // Notify recordings list to refresh
            NotificationCenter.default.post(name: .recordingsDidChange, object: nil)
        }
    }

    private var controlsOverlay: some View {
        VStack {
            // Top bar
            topBar

            Spacer()

            // Center controls: seek backward, play/pause, seek forward
            centerControls

            Spacer()

            // Bottom controls: progress bar and time (recordings only)
            if !isLiveStream && duration > 0 {
                bottomControls
            }
        }
        .background(
            LinearGradient(
                colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.5)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var isLiveStream: Bool { recordingId == nil }

    private var centerControls: some View {
        HStack(spacing: 48) {
            if !isLiveStream {
                // Seek backward button
                Button {
                    seekBackward?()
                } label: {
                    Image(systemName: "gobackward.\(seekBackwardTime)")
                        .font(.system(size: 40))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            // Play/pause button
            Button {
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            if !isLiveStream {
                // Seek forward button
                Button {
                    seekForward?()
                } label: {
                    Image(systemName: "goforward.\(seekForwardTime)")
                        .font(.system(size: 40))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 8) {
            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    Rectangle()
                        .fill(Color.white.opacity(0.3))
                        .frame(height: 4)

                    // Progress fill
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: progressWidth(for: geometry.size.width), height: 4)

                    // Scrubber handle
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .offset(x: progressWidth(for: geometry.size.width) - 7)
                }
                .frame(height: 14)
                .contentShape(Rectangle())
                #if !os(tvOS)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isSeeking = true
                            let progress = max(0, min(1, value.location.x / geometry.size.width))
                            seekPosition = progress * duration + startTimeOffset
                            scheduleHideControls()
                        }
                        .onEnded { value in
                            let progress = max(0, min(1, value.location.x / geometry.size.width))
                            let targetPosition = progress * duration + startTimeOffset
                            seekToPosition(targetPosition)
                            isSeeking = false
                        }
                )
                #endif
            }
            .frame(height: 14)

            // Time labels
            HStack {
                Text(formatTime((isSeeking ? seekPosition : currentPosition) - startTimeOffset))
                    .font(.caption)
                    .foregroundStyle(.white)
                    .monospacedDigit()

                Spacer()

                Text(formatTime(duration))
                    .font(.caption)
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    private func progressWidth(for totalWidth: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        let adjPosition = (isSeeking ? seekPosition : currentPosition) - startTimeOffset
        let progress = adjPosition / duration
        return max(0, min(totalWidth, CGFloat(progress) * totalWidth))
    }

    private func seekToPosition(_ position: Double) {
        seekToPositionFunc?(position)
        currentPosition = position
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    private var topBar: some View {
        HStack {
            #if !os(tvOS)
            Button {
                savePlaybackPosition()
                appState.stopPlayback()
            } label: {
                Image(systemName: "xmark")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("player-close-button")
            #endif

            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer()

            videoBadges
                .padding(.trailing, 4)
        }
        .padding(.horizontal)
        .padding(.top, Theme.spacingMD)
    }

    private var videoBadges: some View {
        HStack(spacing: 6) {
            if let height = videoHeight {
                badgeText(resolutionLabel(height: height), color: .white)
            }
            if let codec = videoCodec {
                badgeText(formatCodecName(codec), color: .white)
            }
            if let hw = hwDecoder, !hw.isEmpty, hw != "no" {
                badgeText("HW", color: .green)
            } else if videoCodec != nil {
                badgeText("SW", color: .orange)
            }
            if let audio = audioChannelLayout {
                badgeText(audio, color: .white)
            }
        }
    }

    private func badgeText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.6))
            .cornerRadius(4)
    }

    private func resolutionLabel(height: Int) -> String {
        if height >= 2160 { return "4K" }
        if height >= 1440 { return "1440p" }
        if height >= 1080 { return "1080p" }
        if height >= 720 { return "720p" }
        if height >= 480 { return "480p" }
        return "\(height)p"
    }

    private func formatCodecName(_ codec: String) -> String {
        let lower = codec.lowercased()
        if lower.contains("h264") || lower.contains("avc") { return "H.264" }
        if lower.contains("hevc") || lower.contains("h265") { return "HEVC" }
        if lower.contains("vp9") { return "VP9" }
        if lower.contains("av1") || lower.contains("av01") { return "AV1" }
        return codec.uppercased()
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls.toggle()
        }

        if showControls {
            scheduleHideControls()
        }
    }

    private func scheduleHideControls() {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls = false
                    }
                }
            }
        }
    }
}

// MARK: - MPV Player Core

class MPVPlayerCore: NSObject {
    private var mpv: OpaquePointer?
    var mpvGL: OpaquePointer?
    private var errorBinding: Binding<String?>?
    private var isDestroyed = false
    private var positionTimer: Timer?
    private let eventLoopGroup = DispatchGroup()
    var onPositionUpdate: ((Double, Double) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onVideoInfoUpdate: ((String?, Int?, String?, String?) -> Void)?
    private var lastCodec: String?
    private var lastHeight: Int?
    private var lastHwdec: String?
    private var lastAudioChannels: String?
    private var hasTriedHwdecCopy = false
    private var currentURLPath: String?
    private var lastPlaybackError: String?

    // Performance stats accumulation
    private var fpsSamples: [Double] = []
    private var bitrateSamples: [Double] = []
    private var peakAvsync: Double = 0

    override init() {
        super.init()
    }

    deinit {
        destroy()
    }

    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true

        savePlayerStats()
        stopPositionPolling()

        // Nil out callbacks to break reference cycles with SwiftUI @State
        onPositionUpdate = nil
        onPlaybackEnded = nil
        onVideoInfoUpdate = nil

        if let mpvGL = mpvGL {
            mpv_render_context_set_update_callback(mpvGL, nil, nil)
            mpv_render_context_free(mpvGL)
            self.mpvGL = nil
        }

        // Wake the event loop so it sees isDestroyed and exits
        if let mpv = mpv {
            mpv_wakeup(mpv)
        }

        // Wait for the event loop thread to finish before freeing mpv
        // (mpv API is not safe to call concurrently with mpv_terminate_destroy)
        eventLoopGroup.wait()

        if let mpv = mpv {
            mpv_terminate_destroy(mpv)
            self.mpv = nil
        }
    }

    func startPositionPolling() {
        stopPositionPolling()
        var statsCounter = 0
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let position = self.getTimePosition()
            let duration = self.getDuration()
            let info = self.getVideoInfo()
            let changed = info.codec != self.lastCodec || info.height != self.lastHeight || info.hwdec != self.lastHwdec || info.audioChannels != self.lastAudioChannels
            if changed {
                self.lastCodec = info.codec
                self.lastHeight = info.height
                self.lastHwdec = info.hwdec
                self.lastAudioChannels = info.audioChannels
                // Log video info to event log when it first becomes available
                if info.codec != nil {
                    self.logVideoInfo(info)
                }
            }
            // Log performance stats every 5 seconds
            statsCounter += 1
            if statsCounter % 10 == 0 {
                self.logPerformanceStats()
            }
            DispatchQueue.main.async {
                self.onPositionUpdate?(position, duration)
                if changed {
                    self.onVideoInfoUpdate?(info.codec, info.height, info.hwdec, info.audioChannels)
                }
            }
        }
    }

    func stopPositionPolling() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func logPerformanceStats() {
        guard let mpv = mpv else { return }

        var droppedFrames: Int64 = 0
        mpv_get_property(mpv, "frame-drop-count", MPV_FORMAT_INT64, &droppedFrames)

        var decoderDroppedFrames: Int64 = 0
        mpv_get_property(mpv, "decoder-frame-drop-count", MPV_FORMAT_INT64, &decoderDroppedFrames)

        var fps: Double = 0
        mpv_get_property(mpv, "estimated-vf-fps", MPV_FORMAT_DOUBLE, &fps)

        var avsync: Double = 0
        mpv_get_property(mpv, "avsync", MPV_FORMAT_DOUBLE, &avsync)

        var voDelayed: Int64 = 0
        mpv_get_property(mpv, "vo-delayed-frame-count", MPV_FORMAT_INT64, &voDelayed)

        var videoBitrate: Double = 0
        mpv_get_property(mpv, "video-bitrate", MPV_FORMAT_DOUBLE, &videoBitrate)

        var cacheUsed: Int64 = 0
        mpv_get_property(mpv, "demuxer-cache-duration", MPV_FORMAT_INT64, &cacheUsed)

        // Accumulate samples for averages
        if fps > 0 { fpsSamples.append(fps) }
        if videoBitrate > 0 { bitrateSamples.append(videoBitrate / 1000) }
        peakAvsync = max(peakAvsync, abs(avsync))

        print("MPV [perf]: fps=\(String(format: "%.1f", fps)) avsync=\(String(format: "%.3f", avsync))s dropped=\(droppedFrames) decoder-dropped=\(decoderDroppedFrames) vo-delayed=\(voDelayed) bitrate=\(String(format: "%.0f", videoBitrate / 1000))kbps cache=\(cacheUsed)s")
    }

    func savePlayerStats() {
        guard let mpv = mpv else { return }

        var droppedFrames: Int64 = 0
        mpv_get_property(mpv, "frame-drop-count", MPV_FORMAT_INT64, &droppedFrames)

        var decoderDroppedFrames: Int64 = 0
        mpv_get_property(mpv, "decoder-frame-drop-count", MPV_FORMAT_INT64, &decoderDroppedFrames)

        var voDelayed: Int64 = 0
        mpv_get_property(mpv, "vo-delayed-frame-count", MPV_FORMAT_INT64, &voDelayed)

        let avgFps = fpsSamples.isEmpty ? 0 : fpsSamples.reduce(0, +) / Double(fpsSamples.count)
        let avgBitrate = bitrateSamples.isEmpty ? 0 : bitrateSamples.reduce(0, +) / Double(bitrateSamples.count)

        var stats = PlayerStats()
        stats.avgFps = avgFps
        stats.avgBitrateKbps = avgBitrate
        stats.totalDroppedFrames = droppedFrames
        stats.totalDecoderDroppedFrames = decoderDroppedFrames
        stats.totalVoDelayedFrames = voDelayed
        stats.maxAvsync = peakAvsync
        stats.save()
    }

    func getTimePosition() -> Double {
        guard let mpv = mpv else { return 0 }
        var position: Double = 0
        mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &position)
        return position
    }

    func getDuration() -> Double {
        guard let mpv = mpv else { return 0 }
        var duration: Double = 0
        mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &duration)
        return duration
    }

    func seek(seconds: Int) {
        guard let mpv = mpv else { return }
        let command = "seek \(seconds) relative"
        let result = mpv_command_string(mpv, command)
        if result < 0 {
            print("MPV: seek command failed: \(result)")
        }
    }

    func seekTo(position: Double) {
        guard let mpv = mpv else { return }
        let command = "seek \(position) absolute"
        let result = mpv_command_string(mpv, command)
        if result < 0 {
            print("MPV: seekTo command failed: \(result)")
        }
    }

    func getVideoInfo() -> (codec: String?, width: Int?, height: Int?, hwdec: String?, audioChannels: String?) {
        guard let mpv = mpv else { return (nil, nil, nil, nil, nil) }

        var codec: String?
        var width: Int?
        var height: Int?
        var hwdec: String?
        var audioChannels: String?

        if let cString = mpv_get_property_string(mpv, "video-codec") {
            codec = String(cString: cString)
            mpv_free(cString)
        }

        var w: Int64 = 0
        if mpv_get_property(mpv, "width", MPV_FORMAT_INT64, &w) >= 0 {
            width = Int(w)
        }

        var h: Int64 = 0
        if mpv_get_property(mpv, "height", MPV_FORMAT_INT64, &h) >= 0 {
            height = Int(h)
        }

        if let cString = mpv_get_property_string(mpv, "hwdec-current") {
            hwdec = String(cString: cString)
            mpv_free(cString)
        }

        if let cString = mpv_get_property_string(mpv, "audio-params/channel-count") {
            let count = String(cString: cString)
            mpv_free(cString)
            if let n = Int(count) {
                switch n {
                case 1: audioChannels = "Mono"
                case 2: audioChannels = "Stereo"
                case 6: audioChannels = "5.1"
                case 8: audioChannels = "7.1"
                default: audioChannels = "\(n)ch"
                }
            }
        }

        return (codec, width, height, hwdec, audioChannels)
    }

    private var hasLoggedVideoInfo = false

    private func logVideoInfo(_ info: (codec: String?, width: Int?, height: Int?, hwdec: String?, audioChannels: String?)) {
        guard !hasLoggedVideoInfo, info.codec != nil else { return }
        hasLoggedVideoInfo = true

        var details: [String] = []
        if let w = info.width, let h = info.height {
            details.append("\(w)x\(h)")
        }
        if let codec = info.codec {
            details.append(codec)
        }
        if let hw = info.hwdec, !hw.isEmpty, hw != "no" {
            details.append("hwdec: \(hw)")
        } else {
            details.append("swdec")
        }
        if let audio = info.audioChannels {
            details.append(audio)
        }

        NetworkEventLog.shared.log(NetworkEvent(
            timestamp: Date(),
            method: "PLAY",
            path: details.joined(separator: " · "),
            statusCode: nil,
            isSuccess: true,
            durationMs: 0,
            responseSize: 0,
            errorDetail: nil
        ))
    }

    func setup(errorBinding: Binding<String?>?) -> Bool {
        self.errorBinding = errorBinding

        // Create MPV
        mpv = mpv_create()
        guard let mpv = mpv else {
            print("MPV: Failed to create context")
            return false
        }

        // Video output
        #if os(macOS)
        mpv_set_option_string(mpv, "vo", "gpu")
        mpv_set_option_string(mpv, "gpu-api", "opengl")
        #else
        mpv_set_option_string(mpv, "vo", "libmpv")
        mpv_set_option_string(mpv, "gpu-api", "opengl")
        mpv_set_option_string(mpv, "opengl-es", "yes")
        #endif

        // Enable yt-dlp for direct YouTube URL support (optional)
        mpv_set_option_string(mpv, "ytdl", "no")

        // Disable ALL Lua scripts — LuaJIT's JIT compiler generates code at runtime
        // that violates macOS hardened runtime code signing (SIGKILL Code Signature Invalid).
        // Each built-in script must be disabled individually; load-scripts only affects external ones.
        mpv_set_option_string(mpv, "load-scripts", "no")
        mpv_set_option_string(mpv, "osc", "no")
        mpv_set_option_string(mpv, "load-stats-overlay", "no")
        mpv_set_option_string(mpv, "load-console", "no")
        mpv_set_option_string(mpv, "load-auto-profiles", "no")
        mpv_set_option_string(mpv, "load-select", "no")
        mpv_set_option_string(mpv, "load-commands", "no")
        mpv_set_option_string(mpv, "load-context-menu", "no")
        mpv_set_option_string(mpv, "load-positioning", "no")
        mpv_set_option_string(mpv, "input-default-bindings", "no")

        // Hardware decoding - only H.264/HEVC use hardware decode
        // AV1/VP9 forced to software (AV1 hwdec is broken on iOS, causes texture errors)
        mpv_set_option_string(mpv, "hwdec", "auto-safe")
        mpv_set_option_string(mpv, "hwdec-codecs", "h264,hevc,av1")

        // CPU threading for software decode (MPV recommends max 16)
        let threadCount = min(ProcessInfo.processInfo.processorCount * 2, 16)
        mpv_set_option_string(mpv, "vd-lavc-threads", "\(threadCount)")

        // Keep player open
        mpv_set_option_string(mpv, "keep-open", "yes")
        mpv_set_option_string(mpv, "idle", "yes")

        // Frame dropping — allow mpv to drop frames when video can't keep up with audio
        // Prevents progressive A/V desync on slower hardware (e.g. 4K HEVC on older Apple TV)
        mpv_set_option_string(mpv, "framedrop", "vo")

        // Buffering for streaming - wait for video to buffer before starting
        mpv_set_option_string(mpv, "cache", "yes")
        mpv_set_option_string(mpv, "cache-secs", "120")
        mpv_set_option_string(mpv, "cache-pause-initial", "yes")  // Pause until cache is filled initially
        mpv_set_option_string(mpv, "demuxer-max-bytes", "150MiB")
        mpv_set_option_string(mpv, "demuxer-max-back-bytes", "150MiB")
        mpv_set_option_string(mpv, "demuxer-seekable-cache", "yes")
        mpv_set_option_string(mpv, "cache-pause-wait", "5")
        mpv_set_option_string(mpv, "demuxer-readahead-secs", "60")

        // Network
        mpv_set_option_string(mpv, "network-timeout", "30")
        mpv_set_option_string(mpv, "stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_delay_max=5")

        // Audio
        #if os(macOS)
        mpv_set_option_string(mpv, "ao", "coreaudio")
        mpv_set_option_string(mpv, "audio-buffer", "0.5")  // Larger buffer on macOS to avoid coreaudio race with raw TS streams
        mpv_set_option_string(mpv, "audio-wait-open", "0.5")  // Delay opening audio device until data is ready (prevents NULL buffer crash with raw TS streams)
        #else
        mpv_set_option_string(mpv, "ao", "audiounit")
        mpv_set_option_string(mpv, "audio-buffer", "0.2")
        #endif
        let audioChannels = UserPreferences.load().audioChannels
        mpv_set_option_string(mpv, "audio-channels", audioChannels)
        mpv_set_option_string(mpv, "volume", "100")
        mpv_set_option_string(mpv, "audio-fallback-to-null", "yes")
        mpv_set_option_string(mpv, "audio-stream-silence", "yes")  // Output silence while audio buffers (avoid muting)

        // Seeking - precise seeks for better audio sync with external audio tracks
        mpv_set_option_string(mpv, "hr-seek", "yes")

        // Disable MPV's built-in OSD (seek bar, etc.) — we use our own SwiftUI overlay
        mpv_set_option_string(mpv, "osd-level", "0")

        // Dithering - disabled on GLES 2.0 (tvOS/iOS) to avoid INVALID_ENUM texture errors
        // in dumb mode. Content is 8-bit SDR to 8-bit display, so dithering has no effect.
        #if os(macOS)
        mpv_set_option_string(mpv, "dither", "ordered")
        #else
        mpv_set_option_string(mpv, "dither", "no")
        #endif

        // Demuxer
        mpv_set_option_string(mpv, "demuxer", "lavf")
        mpv_set_option_string(mpv, "demuxer-lavf-probe-info", "auto")
        mpv_set_option_string(mpv, "demuxer-lavf-analyzeduration", "3000000")

        // Initialize MPV
        let initResult = mpv_initialize(mpv)
        guard initResult >= 0 else {
            print("MPV: Failed to initialize, error: \(initResult)")
            return false
        }

        print("MPV: Initialized successfully")

        // Request verbose log messages for debugging
        mpv_request_log_messages(mpv, "v")

        // Start event loop
        startEventLoop()

        return true
    }

    func loadURL(_ url: URL) {
        guard let mpv = mpv else {
            print("MPV: No context available")
            return
        }

        let urlString = url.absoluteString
        currentURLPath = url.path
        print("MPV: Loading URL: \(urlString)")

        // Fix TS timing issues (genpts regenerates PTS, igndts ignores broken DTS)
        if url.pathExtension.lowercased() == "ts" {
            mpv_set_property_string(mpv, "demuxer-lavf-o", "fflags=+genpts+igndts")
        } else {
            mpv_set_property_string(mpv, "demuxer-lavf-o", "")
        }

        // Use mpv_command_string for simpler string-based command
        let command = "loadfile \"\(urlString)\" replace"
        let result = mpv_command_string(mpv, command)
        if result < 0 {
            let errorStr = String(cString: mpv_error_string(result))
            print("MPV: loadfile command failed: \(errorStr) (\(result))")
        } else {
            print("MPV: loadfile command sent successfully")
        }
    }

    func play() {
        guard let mpv = mpv else { return }
        var flag: Int32 = 0
        let result = mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
        if result < 0 {
            print("MPV: Failed to unpause: \(result)")
        }
    }

    func pause() {
        guard let mpv = mpv else { return }
        var flag: Int32 = 1
        let result = mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
        if result < 0 {
            print("MPV: Failed to pause: \(result)")
        }
    }

    #if os(macOS)
    func setWindowID(_ layer: CAMetalLayer) {
        guard let mpv = mpv else { return }

        // Cast the layer pointer to Int64 for mpv's wid option
        let wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        var widValue = wid

        let result = mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &widValue)
        if result < 0 {
            let errorStr = String(cString: mpv_error_string(result))
            print("MPV: Failed to set wid: \(errorStr)")
        } else {
            print("MPV: Successfully set window ID")
        }
    }
    #else
    func createRenderContext(view: MPVPlayerGLView) {
        guard let mpv = mpv else { return }

        let api = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String)
        var initParams = mpv_opengl_init_params(
            get_proc_address: { (ctx, name) -> UnsafeMutableRawPointer? in
                let symbolName = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
                let identifier = CFBundleGetBundleWithIdentifier("com.apple.opengles" as CFString)
                return CFBundleGetFunctionPointerForName(identifier, symbolName)
            },
            get_proc_address_ctx: nil
        )

        withUnsafeMutablePointer(to: &initParams) { initParamsPtr in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initParamsPtr),
                mpv_render_param()
            ]

            let result = mpv_render_context_create(&mpvGL, mpv, &params)
            if result < 0 {
                let errorStr = String(cString: mpv_error_string(result))
                print("MPV: Failed to create render context: \(errorStr)")
                return
            }
            print("MPV: Render context created successfully")

            view.mpvGL = UnsafeMutableRawPointer(mpvGL)

            mpv_render_context_set_update_callback(
                mpvGL,
                { (ctx) in
                    guard let ctx = ctx else { return }
                    let view = Unmanaged<MPVPlayerGLView>.fromOpaque(ctx).takeUnretainedValue()
                    guard view.needsDrawing else { return }
                    view.renderQueue.async {
                        view.display()
                    }
                },
                UnsafeMutableRawPointer(Unmanaged.passUnretained(view).toOpaque())
            )
        }
    }
    #endif

    private func startEventLoop() {
        eventLoopGroup.enter()
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            defer { self?.eventLoopGroup.leave() }
            while let strongSelf = self, !strongSelf.isDestroyed, let mpv = strongSelf.mpv {
                guard let event = mpv_wait_event(mpv, 0.5) else { continue }
                if strongSelf.isDestroyed { break }
                strongSelf.handleEvent(event.pointee)

                if event.pointee.event_id == MPV_EVENT_SHUTDOWN {
                    break
                }
            }
            print("MPV: Event loop ended")
        }
    }

    private func handleEvent(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_LOG_MESSAGE:
            if let msg = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee,
               let text = msg.text {
                let logText = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
                if !logText.isEmpty && !logText.hasPrefix("Set property:") {
                    print("MPV [\(String(cString: msg.level!))]: \(logText)")
                }

                // Log mpv errors and HTTP warnings to the event log
                let level = String(cString: msg.level!)
                if level == "error" || (level == "warn" && logText.contains("http:")) {
                    NetworkEventLog.shared.log(NetworkEvent(
                        timestamp: Date(),
                        method: "PLAY",
                        path: currentURLPath ?? "mpv",
                        statusCode: nil,
                        isSuccess: false,
                        durationMs: 0,
                        responseSize: 0,
                        errorDetail: logText
                    ))
                }

                // Capture HTTP errors for on-screen display.
                // Prefer HTTP errors (e.g. "503 Service Unavailable") over generic
                // "Failed to open" messages that follow.
                if level == "warn" && logText.contains("HTTP error") {
                    lastPlaybackError = logText
                } else if level == "error" && lastPlaybackError == nil {
                    if logText.contains("Failed to open") || logText.contains("Failed to recognize") {
                        lastPlaybackError = logText
                    }
                }

                // Detect hardware decoding texture failures on iOS/tvOS where
                // OpenGL ES can't handle certain VideoToolbox surface formats
                // (e.g. p010 for 10-bit HDR, or standard 4K HEVC textures).
                // Fall back to videotoolbox-copy which copies frames to CPU memory.
                #if !os(macOS)
                if !hasTriedHwdecCopy && level == "error" && (
                    logText.contains("texture") ||
                    logText.contains("hardware decod") ||
                    logText.contains("surface failed")
                ) {
                    hasTriedHwdecCopy = true
                    print("MPV: Hardware texture failure — falling back to videotoolbox-copy")
                    mpv_set_property_string(mpv, "hwdec", "videotoolbox-copy")
                    hasLoggedVideoInfo = false  // Re-log video info after hwdec change
                    NetworkEventLog.shared.log(NetworkEvent(
                        timestamp: Date(),
                        method: "PLAY",
                        path: "hwdec fallback → videotoolbox-copy",
                        statusCode: nil,
                        isSuccess: false,
                        durationMs: 0,
                        responseSize: 0,
                        errorDetail: logText
                    ))
                }
                #endif
            }

        case MPV_EVENT_START_FILE:
            print("MPV: Starting file")

        case MPV_EVENT_FILE_LOADED:
            print("MPV: File loaded successfully")

        case MPV_EVENT_PLAYBACK_RESTART:
            print("MPV: Playback started/restarted")
            let info = getVideoInfo()
            DispatchQueue.main.async { [weak self] in
                self?.onVideoInfoUpdate?(info.codec, info.height, info.hwdec, info.audioChannels)
                if let self = self, info.codec != nil {
                    self.logVideoInfo(info)
                }
            }

        case MPV_EVENT_AUDIO_RECONFIG:
            print("MPV: Audio reconfigured")

        case MPV_EVENT_VIDEO_RECONFIG:
            print("MPV: Video reconfigured")

        case MPV_EVENT_END_FILE:
            if let data = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee {
                let reason = data.reason
                print("MPV: Playback ended (reason: \(reason))")
                if reason == MPV_END_FILE_REASON_EOF {
                    // Normal end of file - video finished playing
                    print("MPV: Video playback completed naturally")
                    DispatchQueue.main.async { [weak self] in
                        self?.onPlaybackEnded?()
                    }
                } else if reason == MPV_END_FILE_REASON_ERROR {
                    let error = data.error
                    let errorStr = String(cString: mpv_error_string(error))
                    let path = currentURLPath ?? "unknown"
                    let detail = lastPlaybackError ?? errorStr
                    print("MPV: Playback error: \(errorStr)")

                    // Log to event log (no weak self — NetworkEventLog is a singleton)
                    NetworkEventLog.shared.log(NetworkEvent(
                        timestamp: Date(),
                        method: "PLAY",
                        path: path,
                        statusCode: nil,
                        isSuccess: false,
                        durationMs: 0,
                        responseSize: 0,
                        errorDetail: detail
                    ))

                    // Show error on screen
                    let errorBinding = self.errorBinding
                    DispatchQueue.main.async {
                        errorBinding?.wrappedValue = detail
                    }
                    lastPlaybackError = nil
                }
            }

        case MPV_EVENT_SHUTDOWN:
            print("MPV: Shutdown event received")

        case MPV_EVENT_NONE:
            break

        default:
            print("MPV: Event \(event.event_id.rawValue)")
        }
    }
}

// MARK: - MPV Container View

#if os(macOS)
struct MPVContainerView: NSViewRepresentable {
    let url: URL
    @Binding var isPlaying: Bool
    @Binding var errorMessage: String?
    @Binding var currentPosition: Double
    @Binding var duration: Double
    @Binding var seekForward: (() -> Void)?
    @Binding var seekBackward: (() -> Void)?
    @Binding var seekToPosition: ((Double) -> Void)?
    let seekBackwardTime: Int
    let seekForwardTime: Int

    var onPlaybackEnded: (() -> Void)?
    var onVideoInfoUpdate: ((String?, Int?, String?, String?) -> Void)?

    func makeNSView(context: Context) -> MPVPlayerNSView {
        let view = MPVPlayerNSView()
        view.setup(errorBinding: $errorMessage)
        view.onPositionUpdate = { position, dur in
            DispatchQueue.main.async {
                self.currentPosition = position
                self.duration = dur
            }
        }
        view.onPlaybackEnded = onPlaybackEnded
        view.onVideoInfoUpdate = onVideoInfoUpdate
        view.loadURL(url)
        view.startPositionPolling()
        context.coordinator.playerView = view

        // Set up seek closures
        DispatchQueue.main.async {
            self.seekForward = {
                view.seek(seconds: self.seekForwardTime)
            }
            self.seekBackward = {
                view.seek(seconds: -self.seekBackwardTime)
            }
            self.seekToPosition = { position in
                view.seekTo(position: position)
            }
        }

        return view
    }

    func updateNSView(_ nsView: MPVPlayerNSView, context: Context) {
        if isPlaying {
            nsView.play()
        } else {
            nsView.pause()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleNSView(_ nsView: MPVPlayerNSView, coordinator: Coordinator) {
        nsView.cleanup()
    }

    class Coordinator {
        var playerView: MPVPlayerNSView?
    }
}

class MPVPlayerNSView: NSView {
    private var player: MPVPlayerCore?
    private var metalLayer: CAMetalLayer?
    var onPositionUpdate: ((Double, Double) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onVideoInfoUpdate: ((String?, Int?, String?, String?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        metalLayer = CAMetalLayer()
        metalLayer?.backgroundColor = NSColor.black.cgColor
        metalLayer?.pixelFormat = .bgra8Unorm
        wantsLayer = true
        layer = metalLayer
    }

    override func layout() {
        super.layout()
        metalLayer?.frame = bounds
    }

    func setup(errorBinding: Binding<String?>?) {
        player = MPVPlayerCore()
        guard let success = player?.setup(errorBinding: errorBinding), success else {
            return
        }
        if let metalLayer = metalLayer {
            player?.setWindowID(metalLayer)
        }
        player?.onPositionUpdate = { [weak self] position, duration in
            self?.onPositionUpdate?(position, duration)
        }
        player?.onPlaybackEnded = { [weak self] in
            self?.onPlaybackEnded?()
        }
        player?.onVideoInfoUpdate = { [weak self] codec, height, hwdec, audioChannels in
            self?.onVideoInfoUpdate?(codec, height, hwdec, audioChannels)
        }
    }

    func loadURL(_ url: URL) {
        player?.loadURL(url)
    }

    func play() {
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func seek(seconds: Int) {
        player?.seek(seconds: seconds)
    }

    func seekTo(position: Double) {
        player?.seekTo(position: position)
    }

    func startPositionPolling() {
        player?.startPositionPolling()
    }

    func cleanup() {
        player?.destroy()
        player = nil
        onPositionUpdate = nil
        onPlaybackEnded = nil
        onVideoInfoUpdate = nil
    }
}

#else
// iOS/tvOS implementation
struct MPVContainerView: UIViewRepresentable {
    let url: URL
    @Binding var isPlaying: Bool
    @Binding var errorMessage: String?
    @Binding var currentPosition: Double
    @Binding var duration: Double
    @Binding var seekForward: (() -> Void)?
    @Binding var seekBackward: (() -> Void)?
    @Binding var seekToPosition: ((Double) -> Void)?
    let seekBackwardTime: Int
    let seekForwardTime: Int

    var onPlaybackEnded: (() -> Void)?

    #if os(tvOS)
    var onTogglePlayPause: (() -> Void)?
    var onToggleControls: (() -> Void)?
    var onShowControls: (() -> Void)?
    var onDismiss: (() -> Void)?
    #endif

    var onVideoInfoUpdate: ((String?, Int?, String?, String?) -> Void)?

    func makeUIView(context: Context) -> MPVPlayerGLView {
        let view = MPVPlayerGLView(frame: .zero)
        view.setup(errorBinding: $errorMessage)
        view.onPositionUpdate = { position, dur in
            DispatchQueue.main.async {
                self.currentPosition = position
                self.duration = dur
            }
        }
        view.onPlaybackEnded = onPlaybackEnded
        view.onVideoInfoUpdate = onVideoInfoUpdate
        view.loadURL(url)
        view.startPositionPolling()
        context.coordinator.playerView = view

        // Set up seek closures
        DispatchQueue.main.async {
            self.seekForward = {
                view.seek(seconds: self.seekForwardTime)
            }
            self.seekBackward = {
                view.seek(seconds: -self.seekBackwardTime)
            }
            self.seekToPosition = { position in
                view.seekTo(position: position)
            }
        }

        #if os(tvOS)
        // Set up tvOS remote control callbacks
        view.onPlayPause = onTogglePlayPause
        view.onSeekForward = {
            view.seek(seconds: self.seekForwardTime)
            self.onShowControls?()
        }
        view.onSeekBackward = {
            view.seek(seconds: -self.seekBackwardTime)
            self.onShowControls?()
        }
        view.onSelect = onToggleControls
        view.onMenu = onDismiss
        #endif

        return view
    }

    func updateUIView(_ uiView: MPVPlayerGLView, context: Context) {
        if isPlaying {
            uiView.play()
        } else {
            uiView.pause()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleUIView(_ uiView: MPVPlayerGLView, coordinator: Coordinator) {
        uiView.cleanup()
    }

    class Coordinator {
        var playerView: MPVPlayerGLView?
    }
}

class MPVPlayerGLView: GLKView {
    private var player: MPVPlayerCore?
    private var defaultFBO: GLint = -1
    private var displayLink: CADisplayLink?
    private var resizeDebouncer: DispatchWorkItem?
    private var isResizing = false
    var mpvGL: UnsafeMutableRawPointer?
    var needsDrawing = true
    let renderQueue = DispatchQueue(label: "nexuspvr.opengl", qos: .userInteractive)
    var onPositionUpdate: ((Double, Double) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onVideoInfoUpdate: ((String?, Int?, String?, String?) -> Void)?

    #if os(tvOS)
    // Callbacks for tvOS remote control
    var onPlayPause: (() -> Void)?
    var onSeekForward: (() -> Void)?
    var onSeekBackward: (() -> Void)?
    var onSelect: (() -> Void)?
    var onMenu: (() -> Void)?

    override var canBecomeFocused: Bool { true }
    #endif

    override init(frame: CGRect) {
        guard let glContext = EAGLContext(api: .openGLES2) else {
            fatalError("Failed to initialize OpenGL ES 2.0 context")
        }
        super.init(frame: frame, context: glContext)
        commonInit()
    }

    override init(frame: CGRect, context: EAGLContext) {
        super.init(frame: frame, context: context)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        bindDrawable()
        isOpaque = true
        enableSetNeedsDisplay = false
        backgroundColor = .black
        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Fill black initially
        glClearColor(0, 0, 0, 1)
        glClear(UInt32(GL_COLOR_BUFFER_BIT))

        // Display link for frame sync
        displayLink = CADisplayLink(target: self, selector: #selector(updateFrame))
        displayLink?.add(to: .main, forMode: .common)

        #if os(tvOS)
        isUserInteractionEnabled = true
        #endif
    }

    deinit {
        displayLink?.invalidate()
    }

    @objc private func updateFrame() {
        if needsDrawing {
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard needsDrawing, !isResizing, let mpvGL = mpvGL else { return }

        guard EAGLContext.setCurrent(context) else { return }

        glGetIntegerv(UInt32(GL_FRAMEBUFFER_BINDING), &defaultFBO)
        guard defaultFBO != 0 else { return }

        var dims: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &dims)

        var data = mpv_opengl_fbo(
            fbo: Int32(defaultFBO),
            w: Int32(dims[2]),
            h: Int32(dims[3]),
            internal_format: 0
        )

        var flip: CInt = 1

        withUnsafeMutablePointer(to: &flip) { flipPtr in
            withUnsafeMutablePointer(to: &data) { dataPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: dataPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPtr),
                    mpv_render_param()
                ]
                mpv_render_context_render(OpaquePointer(mpvGL), &params)
            }
        }
    }

    #if os(tvOS)
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            // Request focus when added to window
            DispatchQueue.main.async {
                self.setNeedsFocusUpdate()
                self.updateFocusIfNeeded()
            }
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .playPause:
                onPlayPause?()
                return
            case .leftArrow:
                onSeekBackward?()
                return
            case .rightArrow:
                onSeekForward?()
                return
            case .select:
                onSelect?()
                return
            case .menu:
                onMenu?()
                return
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }
    #endif

    override func layoutSubviews() {
        super.layoutSubviews()
        // During orientation animation, layoutSubviews fires on every frame.
        // Skip MPV renders during the resize — the last rendered frame scales
        // naturally via UIKit's animation. Re-render once the size settles.
        resizeDebouncer?.cancel()
        isResizing = true
        let work = DispatchWorkItem { [weak self] in
            self?.isResizing = false
            self?.needsDrawing = true
        }
        resizeDebouncer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func setup(errorBinding: Binding<String?>?) {
        player = MPVPlayerCore()
        guard let success = player?.setup(errorBinding: errorBinding), success else {
            return
        }
        player?.createRenderContext(view: self)
        player?.onPositionUpdate = { [weak self] position, duration in
            self?.onPositionUpdate?(position, duration)
        }
        player?.onPlaybackEnded = { [weak self] in
            self?.onPlaybackEnded?()
        }
        player?.onVideoInfoUpdate = { [weak self] codec, height, hwdec, audioChannels in
            self?.onVideoInfoUpdate?(codec, height, hwdec, audioChannels)
        }
    }

    func loadURL(_ url: URL) {
        player?.loadURL(url)
    }

    func play() {
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func seek(seconds: Int) {
        player?.seek(seconds: seconds)
    }

    func seekTo(position: Double) {
        player?.seekTo(position: position)
    }

    func startPositionPolling() {
        player?.startPositionPolling()
    }

    func cleanup() {
        // Stop new frames from being queued
        needsDrawing = false
        displayLink?.invalidate()
        displayLink = nil
        // Nil out render context pointer so any in-flight draw() exits early
        mpvGL = nil
        // Wait for any pending render to finish before destroying
        renderQueue.sync {}
        player?.destroy()
        player = nil
        onPositionUpdate = nil
        onPlaybackEnded = nil
        onVideoInfoUpdate = nil
    }
}
#endif

#Preview {
    PlayerView(
        url: URL(string: "https://example.com/video.mp4")!,
        title: "Sample Video"
    )
    .environmentObject(AppState())
    .environmentObject(PVRClient())
}
