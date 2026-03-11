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
import IOKit.pwr_mgt
#else
import UIKit
#if os(iOS)
import AVKit
import AVFoundation
#endif
#endif

private enum PiPFeatureFlags {
    // A/B toggle:
    // false => fullscreen restore uses base stream URL (TS/live source)
    // true  => fullscreen restore uses PiP prepared URL (local HLS proxy)
    static let usePreparedPiPURLForFullscreenRestore = true
    // Enable sample-buffer PiP path for raw TS streams. Falls back to AVPlayer PiP on failure.
    static let useSampleBufferPiPForTS = true
}

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
    @State private var cleanupAction: (() -> Void)?
    @State private var hasResumed = false
    @State private var isPlayerReady = false
    @State private var startTimeOffset: Double = 0
    @State private var videoCodec: String?
    @State private var videoHeight: Int?
    @State private var hwDecoder: String?
    @State private var audioChannelLayout: String?
    #if os(iOS)
    @State private var pipManager = IOSPiPManager.shared
    @State private var sampleBufferPiPManager = IOSSampleBufferPiPManager.shared
    @State private var pipIsSupported = AVPictureInPictureController.isPictureInPictureSupported()
    @State private var pipIsActive = false
    @State private var dismissingForPiP = false
    @State private var restoringFromPiP = false
    @State private var preparedPlaybackURL: URL?
    #endif
    #if DISPATCHERPVR
    @State private var dispatchProfileBadge: String?
    @State private var dispatchProfileRefreshTask: Task<Void, Never>?
    #endif
    #if os(macOS)
    @State private var sleepAssertionID: IOPMAssertionID = 0
    #endif

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
                },
                cleanupAction: $cleanupAction
            )
                .ignoresSafeArea()
            #elseif os(iOS)
            if let preparedPlaybackURL {
                MPVContainerView(
                    url: preparedPlaybackURL,
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
                    },
                    cleanupAction: $cleanupAction
                )
                    .ignoresSafeArea()
                    .onTapGesture {
                        toggleControls()
                    }
            } else {
                Color.black.ignoresSafeArea()
            }
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
            #if os(iOS)
            Task {
                var headers = client.streamAuthHeaders()
                if url.path.contains("/proxy/ts/stream/") || url.path.contains("/proxy/hls/") {
                    headers = [:]
                }
                if let host = url.host?.lowercased(), host == "127.0.0.1" || host == "localhost" {
                    headers = [:]
                }
                let prepared = await PiPSourceAdapter.shared.prepare(url: url, headers: headers)
                await MainActor.run {
                    preparedPlaybackURL = prepared.url
                    appState.currentlyPlayingPiPURL = prepared.url
                    print("PiP: prepared fullscreen playback url=\(prepared.url.absoluteString)")
                }
            }
            pipManager.onStatusChanged = { isSupported, isActive in
                pipIsSupported = isSupported
                pipIsActive = isActive
                print("PiP: status changed supported=\(isSupported) active=\(isActive)")
            }
            sampleBufferPiPManager.onStatusChanged = { isSupported, isActive in
                pipIsSupported = isSupported
                pipIsActive = isActive
                print("PiP(SB): status changed supported=\(isSupported) active=\(isActive)")
            }
            pipManager.refreshSupportState()
            sampleBufferPiPManager.refreshSupportState()
            print("PiP: onAppear support=\(pipIsSupported)")
            #endif
            scheduleHideControls()
            #if os(macOS)
            // Prevent display sleep during video playback
            disableScreenSaver()
            #else
            // Prevent screen from sleeping during video playback
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
            #if DISPATCHERPVR
            startDispatchProfileRefreshLoop()
            #endif
        }
        .onDisappear {
            #if os(iOS)
            if !dismissingForPiP {
                pipManager.stopAndCleanup()
                sampleBufferPiPManager.stopAndCleanup()
                PiPSourceAdapter.shared.release(url: url)
                if let preparedPlaybackURL {
                    PiPSourceAdapter.shared.release(url: preparedPlaybackURL)
                }
            }
            pipManager.onStatusChanged = nil
            sampleBufferPiPManager.onStatusChanged = nil
            preparedPlaybackURL = nil
            #endif
            // Stop mpv immediately — dismantleUIView may be delayed by SwiftUI
            cleanupAction?()
            cleanupAction = nil
            // Only save if not already stopped by an explicit exit path
            if appState.isShowingPlayer {
                savePlaybackPosition()
                appState.stopPlayback()
            }
            // Notify recordings list to refresh with updated progress
            if recordingId != nil {
                NotificationCenter.default.post(name: .recordingsDidChange, object: nil)
            }
            #if os(macOS)
            // Re-enable display sleep
            enableScreenSaver()
            #else
            // Re-enable screen sleeping
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
            #if DISPATCHERPVR
            dispatchProfileRefreshTask?.cancel()
            dispatchProfileRefreshTask = nil
            #endif
            #if os(iOS)
            dismissingForPiP = false
            #endif
        }
        #if DISPATCHERPVR
        .onChange(of: appState.currentlyPlayingChannelName) {
            startDispatchProfileRefreshLoop()
        }
        #endif
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
                #if os(iOS)
                pipManager.stopAndCleanup()
                #endif
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

            Text(headerTitle)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)

            Spacer()

            #if os(iOS)
            if pipIsSupported {
                Button {
                    print("PiP: button tapped")
                    togglePictureInPicture()
                } label: {
                    Image(systemName: pipIsActive ? "pip.exit" : "pip.enter")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .zIndex(20)
                .accessibilityIdentifier("player-pip-button")
            }
            #endif

            videoBadges
                .padding(.trailing, 4)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
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
                badgeText(codecBadgeText(codec), color: codecBadgeColor)
            }
            #if DISPATCHERPVR
            if let profile = dispatchProfileBadge {
                badgeText(profile, color: .white)
            }
            #endif
            if let audio = audioChannelLayout {
                badgeText(audio, color: .white)
            }
        }
    }

    private var headerTitle: String {
        return title
    }

    private var codecBadgeColor: Color {
        if let hw = hwDecoder, !hw.isEmpty, hw != "no" {
            return .green
        }
        return .yellow
    }

    private func codecBadgeText(_ codec: String) -> String {
        let base = formatCodecName(codec)
        guard isUsingMetalRenderer else { return base }
        return "\(base) (M)"
    }

    #if os(iOS)
    private func togglePictureInPicture() {
        print("PiP: toggle requested active=\(pipIsActive) supported=\(pipIsSupported)")
        if pipIsActive {
            print("PiP: stopping active PiP session")
            pipManager.stop()
            sampleBufferPiPManager.stop()
            return
        }
        guard pipIsSupported else {
            print("PiP: unsupported on this device")
            errorMessage = "Picture in Picture is not supported on this device."
            return
        }

        // Live streams should start "now" (no initial seek), AVPlayer is fragile with seek on raw TS/live.
        let startAt = recordingId == nil ? 0 : max(0, currentPosition)
        let baseURL: URL
        if let pipSource = appState.currentlyPlayingPiPURL {
            baseURL = pipSource
        } else if recordingId == nil, let liveSource = appState.currentlyPlayingLiveSourceURL {
            baseURL = liveSource
        } else {
            baseURL = url
        }
        let playbackTitle = title
        let playbackRecordingId = recordingId
        let playbackChannelId = appState.currentlyPlayingChannelId
        let playbackChannelName = appState.currentlyPlayingChannelName
        var authHeaders = (baseURL == url) ? client.streamAuthHeaders() : [:]
        // Dispatcharr proxy stream endpoints are public in your setup; force no auth headers for AVPlayer.
        if baseURL.path.contains("/proxy/ts/stream/") || baseURL.path.contains("/proxy/hls/") {
            authHeaders = [:]
        }
        if let host = baseURL.host?.lowercased(), host == "127.0.0.1" || host == "localhost" {
            authHeaders = [:]
        }

        Task {
            let prepared = await PiPSourceAdapter.shared.prepare(url: baseURL, headers: authHeaders)
            let playbackURL = pipManifestURL(from: prepared.url)
            let playbackHeaders = prepared.headers
            print("PiP: start requested url=\(playbackURL.absoluteString) start=\(String(format: "%.2f", startAt)) recordingId=\(playbackRecordingId.map(String.init) ?? "nil") usingLiveSource=\(recordingId == nil && appState.currentlyPlayingLiveSourceURL != nil)")
            let onStarted = {
                print("PiP: started successfully")
                isPlaying = false
                showControls = false
                dismissingForPiP = true
                appState.stopPlayback()
            }
            let onStopped: (Double) -> Void = { pipPosition in
                print("PiP: stopped position=\(String(format: "%.2f", pipPosition)) dismissingForPiP=\(dismissingForPiP)")
                if restoringFromPiP {
                    print("PiP: preserving local source for fullscreen restore")
                    restoringFromPiP = false
                } else {
                    PiPSourceAdapter.shared.release(url: playbackURL)
                }
                if !dismissingForPiP {
                    seekToPosition(pipPosition)
                    isPlaying = true
                    scheduleHideControls()
                }
                dismissingForPiP = false
            }
            let onRestoreRequested: (Double) -> Bool = { pipPosition in
                print("PiP: restore requested position=\(String(format: "%.2f", pipPosition))")
                restoringFromPiP = true
                dismissingForPiP = false
                let resume = pipPosition > 0 ? Int(pipPosition) : nil
                let restorePreparedURL = mpvManifestURL(from: playbackURL)
                let restoreURL = PiPFeatureFlags.usePreparedPiPURLForFullscreenRestore ? restorePreparedURL : baseURL
                let restoreMode = PiPFeatureFlags.usePreparedPiPURLForFullscreenRestore ? "prepared-pip-url" : "base-stream-url"
                print("PiP: restore mode=\(restoreMode) url=\(restoreURL.absoluteString)")
                appState.playStream(
                    url: restoreURL,
                    title: playbackTitle,
                    recordingId: playbackRecordingId,
                    resumePosition: resume,
                    channelId: playbackChannelId,
                    channelName: playbackChannelName
                )
                return true
            }
            let startWithAVPlayerPiP = {
                pipManager.start(
                    url: playbackURL,
                    startPosition: startAt,
                    headers: playbackHeaders,
                    onStarted: onStarted,
                    onStopped: onStopped,
                    onRestoreRequested: onRestoreRequested,
                    onFailed: { reason in
                        print("PiP: failed reason=\(reason)")
                        PiPSourceAdapter.shared.release(url: playbackURL)
                        restoringFromPiP = false
                        errorMessage = reason
                        dismissingForPiP = false
                    }
                )
            }

            let shouldUseSampleBuffer = PiPFeatureFlags.useSampleBufferPiPForTS &&
                (baseURL.path.contains("/proxy/ts/stream/") || playbackURL.path.contains("/proxy/ts/stream/"))
            if shouldUseSampleBuffer {
                sampleBufferPiPManager.start(
                    url: playbackURL,
                    startPosition: startAt,
                    headers: playbackHeaders,
                    onStarted: onStarted,
                    onStopped: onStopped,
                    onRestoreRequested: onRestoreRequested,
                    onFailed: { reason in
                        print("PiP(SB): failed reason=\(reason), fallback=AVPlayer")
                        startWithAVPlayerPiP()
                    }
                )
            } else {
                startWithAVPlayerPiP()
            }
        }
    }
    #endif

    private func pipManifestURL(from url: URL) -> URL {
        guard url.path.hasSuffix("/index.m3u8") else { return url }
        return url.deletingLastPathComponent().appendingPathComponent("pip.m3u8")
    }

    private func mpvManifestURL(from url: URL) -> URL {
        guard url.path.hasSuffix("/pip.m3u8") else { return url }
        return url.deletingLastPathComponent().appendingPathComponent("index.m3u8")
    }

    #if DISPATCHERPVR
    private var canQueryDispatchProxyStatus: Bool {
        // Streamer/output-only users don't have access to /proxy/ts/status.
        appState.userLevel >= 1 && !client.useOutputEndpoints
    }

    private func startDispatchProfileRefreshLoop() {
        dispatchProfileRefreshTask?.cancel()
        guard canQueryDispatchProxyStatus else {
            dispatchProfileBadge = nil
            dispatchProfileRefreshTask = nil
            return
        }
        dispatchProfileRefreshTask = Task {
            await refreshDispatchProfileBadge()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                await refreshDispatchProfileBadge()
            }
        }
    }

    private func refreshDispatchProfileBadge() async {
        guard canQueryDispatchProxyStatus else {
            dispatchProfileBadge = nil
            return
        }
        // Stream status can lag behind player start, so retry briefly.
        dispatchProfileBadge = nil
        for attempt in 0..<5 {
            if let profile = await loadDispatchProfileBadge() {
                dispatchProfileBadge = profile
                return
            }
            if attempt < 4 {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func loadDispatchProfileBadge() async -> String? {
        do {
            let status = try await client.getProxyStatus()
            guard let channels = status.channels, !channels.isEmpty else { return nil }

            // Prefer active channels only when available.
            let activeChannels = channels.filter { $0.state.lowercased() == "active" }
            let candidates = activeChannels.isEmpty ? channels : activeChannels

            let names = [
                appState.currentlyPlayingChannelName,
                appState.currentlyPlayingTitle,
                title
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

            if let matched = candidates.first(where: { channel in
                names.contains(where: { matchesStreamName(channel.streamName, $0) })
            }) {
                return shortDispatchProfileName(from: matched.m3uProfileName)
            }

            // If only one active stream exists, use its profile as a fallback.
            if candidates.count == 1 {
                return shortDispatchProfileName(from: candidates[0].m3uProfileName)
            }
        } catch {
            return nil
        }
        return nil
    }

    private func matchesStreamName(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalizedStreamName(lhs)
        let b = normalizedStreamName(rhs)
        if a.isEmpty || b.isEmpty { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    private func normalizedStreamName(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "default", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private func shortDispatchProfileName(from profile: String?) -> String? {
        guard let profile else { return nil }
        let shortProfile = profile
            .replacingOccurrences(of: "Default", with: "")
            .trimmingCharacters(in: .whitespaces)
        return shortProfile.isEmpty ? nil : shortProfile
    }
    #endif

    private var isUsingMetalRenderer: Bool {
        #if os(tvOS)
        return UserPreferences.load().tvosGPUAPI == .metal
        #elseif os(iOS)
        return UserPreferences.load().iosGPUAPI == .metal
        #elseif os(macOS)
        return UserPreferences.load().macosGPUAPI == .metal
        #else
        return false
        #endif
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

    #if os(macOS)
    private func disableScreenSaver() {
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "NexusPVR video playback" as CFString,
            &sleepAssertionID
        )
        if result != kIOReturnSuccess {
            print("Failed to disable screen saver: \(result)")
        }
    }

    private func enableScreenSaver() {
        if sleepAssertionID != 0 {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = 0
        }
    }
    #endif

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

#if os(iOS)
private final class IOSPiPHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        guard let layer = self.layer as? AVPlayerLayer else {
            fatalError("Expected AVPlayerLayer")
        }
        return layer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspect
    }
}

@MainActor
private final class IOSSampleBufferPiPHostView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        guard let layer = self.layer as? AVSampleBufferDisplayLayer else {
            fatalError("Expected AVSampleBufferDisplayLayer")
        }
        return layer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        isUserInteractionEnabled = false
        displayLayer.videoGravity = .resizeAspect
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let timebase {
            displayLayer.controlTimebase = timebase
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 1.0)
        }
    }
}

@MainActor
private final class TSFFmpegPiPItem {
    enum PlaybackError: LocalizedError {
        case bootstrapNotImplemented

        var errorDescription: String? {
            switch self {
            case .bootstrapNotImplemented:
                return "Sample-buffer TS pipeline bootstrap complete, FFmpeg decode path not wired yet."
            }
        }
    }

    var currentPosition: Double { 0 }
    var isPaused: Bool { false }

    func start(
        url: URL,
        headers: [String: String],
        startPosition: Double,
        onSampleBuffer: @escaping @MainActor (CMSampleBuffer) -> Void,
        onFailed: @escaping @MainActor (Error) -> Void
    ) {
        _ = url
        _ = headers
        _ = startPosition
        _ = onSampleBuffer
        Task { @MainActor in
            onFailed(PlaybackError.bootstrapNotImplemented)
        }
    }

    func stop() {}
    func setPlaying(_ isPlaying: Bool) { _ = isPlaying }
    func skip(by seconds: Double) { _ = seconds }
}

@available(iOS 15.0, *)
@MainActor
private final class IOSSampleBufferPiPManager: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    static let shared = IOSSampleBufferPiPManager()

    private(set) var isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    private(set) var isActive = false
    var onStatusChanged: ((Bool, Bool) -> Void)?

    private weak var hostView: IOSSampleBufferPiPHostView?
    private var pipController: AVPictureInPictureController?
    private var pipItem: TSFFmpegPiPItem?
    private var onStarted: (() -> Void)?
    private var onStopped: ((Double) -> Void)?
    private var onRestoreRequested: ((Double) -> Bool)?
    private var onFailed: ((String) -> Void)?

    func refreshSupportState() {
        isSupported = AVPictureInPictureController.isPictureInPictureSupported()
        notifyState()
    }

    private func notifyState() {
        let supported = isSupported
        let active = isActive
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?(supported, active)
        }
    }

    private func ensureHostView() -> IOSSampleBufferPiPHostView? {
        if let hostView { return hostView }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else {
            return nil
        }
        let host = IOSSampleBufferPiPHostView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        host.alpha = 0.01
        host.isHidden = false
        window.addSubview(host)
        self.hostView = host
        return host
    }

    func start(
        url: URL,
        startPosition: Double,
        headers: [String: String],
        onStarted: @escaping () -> Void,
        onStopped: @escaping (Double) -> Void,
        onRestoreRequested: @escaping (Double) -> Bool,
        onFailed: @escaping (String) -> Void
    ) {
        guard isSupported else {
            onFailed("Picture in Picture is not supported on this device.")
            return
        }
        guard let hostView = ensureHostView() else {
            onFailed("Picture in Picture sample-buffer host is not ready.")
            return
        }
        guard !isActive else { return }
        print("PiP(SB): manager start accepted url=\(url.absoluteString) start=\(String(format: "%.2f", startPosition))")

        self.onStarted = onStarted
        self.onStopped = onStopped
        self.onRestoreRequested = onRestoreRequested
        self.onFailed = onFailed

        let item = TSFFmpegPiPItem()
        pipItem = item

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: hostView.displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.requiresLinearPlayback = true
        pipController = controller

        item.start(
            url: url,
            headers: headers,
            startPosition: startPosition,
            onSampleBuffer: { [weak self] sampleBuffer in
                guard let self else { return }
                let layer = hostView.displayLayer
                if layer.isReadyForMoreMediaData {
                    layer.enqueue(sampleBuffer)
                } else {
                    layer.enqueue(sampleBuffer)
                }
            },
            onFailed: { [weak self] error in
                guard let self else { return }
                self.onFailed?(error.localizedDescription)
                self.cleanup()
            }
        )
    }

    func stop() {
        pipController?.stopPictureInPicture()
    }

    func stopAndCleanup() {
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
        cleanup()
        isActive = false
        notifyState()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
        notifyState()
        print("PiP(SB): delegate didStartPictureInPicture")
        onStarted?()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isActive = false
        notifyState()
        let nsError = error as NSError
        print("PiP(SB): delegate failedToStart domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)")
        onFailed?("PiP failed: \(nsError.localizedDescription) [\(nsError.domain):\(nsError.code)]")
        cleanup()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = false
        notifyState()
        let pos = pipItem?.currentPosition ?? 0
        let safePos = pos.isFinite && pos > 0 ? pos : 0
        print("PiP(SB): delegate didStopPictureInPicture pos=\(String(format: "%.2f", safePos))")
        onStopped?(safePos)
        cleanup()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        let pos = pipItem?.currentPosition ?? 0
        let safePos = pos.isFinite && pos > 0 ? pos : 0
        print("PiP(SB): delegate restoreUI requested pos=\(String(format: "%.2f", safePos))")
        let restored = onRestoreRequested?(safePos) ?? false
        completionHandler(restored)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        pipItem?.setPlaying(playing)
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        pipItem?.isPaused ?? true
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime
    ) async {
        pipItem?.skip(by: skipInterval.seconds)
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    private func cleanup() {
        print("PiP(SB): cleanup")
        pipController?.delegate = nil
        pipController = nil
        pipItem?.stop()
        pipItem = nil
        hostView?.displayLayer.flush()
        hostView?.removeFromSuperview()
        hostView = nil
        onStarted = nil
        onStopped = nil
        onRestoreRequested = nil
        onFailed = nil
    }
}

@MainActor
private final class IOSPiPManager: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = IOSPiPManager()

    private(set) var isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    private(set) var isActive = false
    var onStatusChanged: ((Bool, Bool) -> Void)?

    private weak var hostView: IOSPiPHostView?
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var pipController: AVPictureInPictureController?
    private var itemStatusObserver: NSKeyValueObservation?
    private var itemLikelyToKeepUpObserver: NSKeyValueObservation?
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var playbackStalledObserver: NSObjectProtocol?
    private var onStarted: (() -> Void)?
    private var onStopped: ((Double) -> Void)?
    private var onRestoreRequested: ((Double) -> Bool)?
    private var onFailed: ((String) -> Void)?
    private var pendingStartPosition: Double = 0
    private var lastPiPResumeAttemptAt: Date?
    private var waitingForStallRecovery = false

    func refreshSupportState() {
        isSupported = AVPictureInPictureController.isPictureInPictureSupported()
        notifyState()
    }

    private func notifyState() {
        let supported = isSupported
        let active = isActive
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?(supported, active)
        }
    }

    private func ensureHostView() -> IOSPiPHostView? {
        if let hostView { return hostView }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else {
            return nil
        }
        let host = IOSPiPHostView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        host.alpha = 0.01
        host.isHidden = false
        window.addSubview(host)
        self.hostView = host
        return host
    }

    func start(
        url: URL,
        startPosition: Double,
        headers: [String: String],
        onStarted: @escaping () -> Void,
        onStopped: @escaping (Double) -> Void,
        onRestoreRequested: @escaping (Double) -> Bool,
        onFailed: @escaping (String) -> Void
    ) {
        guard isSupported else {
            print("PiP: manager start rejected (unsupported)")
            onFailed("Picture in Picture is not supported on this device.")
            return
        }
        guard let hostView = ensureHostView() else {
            print("PiP: manager start rejected (host view unavailable)")
            onFailed("Picture in Picture is not ready yet.")
            return
        }
        guard !isActive else { return }
        print("PiP: manager start accepted url=\(url.absoluteString) start=\(String(format: "%.2f", startPosition))")

        self.onStarted = onStarted
        self.onStopped = onStopped
        self.onRestoreRequested = onRestoreRequested
        self.onFailed = onFailed
        let sourceIsLocalHLS = url.path.contains("/hls/")

        print("PiP: AVURLAsset headers=\(Array(headers.keys).sorted())")
        let item = makePlayerItem(url: url, headers: headers, isLocalHLS: sourceIsLocalHLS)
        playerItem = item
        let player = AVPlayer(playerItem: item)
        let isLocalHLS = sourceIsLocalHLS
        // Let AVPlayer handle rebuffering for live HLS instead of manual play() loops.
        player.automaticallyWaitsToMinimizeStalling = true
        if isLocalHLS {
            item.preferredForwardBufferDuration = 90
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            print("PiP: AVPlayer configured for local HLS buffering (stability)")
        }
        hostView.playerLayer.player = player
        self.player = player
        pendingStartPosition = max(0, startPosition)

        if pipController == nil {
            pipController = AVPictureInPictureController(playerLayer: hostView.playerLayer)
            pipController?.delegate = self
            pipController?.canStartPictureInPictureAutomaticallyFromInline = false
            pipController?.requiresLinearPlayback = true
        }

        Task { [weak self] in
            guard self != nil else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }

        observeItemAndStartPiPWhenReady()
    }

    func stop() {
        print("PiP: manager stop requested")
        pipController?.stopPictureInPicture()
    }

    func stopAndCleanup() {
        print("PiP: manager stopAndCleanup requested active=\(pipController?.isPictureInPictureActive == true)")
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
        cleanup()
        isActive = false
        notifyState()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
        notifyState()
        print("PiP: delegate didStartPictureInPicture")
        onStarted?()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isActive = false
        notifyState()
        let nsError = error as NSError
        print("PiP: delegate failedToStart domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)")
        onFailed?("PiP failed: \(nsError.localizedDescription) [\(nsError.domain):\(nsError.code)]")
        cleanup()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = false
        notifyState()
        let pos = player?.currentTime().seconds ?? 0
        let safePos = pos.isFinite && pos > 0 ? pos : 0
        print("PiP: delegate didStopPictureInPicture pos=\(String(format: "%.2f", safePos))")
        onStopped?(safePos)
        cleanup()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        let pos = player?.currentTime().seconds ?? 0
        let safePos = pos.isFinite && pos > 0 ? pos : 0
        print("PiP: delegate restoreUI requested pos=\(String(format: "%.2f", safePos))")
        let restored = onRestoreRequested?(safePos) ?? false
        print("PiP: delegate restoreUI completion restored=\(restored)")
        completionHandler(restored)
    }

    private func cleanup() {
        print("PiP: cleanup")
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        itemLikelyToKeepUpObserver?.invalidate()
        itemLikelyToKeepUpObserver = nil
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
            self.playbackStalledObserver = nil
        }
        pipController?.delegate = nil
        pipController = nil
        player?.pause()
        player = nil
        playerItem = nil
        hostView?.playerLayer.player = nil
        hostView?.removeFromSuperview()
        hostView = nil
        onStarted = nil
        onStopped = nil
        onRestoreRequested = nil
        onFailed = nil
        lastPiPResumeAttemptAt = nil
        waitingForStallRecovery = false
    }

    private func makePlayerItem(url: URL, headers: [String: String], isLocalHLS: Bool) -> AVPlayerItem {
        let item: AVPlayerItem
        if headers.isEmpty {
            item = AVPlayerItem(url: url)
        } else {
            let assetOptions: [String: Any] = [
                "AVURLAssetHTTPHeaderFieldsKey": headers
            ]
            let asset = AVURLAsset(url: url, options: assetOptions)
            item = AVPlayerItem(asset: asset)
        }
        if isLocalHLS {
            item.preferredForwardBufferDuration = 30
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            if #available(iOS 15.0, *) {
                item.automaticallyPreservesTimeOffsetFromLive = true
            }
        }
        return item
    }

    private func observeItemAndStartPiPWhenReady() {
        guard let item = playerItem, let player else {
            print("PiP: observe start failed (missing AVPlayer item)")
            onFailed?("PiP failed: missing AVPlayer item.")
            return
        }
        itemStatusObserver?.invalidate()
        itemLikelyToKeepUpObserver?.invalidate()
        timeControlStatusObserver?.invalidate()
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
            self.playbackStalledObserver = nil
        }
        itemStatusObserver = item.observe(\AVPlayerItem.status, options: NSKeyValueObservingOptions([.initial, .new])) { [weak self] observed, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                switch observed.status {
                case .readyToPlay:
                    print("PiP: AVPlayerItem readyToPlay")
                    self.itemStatusObserver?.invalidate()
                    self.itemStatusObserver = nil
                    let start = self.pendingStartPosition
                    self.pendingStartPosition = 0
                    if start > 0 {
                        let time = CMTime(seconds: start, preferredTimescale: 600)
                        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                            player.play()
                            self.pipController?.startPictureInPicture()
                        }
                    } else {
                        player.play()
                        self.pipController?.startPictureInPicture()
                    }
                case .failed:
                    let err = observed.error?.localizedDescription ?? "unknown AVPlayer error"
                    let nserr = observed.error as NSError?
                    if let nserr {
                        print("PiP: AVPlayerItem failed domain=\(nserr.domain) code=\(nserr.code) desc=\(nserr.localizedDescription)")
                        if let underlying = nserr.userInfo[NSUnderlyingErrorKey] as? NSError {
                            print("PiP: AVPlayerItem underlying domain=\(underlying.domain) code=\(underlying.code) desc=\(underlying.localizedDescription)")
                        }
                        if !nserr.userInfo.isEmpty {
                            print("PiP: AVPlayerItem userInfo=\(nserr.userInfo)")
                        }
                    } else {
                        print("PiP: AVPlayerItem failed desc=\(err)")
                    }
                    if let events = observed.errorLog()?.events, !events.isEmpty {
                        for event in events.suffix(3) {
                            print("PiP: AVPlayerItem errorLog status=\(event.errorStatusCode) domain=\(event.errorDomain) comment=\(event.errorComment ?? "<nil>") uri=\(event.uri ?? "<nil>")")
                        }
                    }
                    self.onFailed?("PiP failed: \(err)")
                    self.cleanup()
                case .unknown:
                    print("PiP: AVPlayerItem status unknown")
                    break
                @unknown default:
                    print("PiP: AVPlayerItem status @unknown")
                    break
                }
            }
        }

        itemLikelyToKeepUpObserver = item.observe(\AVPlayerItem.isPlaybackLikelyToKeepUp, options: [.new]) { _, change in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let keepUp = change.newValue ?? false
                print("PiP: AVPlayerItem likelyToKeepUp=\(keepUp)")
                guard keepUp else { return }
                guard let player = self.player else { return }
                guard player.timeControlStatus != .playing else { return }
                let now = Date()
                if let last = self.lastPiPResumeAttemptAt, now.timeIntervalSince(last) < 3 {
                    return
                }
                self.lastPiPResumeAttemptAt = now
                if self.waitingForStallRecovery {
                    self.waitingForStallRecovery = false
                    // For live HLS, jumping to "end" avoids resuming several seconds behind after a stall.
                    print("PiP: stall recovery seeking to live edge")
                    player.seek(to: .positiveInfinity, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                        player.play()
                    }
                } else {
                    print("PiP: resume attempt after likelyToKeepUp=true")
                    player.play()
                }
            }
        }

        timeControlStatusObserver = player.observe(\AVPlayer.timeControlStatus, options: [.initial, .new]) { player, _ in
            DispatchQueue.main.async {
                let reason = player.reasonForWaitingToPlay?.rawValue ?? "<none>"
                print("PiP: AVPlayer timeControlStatus=\(player.timeControlStatus.rawValue) reason=\(reason)")
            }
        }

        playbackStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            print("PiP: AVPlayerItemPlaybackStalled received")
            Task { @MainActor in
                self.waitingForStallRecovery = true
            }
            // Let AVPlayer recover according to automaticallyWaitsToMinimizeStalling.
            // Forced play() here tends to create churn during transient live stalls.
        }
    }
}
#endif

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

        // Tell mpv to quit gracefully — this shuts down the VO thread, audio, etc.
        // Critical for vo=gpu+wid where mpv owns the render loop.
        if let mpv = mpv {
            mpv_command_string(mpv, "quit")
        }

        // Wait for the event loop thread to finish (it exits on MPV_EVENT_SHUTDOWN)
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
        let gpuAPI = UserPreferences.load().macosGPUAPI
        mpv_set_option_string(mpv, "vo", "gpu")
        if gpuAPI == .metal {
            mpv_set_option_string(mpv, "gpu-api", "metal")
            mpv_set_option_string(mpv, "gpu-context", "metal")
            print("MPV: macOS GPU API = Metal")
        } else {
            mpv_set_option_string(mpv, "gpu-api", "opengl")
            print("MPV: macOS GPU API = OpenGL")
        }
        #elseif os(tvOS)
        let gpuAPI = UserPreferences.load().tvosGPUAPI
        if gpuAPI == .metal {
            mpv_set_option_string(mpv, "vo", "gpu")
            mpv_set_option_string(mpv, "gpu-api", "metal")
            mpv_set_option_string(mpv, "gpu-context", "metal")
            print("MPV: tvOS GPU API = Metal")
        } else {
            mpv_set_option_string(mpv, "vo", "libmpv")
            mpv_set_option_string(mpv, "gpu-api", "opengl")
            mpv_set_option_string(mpv, "opengl-es", "yes")
            print("MPV: tvOS GPU API = OpenGL")
        }
        #elseif os(iOS)
        let gpuAPI = UserPreferences.load().iosGPUAPI
        if gpuAPI == .metal {
            mpv_set_option_string(mpv, "vo", "gpu")
            mpv_set_option_string(mpv, "gpu-api", "metal")
            mpv_set_option_string(mpv, "gpu-context", "metal")
            print("MPV: iOS GPU API = Metal")
        } else {
            mpv_set_option_string(mpv, "vo", "libmpv")
            mpv_set_option_string(mpv, "gpu-api", "opengl")
            mpv_set_option_string(mpv, "opengl-es", "yes")
            print("MPV: iOS GPU API = OpenGL")
        }
        #else
        mpv_set_option_string(mpv, "vo", "libmpv")
        mpv_set_option_string(mpv, "gpu-api", "opengl")
        mpv_set_option_string(mpv, "opengl-es", "yes")
        #endif

        // Keep video letterboxed to source aspect ratio across view size changes.
        mpv_set_option_string(mpv, "keepaspect", "yes")

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
        let isLocalProxyHLS = (url.host == "127.0.0.1" || url.host == "localhost") && url.path.contains("/hls/")

        // Fix TS timing issues (genpts regenerates PTS, igndts ignores broken DTS)
        if url.pathExtension.lowercased() == "ts" {
            mpv_set_property_string(mpv, "demuxer-lavf-o", "fflags=+genpts+igndts")
        } else {
            mpv_set_property_string(mpv, "demuxer-lavf-o", "")
        }

        if isLocalProxyHLS {
            // Local HLS in fullscreen prioritizes smoothness over absolute lowest latency.
            mpv_set_property_string(mpv, "cache-secs", "45")
            mpv_set_property_string(mpv, "cache-pause", "yes")
            mpv_set_property_string(mpv, "cache-pause-wait", "2.5")
            mpv_set_property_string(mpv, "demuxer-readahead-secs", "25")
            mpv_set_property_string(mpv, "demuxer-seekable-cache", "yes")
            mpv_set_property_string(mpv, "demuxer-max-bytes", "128MiB")
            mpv_set_property_string(mpv, "demuxer-max-back-bytes", "64MiB")
            print("MPV: using local HLS smooth playback profile")
        } else {
            // Restore default profile for non-local-HLS sources.
            mpv_set_property_string(mpv, "cache-secs", "120")
            mpv_set_property_string(mpv, "cache-pause", "yes")
            mpv_set_property_string(mpv, "cache-pause-wait", "5")
            mpv_set_property_string(mpv, "demuxer-readahead-secs", "60")
            mpv_set_property_string(mpv, "demuxer-seekable-cache", "yes")
            mpv_set_property_string(mpv, "demuxer-max-bytes", "150MiB")
            mpv_set_property_string(mpv, "demuxer-max-back-bytes", "150MiB")
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

    #if os(macOS) || os(tvOS) || os(iOS)
    func setWindowID(_ layer: CAMetalLayer) {
        guard let mpv = mpv else { return }

        // Cast the layer pointer to Int64 for mpv's wid option
        let wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        var widValue = wid

        // wid can change at runtime on rotation/resize; use property update.
        let result = mpv_set_property(mpv, "wid", MPV_FORMAT_INT64, &widValue)
        if result < 0 {
            let errorStr = String(cString: mpv_error_string(result))
            print("MPV: Failed to set wid: \(errorStr)")
        } else {
            print("MPV: Successfully set window ID")
        }
    }
    #endif

    #if os(iOS) || os(tvOS)
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

#elseif os(tvOS)
// tvOS implementation — runtime-selected renderer (Metal/OpenGL)
struct MPVContainerView: UIViewRepresentable {
    typealias UIViewType = UIView

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
    var onTogglePlayPause: (() -> Void)?
    var onToggleControls: (() -> Void)?
    var onShowControls: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onVideoInfoUpdate: ((String?, Int?, String?, String?) -> Void)?
    @Binding var cleanupAction: (() -> Void)?

    private func configureCommonCallbacks(for view: MPVPlayerMetalView) {
        view.onPositionUpdate = { position, dur in
            DispatchQueue.main.async {
                self.currentPosition = position
                self.duration = dur
            }
        }
        view.onPlaybackEnded = onPlaybackEnded
        view.onVideoInfoUpdate = onVideoInfoUpdate
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
    }

    private func configureCommonCallbacks(for view: MPVPlayerGLView) {
        view.onPositionUpdate = { position, dur in
            DispatchQueue.main.async {
                self.currentPosition = position
                self.duration = dur
            }
        }
        view.onPlaybackEnded = onPlaybackEnded
        view.onVideoInfoUpdate = onVideoInfoUpdate
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
    }

    private func setupSeekBindings(for view: MPVPlayerMetalView) {
        DispatchQueue.main.async {
            self.seekForward = {
                view.seek(seconds: self.seekForwardTime)
                self.onShowControls?()
            }
            self.seekBackward = {
                view.seek(seconds: -self.seekBackwardTime)
                self.onShowControls?()
            }
            self.seekToPosition = { position in
                view.seekTo(position: position)
            }
        }
    }

    private func setupSeekBindings(for view: MPVPlayerGLView) {
        DispatchQueue.main.async {
            self.seekForward = {
                view.seek(seconds: self.seekForwardTime)
                self.onShowControls?()
            }
            self.seekBackward = {
                view.seek(seconds: -self.seekBackwardTime)
                self.onShowControls?()
            }
            self.seekToPosition = { position in
                view.seekTo(position: position)
            }
        }
    }

    func makeUIView(context: Context) -> UIView {
        if UserPreferences.load().tvosGPUAPI == .opengl {
            let view = MPVPlayerGLView(frame: .zero)
            view.setup(errorBinding: $errorMessage)
            configureCommonCallbacks(for: view)
            view.loadURL(url)
            view.startPositionPolling()
            context.coordinator.playerView = view
            DispatchQueue.main.async {
                self.cleanupAction = { view.cleanup() }
            }
            setupSeekBindings(for: view)
            return view
        }

        let view = MPVPlayerMetalView(frame: .zero)
        view.setup(errorBinding: $errorMessage)
        configureCommonCallbacks(for: view)
        view.loadURL(url)
        view.startPositionPolling()
        context.coordinator.playerView = view
        DispatchQueue.main.async {
            self.cleanupAction = { view.cleanup() }
        }
        setupSeekBindings(for: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let metalView = uiView as? MPVPlayerMetalView {
            if isPlaying {
                metalView.play()
            } else {
                metalView.pause()
            }
            return
        }
        if let glView = uiView as? MPVPlayerGLView {
            if isPlaying {
                glView.play()
            } else {
                glView.pause()
            }
            return
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let metalView = uiView as? MPVPlayerMetalView {
            metalView.cleanup()
        } else {
            (uiView as? MPVPlayerGLView)?.cleanup()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var playerView: UIView?
    }
}

#else
// iOS implementation — runtime-selected renderer (OpenGL/Metal)
struct MPVContainerView: UIViewRepresentable {
    typealias UIViewType = UIView

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
    @Binding var cleanupAction: (() -> Void)?

    private func configureCommonCallbacks(for view: MPVPlayerGLView) {
        view.setup(errorBinding: $errorMessage)
        view.onPositionUpdate = { position, dur in
            DispatchQueue.main.async {
                self.currentPosition = position
                self.duration = dur
            }
        }
        view.onPlaybackEnded = onPlaybackEnded
        view.onVideoInfoUpdate = onVideoInfoUpdate
    }

    private func configureCommonCallbacks(for view: MPVPlayerMetalView) {
        view.setup(errorBinding: $errorMessage)
        view.onPositionUpdate = { position, dur in
            DispatchQueue.main.async {
                self.currentPosition = position
                self.duration = dur
            }
        }
        view.onPlaybackEnded = onPlaybackEnded
        view.onVideoInfoUpdate = onVideoInfoUpdate
    }

    private func setupSeekBindings(for view: MPVPlayerGLView) {
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
    }

    private func setupSeekBindings(for view: MPVPlayerMetalView) {
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
    }

    func makeUIView(context: Context) -> UIView {
        if UserPreferences.load().iosGPUAPI == .metal {
            let view = MPVPlayerMetalView(frame: .zero)
            configureCommonCallbacks(for: view)
            view.loadURL(url)
            view.startPositionPolling()
            context.coordinator.playerView = view
            DispatchQueue.main.async {
                self.cleanupAction = { view.cleanup() }
            }
            setupSeekBindings(for: view)
            return view
        }

        let view = MPVPlayerGLView(frame: .zero)
        configureCommonCallbacks(for: view)
        view.loadURL(url)
        view.startPositionPolling()
        context.coordinator.playerView = view
        DispatchQueue.main.async {
            self.cleanupAction = { view.cleanup() }
        }

        setupSeekBindings(for: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let metalView = uiView as? MPVPlayerMetalView {
            if isPlaying {
                metalView.play()
            } else {
                metalView.pause()
            }
            return
        }
        if let glView = uiView as? MPVPlayerGLView {
            if isPlaying {
                glView.play()
            } else {
                glView.pause()
            }
            return
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let metalView = uiView as? MPVPlayerMetalView {
            metalView.cleanup()
        } else {
            (uiView as? MPVPlayerGLView)?.cleanup()
        }
    }

    class Coordinator {
        var playerView: UIView?
    }
}
#endif

// MARK: - iOS/tvOS Metal View

#if os(iOS) || os(tvOS)
class MPVPlayerMetalView: UIView {
    private var player: MPVPlayerCore?
    private var metalLayer: CAMetalLayer?
    var onPositionUpdate: ((Double, Double) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onVideoInfoUpdate: ((String?, Int?, String?, String?) -> Void)?

    #if os(tvOS)
    // tvOS remote control callbacks
    var onPlayPause: (() -> Void)?
    var onSeekForward: (() -> Void)?
    var onSeekBackward: (() -> Void)?
    var onSelect: (() -> Void)?
    var onMenu: (() -> Void)?
    #endif

    override class var layerClass: AnyClass { CAMetalLayer.self }

    #if os(tvOS)
    override var canBecomeFocused: Bool { true }
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        metalLayer = layer as? CAMetalLayer
        metalLayer?.backgroundColor = UIColor.black.cgColor
        metalLayer?.pixelFormat = .bgra8Unorm
        isOpaque = true
        clipsToBounds = true
        backgroundColor = .black
        isUserInteractionEnabled = true
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        updateDrawableSize()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer?.frame = bounds
        updateDrawableSize()
        #if os(iOS)
        if let metalLayer = metalLayer {
            player?.setWindowID(metalLayer)
        }
        #endif
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let metalLayer else { return }
        #if os(iOS)
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        #else
        let scale = UIScreen.main.scale
        #endif
        metalLayer.contentsScale = scale

        let drawableWidth = max(bounds.width * scale, 1)
        let drawableHeight = max(bounds.height * scale, 1)
        let drawableSize = CGSize(width: drawableWidth, height: drawableHeight)
        if metalLayer.drawableSize != drawableSize {
            metalLayer.drawableSize = drawableSize
        }
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

    #if os(tvOS)
    // MARK: - tvOS Remote Control
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
}
#endif

// MARK: - iOS/tvOS OpenGL ES View

#if os(iOS) || os(tvOS)
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

    #if os(tvOS)
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
