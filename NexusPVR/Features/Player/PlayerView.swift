//
//  PlayerView.swift
//  nextpvr-apple-client
//
//  Video player view using MPV for MPEG-TS support
//

import SwiftUI
import Libmpv
import MPVPixelBufferBridge
import AVFoundation
import AVKit
#if !os(macOS)
import GLKit
import OpenGLES
#endif
#if os(macOS)
import AppKit
import IOKit.pwr_mgt
import OpenGL.GL
import OpenGL.GL3
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
    let isRecordingInProgress: Bool

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
    @State private var droppedFrames: Int64 = 0
    @State private var videoGamma: String?
    @State private var showSettingsPanel = false
    @State private var settingsTab: StreamSettingsTab = .video
    @State private var trackList: [MPVTrack] = []
    @State private var getTrackListFunc: (() -> [MPVTrack])?
    @State private var setAudioTrackFunc: ((Int) -> Void)?
    @State private var setSubtitleTrackFunc: ((Int?) -> Void)?
    @State private var getSubtitleTextFunc: (() -> String?)?
    @State private var currentSubtitleText: String?
    #if os(tvOS)
    @State private var tvFocusedTrackIndex: Int = -1  // -1 = tabs focused, 0+ = track list index
    #endif
    @State private var isBuffering = false
    @State private var lastBufferingCheckPosition: Double = -1
    @State private var bufferingStallCount = 0
    #if DISPATCHERPVR
    @State private var dispatchProfileBadge: String?
    @State private var dispatchProfileRefreshTask: Task<Void, Never>?
    #endif
    #if os(tvOS)
    @State private var hasSetDisplayCriteria = false
    #endif
    #if os(iOS)
    @State private var pipIsSupported = AVPictureInPictureController.isPictureInPictureSupported()
    @State private var pipIsActive = false
    #endif
    #if !os(macOS)
    @State private var pixelBufferView: MPVPlayerPixelBufferView? = nil
    #endif
    #if os(macOS)
    @State private var sleepAssertionID: IOPMAssertionID = 0
    #endif

    init(url: URL, title: String, recordingId: Int? = nil, resumePosition: Int? = nil, isRecordingInProgress: Bool = false) {
        self.url = url
        self.title = title
        self.recordingId = recordingId
        self.resumePosition = resumePosition
        self.isRecordingInProgress = isRecordingInProgress
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
                isRecordingInProgress: isRecordingInProgress,
                onPlaybackEnded: {
                    savePlaybackPosition()
                    markAsWatched()
                    if !isRecordingInProgress {
                        appState.stopPlayback()
                    }
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
                onOpenSettings: {
                    if showSettingsPanel {
                        // Already open: navigate up in track list or close
                        if tvFocusedTrackIndex >= 0 {
                            tvFocusedTrackIndex -= 1
                        } else {
                            dismissSettingsPanel()
                            tvFocusedTrackIndex = -1
                        }
                    } else {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showSettingsPanel = true
                        }
                        trackList = getTrackListFunc?() ?? []
                        showControls = true
                        hideControlsTask?.cancel()
                        tvFocusedTrackIndex = -1
                    }
                },
                onVideoInfoUpdate: { codec, height, hwdec, audioChannels, dropped, gamma, fps in
                    videoCodec = codec
                    videoHeight = height
                    hwDecoder = hwdec
                    audioChannelLayout = audioChannels
                    droppedFrames = dropped
                    videoGamma = gamma
                    #if os(tvOS)
                    updateDisplayCriteriaIfNeeded(gamma: gamma, fps: fps)
                    #endif
                },
                cleanupAction: $cleanupAction,
                getTrackListFunc: $getTrackListFunc,
                setAudioTrackFunc: $setAudioTrackFunc,
                setSubtitleTrackFunc: $setSubtitleTrackFunc,
                getSubtitleTextFunc: $getSubtitleTextFunc,
                showSettingsPanel: $showSettingsPanel,
                settingsTab: $settingsTab,
                tvFocusedTrackIndex: $tvFocusedTrackIndex,
                tvTrackCountProvider: { tvTrackCount },
                tvSelectTrack: { tvSelectFocusedTrack() }
            )
                .ignoresSafeArea()
            #elseif os(iOS)
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
                isRecordingInProgress: isRecordingInProgress,
                onPlaybackEnded: {
                    savePlaybackPosition()
                    markAsWatched()
                    if !isRecordingInProgress {
                        appState.stopPlayback()
                    }
                },
                onVideoInfoUpdate: { codec, height, hwdec, audioChannels, dropped, gamma, fps in
                    videoCodec = codec
                    videoHeight = height
                    hwDecoder = hwdec
                    audioChannelLayout = audioChannels
                    droppedFrames = dropped
                    videoGamma = gamma
                    #if os(tvOS)
                    updateDisplayCriteriaIfNeeded(gamma: gamma, fps: fps)
                    #endif
                },
                cleanupAction: $cleanupAction,
                pixelBufferViewRef: $pixelBufferView,
                getTrackListFunc: $getTrackListFunc,
                setAudioTrackFunc: $setAudioTrackFunc,
                setSubtitleTrackFunc: $setSubtitleTrackFunc,
                getSubtitleTextFunc: $getSubtitleTextFunc
            )
                .ignoresSafeArea()
                .onTapGesture {
                    toggleControls()
                }
                .onChange(of: pixelBufferView != nil) { hasView in
                    if hasView { setupNativePiPIfNeeded() }
                }
                .onChange(of: isPlayerReady) { ready in
                    if ready { setupNativePiPIfNeeded() }
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
                isRecordingInProgress: isRecordingInProgress,
                onPlaybackEnded: {
                    savePlaybackPosition()
                    markAsWatched()
                    if !isRecordingInProgress {
                        appState.stopPlayback()
                    }
                },
                onVideoInfoUpdate: { codec, height, hwdec, audioChannels, dropped, gamma, fps in
                    videoCodec = codec
                    videoHeight = height
                    hwDecoder = hwdec
                    audioChannelLayout = audioChannels
                    droppedFrames = dropped
                    videoGamma = gamma
                    #if os(tvOS)
                    updateDisplayCriteriaIfNeeded(gamma: gamma, fps: fps)
                    #endif
                },
                getTrackListFunc: $getTrackListFunc,
                setAudioTrackFunc: $setAudioTrackFunc,
                setSubtitleTrackFunc: $setSubtitleTrackFunc,
                getSubtitleTextFunc: $getSubtitleTextFunc
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

            // Buffering overlay for in-progress recordings
            if isBuffering && isRecordingInProgress && isPlayerReady {
                VStack(spacing: Theme.spacingSM) {
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(.white)
                    Text("Buffering...")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                }
                .padding(Theme.spacingLG)
                .background(.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))
            }

            // Subtitle text overlay — positioned at the bottom of the video content
            // (not the screen) so subtitles stay inside the video in portrait mode
            if let subtitleText = currentSubtitleText, isPlayerReady {
                let subPrefs = UserPreferences.load()
                GeometryReader { geo in
                    let videoAspect: CGFloat = 16.0 / 9.0
                    let screenAspect = geo.size.width / geo.size.height
                    let videoHeight = screenAspect < videoAspect
                        ? geo.size.width / videoAspect
                        : geo.size.height
                    let blackBarHeight = (geo.size.height - videoHeight) / 2
                    let controlsOffset: CGFloat = showControls && !isLiveStream && duration > 0 ? 80 : 20
                    let bottomY = geo.size.height - blackBarHeight - controlsOffset

                    subtitleLabel(subtitleText, size: subPrefs.subtitleSize, showBackground: subPrefs.subtitleBackground)
                        .position(x: geo.size.width / 2, y: bottomY)
                }
                .allowsHitTesting(false)
            }

            // Custom controls overlay
            if showControls && isPlayerReady {
                controlsOverlay
            }

            // Stream settings panel overlay
            if showSettingsPanel && isPlayerReady {
                streamSettingsPanel
                    .transition(.move(edge: .trailing))
                    .zIndex(2)
            }

            // Error message
            if let error = errorMessage {
                VStack {
                    // Show close button over the error when controls are not accessible
                    if !isPlayerReady {
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
                            #endif
                            Spacer()
                        }
                        .padding(.top, Theme.spacingSM)
                    }
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
        #if os(tvOS)
        .onExitCommand {
            if showSettingsPanel {
                dismissSettingsPanel()
                tvFocusedTrackIndex = -1
            } else {
                savePlaybackPosition()
                appState.stopPlayback()
            }
        }
        #endif
        .onAppear {
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
            #if os(tvOS)
            clearDisplayCriteria()
            #endif
            // Save position BEFORE cleanup — cleanup destroys the MPV player
            // which can interfere with reading currentPosition.
            // Always save unconditionally — on tvOS the Menu button may be
            // intercepted by SwiftUI's fullScreenCover dismiss before reaching
            // the MPV view, so the onDismiss callback never fires.
            savePlaybackPosition()
            #if os(iOS)
            let session = ActivePlayerSession.shared
            let nativePiPActive = isUsingPixelBufferRenderer && (session.isPiPActive || session.dismissingForPiP)
            if nativePiPActive {
                // Don't stop player — mpv continues feeding PiP
            } else {
                cleanupAction?()
                cleanupAction = nil
                if appState.isShowingPlayer {
                    appState.stopPlayback()
                }
            }
            #else
            cleanupAction?()
            cleanupAction = nil
            if appState.isShowingPlayer {
                appState.stopPlayback()
            }
            #endif
            // Notify recordings list to refresh with updated progress.
            // Delay slightly so the async position save completes first.
            if recordingId != nil {
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    NotificationCenter.default.post(name: .recordingsDidChange, object: nil)
                }
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
        }
        #if DISPATCHERPVR
        .onChange(of: appState.currentlyPlayingChannelName) { _ in
            startDispatchProfileRefreshLoop()
        }
        #endif
        .onChange(of: duration) { _ in
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
        .onChange(of: isPlaying) { _ in
            if !isPlaying {
                savePlaybackPosition()
            }
        }
        .task(id: isPlayerReady) {
            guard isPlayerReady else { return }
            // Wait for tracks to be populated after demuxing starts
            try? await Task.sleep(for: .seconds(2))
            autoSelectSubtitleIfNeeded()
            // Poll subtitle text while playing
            while !Task.isCancelled {
                let text = getSubtitleTextFunc?()
                if text != currentSubtitleText {
                    currentSubtitleText = text
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .onChange(of: currentPosition) { _ in
            detectBuffering()
        }
        #if os(tvOS)
        .onChange(of: showSettingsPanel) { _ in
            appState.tvosPlayerSettingsPanelOpen = showSettingsPanel
        }
        #endif
        .onChange(of: duration) { _ in
            // duration keeps growing for in-progress recordings even when
            // position is frozen by cache-pause, so this fires the detection
            // when onChange(of: currentPosition) can't.
            detectBuffering()
        }
    }

    /// Detects when playback has stalled (position not advancing while
    /// playing) and triggers a stream reload to recover.
    private func detectBuffering() {
        guard isRecordingInProgress, isPlayerReady, isPlaying else {
            bufferingStallCount = 0
            isBuffering = false
            return
        }
        // Detect position jumps (e.g. after reload with backoff) — reset tracking
        if currentPosition < lastBufferingCheckPosition - 1 {
            lastBufferingCheckPosition = currentPosition
            bufferingStallCount = 0
            isBuffering = false
            return
        }
        if currentPosition > lastBufferingCheckPosition + 0.1 {
            // Position advancing — not buffering
            lastBufferingCheckPosition = currentPosition
            bufferingStallCount = 0
            if isBuffering {
                isBuffering = false
            }
        } else {
            // Position stalled — count consecutive stalls (each ~0.5s from duration changes)
            bufferingStallCount += 1
            if bufferingStallCount >= 3 && !isBuffering {
                isBuffering = true
            }
            // No app-level reload needed — stream-lavf-growing-file
            // handles the close/reopen at the stream layer.
        }
    }

    private func savePlaybackPosition() {
        guard let recordingId = recordingId else {
            print("[Player] savePlaybackPosition: no recordingId")
            return
        }
        let position = Int(currentPosition)
        let dur = duration
        print("[Player] savePlaybackPosition: id=\(recordingId) pos=\(position) dur=\(Int(dur))")
        // Don't save if we're at the very beginning
        guard position > 10 else { return }
        // If near the end, mark as fully watched instead (but not for in-progress recordings)
        if !isRecordingInProgress && dur > 0 && Double(position) > dur - 30 {
            markAsWatched()
            return
        }

        Task.detached { [client] in
            try? await client.setRecordingPosition(recordingId: recordingId, positionSeconds: position)
        }
    }

    private func markAsWatched() {
        guard let recordingId = recordingId else { return }
        // Set position to full duration to mark as watched
        let watchedPosition = Int(duration > 0 ? duration : currentPosition)
        Task.detached { [client] in
            try? await client.setRecordingPosition(recordingId: recordingId, positionSeconds: watchedPosition)
            print("[Player] Marked recording \(recordingId) as watched")
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

    #if os(tvOS)
    private func updateDisplayCriteriaIfNeeded(gamma: String?, fps: Double) {
        guard !hasSetDisplayCriteria else { return }
        guard let gamma, !gamma.isEmpty else { return }

        // Map mpv's gamma/transfer to CoreMedia transfer function
        let transferFunction: CFString
        switch gamma.lowercased() {
        case "pq", "smpte-st2084", "smpte2084":
            transferFunction = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case "hlg", "arib-std-b67":
            transferFunction = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        case "bt.1886", "gamma2.2", "srgb":
            return // SDR — no need to change display mode
        default:
            return
        }

        // Create a format description that fully describes the HDR video.
        // The system needs codec type, resolution, transfer function, color primaries,
        // YCbCr matrix, AND bit depth to properly trigger HDR display mode.
        let width = videoHeight.map { Int($0) * 16 / 9 } ?? 3840
        let height = videoHeight ?? 2160
        let bitsPerComponent: Int = 10
        var formatDescription: CMFormatDescription?
        let extensions: [String: Any] = [
            kCMFormatDescriptionExtension_TransferFunction as String: transferFunction,
            kCMFormatDescriptionExtension_ColorPrimaries as String: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_YCbCrMatrix as String: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
            kCMFormatDescriptionExtension_BitsPerComponent as String: bitsPerComponent,
            kCMFormatDescriptionExtension_FullRangeVideo as String: false,
            "CVPixelFormatType" as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        ]
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: Int32(width),
            height: Int32(height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )

        guard let formatDescription else {
            print("DisplayManager: failed to create format description")
            return
        }

        let refreshRate = fps > 0 ? Float(fps) : 0
        let criteria = AVDisplayCriteria(refreshRate: refreshRate, formatDescription: formatDescription)

        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else { return }

        window.avDisplayManager.preferredDisplayCriteria = criteria
        hasSetDisplayCriteria = true
        print("DisplayManager: set HDR criteria transfer=\(gamma) fps=\(refreshRate)")
    }

    private func clearDisplayCriteria() {
        guard hasSetDisplayCriteria else { return }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else { return }

        window.avDisplayManager.preferredDisplayCriteria = nil
        hasSetDisplayCriteria = false
        print("DisplayManager: cleared criteria")
    }
    #endif

    private var isUsingPixelBufferRenderer: Bool {
        #if os(tvOS)
        return UserPreferences.load().tvosGPUAPI == .pixelbuffer
        #elseif os(iOS)
        return UserPreferences.load().iosGPUAPI == .pixelbuffer
        #elseif os(macOS)
        return UserPreferences.load().macosGPUAPI == .pixelbuffer
        #else
        return false
        #endif
    }

    #if os(iOS)
    private func setupNativePiPIfNeeded() {
        let session = ActivePlayerSession.shared
        guard isUsingPixelBufferRenderer,
              session.pipController == nil,
              session.hasActiveSession else { return }

        session.setupPiP(
            playPauseHandler: { playing in
                if playing { session.player?.play() } else { session.player?.pause() }
            },
            isPausedQuery: {
                session.player?.isPaused ?? true
            }
        )
    }

    private func toggleNativePiP() {
        let session = ActivePlayerSession.shared
        guard let controller = session.pipController else { return }

        if controller.isPictureInPictureActive {
            controller.stop()
            pipIsActive = false
            session.isPiPActive = false
        } else {
            session.isPiPActive = true
            session.dismissingForPiP = true
            controller.start()
            pipIsActive = true
            appState.dismissPlayer()
        }
    }
    #endif

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

            Text(headerTitle)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)

            Spacer()

            #if os(iOS)
            if isUsingPixelBufferRenderer && pipIsSupported {
                Button {
                    toggleNativePiP()
                } label: {
                    Image(systemName: pipIsActive ? "pip.exit" : "pip.enter")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(8)
                }
                .buttonStyle(.plain)
            }
            #endif

            #if !os(tvOS)
            if videoHeight != nil {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showSettingsPanel.toggle()
                    }
                    if showSettingsPanel {
                        trackList = getTrackListFunc?() ?? []
                        hideControlsTask?.cancel()
                    } else {
                        scheduleHideControls()
                    }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(8)
                }
                .buttonStyle(.plain)
            }
            #endif
        }
        .padding(.horizontal)
        .padding(.top, Theme.spacingMD)
    }

    // MARK: - Stream Settings Panel

    private var panelWidth: CGFloat {
        #if os(tvOS)
        return 400
        #elseif os(macOS)
        return 340
        #else
        return 320
        #endif
    }

    #if os(tvOS)
    private var tvTrackCount: Int {
        switch settingsTab {
        case .video: return 0
        case .audio: return trackList.filter { $0.type == "audio" }.count
        case .subtitles: return trackList.filter { $0.type == "sub" }.count + 1 // +1 for "None"
        }
    }

    private func tvSelectFocusedTrack() {
        guard tvFocusedTrackIndex >= 0 else { return }
        switch settingsTab {
        case .video: break
        case .audio:
            let audioTracks = trackList.filter { $0.type == "audio" }
            if tvFocusedTrackIndex < audioTracks.count {
                setAudioTrackFunc?(audioTracks[tvFocusedTrackIndex].id)
                trackList = getTrackListFunc?() ?? []
            }
        case .subtitles:
            if tvFocusedTrackIndex == 0 {
                // "None" option
                setSubtitleTrackFunc?(nil)
                trackList = getTrackListFunc?() ?? []
                let prefs = UserPreferences.load()
                if prefs.subtitleMode == .auto {
                    var updated = prefs
                    updated.preferredSubtitleLanguage = nil
                    updated.save()
                }
            } else {
                let subtitleTracks = trackList.filter { $0.type == "sub" }
                let idx = tvFocusedTrackIndex - 1 // -1 for "None" row
                if idx < subtitleTracks.count {
                    let track = subtitleTracks[idx]
                    setSubtitleTrackFunc?(track.id)
                    trackList = getTrackListFunc?() ?? []
                    let prefs = UserPreferences.load()
                    if prefs.subtitleMode == .auto {
                        var updated = prefs
                        updated.preferredSubtitleLanguage = track.lang ?? track.codec
                        updated.save()
                    }
                }
            }
        }
    }
    #endif

    private func dismissSettingsPanel() {
        withAnimation(.easeInOut(duration: 0.25)) {
            showSettingsPanel = false
        }
        scheduleHideControls()
    }

    private var streamSettingsPanel: some View {
        HStack(spacing: 0) {
            #if !os(tvOS)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissSettingsPanel()
                }
            #else
            Spacer()
            #endif

            VStack(alignment: .leading, spacing: 0) {
                settingsTabBar
                    .padding(.top, Theme.spacingMD)

                Divider()
                    .background(Color.white.opacity(0.2))

                // Tab content
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.spacingSM) {
                        switch settingsTab {
                        case .video:
                            videoTabContent
                        case .audio:
                            audioTabContent
                        case .subtitles:
                            subtitlesTabContent
                        }
                    }
                    .padding(Theme.spacingMD)
                }
            }
            .frame(width: panelWidth)
            .background(Color.black.opacity(0.9))
        }
    }


    private var settingsTabBar: some View {
        HStack(spacing: 0) {
            ForEach(StreamSettingsTab.allCases, id: \.self) { tab in
                Button {
                    settingsTab = tab
                } label: {
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: tab.icon)
                                .font(.caption)
                            Text(tab.rawValue)
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(settingsTab == tab ? Theme.accent : .white.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                        Rectangle()
                            .fill(settingsTab == tab ? Theme.accent : Color.clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.spacingSM)
    }

    private var videoTabContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let height = videoHeight {
                videoInfoRow("Resolution", resolutionLabel(height: height))
            }
            if let codec = videoCodec {
                videoInfoRow("Video", formatCodecName(codec))
            }
            if let hw = hwDecoder, !hw.isEmpty, hw != "no" {
                videoInfoRow("HW Decode", hw)
            } else {
                videoInfoRow("HW Decode", "No")
            }
            if let gamma = videoGamma, !gamma.isEmpty {
                videoInfoRow("HDR", hdrLabel(gamma))
            }
            #if DISPATCHERPVR
            if let profile = dispatchProfileBadge {
                videoInfoRow("Profile", profile)
            }
            #endif
            videoInfoRow("Renderer", rendererTag)
            if droppedFrames > 0 {
                videoInfoRow("Dropped", "\(droppedFrames)")
            }
        }
    }

    private var audioTabContent: some View {
        let audioTracks = trackList.filter { $0.type == "audio" }
        return VStack(alignment: .leading, spacing: 0) {
            // Current audio info
            if let audio = audioChannelLayout {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current Audio")
                        .font(.caption)
                        .foregroundStyle(.gray)
                    if let selectedTrack = audioTracks.first(where: { $0.isSelected }) {
                        Text(selectedTrack.audioDetail)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                    } else {
                        Text(audio)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                    }
                }
                .padding(.bottom, Theme.spacingMD)
            }

            if audioTracks.isEmpty {
                Text("No audio tracks available")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
                    .padding(.vertical, Theme.spacingMD)
            } else {
                Text("Audio Tracks")
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .padding(.bottom, 4)

                ForEach(Array(audioTracks.enumerated()), id: \.element.id) { index, track in
                    trackRow(track, isActive: track.isSelected, isTVFocused: tvOSFocused(index)) {
                        setAudioTrackFunc?(track.id)
                        trackList = getTrackListFunc?() ?? []
                    }
                }
            }
        }
    }

    private var subtitlesTabContent: some View {
        let subtitleTracks = trackList.filter { $0.type == "sub" }
        let noneSelected = !subtitleTracks.contains(where: { $0.isSelected })
        return VStack(alignment: .leading, spacing: 0) {
            Text("Subtitle Tracks")
                .font(.caption)
                .foregroundStyle(.gray)
                .padding(.bottom, 4)

            // "None" option
            Button {
                setSubtitleTrackFunc?(nil)
                trackList = getTrackListFunc?() ?? []
                let prefs = UserPreferences.load()
                if prefs.subtitleMode == .auto {
                    var updated = prefs
                    updated.preferredSubtitleLanguage = nil
                    updated.save()
                }
            } label: {
                HStack {
                    Text("None")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                    Spacer()
                    if noneSelected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.horizontal, Theme.spacingMD)
                .padding(.vertical, 10)
                .background(tvOSFocused(0) ? Color.white.opacity(0.2) : Color.clear)
                .cornerRadius(6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if subtitleTracks.isEmpty {
                Text("No subtitle tracks available")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
                    .padding(.vertical, Theme.spacingMD)
                    .padding(.horizontal, Theme.spacingMD)
            } else {
                ForEach(Array(subtitleTracks.enumerated()), id: \.element.id) { index, track in
                    trackRow(track, isActive: track.isSelected, isTVFocused: tvOSFocused(index + 1)) {
                        setSubtitleTrackFunc?(track.id)
                        trackList = getTrackListFunc?() ?? []
                        let prefs = UserPreferences.load()
                        if prefs.subtitleMode == .auto {
                            var updated = prefs
                            updated.preferredSubtitleLanguage = track.lang ?? track.codec
                            updated.save()
                        }
                    }
                }
            }
        }
    }

    private func tvOSFocused(_ index: Int) -> Bool {
        #if os(tvOS)
        return tvFocusedTrackIndex == index
        #else
        return false
        #endif
    }

    private func trackRow(_ track: MPVTrack, isActive: Bool, isTVFocused: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                    if !track.audioDetail.isEmpty {
                        Text(track.audioDetail)
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, Theme.spacingMD)
            .padding(.vertical, 10)
            .background(isTVFocused ? Color.white.opacity(0.2) : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hdrLabel(_ gamma: String) -> String {
        switch gamma.lowercased() {
        case "pq", "smpte-st2084", "smpte2084": return "HDR10 (PQ)"
        case "hlg", "arib-std-b67": return "HLG"
        case "bt.1886": return "SDR (BT.1886)"
        case "srgb": return "SDR (sRGB)"
        default: return gamma
        }
    }

    private func videoInfoRow(_ label: String, _ value: String) -> some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.gray)
            Text(value)
                .font(.body)
                .fontWeight(.medium)
                .foregroundStyle(.white)
        }
        .padding(.vertical, 4)
        #else
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.gray)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.white)
        }
        #endif
    }

    private var headerTitle: String {
        return title
    }

    private var rendererTag: String {
        #if os(tvOS)
        let api = UserPreferences.load().tvosGPUAPI
        #elseif os(iOS)
        let api = UserPreferences.load().iosGPUAPI
        #elseif os(macOS)
        let api = UserPreferences.load().macosGPUAPI
        #else
        return ""
        #endif
        switch api {
        case .metal: return "M"
        case .pixelbuffer: return "PB"
        case .opengl: return "GL"
        }
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

    @ViewBuilder
    private func subtitleLabel(_ text: String, size: SubtitleSize, showBackground: Bool) -> some View {
        if showBackground {
            Text(text)
                .font(.system(size: size.fontSize, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.spacingLG)
                .padding(.vertical, Theme.spacingSM)
                .background(Color.black.opacity(0.7))
                .cornerRadius(4)
        } else {
            Text(text)
                .font(.system(size: size.fontSize, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 0, x: -1, y: -1)
                .shadow(color: .black, radius: 0, x: 1, y: -1)
                .shadow(color: .black, radius: 0, x: -1, y: 1)
                .shadow(color: .black, radius: 0, x: 1, y: 1)
                .shadow(color: .black, radius: 2, x: 0, y: 0)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.spacingLG)
                .padding(.vertical, Theme.spacingSM)
        }
    }

    private func autoSelectSubtitleIfNeeded() {
        let prefs = UserPreferences.load()
        guard prefs.subtitleMode == .auto,
              let preferred = prefs.preferredSubtitleLanguage else { return }
        let tracks = getTrackListFunc?() ?? []
        let subtitleTracks = tracks.filter { $0.type == "sub" }
        // Match by language first, then fall back to codec (e.g. "eia_608" for CC)
        let match = subtitleTracks.first(where: { $0.lang == preferred })
            ?? subtitleTracks.first(where: { $0.codec == preferred })
        if let match {
            setSubtitleTrackFunc?(match.id)
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls.toggle()
            if !showControls && showSettingsPanel {
                showSettingsPanel = false
            }
        }

        if showControls {
            scheduleHideControls()
        }
    }

    private func scheduleHideControls() {
        guard !showSettingsPanel else { return }
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
    var onVideoInfoUpdate: ((String?, Int?, String?, String?, Int64, String?, Double) -> Void)?
    let recordingMonitor = MPVRecordingMonitor()
    var isRecordingInProgress = false
    private var lastCodec: String?
    private var lastHeight: Int?
    private var lastHwdec: String?
    private var lastAudioChannels: String?
    private var hasTriedHwdecCopy = false
    private var currentURLPath: String?
    private var currentURL: URL?
    private var sourceURL: URL?
    private var lastPlaybackError: String?
    private var hasTriedMasterPlaylistFallback = false
    private var masterVariantCandidates: [URL] = []
    private var failedVariantURLs: Set<String> = []
    private var recoveryVariantCursor = 0
    private var lastLiveHLSReloadAt: Date = .distantPast
    private var hasDisabledHwdecForSession = false
    private var hasAppliedLiveHLSProfile = false
    private var lastPrintedMPVLog: String?
    private var lastPrintedMPVLogAt: Date = .distantPast

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
        recordingMonitor.stop()

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
            var duration = self.getDuration()

            // For recordings in progress: estimate growing duration via HEAD,
            // then subtract a 15s safety margin so the seek bar and playback
            // never reach the actual write edge (same approach as Kodi's
            // NextPVR addon). The demuxer still has real data beyond this
            // point, preventing EOF stalls during normal playback.
            if self.isRecordingInProgress {
                self.recordingMonitor.updateBaseline(duration: duration)
                self.recordingMonitor.refreshIfNeeded()
                let estimated = self.recordingMonitor.estimatedDuration
                if estimated > duration {
                    duration = estimated
                }
                duration = max(0, duration - 15)
                self.reportedDuration = duration
            }

            // Only query full video info every 2 seconds (4 ticks) to reduce mpv lock contention.
            // Position/duration are lightweight reads; getVideoInfo reads 6+ properties.
            statsCounter += 1
            let shouldQueryInfo = statsCounter % 4 == 0 || self.lastCodec == nil

            var info: (codec: String?, width: Int?, height: Int?, hwdec: String?, audioChannels: String?, droppedFrames: Int64, gamma: String?, fps: Double)?
            if shouldQueryInfo {
                let i = self.getVideoInfo()
                info = i
                let changed = i.codec != self.lastCodec || i.height != self.lastHeight || i.hwdec != self.lastHwdec || i.audioChannels != self.lastAudioChannels
                if changed {
                    self.lastCodec = i.codec
                    self.lastHeight = i.height
                    self.lastHwdec = i.hwdec
                    self.lastAudioChannels = i.audioChannels
                    if i.codec != nil {
                        self.logVideoInfo(i)
                    }
                }
            }

            // Log performance stats every 10 seconds (less frequent to reduce lock pressure)
            // Disabled by default — uncomment for diagnostics. Each call reads 7 mpv properties
            // which can cause frame drops on constrained hardware (4K HEVC on Apple TV).
            // if statsCounter % 20 == 0 {
            //     self.logPerformanceStats()
            // }

            DispatchQueue.main.async {
                self.onPositionUpdate?(position, duration)
                if let info {
                    self.onVideoInfoUpdate?(info.codec, info.height, info.hwdec, info.audioChannels, info.droppedFrames, info.gamma, info.fps)
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

    /// The last duration reported to the UI (with 15s margin already applied).
    /// Set by PlayerView via the position timer callback.
    var reportedDuration: Double = 0

    func seek(seconds: Int) {
        guard let mpv = mpv else { return }
        var actualSeconds = seconds
        // Clamp forward seeks to the reported duration (which has 15s margin)
        if isRecordingInProgress && seconds > 0 && reportedDuration > 0 {
            let position = getTimePosition()
            let maxSeek = Int(reportedDuration - position)
            if maxSeek <= 0 { return }
            actualSeconds = min(seconds, maxSeek)
        }
        let command = "seek \(actualSeconds) relative"
        let result = mpv_command_string(mpv, command)
        if result < 0 {
            print("MPV: seek command failed: \(result)")
        }
    }

    func seekTo(position: Double) {
        guard let mpv = mpv else { return }
        var target = position
        // Clamp to the reported duration (which has 15s margin)
        if isRecordingInProgress && reportedDuration > 0 {
            target = min(target, reportedDuration)
        }
        let command = "seek \(target) absolute"
        let result = mpv_command_string(mpv, command)
        if result < 0 {
            print("MPV: seekTo command failed: \(result)")
        }
    }

    func startRecordingMonitor(url: URL) {
        guard let mpv = mpv else { return }
        recordingMonitor.start(mpv: mpv, url: url.absoluteString)
    }



    func getVideoInfo() -> (codec: String?, width: Int?, height: Int?, hwdec: String?, audioChannels: String?, droppedFrames: Int64, gamma: String?, fps: Double) {
        guard let mpv = mpv else { return (nil, nil, nil, nil, nil, 0, nil, 0) }

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

        var droppedFrames: Int64 = 0
        mpv_get_property(mpv, "frame-drop-count", MPV_FORMAT_INT64, &droppedFrames)

        // Color transfer function (e.g. "pq", "hlg", "bt.1886") for HDR display mode matching
        var gamma: String?
        if let cString = mpv_get_property_string(mpv, "video-params/gamma") {
            gamma = String(cString: cString)
            mpv_free(cString)
        }

        // Frame rate for display mode matching
        var fps: Double = 0
        mpv_get_property(mpv, "container-fps", MPV_FORMAT_DOUBLE, &fps)

        return (codec, width, height, hwdec, audioChannels, droppedFrames, gamma, fps)
    }

    func getTrackList() -> [MPVTrack] {
        guard let mpv = mpv else { return [] }

        var count: Int64 = 0
        mpv_get_property(mpv, "track-list/count", MPV_FORMAT_INT64, &count)

        var tracks: [MPVTrack] = []
        for i in 0..<Int(count) {
            var trackId: Int64 = 0
            mpv_get_property(mpv, "track-list/\(i)/id", MPV_FORMAT_INT64, &trackId)

            var type: String?
            if let cString = mpv_get_property_string(mpv, "track-list/\(i)/type") {
                type = String(cString: cString)
                mpv_free(cString)
            }
            guard let trackType = type else { continue }

            var title: String?
            if let cString = mpv_get_property_string(mpv, "track-list/\(i)/title") {
                title = String(cString: cString)
                mpv_free(cString)
            }

            var lang: String?
            if let cString = mpv_get_property_string(mpv, "track-list/\(i)/lang") {
                lang = String(cString: cString)
                mpv_free(cString)
            }

            var codec: String?
            if let cString = mpv_get_property_string(mpv, "track-list/\(i)/codec") {
                codec = String(cString: cString)
                mpv_free(cString)
            }

            var channels: String?
            if let cString = mpv_get_property_string(mpv, "track-list/\(i)/demux-channel-count") {
                channels = String(cString: cString)
                mpv_free(cString)
            }

            var bitrate: Int64 = 0
            mpv_get_property(mpv, "track-list/\(i)/demux-bitrate", MPV_FORMAT_INT64, &bitrate)

            var selected: Int32 = 0
            mpv_get_property(mpv, "track-list/\(i)/selected", MPV_FORMAT_FLAG, &selected)

            tracks.append(MPVTrack(
                id: Int(trackId),
                type: trackType,
                title: title,
                lang: lang,
                codec: codec,
                channels: channels,
                bitrate: bitrate > 0 ? Int(bitrate) : nil,
                isSelected: selected != 0
            ))
        }
        return tracks
    }

    private var isChangingTrack = false

    func setAudioTrack(_ trackId: Int) {
        guard let mpv = mpv else { return }
        isChangingTrack = true
        var value = Int64(trackId)
        mpv_set_property(mpv, "aid", MPV_FORMAT_INT64, &value)
        // Allow enough time for mpv to reconfigure audio on non-seekable streams
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.isChangingTrack = false
        }
    }

    func getSubtitleText() -> String? {
        guard let mpv = mpv else { return nil }
        guard let cString = mpv_get_property_string(mpv, "sub-text") else { return nil }
        let text = String(cString: cString)
        mpv_free(cString)
        return text.isEmpty ? nil : text
    }

    func setSubtitleTrack(_ trackId: Int?) {
        guard let mpv = mpv else { return }
        if let trackId = trackId {
            var value = Int64(trackId)
            mpv_set_property(mpv, "sid", MPV_FORMAT_INT64, &value)
        } else {
            mpv_set_property_string(mpv, "sid", "no")
        }
    }

    private var hasLoggedVideoInfo = false

    private func logVideoInfo(_ info: (codec: String?, width: Int?, height: Int?, hwdec: String?, audioChannels: String?, droppedFrames: Int64, gamma: String?, fps: Double)) {
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

    func setup(errorBinding: Binding<String?>?, isRecordingInProgress: Bool = false) -> Bool {
        self.errorBinding = errorBinding
        self.isRecordingInProgress = isRecordingInProgress

        // Create MPV
        mpv = mpv_create()
        guard let mpv = mpv else {
            print("MPV: Failed to create context")
            return false
        }

        // Video output
        #if os(macOS)
        let gpuAPI = UserPreferences.load().macosGPUAPI
        if gpuAPI == .pixelbuffer {
            mpv_set_option_string(mpv, "vo", "pixelbuffer")
            print("MPV: macOS VO = pixelbuffer (AVSampleBufferDisplayLayer)")
        } else if gpuAPI == .metal {
            mpv_set_option_string(mpv, "vo", "gpu")
            mpv_set_option_string(mpv, "gpu-api", "metal")
            mpv_set_option_string(mpv, "gpu-context", "metal")
            print("MPV: macOS GPU API = Metal")
        } else {
            mpv_set_option_string(mpv, "vo", "libmpv")
            mpv_set_option_string(mpv, "gpu-api", "opengl")
            print("MPV: macOS GPU API = OpenGL")
        }
        #elseif os(tvOS)
        let gpuAPI = UserPreferences.load().tvosGPUAPI
        if gpuAPI == .pixelbuffer {
            mpv_set_option_string(mpv, "vo", "pixelbuffer")
            print("MPV: tvOS VO = pixelbuffer (AVSampleBufferDisplayLayer)")
        } else if gpuAPI == .metal {
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
        if gpuAPI == .pixelbuffer {
            mpv_set_option_string(mpv, "vo", "pixelbuffer")
            print("MPV: iOS VO = pixelbuffer (AVSampleBufferDisplayLayer)")
        } else if gpuAPI == .metal {
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
        // Allow more hw decode failures before permanent fallback to software.
        // Live MPEG-TS streams start mid-GOP without SPS/PPS, causing initial
        // VideoToolbox errors. Default threshold is too low — mpv falls back to
        // software permanently before the first IDR frame arrives.
        mpv_set_option_string(mpv, "vd-lavc-software-fallback", "600")

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
        mpv_set_option_string(mpv, "cache-pause-initial", "yes")
        mpv_set_option_string(mpv, "demuxer-max-bytes", "150MiB")
        mpv_set_option_string(mpv, "demuxer-max-back-bytes", "150MiB")
        mpv_set_option_string(mpv, "demuxer-seekable-cache", "yes")
        mpv_set_option_string(mpv, "cache-pause-wait", "1")       // Shorter pause to avoid visible glitches
        mpv_set_option_string(mpv, "cache-pause", "yes")          // Pause and rebuffer on underrun (prevents choppy live streams)
        mpv_set_option_string(mpv, "demuxer-readahead-secs", "60")

        // Network
        mpv_set_option_string(mpv, "network-timeout", "30")
        mpv_set_option_string(mpv, "stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_delay_max=3")
        if isRecordingInProgress {
            // Growing file: when the stream hits EOF, close and reopen the
            // HTTP connection to get a fresh Content-Length with new data.
            // Combined with demuxer-force-retry-eof, this lets mpv seamlessly
            // play a file that's still being written to.
            mpv_set_option_string(mpv, "stream-lavf-growing-file", "yes")
            mpv_set_option_string(mpv, "demuxer-force-retry-eof", "yes")
            mpv_set_option_string(mpv, "cache-pause-initial", "no")
        }

        // Audio
        #if os(macOS)
        mpv_set_option_string(mpv, "ao", "coreaudio")
        mpv_set_option_string(mpv, "audio-buffer", "0.5")  // Larger buffer on macOS to avoid coreaudio race with raw TS streams
        mpv_set_option_string(mpv, "audio-wait-open", "0.5")  // Delay opening audio device until data is ready (prevents NULL buffer crash with raw TS streams)
        #elseif os(tvOS)
        mpv_set_option_string(mpv, "ao", "audiounit")
        mpv_set_option_string(mpv, "audio-buffer", "0.5")
        mpv_set_option_string(mpv, "audio-wait-open", "0.5")
        #else
        mpv_set_option_string(mpv, "ao", "audiounit")
        mpv_set_option_string(mpv, "audio-buffer", "0.2")
        #endif
        let audioChannels = UserPreferences.load().audioChannels
        mpv_set_option_string(mpv, "audio-channels", audioChannels)
        mpv_set_option_string(mpv, "volume", "100")
        mpv_set_option_string(mpv, "audio-fallback-to-null", "yes")
        mpv_set_option_string(mpv, "audio-stream-silence", "no")

        // Seeking - precise seeks for better audio sync with external audio tracks
        mpv_set_option_string(mpv, "hr-seek", "yes")

        // Subtitles: start with no subtitle selected; user picks from settings panel.
        // Subtitle text is read via sub-text and rendered as a SwiftUI overlay,
        // since the custom pixelbuffer VO does not support OSD/subtitle rendering.
        mpv_set_option_string(mpv, "sid", "no")

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

        // Request error/fatal logs only to avoid MPV log buffer overflows
        // on noisy live HLS streams.
        mpv_request_log_messages(mpv, "error")

        // Observe eof-reached so we know when playback finishes
        // (keep-open=yes prevents MPV_EVENT_END_FILE from firing on EOF)
        mpv_observe_property(mpv, 0, "eof-reached", MPV_FORMAT_FLAG)

        // Start event loop
        startEventLoop()

        return true
    }

    func loadURL(_ url: URL) {
        loadURL(url, isFallbackAttempt: false)
    }

    private func loadURL(_ url: URL, isFallbackAttempt: Bool) {
        guard let mpv = mpv else {
            print("MPV: No context available")
            return
        }

        let urlString = url.absoluteString
        currentURL = url
        currentURLPath = url.path
        if !isFallbackAttempt {
            sourceURL = url
            hasTriedMasterPlaylistFallback = false
            masterVariantCandidates = []
            failedVariantURLs.removeAll()
            recoveryVariantCursor = 0
        }
        if isLikelyUnstableLiveHLS(url) {
            applyLiveHLSProfileIfNeeded(mpv: mpv)
        }
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

    var isPaused: Bool {
        guard let mpv = mpv else { return true }
        var flag: Int32 = 0
        mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
        return flag != 0
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

    #if os(macOS)
    func createRenderContext(view: MPVPlayerMacOGLView) {
        guard let mpv = mpv else { return }

        let api = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String)
        var initParams = mpv_opengl_init_params(
            get_proc_address: { (_, name) -> UnsafeMutableRawPointer? in
                let symbolName = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
                let identifier = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
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
                print("MPV: Failed to create macOS OpenGL render context: \(errorStr)")
                return
            }
            print("MPV: macOS OpenGL render context created successfully")

            view.mpvGL = UnsafeMutableRawPointer(mpvGL)

            mpv_render_context_set_update_callback(
                mpvGL,
                { ctx in
                    guard let ctx else { return }
                    let view = Unmanaged<MPVPlayerMacOGLView>.fromOpaque(ctx).takeUnretainedValue()
                    guard view.needsDrawing else { return }
                    view.renderQueue.async {
                        DispatchQueue.main.async {
                            view.display()
                        }
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
                let level = msg.level.map { String(cString: $0) } ?? "info"
                if (level == "error" || level == "fatal"),
                   !logText.isEmpty,
                   !logText.hasPrefix("Set property:"),
                   shouldEmitMPVLog(level: level, text: logText) {
                    print("MPV [\(level)]: \(logText)")
                }

                // Log mpv errors and HTTP warnings to the event log
                // Skip transient errors during audio/subtitle track changes
                if (level == "error" || level == "fatal") && !isChangingTrack {
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
                if !isChangingTrack {
                    if level == "warn" && logText.contains("HTTP error") {
                        lastPlaybackError = logText
                    } else if level == "error" && lastPlaybackError == nil {
                        if logText.contains("Failed to open") || logText.contains("Failed to recognize") {
                            lastPlaybackError = logText
                        }
                    }
                }

                if level == "error", !isChangingTrack, tryNextVariantAfterSegmentError(logText) {
                    return
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

                // Some live HLS feeds repeatedly fail VT init (err=-12906) before
                // eventually falling back to software. Disable hwdec early for this
                // session to reduce startup stalls and repeated decoder churn.
                if !hasDisabledHwdecForSession && level == "error" &&
                    logText.contains("Failed setup for format videotoolbox_vld") {
                    hasDisabledHwdecForSession = true
                    mpv_set_property_string(mpv, "hwdec", "no")
                    print("MPV: Disabled hwdec for this session after repeated VT init failures")
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
                self?.onVideoInfoUpdate?(info.codec, info.height, info.hwdec, info.audioChannels, info.droppedFrames, info.gamma, info.fps)
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
                    if shouldIgnoreEOFAsTransientLiveHLS() {
                        print("MPV: Ignoring transient EOF for live HLS stream")
                        recoverLiveHLSAfterEOFIfNeeded()
                        return
                    }
                    // Normal end of file - video finished playing
                    print("MPV: Video playback completed naturally")
                    DispatchQueue.main.async { [weak self] in
                        self?.onPlaybackEnded?()
                    }
                } else if reason == MPV_END_FILE_REASON_ERROR {
                    let error = data.error
                    let errorStr = String(cString: mpv_error_string(error))
                    // Ignore transient errors during audio/subtitle track changes —
                    // mpv may internally seek to resync, which fails on non-seekable streams.
                    if isChangingTrack {
                        print("MPV: Ignoring error during track change: \(errorStr)")
                        return
                    }
                    if tryMasterPlaylistFallbackIfNeeded() {
                        return
                    }
                    if shouldAutoRecoverLiveHLSOnError(errorText: errorStr) {
                        print("MPV: Recovering live HLS stream after error: \(errorStr)")
                        recoverLiveHLSAfterFailureIfNeeded()
                        return
                    }
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

        case MPV_EVENT_PROPERTY_CHANGE:
            if let prop = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee {
                let name = String(cString: prop.name)
                if name == "eof-reached",
                   prop.format == MPV_FORMAT_FLAG,
                   let flag = prop.data?.assumingMemoryBound(to: Int32.self).pointee,
                   flag != 0 {
                    if isChangingTrack {
                        print("MPV: Ignoring eof-reached during track change")
                        return
                    }
                    if shouldIgnoreEOFAsTransientLiveHLS() {
                        print("MPV: Ignoring eof-reached for live HLS stream")
                        recoverLiveHLSAfterEOFIfNeeded()
                        return
                    }
                    print("MPV: EOF reached (keep-open)")
                    DispatchQueue.main.async { [weak self] in
                        self?.onPlaybackEnded?()
                    }
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

    private func tryMasterPlaylistFallbackIfNeeded() -> Bool {
        guard !hasTriedMasterPlaylistFallback, let url = currentURL else { return false }
        guard url.pathExtension.lowercased() == "m3u8" else { return false }
        guard url.lastPathComponent.lowercased().contains("master") else { return false }
        hasTriedMasterPlaylistFallback = true

        Task { [weak self] in
            guard let self else { return }
            let variants = await self.resolvePreferredVariantURLs(from: url)
            let reachableVariants = await self.filterReachableVariantURLs(variants)
            let usableVariants = reachableVariants.isEmpty ? variants : reachableVariants
            guard let mediaURL = usableVariants.first, mediaURL != url else {
                return
            }
            self.masterVariantCandidates = usableVariants
            self.failedVariantURLs.removeAll()
            self.recoveryVariantCursor = 0

            NetworkEventLog.shared.log(NetworkEvent(
                timestamp: Date(),
                method: "PLAY",
                path: mediaURL.path,
                statusCode: nil,
                isSuccess: true,
                durationMs: 0,
                responseSize: 0,
                errorDetail: "Master playlist fallback applied"
            ))

            self.loadURL(mediaURL, isFallbackAttempt: true)
        }

        return true
    }

    private func resolvePreferredVariantURLs(from masterURL: URL) async -> [URL] {
        do {
            let (data, _) = try await URLSession.shared.data(from: masterURL)
            guard let content = String(data: data, encoding: .utf8) else { return [] }
            guard content.contains("#EXT-X-STREAM-INF") else { return [] }

            let lines = content
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            var candidates: [(url: URL, score: Int, bandwidth: Int)] = []
            var pendingInf: String?

            for line in lines {
                if line.hasPrefix("#EXT-X-STREAM-INF:") {
                    pendingInf = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
                    continue
                }
                guard let inf = pendingInf else { continue }
                if line.isEmpty || line.hasPrefix("#") { continue }
                guard let variantURL = URL(string: line, relativeTo: masterURL)?.absoluteURL else {
                    pendingInf = nil
                    continue
                }

                let attrs = parseHLSAttributes(inf)
                let codecs = (attrs["CODECS"] ?? "").lowercased()
                let bandwidth = Int(attrs["BANDWIDTH"] ?? "") ?? 0
                var score = 0

                if codecs.contains("avc1") { score += 100 }
                if codecs.contains("hvc1") || codecs.contains("hev1") || codecs.contains("av01") { score -= 100 }
                if codecs.contains("mp4a") { score += 10 }

                candidates.append((variantURL, score, bandwidth))
                pendingInf = nil
            }

            let avcCandidates = candidates
                .filter { $0.score > 0 } // AVC + audio preferred

            // Prefer a conservative bitrate for unstable live HLS.
            // In practice this is often much more resilient than forcing the top variant.
            let conservativeCap = 2_500_000
            if let underCap = avcCandidates
                .filter({ $0.bandwidth > 0 && $0.bandwidth <= conservativeCap })
                .sorted(by: { $0.bandwidth > $1.bandwidth })
                .first {
                var ordered: [URL] = [underCap.url]
                ordered.append(contentsOf: avcCandidates
                    .filter { $0.url != underCap.url }
                    .sorted(by: { lhs, rhs in
                        if lhs.bandwidth == 0 { return false }
                        if rhs.bandwidth == 0 { return true }
                        return lhs.bandwidth < rhs.bandwidth
                    })
                    .map(\.url))
                return dedupeURLs(ordered)
            }

            if let lowestAVC = avcCandidates
                .sorted(by: { lhs, rhs in
                    if lhs.bandwidth == 0 { return false }
                    if rhs.bandwidth == 0 { return true }
                    return lhs.bandwidth < rhs.bandwidth
                })
                .first {
                var ordered: [URL] = [lowestAVC.url]
                ordered.append(contentsOf: avcCandidates
                    .filter { $0.url != lowestAVC.url }
                    .sorted(by: { $0.bandwidth < $1.bandwidth })
                    .map(\.url))
                return dedupeURLs(ordered)
            }

            return dedupeURLs(candidates
                .sorted { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    if lhs.bandwidth == 0 { return false }
                    if rhs.bandwidth == 0 { return true }
                    return lhs.bandwidth < rhs.bandwidth
                }
                .map(\.url))
        } catch {
            return []
        }
    }

    private func parseHLSAttributes(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        let parts = splitCSVPreservingQuotedCommas(raw)
        for part in parts {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard pieces.count == 2 else { continue }
            let key = String(pieces[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            result[key] = value
        }
        return result
    }

    private func splitCSVPreservingQuotedCommas(_ text: String) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex
        var index = text.startIndex
        var inQuotes = false

        while index < text.endIndex {
            let char = text[index]
            if char == "\"" {
                inQuotes.toggle()
            } else if char == ",", !inQuotes {
                result.append(text[start..<index])
                start = text.index(after: index)
            }
            index = text.index(after: index)
        }

        if start <= text.endIndex {
            result.append(text[start..<text.endIndex])
        }
        return result.filter { !$0.isEmpty }
    }

    private func shouldIgnoreEOFAsTransientLiveHLS() -> Bool {
        guard !isRecordingInProgress else { return false }
        guard let url = currentURL, url.pathExtension.lowercased() == "m3u8" else { return false }
        return !isCurrentStreamSeekable()
    }

    private func isCurrentStreamSeekable() -> Bool {
        guard let mpv else { return true }
        var flag: Int32 = 1
        if mpv_get_property(mpv, "seekable", MPV_FORMAT_FLAG, &flag) >= 0 {
            return flag != 0
        }
        return true
    }

    private func recoverLiveHLSAfterEOFIfNeeded() {
        print("MPV: Live HLS EOF detected, scheduling reload")
        recoverLiveHLSAfterFailureIfNeeded()
    }

    private func recoverLiveHLSAfterFailureIfNeeded() {
        guard let url = currentURL else { return }
        let now = Date()
        guard now.timeIntervalSince(lastLiveHLSReloadAt) >= 1.5 else { return }
        lastLiveHLSReloadAt = now
        let targetURL = nextRecoveryURL(current: url)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            print("MPV: Reloading live HLS stream after EOF (\(targetURL.absoluteString))")
            self.loadURL(targetURL, isFallbackAttempt: true)
        }
    }

    private func shouldAutoRecoverLiveHLSOnError(errorText: String) -> Bool {
        guard let url = currentURL, isLikelyUnstableLiveHLS(url) else { return false }
        let text = errorText.lowercased()
        return text.contains("timed out") ||
            text.contains("tls") ||
            text.contains("avformat_open_input() failed") ||
            text.contains("failed to recognize file format")
    }

    private func isLikelyUnstableLiveHLS(_ url: URL) -> Bool {
        guard !isRecordingInProgress else { return false }
        return url.pathExtension.lowercased() == "m3u8"
    }

    private func applyLiveHLSProfileIfNeeded(mpv: OpaquePointer) {
        guard !hasAppliedLiveHLSProfile else { return }
        hasAppliedLiveHLSProfile = true

        // Tune buffering/reconnect behavior for flaky live HLS feeds.
        // Goal: start faster and recover quickly rather than waiting for deep cache.
        mpv_set_property_string(mpv, "cache-secs", "12")
        mpv_set_property_string(mpv, "demuxer-readahead-secs", "6")
        mpv_set_property_string(mpv, "cache-pause-initial", "no")
        mpv_set_property_string(mpv, "cache-pause-wait", "0.2")
        mpv_set_property_string(mpv, "network-timeout", "12")
        mpv_set_property_string(mpv, "stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_delay_max=2")
        mpv_set_property_string(mpv, "hls-bitrate", "min")
        print("MPV: Applied live HLS low-latency recovery profile")
    }

    private func tryNextVariantAfterSegmentError(_ logText: String) -> Bool {
        guard logText.contains("hls: Error when loading first segment") else { return false }
        guard let current = currentURL else { return false }
        guard !masterVariantCandidates.isEmpty else { return false }

        failedVariantURLs.insert(current.absoluteString)
        guard let next = masterVariantCandidates.first(where: { !failedVariantURLs.contains($0.absoluteString) }) else {
            return false
        }

        print("MPV: Switching to next HLS variant after segment error: \(next.absoluteString)")
        loadURL(next, isFallbackAttempt: true)
        return true
    }

    private func dedupeURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls {
            let key = url.absoluteString
            if seen.insert(key).inserted {
                result.append(url)
            }
        }
        return result
    }

    private func filterReachableVariantURLs(_ urls: [URL]) async -> [URL] {
        guard !urls.isEmpty else { return [] }
        var out: [URL] = []
        for url in urls {
            if await sanityCheckVariantPlaylist(url) {
                out.append(url)
            }
        }
        return out
    }

    private func sanityCheckVariantPlaylist(_ url: URL) async -> Bool {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                return false
            }
            guard let body = String(data: data, encoding: .utf8) else { return false }
            return body.contains("#EXTINF")
        } catch {
            return false
        }
    }

    private func nextRecoveryURL(current: URL) -> URL {
        let currentKey = current.absoluteString
        if !masterVariantCandidates.isEmpty {
            failedVariantURLs.insert(currentKey)
            let candidates = masterVariantCandidates.filter { !failedVariantURLs.contains($0.absoluteString) }
            if !candidates.isEmpty {
                let index = recoveryVariantCursor % candidates.count
                recoveryVariantCursor += 1
                return candidates[index]
            }
            // All variants failed once: reset and keep cycling.
            failedVariantURLs.removeAll()
            let index = recoveryVariantCursor % masterVariantCandidates.count
            recoveryVariantCursor += 1
            return masterVariantCandidates[index]
        }
        return preferredRecoveryURL(from: current)
    }

    private func shouldEmitMPVLog(level: String, text: String) -> Bool {
        let now = Date()
        let key = "\(level):\(text)"
        if lastPrintedMPVLog == key, now.timeIntervalSince(lastPrintedMPVLogAt) < 1 {
            return false
        }
        lastPrintedMPVLog = key
        lastPrintedMPVLogAt = now
        return true
    }

    private func preferredRecoveryURL(from current: URL) -> URL {
        if let primary = normalizedPrimaryMirrorURL(current), primary != current {
            return primary
        }
        if let sourceURL, sourceURL != current {
            return sourceURL
        }
        return current
    }

    private func normalizedPrimaryMirrorURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let rewritten = components.path
            .split(separator: "/")
            .map { segment -> String in
                let value = String(segment)
                if value.hasSuffix("-b"), value.count > 2 {
                    return String(value.dropLast(2))
                }
                return value
            }
            .joined(separator: "/")
        components.path = "/" + rewritten
        return components.url
    }
}

// MARK: - MPV Container View

#if os(macOS)
struct MPVContainerView: NSViewControllerRepresentable {
    typealias NSViewControllerType = NSViewController

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
    let isRecordingInProgress: Bool

    var onPlaybackEnded: (() -> Void)?
    var onVideoInfoUpdate: ((String?, Int?, String?, String?, Int64, String?, Double) -> Void)?
    @Binding var getTrackListFunc: (() -> [MPVTrack])?
    @Binding var setAudioTrackFunc: ((Int) -> Void)?
    @Binding var setSubtitleTrackFunc: ((Int?) -> Void)?
    @Binding var getSubtitleTextFunc: (() -> String?)?

    func makeNSViewController(context: Context) -> NSViewController {
        let controller: NSViewController & MPVPlayerMacOSController
        let gpuAPI = UserPreferences.load().macosGPUAPI
        if gpuAPI == .pixelbuffer {
            controller = MPVPlayerPixelBufferNSViewController()
        } else if gpuAPI == .metal {
            controller = MPVPlayerNSViewController()
        } else {
            controller = MPVPlayerNSOpenGLViewController()
        }
        _ = controller.view
        controller.setup(errorBinding: $errorMessage, isRecordingInProgress: isRecordingInProgress)
        controller.onPositionUpdate = { position, dur in
            DispatchQueue.main.async {
                self.currentPosition = position
                self.duration = dur
            }
        }
        controller.onPlaybackEnded = onPlaybackEnded
        controller.onVideoInfoUpdate = onVideoInfoUpdate
        controller.loadURL(url)
        controller.startPositionPolling()
        if isRecordingInProgress {
            controller.startRecordingMonitor(url: url)
            controller.recordingMonitor?.onRecordingFinished = {
                print("Recording completed, normal playback mode")
            }
        }
        context.coordinator.playerController = controller

        // Set up seek and playlist closures
        DispatchQueue.main.async {
            self.seekForward = {
                controller.seek(seconds: self.seekForwardTime)
            }
            self.seekBackward = {
                controller.seek(seconds: -self.seekBackwardTime)
            }
            self.seekToPosition = { position in
                controller.seekTo(position: position)
            }
            self.getTrackListFunc = { controller.getTrackList() }
            self.setAudioTrackFunc = { controller.setAudioTrack($0) }
            self.setSubtitleTrackFunc = { controller.setSubtitleTrack($0) }
            self.getSubtitleTextFunc = { controller.getSubtitleText() }
        }

        return controller
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {
        guard let controller = nsViewController as? MPVPlayerMacOSController else { return }
        if isPlaying {
            controller.play()
        } else {
            controller.pause()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleNSViewController(_ nsViewController: NSViewController, coordinator: Coordinator) {
        (nsViewController as? MPVPlayerMacOSController)?.cleanup()
    }

    class Coordinator {
        weak var playerController: MPVPlayerMacOSController?
    }
}

protocol MPVPlayerMacOSController: AnyObject {
    var onPositionUpdate: ((Double, Double) -> Void)? { get set }
    var onPlaybackEnded: (() -> Void)? { get set }
    var onVideoInfoUpdate: ((String?, Int?, String?, String?, Int64, String?, Double) -> Void)? { get set }
    var recordingMonitor: MPVRecordingMonitor? { get }
    func setup(errorBinding: Binding<String?>?, isRecordingInProgress: Bool)
    func loadURL(_ url: URL)
    func play()
    func pause()
    func seek(seconds: Int)
    func seekTo(position: Double)
    func startRecordingMonitor(url: URL)
    func startPositionPolling()
    func cleanup()
    func getTrackList() -> [MPVTrack]
    func setAudioTrack(_ trackId: Int)
    func setSubtitleTrack(_ trackId: Int?)
    func getSubtitleText() -> String?
}

final class MPVPlayerNSViewController: NSViewController, MPVPlayerMacOSController {
    private var player: MPVPlayerCore?
    private let metalLayer = StableMetalLayer()
    var onPositionUpdate: ((Double, Double) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onVideoInfoUpdate: ((String?, Int?, String?, String?, Int64, String?, Double) -> Void)?
    var recordingMonitor: MPVRecordingMonitor? { player?.recordingMonitor }

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        // Set layer before wantsLayer for layer-hosting mode
        v.layer = metalLayer
        v.wantsLayer = true
        view = v
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateRenderSurface()
    }

    func setup(errorBinding: Binding<String?>?, isRecordingInProgress: Bool = false) {
        player = MPVPlayerCore()
        guard let success = player?.setup(errorBinding: errorBinding, isRecordingInProgress: isRecordingInProgress), success else {
            return
        }
        player?.setWindowID(metalLayer)
        player?.onPositionUpdate = { [weak self] position, duration in
            self?.onPositionUpdate?(position, duration)
        }
        player?.onPlaybackEnded = { [weak self] in
            self?.onPlaybackEnded?()
        }
        player?.onVideoInfoUpdate = { [weak self] codec, height, hwdec, audioChannels, dropped, gamma, fps in
            self?.onVideoInfoUpdate?(codec, height, hwdec, audioChannels, dropped, gamma, fps)
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

    func startRecordingMonitor(url: URL) {
        player?.startRecordingMonitor(url: url)
    }

    func startPositionPolling() {
        player?.startPositionPolling()
    }

    func getTrackList() -> [MPVTrack] { player?.getTrackList() ?? [] }
    func setAudioTrack(_ trackId: Int) { player?.setAudioTrack(trackId) }
    func setSubtitleTrack(_ trackId: Int?) { player?.setSubtitleTrack(trackId) }
    func getSubtitleText() -> String? { player?.getSubtitleText() }

    func cleanup() {
        player?.destroy()
        player = nil
        onPositionUpdate = nil
        onPlaybackEnded = nil
        onVideoInfoUpdate = nil
    }

    private func updateRenderSurface() {
        let layerSize = view.bounds.size
        guard layerSize.width > 1, layerSize.height > 1 else { return }
        let scale = view.window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        metalLayer.frame = CGRect(origin: .zero, size: layerSize)
        let drawableSize = CGSize(
            width: max(layerSize.width * scale, 1),
            height: max(layerSize.height * scale, 1)
        )
        if metalLayer.drawableSize != drawableSize {
            metalLayer.drawableSize = drawableSize
        }
    }
}

final class MPVPlayerPixelBufferNSViewController: NSViewController, MPVPlayerMacOSController {
    private var player: MPVPlayerCore?
    private var bridge: MPVPixelBufferBridge?
    var onPositionUpdate: ((Double, Double) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onVideoInfoUpdate: ((String?, Int?, String?, String?, Int64, String?, Double) -> Void)?
    var recordingMonitor: MPVRecordingMonitor? { player?.recordingMonitor }

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        // Set layer before wantsLayer for layer-hosting mode
        v.layer = CALayer()
        v.wantsLayer = true
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let displayLayer = AVSampleBufferDisplayLayer()
        bridge = MPVPixelBufferBridge(displayLayer: displayLayer)
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        view.layer?.addSublayer(displayLayer)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        bridge?.displayLayer.frame = view.bounds
    }

    func setup(errorBinding: Binding<String?>?, isRecordingInProgress: Bool = false) {
        guard let bridge else { return }
        bridge.attach()

        player = MPVPlayerCore()
        guard player?.setup(errorBinding: errorBinding, isRecordingInProgress: isRecordingInProgress) == true else { return }
        player?.onPositionUpdate = { [weak self] position, duration in
            self?.onPositionUpdate?(position, duration)
        }
        player?.onPlaybackEnded = { [weak self] in
            self?.onPlaybackEnded?()
        }
        player?.onVideoInfoUpdate = { [weak self] codec, height, hwdec, audioChannels, dropped, gamma, fps in
            self?.onVideoInfoUpdate?(codec, height, hwdec, audioChannels, dropped, gamma, fps)
        }
    }

    func loadURL(_ url: URL) { player?.loadURL(url) }
    func play() { player?.play() }
    func pause() { player?.pause() }

    func seek(seconds: Int) {
        player?.seek(seconds: seconds)
        Task { @MainActor in bridge?.flush() }
    }

    func seekTo(position: Double) {
        player?.seekTo(position: position)
        Task { @MainActor in bridge?.flush() }
    }

    func startRecordingMonitor(url: URL) {
        player?.startRecordingMonitor(url: url)
    }

    func startPositionPolling() { player?.startPositionPolling() }

    func getTrackList() -> [MPVTrack] { player?.getTrackList() ?? [] }
    func setAudioTrack(_ trackId: Int) { player?.setAudioTrack(trackId) }
    func setSubtitleTrack(_ trackId: Int?) { player?.setSubtitleTrack(trackId) }
    func getSubtitleText() -> String? { player?.getSubtitleText() }

    func cleanup() {
        player?.destroy()
        player = nil
        onPositionUpdate = nil
        onPlaybackEnded = nil
        onVideoInfoUpdate = nil
    }
}

final class MPVPlayerNSOpenGLViewController: NSViewController, MPVPlayerMacOSController {
    private var glView: MPVPlayerMacOGLView!
    var onPositionUpdate: ((Double, Double) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onVideoInfoUpdate: ((String?, Int?, String?, String?, Int64, String?, Double) -> Void)?
    var recordingMonitor: MPVRecordingMonitor? { glView?.recordingMonitor }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        glView = MPVPlayerMacOGLView(frame: view.bounds)
        glView.autoresizingMask = [.width, .height]
        view.addSubview(glView)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        glView.frame = view.bounds
        glView.handleContainerLayout()
    }

    func setup(errorBinding: Binding<String?>?, isRecordingInProgress: Bool = false) {
        glView.setup(errorBinding: errorBinding, isRecordingInProgress: isRecordingInProgress)
        glView.onPositionUpdate = { [weak self] position, duration in
            self?.onPositionUpdate?(position, duration)
        }
        glView.onPlaybackEnded = { [weak self] in
            self?.onPlaybackEnded?()
        }
        glView.onVideoInfoUpdate = { [weak self] codec, height, hwdec, audioChannels, dropped, gamma, fps in
            self?.onVideoInfoUpdate?(codec, height, hwdec, audioChannels, dropped, gamma, fps)
        }
    }

    func loadURL(_ url: URL) {
        glView.loadURL(url)
    }

    func play() {
        glView.play()
    }

    func pause() {
        glView.pause()
    }

    func seek(seconds: Int) {
        glView.seek(seconds: seconds)
    }

    func seekTo(position: Double) {
        glView.seekTo(position: position)
    }

    func startRecordingMonitor(url: URL) {
        glView.startRecordingMonitor(url: url)
    }

    func startPositionPolling() {
        glView.startPositionPolling()
    }

    func getTrackList() -> [MPVTrack] { glView.getTrackList() }
    func setAudioTrack(_ trackId: Int) { glView.setAudioTrack(trackId) }
    func setSubtitleTrack(_ trackId: Int?) { glView.setSubtitleTrack(trackId) }
    func getSubtitleText() -> String? { glView.getSubtitleText() }

    func cleanup() {
        glView.cleanup()
        onPositionUpdate = nil
        onPlaybackEnded = nil
        onVideoInfoUpdate = nil
    }
}

final class MPVPlayerMacOGLView: NSOpenGLView {
    private var player: MPVPlayerCore?
    private var defaultFBO: GLint = -1
    let renderQueue = DispatchQueue(label: "nexuspvr.macos.opengl", qos: .userInteractive)
    var mpvGL: UnsafeMutableRawPointer?
    var needsDrawing = true
    var onPositionUpdate: ((Double, Double) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onVideoInfoUpdate: ((String?, Int?, String?, String?, Int64, String?, Double) -> Void)?
    var recordingMonitor: MPVRecordingMonitor? { player?.recordingMonitor }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect, pixelFormat: Self.defaultPixelFormat())!
        autoresizingMask = [.width, .height]
        wantsBestResolutionOpenGLSurface = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override class func defaultPixelFormat() -> NSOpenGLPixelFormat {
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADoubleBuffer),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAColorSize), NSOpenGLPixelFormatAttribute(32),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADepthSize), NSOpenGLPixelFormatAttribute(24),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAStencilSize), NSOpenGLPixelFormatAttribute(8),
            NSOpenGLPixelFormatAttribute(0)
        ]
        guard let format = NSOpenGLPixelFormat(attributes: attributes) else {
            fatalError("Failed to create NSOpenGLPixelFormat")
        }
        return format
    }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        openGLContext?.makeCurrentContext()
        var swapInterval: GLint = 1
        openGLContext?.setValues(&swapInterval, for: .swapInterval)
        refreshViewport()
    }

    override func reshape() {
        super.reshape()
        handleContainerLayout()
    }

    override func update() {
        super.update()
        handleContainerLayout()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        handleContainerLayout()
    }

    func setup(errorBinding: Binding<String?>?, isRecordingInProgress: Bool = false) {
        openGLContext?.makeCurrentContext()
        refreshViewport()
        player = MPVPlayerCore()
        guard let success = player?.setup(errorBinding: errorBinding, isRecordingInProgress: isRecordingInProgress), success else {
            return
        }
        player?.createRenderContext(view: self)
        player?.onPositionUpdate = { [weak self] position, duration in
            self?.onPositionUpdate?(position, duration)
        }
        player?.onPlaybackEnded = { [weak self] in
            self?.onPlaybackEnded?()
        }
        player?.onVideoInfoUpdate = { [weak self] codec, height, hwdec, audioChannels, dropped, gamma, fps in
            self?.onVideoInfoUpdate?(codec, height, hwdec, audioChannels, dropped, gamma, fps)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard needsDrawing, let mpvGL else { return }
        openGLContext?.makeCurrentContext()

        glClearColor(0, 0, 0, 1)
        glClear(UInt32(GL_COLOR_BUFFER_BIT))
        glGetIntegerv(UInt32(GL_FRAMEBUFFER_BINDING), &defaultFBO)

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
        openGLContext?.flushBuffer()
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

    func startRecordingMonitor(url: URL) {
        player?.startRecordingMonitor(url: url)
    }

    func startPositionPolling() {
        player?.startPositionPolling()
    }

    func getTrackList() -> [MPVTrack] { player?.getTrackList() ?? [] }
    func setAudioTrack(_ trackId: Int) { player?.setAudioTrack(trackId) }
    func setSubtitleTrack(_ trackId: Int?) { player?.setSubtitleTrack(trackId) }
    func getSubtitleText() -> String? { player?.getSubtitleText() }

    func cleanup() {
        needsDrawing = false
        mpvGL = nil
        renderQueue.sync {}
        player?.destroy()
        player = nil
        onPositionUpdate = nil
        onPlaybackEnded = nil
        onVideoInfoUpdate = nil
    }

    func handleContainerLayout() {
        openGLContext?.makeCurrentContext()
        openGLContext?.update()
        refreshViewport()
        if mpvGL != nil {
            needsDisplay = true
            displayIfNeeded()
        }
    }

    private func refreshViewport() {
        let backingBounds = convertToBacking(bounds)
        let width = GLsizei(max(backingBounds.width.rounded(.down), 1))
        let height = GLsizei(max(backingBounds.height.rounded(.down), 1))
        guard width > 1, height > 1 else { return }
        glViewport(0, 0, width, height)
    }
}

private final class StableMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1, Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
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
    let isRecordingInProgress: Bool

    var onPlaybackEnded: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onToggleControls: (() -> Void)?
    var onShowControls: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onVideoInfoUpdate: ((String?, Int?, String?, String?, Int64, String?, Double) -> Void)?
    @Binding var cleanupAction: (() -> Void)?
    @Binding var getTrackListFunc: (() -> [MPVTrack])?
    @Binding var setAudioTrackFunc: ((Int) -> Void)?
    @Binding var setSubtitleTrackFunc: ((Int?) -> Void)?
    @Binding var getSubtitleTextFunc: (() -> String?)?
    @Binding var showSettingsPanel: Bool
    @Binding var settingsTab: StreamSettingsTab
    @Binding var tvFocusedTrackIndex: Int
    var tvTrackCountProvider: (() -> Int)?
    var tvSelectTrack: (() -> Void)?

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
        // onUpArrow, onLeftArrow, onRightArrow, onDownArrow, onSelectOverride, onMenuOverride
        // are set in updateUIView so they capture fresh SwiftUI state
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
        // onUpArrow, onLeftArrow, onRightArrow, onDownArrow, onSelectOverride, onMenuOverride
        // are set in updateUIView so they capture fresh SwiftUI state
    }

    private func configureCommonCallbacks(for view: MPVPlayerPixelBufferView) {
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
        // onUpArrow, onLeftArrow, onRightArrow, onDownArrow, onSelectOverride, onMenuOverride
        // are set in updateUIView so they capture fresh SwiftUI state
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
            self.getTrackListFunc = { view.getTrackList() }
            self.setAudioTrackFunc = { view.setAudioTrack($0) }
            self.setSubtitleTrackFunc = { view.setSubtitleTrack($0) }
            self.getSubtitleTextFunc = { view.getSubtitleText() }
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
            self.getTrackListFunc = { view.getTrackList() }
            self.setAudioTrackFunc = { view.setAudioTrack($0) }
            self.setSubtitleTrackFunc = { view.setSubtitleTrack($0) }
            self.getSubtitleTextFunc = { view.getSubtitleText() }
        }
    }

    private func setupSeekBindings(for view: MPVPlayerPixelBufferView) {
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
            self.getTrackListFunc = { view.getTrackList() }
            self.setAudioTrackFunc = { view.setAudioTrack($0) }
            self.setSubtitleTrackFunc = { view.setSubtitleTrack($0) }
            self.getSubtitleTextFunc = { view.getSubtitleText() }
        }
    }

    func makeUIView(context: Context) -> UIView {
        let gpuAPI = UserPreferences.load().tvosGPUAPI

        if gpuAPI == .pixelbuffer {
            let view = MPVPlayerPixelBufferView(frame: .zero)
            view.setup(errorBinding: $errorMessage, isRecordingInProgress: isRecordingInProgress)
            configureCommonCallbacks(for: view)
            view.loadURL(url)
            view.startPositionPolling()
            if isRecordingInProgress {
                view.startRecordingMonitor(url: url)
                view.recordingMonitor?.onRecordingFinished = {
                    print("Recording completed, normal playback mode")
                }
            }
            context.coordinator.playerView = view
            DispatchQueue.main.async {
                self.cleanupAction = { view.cleanup() }
            }
            setupSeekBindings(for: view)
            return view
        }

        if gpuAPI == .opengl {
            let view = MPVPlayerGLView(frame: .zero)
            view.setup(errorBinding: $errorMessage, isRecordingInProgress: isRecordingInProgress)
            configureCommonCallbacks(for: view)
            view.loadURL(url)
            view.startPositionPolling()
            if isRecordingInProgress {
                view.startRecordingMonitor(url: url)
                view.recordingMonitor?.onRecordingFinished = {
                    print("Recording completed, normal playback mode")
                }
            }
            context.coordinator.playerView = view
            DispatchQueue.main.async {
                self.cleanupAction = { view.cleanup() }
            }
            setupSeekBindings(for: view)
            return view
        }

        let view = MPVPlayerMetalView(frame: .zero)
        view.setup(errorBinding: $errorMessage, isRecordingInProgress: isRecordingInProgress)
        configureCommonCallbacks(for: view)
        view.loadURL(url)
        view.startPositionPolling()
        if isRecordingInProgress {
            view.startRecordingMonitor(url: url)
            view.recordingMonitor?.onRecordingFinished = {
                print("Recording completed, normal playback mode")
            }
        }
        context.coordinator.playerView = view
        DispatchQueue.main.async {
            self.cleanupAction = { view.cleanup() }
        }
        setupSeekBindings(for: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let pbView = uiView as? MPVPlayerPixelBufferView {
            if isPlaying { pbView.play() } else { pbView.pause() }
            applySettingsCallbacks(to: pbView)
            return
        }
        if let metalView = uiView as? MPVPlayerMetalView {
            if isPlaying { metalView.play() } else { metalView.pause() }
            applySettingsCallbacks(to: metalView)
            return
        }
        if let glView = uiView as? MPVPlayerGLView {
            if isPlaying { glView.play() } else { glView.pause() }
            applySettingsCallbacks(to: glView)
            return
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let pbView = uiView as? MPVPlayerPixelBufferView {
            pbView.cleanup()
        } else if let metalView = uiView as? MPVPlayerMetalView {
            metalView.cleanup()
        } else {
            (uiView as? MPVPlayerGLView)?.cleanup()
        }
    }

    private func applySettingsCallbacks(to view: MPVPlayerMetalView) {
        let panelBinding = $showSettingsPanel
        let tabBinding = $settingsTab
        let focusBinding = $tvFocusedTrackIndex
        let openSettings = onOpenSettings
        view.onUpArrow = openSettings
        view.onMenuOverride = {
            print("[tvOS] onMenuOverride called, panelOpen=\(panelBinding.wrappedValue)")
            guard panelBinding.wrappedValue else { return false }
            withAnimation(.easeInOut(duration: 0.25)) { panelBinding.wrappedValue = false }
            focusBinding.wrappedValue = -1
            return true
        }
        view.onLeftArrow = {
            guard panelBinding.wrappedValue else { return false }
            withAnimation(.easeInOut(duration: 0.15)) {
                switch tabBinding.wrappedValue {
                case .video:
                    withAnimation(.easeInOut(duration: 0.25)) { panelBinding.wrappedValue = false }
                case .audio: tabBinding.wrappedValue = .video
                case .subtitles: tabBinding.wrappedValue = .audio
                }
            }
            focusBinding.wrappedValue = -1
            return true
        }
        view.onRightArrow = {
            guard panelBinding.wrappedValue else { return false }
            withAnimation(.easeInOut(duration: 0.15)) {
                switch tabBinding.wrappedValue {
                case .video: tabBinding.wrappedValue = .audio
                case .audio: tabBinding.wrappedValue = .subtitles
                case .subtitles: break
                }
            }
            focusBinding.wrappedValue = -1
            return true
        }
        view.onDownArrow = {
            guard panelBinding.wrappedValue else { return false }
            let maxIndex = (self.tvTrackCountProvider?() ?? 0) - 1
            if maxIndex >= 0 && focusBinding.wrappedValue < maxIndex {
                focusBinding.wrappedValue += 1
            }
            return true
        }
        view.onSelectOverride = {
            guard panelBinding.wrappedValue else { return false }
            self.tvSelectTrack?()
            return true
        }
    }

    private func applySettingsCallbacks(to view: MPVPlayerPixelBufferView) {
        let panelBinding = $showSettingsPanel
        let tabBinding = $settingsTab
        let focusBinding = $tvFocusedTrackIndex
        let openSettings = onOpenSettings
        view.onUpArrow = openSettings
        view.onMenuOverride = {
            print("[tvOS] onMenuOverride called, panelOpen=\(panelBinding.wrappedValue)")
            guard panelBinding.wrappedValue else { return false }
            withAnimation(.easeInOut(duration: 0.25)) { panelBinding.wrappedValue = false }
            focusBinding.wrappedValue = -1
            return true
        }
        view.onLeftArrow = {
            guard panelBinding.wrappedValue else { return false }
            withAnimation(.easeInOut(duration: 0.15)) {
                switch tabBinding.wrappedValue {
                case .video:
                    withAnimation(.easeInOut(duration: 0.25)) { panelBinding.wrappedValue = false }
                case .audio: tabBinding.wrappedValue = .video
                case .subtitles: tabBinding.wrappedValue = .audio
                }
            }
            focusBinding.wrappedValue = -1
            return true
        }
        view.onRightArrow = {
            guard panelBinding.wrappedValue else { return false }
            withAnimation(.easeInOut(duration: 0.15)) {
                switch tabBinding.wrappedValue {
                case .video: tabBinding.wrappedValue = .audio
                case .audio: tabBinding.wrappedValue = .subtitles
                case .subtitles: break
                }
            }
            focusBinding.wrappedValue = -1
            return true
        }
        view.onDownArrow = {
            guard panelBinding.wrappedValue else { return false }
            let maxIndex = (self.tvTrackCountProvider?() ?? 0) - 1
            if maxIndex >= 0 && focusBinding.wrappedValue < maxIndex {
                focusBinding.wrappedValue += 1
            }
            return true
        }
        view.onSelectOverride = {
            guard panelBinding.wrappedValue else { return false }
            self.tvSelectTrack?()
            return true
        }
    }

    private func applySettingsCallbacks(to view: MPVPlayerGLView) {
        let panelBinding = $showSettingsPanel
        let tabBinding = $settingsTab
        let focusBinding = $tvFocusedTrackIndex
        let openSettings = onOpenSettings
        view.onUpArrow = openSettings
        view.onMenuOverride = {
            print("[tvOS] onMenuOverride called, panelOpen=\(panelBinding.wrappedValue)")
            guard panelBinding.wrappedValue else { return false }
            withAnimation(.easeInOut(duration: 0.25)) { panelBinding.wrappedValue = false }
            focusBinding.wrappedValue = -1
            return true
        }
        view.onLeftArrow = {
            guard panelBinding.wrappedValue else { return false }
            withAnimation(.easeInOut(duration: 0.15)) {
                switch tabBinding.wrappedValue {
                case .video:
                    withAnimation(.easeInOut(duration: 0.25)) { panelBinding.wrappedValue = false }
                case .audio: tabBinding.wrappedValue = .video
                case .subtitles: tabBinding.wrappedValue = .audio
                }
            }
            focusBinding.wrappedValue = -1
            return true
        }
        view.onRightArrow = {
            guard panelBinding.wrappedValue else { return false }
            withAnimation(.easeInOut(duration: 0.15)) {
                switch tabBinding.wrappedValue {
                case .video: tabBinding.wrappedValue = .audio
                case .audio: tabBinding.wrappedValue = .subtitles
                case .subtitles: break
                }
            }
            focusBinding.wrappedValue = -1
            return true
        }
        view.onDownArrow = {
            guard panelBinding.wrappedValue else { return false }
            let maxIndex = (self.tvTrackCountProvider?() ?? 0) - 1
            if maxIndex >= 0 && focusBinding.wrappedValue < maxIndex {
                focusBinding.wrappedValue += 1
            }
            return true
        }
        view.onSelectOverride = {
            guard panelBinding.wrappedValue else { return false }
            self.tvSelectTrack?()
            return true
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
    let isRecordingInProgress: Bool

    var onPlaybackEnded: (() -> Void)?
    var onVideoInfoUpdate: ((String?, Int?, String?, String?, Int64, String?, Double) -> Void)?
    @Binding var cleanupAction: (() -> Void)?
    @Binding var pixelBufferViewRef: MPVPlayerPixelBufferView?
    @Binding var getTrackListFunc: (() -> [MPVTrack])?
    @Binding var setAudioTrackFunc: ((Int) -> Void)?
    @Binding var setSubtitleTrackFunc: ((Int?) -> Void)?
    @Binding var getSubtitleTextFunc: (() -> String?)?

    private func configureCommonCallbacks(for view: MPVPlayerGLView) {
        view.setup(errorBinding: $errorMessage, isRecordingInProgress: isRecordingInProgress)
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
        view.setup(errorBinding: $errorMessage, isRecordingInProgress: isRecordingInProgress)
        view.onPositionUpdate = { position, dur in
            DispatchQueue.main.async {
                self.currentPosition = position
                self.duration = dur
            }
        }
        view.onPlaybackEnded = onPlaybackEnded
        view.onVideoInfoUpdate = onVideoInfoUpdate
    }

    private func configureCommonCallbacks(for view: MPVPlayerPixelBufferView) {
        view.setup(errorBinding: $errorMessage, isRecordingInProgress: isRecordingInProgress)
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
            self.getTrackListFunc = { view.getTrackList() }
            self.setAudioTrackFunc = { view.setAudioTrack($0) }
            self.setSubtitleTrackFunc = { view.setSubtitleTrack($0) }
            self.getSubtitleTextFunc = { view.getSubtitleText() }
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
            self.getTrackListFunc = { view.getTrackList() }
            self.setAudioTrackFunc = { view.setAudioTrack($0) }
            self.setSubtitleTrackFunc = { view.setSubtitleTrack($0) }
            self.getSubtitleTextFunc = { view.getSubtitleText() }
        }
    }

    private func setupSeekBindings(for view: MPVPlayerPixelBufferView) {
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
            self.getTrackListFunc = { view.getTrackList() }
            self.setAudioTrackFunc = { view.setAudioTrack($0) }
            self.setSubtitleTrackFunc = { view.setSubtitleTrack($0) }
            self.getSubtitleTextFunc = { view.getSubtitleText() }
        }
    }

    func makeUIView(context: Context) -> UIView {
        let gpuAPI = UserPreferences.load().iosGPUAPI

        if gpuAPI == .pixelbuffer {
            let view = MPVPlayerPixelBufferView(frame: .zero)
            configureCommonCallbacks(for: view)
            view.loadURL(url)
            view.startPositionPolling()
            if isRecordingInProgress {
                view.startRecordingMonitor(url: url)
                view.recordingMonitor?.onRecordingFinished = {
                    print("Recording completed, normal playback mode")
                }
            }
            context.coordinator.playerView = view
            DispatchQueue.main.async {
                self.cleanupAction = { view.cleanup() }
                self.pixelBufferViewRef = view
            }
            setupSeekBindings(for: view)
            return view
        }

        if gpuAPI == .metal {
            let view = MPVPlayerMetalView(frame: .zero)
            configureCommonCallbacks(for: view)
            view.loadURL(url)
            view.startPositionPolling()
            if isRecordingInProgress {
                view.startRecordingMonitor(url: url)
                view.recordingMonitor?.onRecordingFinished = {
                    print("Recording completed, normal playback mode")
                }
            }
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
        if isRecordingInProgress {
            view.startRecordingMonitor(url: url)
            view.recordingMonitor?.onRecordingFinished = {
                print("Recording completed, normal playback mode")
            }
        }
        context.coordinator.playerView = view
        DispatchQueue.main.async {
            self.cleanupAction = { view.cleanup() }
        }
        setupSeekBindings(for: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let pbView = uiView as? MPVPlayerPixelBufferView {
            if isPlaying { pbView.play() } else { pbView.pause() }
            return
        }
        if let metalView = uiView as? MPVPlayerMetalView {
            if isPlaying { metalView.play() } else { metalView.pause() }
            return
        }
        if let glView = uiView as? MPVPlayerGLView {
            if isPlaying { glView.play() } else { glView.pause() }
            return
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let pbView = uiView as? MPVPlayerPixelBufferView {
            pbView.cleanup()
        } else if let metalView = uiView as? MPVPlayerMetalView {
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
    var onVideoInfoUpdate: ((String?, Int?, String?, String?, Int64, String?, Double) -> Void)?
    var recordingMonitor: MPVRecordingMonitor? { player?.recordingMonitor }

    #if os(tvOS)
    // tvOS remote control callbacks
    var onPlayPause: (() -> Void)?
    var onSeekForward: (() -> Void)?
    var onSeekBackward: (() -> Void)?
    var onSelect: (() -> Void)?
    var onMenu: (() -> Void)?
    var onUpArrow: (() -> Void)?
    var onLeftArrow: (() -> Bool)?
    var onRightArrow: (() -> Bool)?
    var onDownArrow: (() -> Bool)?
    var onSelectOverride: (() -> Bool)?
    var onMenuOverride: (() -> Bool)?
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

        #if os(tvOS)
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right, .up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipe.direction = direction
            addGestureRecognizer(swipe)
        }
        #endif
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

    func setup(errorBinding: Binding<String?>?, isRecordingInProgress: Bool = false) {
        player = MPVPlayerCore()
        guard let success = player?.setup(errorBinding: errorBinding, isRecordingInProgress: isRecordingInProgress), success else {
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
        player?.onVideoInfoUpdate = { [weak self] codec, height, hwdec, audioChannels, dropped, gamma, fps in
            self?.onVideoInfoUpdate?(codec, height, hwdec, audioChannels, dropped, gamma, fps)
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

    func startRecordingMonitor(url: URL) {
        player?.startRecordingMonitor(url: url)
    }

    func startPositionPolling() {
        player?.startPositionPolling()
    }

    func getTrackList() -> [MPVTrack] { player?.getTrackList() ?? [] }
    func setAudioTrack(_ trackId: Int) { player?.setAudioTrack(trackId) }
    func setSubtitleTrack(_ trackId: Int?) { player?.setSubtitleTrack(trackId) }
    func getSubtitleText() -> String? { player?.getSubtitleText() }

    func cleanup() {
        player?.destroy()
        player = nil
        onPositionUpdate = nil
        onPlaybackEnded = nil
        onVideoInfoUpdate = nil
    }

    #if os(tvOS)
    private var seekTimer: Timer?
    private var seekDirection: Int = 0

    private func startSeeking(direction: Int) {
        stopSeeking()
        seekDirection = direction
        if direction < 0 {
            onSeekBackward?()
        } else {
            onSeekForward?()
        }
        seekTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.seekDirection < 0 {
                self.onSeekBackward?()
            } else {
                self.onSeekForward?()
            }
        }
    }

    private func stopSeeking() {
        seekTimer?.invalidate()
        seekTimer = nil
        seekDirection = 0
    }

    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        switch gesture.direction {
        case .left:
            if onLeftArrow?() != true {
                onSeekBackward?()
            }
        case .right:
            if onRightArrow?() != true {
                onSeekForward?()
            }
        case .up:
            onUpArrow?()
        case .down:
            _ = onDownArrow?()
        default:
            break
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .playPause:
                onPlayPause?()
                return
            case .leftArrow:
                if onLeftArrow?() != true {
                    startSeeking(direction: -1)
                }
                return
            case .rightArrow:
                if onRightArrow?() != true {
                    startSeeking(direction: 1)
                }
                return
            case .upArrow:
                onUpArrow?()
                return
            case .downArrow:
                onDownArrow?()
                return
            case .select:
                if onSelectOverride?() != true {
                    onSelect?()
                }
                return
            case .menu:
                print("[tvOS] menu pressed, hasOverride=\(onMenuOverride != nil)")
                if onMenuOverride?() != true {
                    onMenu?()
                }
                return
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .leftArrow || press.type == .rightArrow {
                return
            }
        }
        super.pressesChanged(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .leftArrow || press.type == .rightArrow {
                stopSeeking()
                return
            }
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopSeeking()
        super.pressesCancelled(presses, with: event)
    }
    #endif
}
#endif

// MARK: - iOS/tvOS OpenGL ES View

#if os(iOS) || os(tvOS)
class MPVPlayerPixelBufferView: UIView {
    private let session = ActivePlayerSession.shared
    var isPaused: Bool { session.player?.isPaused ?? true }
    var onPositionUpdate: ((Double, Double) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var onVideoInfoUpdate: ((String?, Int?, String?, String?, Int64, String?, Double) -> Void)?
    var recordingMonitor: MPVRecordingMonitor? { session.player?.recordingMonitor }
    private(set) var isReconnected = false

    #if os(tvOS)
    var onPlayPause: (() -> Void)?
    var onSeekForward: (() -> Void)?
    var onSeekBackward: (() -> Void)?
    var onSelect: (() -> Void)?
    var onMenu: (() -> Void)?
    var onUpArrow: (() -> Void)?
    var onLeftArrow: (() -> Bool)?
    var onRightArrow: (() -> Bool)?
    var onDownArrow: (() -> Bool)?
    var onSelectOverride: (() -> Bool)?
    var onMenuOverride: (() -> Bool)?
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
        isOpaque = true
        backgroundColor = .black
        isUserInteractionEnabled = true
        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let displayLayer = session.displayLayer
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.frame = bounds
        layer.addSublayer(displayLayer)

        #if os(tvOS)
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right, .up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipe.direction = direction
            addGestureRecognizer(swipe)
        }
        #endif
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if session.displayLayer.superlayer !== layer {
            layer.addSublayer(session.displayLayer)
        }
        session.displayLayer.frame = bounds
    }

    func setup(errorBinding: Binding<String?>?, isRecordingInProgress: Bool = false) {
        if session.hasActiveSession {
            isReconnected = true
            wireCallbacks()
            DispatchQueue.main.async { [weak self] in
                self?.onPlaybackEnded = nil // Don't re-trigger ended on reconnect
            }
            return
        }

        #if os(iOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        let bridge = MPVPixelBufferBridge(displayLayer: session.displayLayer)
        bridge.attach()

        let player = MPVPlayerCore()
        guard player.setup(errorBinding: errorBinding, isRecordingInProgress: isRecordingInProgress) else {
            return
        }

        session.createSession(player: player, bridge: bridge)
        wireCallbacks()
    }

    private func wireCallbacks() {
        session.player?.onPositionUpdate = { [weak self] position, duration in
            self?.onPositionUpdate?(position, duration)
        }
        session.player?.onPlaybackEnded = { [weak self] in
            self?.onPlaybackEnded?()
        }
        session.player?.onVideoInfoUpdate = { [weak self] codec, width, hwdec, audioChannels, dropped, gamma, fps in
            self?.onVideoInfoUpdate?(codec, width, hwdec, audioChannels, dropped, gamma, fps)
        }
    }

    func loadURL(_ url: URL) {
        guard !isReconnected else { return }
        session.player?.loadURL(url)
    }

    func play() { session.player?.play() }
    func pause() { session.player?.pause() }

    func seek(seconds: Int) {
        session.player?.seek(seconds: seconds)
        Task { @MainActor in session.bridge?.flush() }
    }

    func seekTo(position: Double) {
        session.player?.seekTo(position: position)
        Task { @MainActor in session.bridge?.flush() }
    }

    func startRecordingMonitor(url: URL) {
        session.player?.startRecordingMonitor(url: url)
    }

    func startPositionPolling() {
        session.player?.startPositionPolling()
    }

    func getTrackList() -> [MPVTrack] { session.player?.getTrackList() ?? [] }
    func setAudioTrack(_ trackId: Int) { session.player?.setAudioTrack(trackId) }
    func setSubtitleTrack(_ trackId: Int?) { session.player?.setSubtitleTrack(trackId) }
    func getSubtitleText() -> String? { session.player?.getSubtitleText() }

    func cleanup() {
        if session.isPiPActive {
            session.detachFromView()
            onPositionUpdate = nil
            onPlaybackEnded = nil
            onVideoInfoUpdate = nil
            return
        }
        session.teardown()
        onPositionUpdate = nil
        onPlaybackEnded = nil
        onVideoInfoUpdate = nil
    }

    #if os(tvOS)
    private var seekTimer: Timer?
    private var seekDirection: Int = 0

    private func startSeeking(direction: Int) {
        stopSeeking()
        seekDirection = direction
        if direction < 0 {
            onSeekBackward?()
        } else {
            onSeekForward?()
        }
        seekTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.seekDirection < 0 {
                self.onSeekBackward?()
            } else {
                self.onSeekForward?()
            }
        }
    }

    private func stopSeeking() {
        seekTimer?.invalidate()
        seekTimer = nil
        seekDirection = 0
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            DispatchQueue.main.async {
                self.setNeedsFocusUpdate()
                self.updateFocusIfNeeded()
            }
        }
    }

    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        switch gesture.direction {
        case .left:
            if onLeftArrow?() != true {
                onSeekBackward?()
            }
        case .right:
            if onRightArrow?() != true {
                onSeekForward?()
            }
        case .up:
            onUpArrow?()
        case .down:
            _ = onDownArrow?()
        default:
            break
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .playPause:
                onPlayPause?()
                return
            case .leftArrow:
                if onLeftArrow?() != true {
                    startSeeking(direction: -1)
                }
                return
            case .rightArrow:
                if onRightArrow?() != true {
                    startSeeking(direction: 1)
                }
                return
            case .upArrow:
                onUpArrow?()
                return
            case .downArrow:
                onDownArrow?()
                return
            case .select:
                if onSelectOverride?() != true {
                    onSelect?()
                }
                return
            case .menu:
                print("[tvOS] menu pressed, hasOverride=\(onMenuOverride != nil)")
                if onMenuOverride?() != true {
                    onMenu?()
                }
                return
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .leftArrow || press.type == .rightArrow {
                return
            }
        }
        super.pressesChanged(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .leftArrow || press.type == .rightArrow {
                stopSeeking()
                return
            }
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopSeeking()
        super.pressesCancelled(presses, with: event)
    }
    #endif
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
    var onVideoInfoUpdate: ((String?, Int?, String?, String?, Int64, String?, Double) -> Void)?
    var recordingMonitor: MPVRecordingMonitor? { player?.recordingMonitor }
    #if os(tvOS)
    var onPlayPause: (() -> Void)?
    var onSeekForward: (() -> Void)?
    var onSeekBackward: (() -> Void)?
    var onSelect: (() -> Void)?
    var onMenu: (() -> Void)?
    var onUpArrow: (() -> Void)?
    var onLeftArrow: (() -> Bool)?
    var onRightArrow: (() -> Bool)?
    var onDownArrow: (() -> Bool)?
    var onSelectOverride: (() -> Bool)?
    var onMenuOverride: (() -> Bool)?
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
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right, .up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipe.direction = direction
            addGestureRecognizer(swipe)
        }
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

    func setup(errorBinding: Binding<String?>?, isRecordingInProgress: Bool = false) {
        player = MPVPlayerCore()
        guard let success = player?.setup(errorBinding: errorBinding, isRecordingInProgress: isRecordingInProgress), success else {
            return
        }
        player?.createRenderContext(view: self)
        player?.onPositionUpdate = { [weak self] position, duration in
            self?.onPositionUpdate?(position, duration)
        }
        player?.onPlaybackEnded = { [weak self] in
            self?.onPlaybackEnded?()
        }
        player?.onVideoInfoUpdate = { [weak self] codec, height, hwdec, audioChannels, dropped, gamma, fps in
            self?.onVideoInfoUpdate?(codec, height, hwdec, audioChannels, dropped, gamma, fps)
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

    func startRecordingMonitor(url: URL) {
        player?.startRecordingMonitor(url: url)
    }

    func startPositionPolling() {
        player?.startPositionPolling()
    }

    func getTrackList() -> [MPVTrack] { player?.getTrackList() ?? [] }
    func setAudioTrack(_ trackId: Int) { player?.setAudioTrack(trackId) }
    func setSubtitleTrack(_ trackId: Int?) { player?.setSubtitleTrack(trackId) }
    func getSubtitleText() -> String? { player?.getSubtitleText() }

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
    private var seekTimer: Timer?
    private var seekDirection: Int = 0

    private func startSeeking(direction: Int) {
        stopSeeking()
        seekDirection = direction
        if direction < 0 {
            onSeekBackward?()
        } else {
            onSeekForward?()
        }
        seekTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.seekDirection < 0 {
                self.onSeekBackward?()
            } else {
                self.onSeekForward?()
            }
        }
    }

    private func stopSeeking() {
        seekTimer?.invalidate()
        seekTimer = nil
        seekDirection = 0
    }

    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        switch gesture.direction {
        case .left:
            if onLeftArrow?() != true {
                onSeekBackward?()
            }
        case .right:
            if onRightArrow?() != true {
                onSeekForward?()
            }
        case .up:
            onUpArrow?()
        case .down:
            _ = onDownArrow?()
        default:
            break
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .playPause:
                onPlayPause?()
                return
            case .leftArrow:
                if onLeftArrow?() != true {
                    startSeeking(direction: -1)
                }
                return
            case .rightArrow:
                if onRightArrow?() != true {
                    startSeeking(direction: 1)
                }
                return
            case .upArrow:
                onUpArrow?()
                return
            case .downArrow:
                onDownArrow?()
                return
            case .select:
                if onSelectOverride?() != true {
                    onSelect?()
                }
                return
            case .menu:
                print("[tvOS] menu pressed, hasOverride=\(onMenuOverride != nil)")
                if onMenuOverride?() != true {
                    onMenu?()
                }
                return
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .leftArrow || press.type == .rightArrow {
                return
            }
        }
        super.pressesChanged(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .leftArrow || press.type == .rightArrow {
                stopSeeking()
                return
            }
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopSeeking()
        super.pressesCancelled(presses, with: event)
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
