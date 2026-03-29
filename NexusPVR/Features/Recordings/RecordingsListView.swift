//
//  RecordingsListView.swift
//  nextpvr-apple-client
//
//  Recordings list view
//

import SwiftUI

struct RecordingsListView: View {
    @EnvironmentObject private var client: PVRClient
    @EnvironmentObject private var appState: AppState
    @State private var selectedRecording: Recording?
    @State private var deleteError: String?

    var body: some View {
        RecordingsListContentView(
            client: client,
            appState: appState,
            selectedRecording: $selectedRecording,
            deleteError: $deleteError
        )
    }
}

private struct RecordingsListContentView: View {
    @ObservedObject var client: PVRClient
    @ObservedObject var appState: AppState
    @StateObject private var viewModel: RecordingsViewModel
    @Binding var selectedRecording: Recording?
    @Binding var deleteError: String?
    @State private var inProgressRecording: Recording?
    @State private var resumeRecording: Recording?
    @State private var filterSelection: RecordingsFilter = .completed
    @State private var suppressNextFilterSelectionChange = false
    private static let seriesDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()
    private static let seriesTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init(client: PVRClient, appState: AppState,
         selectedRecording: Binding<Recording?>,
         deleteError: Binding<String?>) {
        self.client = client
        self.appState = appState
        self._selectedRecording = selectedRecording
        self._deleteError = deleteError
        self._viewModel = StateObject(wrappedValue: RecordingsViewModel(client: client))
    }

    @Environment(\.scenePhase) private var scenePhase
    #if os(tvOS)
    @Environment(\.requestSidebarFocus) private var requestSidebarFocus
    #endif

    private var recordingsNavigationTitle: String {
        if appState.showingRecordingsSeriesList {
            return "Series"
        }
        if appState.hasSelectedRecordingsSeries {
            return appState.selectedRecordingsSeriesName
        }
        return appState.recordingsFilter.rawValue
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker (tvOS and macOS only — iOS uses floating nav bar picker)
                #if os(macOS)
                Picker("Filter", selection: $filterSelection) {
                    if viewModel.hasActiveRecordings {
                        Text("Recording").tag(RecordingsFilter.recording)
                    }
                    Text("Completed").tag(RecordingsFilter.completed)
                    Text("Scheduled").tag(RecordingsFilter.scheduled)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("recordings-filter")
                .padding(.horizontal)
                .padding(.vertical, Theme.spacingSM)
                .background(Theme.background)
                .onChange(of: filterSelection) {
                    if suppressNextFilterSelectionChange {
                        suppressNextFilterSelectionChange = false
                        return
                    }
                    appState.setRecordingsFilter(filterSelection, userInitiated: true)
                    Task { viewModel.filter = filterSelection }
                }
                .onChange(of: viewModel.filter) {
                    if filterSelection != viewModel.filter {
                        suppressNextFilterSelectionChange = true
                        filterSelection = viewModel.filter
                    }
                }
                #endif

                // Content
                Group {
                    if viewModel.isLoading &&
                        viewModel.filteredRecordings.isEmpty &&
                        !appState.hasSelectedRecordingsSeries &&
                        appState.recordingsSeriesItems.isEmpty {
                        loadingView
                    } else if let error = viewModel.error,
                              viewModel.filteredRecordings.isEmpty,
                              !appState.hasSelectedRecordingsSeries,
                              appState.recordingsSeriesItems.isEmpty {
                        errorView(error)
                    } else if appState.showingRecordingsSeriesList {
                        seriesIndexList(viewModel)
                    } else if appState.hasSelectedRecordingsSeries {
                        seriesDetailList(viewModel, seriesName: appState.selectedRecordingsSeriesName)
                    } else if viewModel.filteredRecordings.isEmpty {
                        emptyView(viewModel)
                    } else {
                        recordingsList(viewModel)
                    }
                }
            }
            .accessibilityIdentifier("recordings-view")
            #if os(iOS)
            .sidebarMenuToolbar()
            .navigationTitle(recordingsNavigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(item: $selectedRecording) { recording in
                RecordingDetailView(recording: recording)
                    .environmentObject(client)
                    .environmentObject(appState)
            }
            .confirmationDialog("Play Recording", isPresented: .constant(inProgressRecording != nil), presenting: inProgressRecording) { recording in
                #if !DISPATCHERPVR
                let canPlay = UserPreferences.load().currentGPUAPI == .pixelbuffer
                Button(canPlay ? "Play from Beginning" : "Play from Beginning (requires PixelBuffer)") {
                    playRecordingFromBeginning(recording)
                    inProgressRecording = nil
                }
                .disabled(!canPlay)
                if let position = recording.playbackPosition, position > 10 {
                    Button(canPlay ? "Resume" : "Resume (requires PixelBuffer)") {
                        playRecording(recording)
                        inProgressRecording = nil
                    }
                    .disabled(!canPlay)
                }
                #endif
                if recording.channelId != nil {
                    Button("Watch Live") {
                        playRecordingLive(recording)
                        inProgressRecording = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    inProgressRecording = nil
                }
            } message: { recording in
                let canPlay = UserPreferences.load().currentGPUAPI == .pixelbuffer
                if canPlay {
                    Text("\(recording.name) is currently recording.")
                } else {
                    Text("Watching in-progress recordings requires the PixelBuffer renderer. You can change this in Settings > Playback.")
                }
            }
            .alert("Error", isPresented: .constant(deleteError != nil)) {
                Button("OK") { deleteError = nil }
            } message: {
                if let error = deleteError {
                    Text(error)
                }
            }
            #if os(tvOS)
            .onExitCommand {
                requestSidebarFocus()
            }
            #endif
        }
        #if os(tvOS)
        .background(.ultraThinMaterial)
        #else
        .background(Theme.background)
        #endif
        .task {
            // Apply user-selected filter before loading so the view shows the correct tab
            if appState.recordingsFilterUserOverride {
                viewModel.filter = appState.recordingsFilter
            }
            await reloadRecordings()
            if !appState.recordingsFilterUserOverride {
                let initialFilter: RecordingsFilter = viewModel.hasActiveRecordings ? .recording : .completed
                if viewModel.filter != initialFilter {
                    viewModel.filter = initialFilter
                }
                if appState.recordingsFilter != initialFilter {
                    appState.recordingsFilter = initialFilter
                }
            }
            if appState.recordingsFilter != viewModel.filter {
                appState.recordingsFilter = viewModel.filter
            }
            if filterSelection != viewModel.filter {
                suppressNextFilterSelectionChange = true
                filterSelection = viewModel.filter
            }
        }
        .onChange(of: appState.recordingsFilter) {
            if viewModel.filter != appState.recordingsFilter {
                Task { viewModel.filter = appState.recordingsFilter }
            }
        }
        .onChange(of: viewModel.filter) {
            if appState.recordingsFilter != viewModel.filter {
                appState.recordingsFilter = viewModel.filter
            }
            if filterSelection != viewModel.filter {
                suppressNextFilterSelectionChange = true
                filterSelection = viewModel.filter
            }
        }
        .onChange(of: viewModel.hasActiveRecordings) {
            syncAppStateFromViewModel()
        }
        .onChange(of: viewModel.completedRecordings) {
            syncAppStateFromViewModel()
        }
        .onChange(of: viewModel.scheduledRecordings) {
            syncAppStateFromViewModel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingsDidChange)) { _ in
            Task {
                await reloadRecordings()
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                Task { await reloadRecordings() }
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: Theme.spacingMD) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(Theme.accent)
            Text("Loading recordings...")
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: Theme.spacingMD) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(Theme.warning)
            Text("Unable to load recordings")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(error)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task { await viewModel.loadRecordings() }
            }
            .buttonStyle(AccentButtonStyle())
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyView(_ vm: RecordingsViewModel) -> some View {
        VStack(spacing: Theme.spacingMD) {
            Image(systemName: "recordingtape")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textTertiary)
            Text("No recordings")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(emptyMessage(for: vm.filter))
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyMessage(for filter: RecordingsFilter) -> String {
        switch filter {
        case .completed:
            return "No completed recordings."
        case .recording:
            return "No recordings in progress."
        case .scheduled:
            return "No scheduled recordings."
        }
    }

    private func syncAppStateFromViewModel() {
        appState.activeRecordingCount = viewModel.activeRecordings.count
        appState.recordingsSeriesItems = viewModel.recordingsSeriesSummaries.map {
            RecordingsSeriesItem(name: $0.name, count: $0.totalCount)
        }
    }

    private func episodeDescription(for recording: Recording) -> String? {
        guard let raw = recording.desc?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    private func seriesDateTimeRangeText(for recording: Recording) -> String? {
        guard let start = recording.startDate else { return nil }
        let dateText = Self.seriesDateFormatter.string(from: start)
        let startText = Self.seriesTimeFormatter.string(from: start)
        if let end = recording.endDate {
            let endText = Self.seriesTimeFormatter.string(from: end)
            return "\(dateText) - \(startText) - \(endText)"
        }
        return "\(dateText) - \(startText)"
    }

    private func reloadRecordings() async {
        appState.recordingsSeriesIsLoading = true
        await viewModel.loadRecordings()
        syncAppStateFromViewModel()
        appState.recordingsSeriesIsLoading = false
    }

    private func selectSeriesRecording(_ recording: Recording) {
        if recording.recordingStatus == .recording {
            inProgressRecording = recording
        } else if recording.recordingStatus.isPlayable {
            if recording.hasResumePosition && !recording.isWatched {
                resumeRecording = recording
            } else {
                playRecording(recording)
            }
        } else {
            selectedRecording = recording
        }
    }

    @ViewBuilder
    private func recordingContextMenu(for recording: Recording) -> some View {
        if recording.recordingStatus == .recording {
            #if !DISPATCHERPVR
            let canPlay = UserPreferences.load().currentGPUAPI == .pixelbuffer
            Button {
                playRecordingFromBeginning(recording)
            } label: {
                Label(canPlay ? "Play from Beginning" : "Play from Beginning (requires PixelBuffer)", systemImage: "play.fill")
            }
            .disabled(!canPlay)
            if let position = recording.playbackPosition, position > 10 {
                Button {
                    playRecording(recording)
                } label: {
                    Label(canPlay ? "Resume" : "Resume (requires PixelBuffer)", systemImage: "arrow.clockwise")
                }
                .disabled(!canPlay)
            }
            #endif
            if recording.channelId != nil {
                Button {
                    playRecordingLive(recording)
                } label: {
                    Label("Watch Live", systemImage: "dot.radiowaves.left.and.right")
                }
            }
        } else if recording.recordingStatus.isPlayable {
            Button {
                playRecording(recording)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            if recording.hasResumePosition {
                Button {
                    playRecordingFromBeginning(recording)
                } label: {
                    Label("Watch from Beginning", systemImage: "arrow.counterclockwise")
                }
            }
        }

        Button {
            selectedRecording = recording
        } label: {
            Label("Details", systemImage: "info.circle")
        }
    }

    private func recordingsList(_ vm: RecordingsViewModel) -> some View {
        #if os(tvOS)
        let channelIdByName = buildChannelIdByNameMap(from: vm.standaloneRecordings)
        return ScrollView {
            LazyVStack(spacing: Theme.spacingMD) {
                ForEach(vm.standaloneRecordings) { recording in
                    tvOSRecordingRow(recording, channelIdByName: channelIdByName)
                }
            }
            .padding()
        }
        .onExitCommand {
            requestSidebarFocus()
        }
        #else
        List {
            ForEach(vm.standaloneRecordings) { recording in
                iOSRecordingRow(recording)
            }

            #if os(iOS)
            Color.clear
                .frame(height: 96)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            #endif
        }
        .listStyle(.plain)
        .refreshable {
            await reloadRecordings()
        }
        #endif
    }

    private func seriesDetailList(_ vm: RecordingsViewModel, seriesName: String) -> some View {
        let summary = vm.seriesSummary(named: seriesName)
        let representativeRecordingId = summary?.completed.first?.id ?? summary?.scheduled.first?.id
        let resolvedBannerURLString =
            summary?.bannerURL ??
            representativeRecordingId.flatMap { client.recordingArtworkURL(recordingId: $0, fanart: true)?.absoluteString }
        let resolvedLeftArtworkURLString =
            representativeRecordingId.flatMap { client.recordingArtworkURL(recordingId: $0, fanart: false)?.absoluteString } ??
            resolvedBannerURLString
        #if os(tvOS)
        let recordings = (summary?.completed ?? []) + (summary?.scheduled ?? [])
        let channelIdByName = buildChannelIdByNameMap(from: recordings)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.spacingMD) {
                if let summary {
                    let inlineCompletedCount = min(3, summary.completed.count)
                    let inlineScheduledCount = min(3 - inlineCompletedCount, summary.scheduled.count)
                    let inlineCompleted = Array(summary.completed.prefix(inlineCompletedCount))
                    let inlineScheduled = Array(summary.scheduled.prefix(inlineScheduledCount))

                    if resolvedLeftArtworkURLString != nil || !inlineCompleted.isEmpty || !inlineScheduled.isEmpty {
                        seriesInlineTopRowTV(
                            artworkURLString: resolvedLeftArtworkURLString,
                            inlineCompleted: inlineCompleted,
                            inlineScheduled: inlineScheduled
                        )
                    }

                    let remainingCompleted = Array(summary.completed.dropFirst(inlineCompletedCount))
                    let remainingScheduled = Array(summary.scheduled.dropFirst(inlineScheduledCount))

                    if !remainingCompleted.isEmpty {
                        sectionHeaderTV("Completed")
                        ForEach(remainingCompleted) { recording in
                            tvOSSeriesRecordingRow(recording, channelIdByName: channelIdByName)
                        }
                    }
                    if !remainingScheduled.isEmpty {
                        sectionHeaderTV("Scheduled")
                        ForEach(remainingScheduled) { recording in
                            tvOSSeriesRecordingRow(recording, channelIdByName: channelIdByName)
                        }
                    }
                    if summary.totalCount == 0 {
                        emptySeriesView(seriesName: seriesName)
                    }
                } else {
                    emptySeriesView(seriesName: seriesName)
                }
            }
            .padding()
        }
        .background(seriesFanartBackgroundTV(resolvedBannerURLString))
        #else
        return List {
            if let summary {
                if resolvedLeftArtworkURLString != nil {
                    let inlineCompletedCount = min(3, summary.completed.count)
                    let inlineScheduledCount = min(3 - inlineCompletedCount, summary.scheduled.count)
                    let inlineCompleted = Array(summary.completed.prefix(inlineCompletedCount))
                    let inlineScheduled = Array(summary.scheduled.prefix(inlineScheduledCount))

                    seriesInlineTopRow(
                        bannerURLString: resolvedLeftArtworkURLString,
                        inlineCompleted: inlineCompleted,
                        inlineScheduled: inlineScheduled
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    let remainingCompleted = Array(summary.completed.dropFirst(inlineCompletedCount))
                    let remainingScheduled = Array(summary.scheduled.dropFirst(inlineScheduledCount))

                    if !remainingCompleted.isEmpty {
                        sectionHeaderIOS("Completed")
                        ForEach(remainingCompleted) { recording in
                            seriesRecordingRow(recording)
                        }
                    }
                    if !remainingScheduled.isEmpty {
                        sectionHeaderIOS("Scheduled")
                        ForEach(remainingScheduled) { recording in
                            seriesRecordingRow(recording)
                        }
                    }
                } else {
                    if !summary.completed.isEmpty {
                        sectionHeaderIOS("Completed")
                        ForEach(summary.completed) { recording in
                            seriesRecordingRow(recording)
                        }
                    }
                    if !summary.scheduled.isEmpty {
                        sectionHeaderIOS("Scheduled")
                        ForEach(summary.scheduled) { recording in
                            seriesRecordingRow(recording)
                        }
                    }
                }

                if summary.totalCount == 0 {
                    emptySeriesView(seriesName: seriesName)
                }
            } else {
                emptySeriesView(seriesName: seriesName)
            }

            #if os(iOS)
            Color.clear
                .frame(height: 96)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            #endif
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(seriesFanartBackground(resolvedBannerURLString))
        .refreshable {
            await reloadRecordings()
        }
        #endif
    }

    @ViewBuilder
    private func seriesBannerView(_ bannerURLString: String?) -> some View {
        if let bannerURLString,
           let bannerURL = URL(string: bannerURLString) {
            CachedAsyncImage(url: bannerURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    Theme.surfaceHighlight
                    ProgressView()
                        .tint(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadiusMD)
                    .stroke(Theme.surfaceHighlight, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))
            .padding(.vertical, Theme.spacingSM)
        }
    }

    #if os(tvOS)
    @ViewBuilder
    private func seriesFanartBackgroundTV(_ bannerURLString: String?) -> some View {
        ZStack {
            if let bannerURLString,
               let bannerURL = URL(string: bannerURLString) {
                CachedAsyncImage(url: bannerURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .opacity(0.18)
                } placeholder: {
                    Color.clear
                }

                LinearGradient(
                    colors: [Color.black.opacity(0.10), Color.black.opacity(0.62)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .clipped()
    }

    private func seriesTopArtworkTV(_ artworkURLString: String?) -> some View {
        Group {
            if let artworkURLString,
               let artworkURL = URL(string: artworkURLString) {
                CachedAsyncImage(url: artworkURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    ZStack {
                        Theme.surfaceHighlight
                        ProgressView()
                            .tint(Theme.accent)
                    }
                }
                .frame(width: 300)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadiusMD)
                        .stroke(Theme.surfaceHighlight, lineWidth: 1)
                )
            }
        }
        .padding(.vertical, Theme.spacingSM)
    }

    private func seriesInlineTopRowTV(
        artworkURLString: String?,
        inlineCompleted: [Recording],
        inlineScheduled: [Recording]
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.spacingMD) {
            if artworkURLString != nil {
                seriesTopArtworkTV(artworkURLString)
                    .frame(width: 300, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                if !inlineCompleted.isEmpty {
                    Text("Completed")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    ForEach(inlineCompleted) { recording in
                        tvOSSeriesInlineRecordingRow(recording)
                    }
                }

                if !inlineScheduled.isEmpty {
                    Text("Scheduled")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.top, inlineCompleted.isEmpty ? 0 : Theme.spacingXS)
                    ForEach(inlineScheduled) { recording in
                        tvOSSeriesInlineRecordingRow(recording)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Theme.spacingSM)
    }

    private func tvOSSeriesInlineRecordingRow(_ recording: Recording) -> some View {
        Button {
            selectSeriesRecording(recording)
        } label: {
            HStack(alignment: .center, spacing: Theme.spacingSM) {
                RecordingStatusIcon(recording: recording, size: 36)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.spacingXS) {
                        if let series = recording.seriesInfo {
                            Text(series.shortDisplayString)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }

                        if let subtitle = recording.subtitle, !subtitle.isEmpty {
                            let cleaned = SeriesInfo.stripPattern(from: subtitle)
                            if !cleaned.isEmpty {
                                Text(cleaned)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                            } else {
                                Text(recording.cleanName)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                            }
                        } else {
                            Text(recording.cleanName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                        }
                    }

                    if let desc = episodeDescription(for: recording) {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }

                    if let dateTimeRange = seriesDateTimeRangeText(for: recording) {
                        Text(dateTimeRange)
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Theme.spacingSM)
            .padding(.vertical, Theme.spacingXS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.guideNowPlaying)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
        }
        .buttonStyle(TVRecordingSubtleButtonStyle())
    }
    #endif

    #if !os(tvOS)
    @ViewBuilder
    private func seriesFanartBackground(_ bannerURLString: String?) -> some View {
        ZStack {
            Theme.background
            if let bannerURLString,
               let bannerURL = URL(string: bannerURLString) {
                CachedAsyncImage(url: bannerURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .opacity(0.28)
                } placeholder: {
                    Color.clear
                }
                .ignoresSafeArea()

                LinearGradient(
                    colors: [Theme.background.opacity(0.04), Theme.background.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        }
    }
    #endif

    #if !os(tvOS)
    private func seriesInlineTopRow(
        bannerURLString: String?,
        inlineCompleted: [Recording],
        inlineScheduled: [Recording]
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.spacingMD) {
            if let bannerURLString,
               let bannerURL = URL(string: bannerURLString) {
                CachedAsyncImage(url: bannerURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    ZStack {
                        Theme.surfaceHighlight
                        ProgressView()
                            .tint(Theme.accent)
                    }
                }
                .frame(width: 180)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadiusMD)
                        .stroke(Theme.surfaceHighlight, lineWidth: 1)
                )
            }

            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                if !inlineCompleted.isEmpty {
                    Text("Completed")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    ForEach(inlineCompleted) { recording in
                        seriesInlineCompactRow(recording)
                    }
                }

                if !inlineScheduled.isEmpty {
                    Text("Scheduled")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, inlineCompleted.isEmpty ? 0 : Theme.spacingXS)
                    ForEach(inlineScheduled) { recording in
                        seriesInlineCompactRow(recording)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Theme.spacingSM)
    }

    private func seriesInlineCompactRow(_ recording: Recording) -> some View {
        HStack(alignment: .center, spacing: Theme.spacingSM) {
            RecordingStatusIcon(recording: recording, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: Theme.spacingXS) {
                    if let series = recording.seriesInfo {
                        Text(series.shortDisplayString)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    if let subtitle = recording.subtitle, !subtitle.isEmpty {
                        let cleaned = SeriesInfo.stripPattern(from: subtitle)
                        if !cleaned.isEmpty {
                            Text(cleaned)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(2)
                        }
                    } else {
                        Text(recording.cleanName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                    }
                }

                if let desc = episodeDescription(for: recording) {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                if let date = recording.startDate {
                    Text(date, style: .date)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, Theme.spacingSM)
        .padding(.vertical, Theme.spacingXS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.60))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
        .contentShape(Rectangle())
        .onTapGesture {
            selectSeriesRecording(recording)
        }
    }
    #endif

    private func seriesIndexList(_ vm: RecordingsViewModel) -> some View {
        #if os(tvOS)
        return ScrollView {
            LazyVStack(spacing: Theme.spacingMD) {
                ForEach(vm.recordingsSeriesSummaries) { summary in
                    Button {
                        appState.selectRecordingsSeries(named: summary.name, userInitiated: true)
                    } label: {
                        HStack(spacing: Theme.spacingMD) {
                            Image(systemName: "arrow.2.squarepath")
                                .foregroundStyle(Theme.accent)
                            Text(summary.name)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("(\(summary.totalCount))")
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, Theme.spacingMD)
                        .padding(.vertical, Theme.spacingSM)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                    }
                    .buttonStyle(.card)
                }
            }
            .padding()
        }
        #else
        return List {
            ForEach(vm.recordingsSeriesSummaries) { summary in
                Button {
                    appState.selectRecordingsSeries(named: summary.name, userInitiated: true)
                } label: {
                    HStack(spacing: Theme.spacingSM) {
                        Image(systemName: "arrow.2.squarepath")
                            .foregroundStyle(Theme.accent)
                        Text(summary.name)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("(\(summary.totalCount))")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .font(.headline)
                }
                .listRowBackground(Theme.surface)
            }

            #if os(iOS)
            Color.clear
                .frame(height: 96)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            #endif
        }
        .listStyle(.plain)
        .refreshable {
            await reloadRecordings()
        }
        #endif
    }

    #if os(tvOS)
    private func buildChannelIdByNameMap(from recordings: [Recording]) -> [String: Int] {
        var map: [String: Int] = [:]
        for recording in recordings {
            guard let channelId = recording.channelId,
                  let channelName = recording.channel?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !channelName.isEmpty else { continue }
            map[channelName.lowercased()] = channelId
        }
        return map
    }

    private func tvOSRecordingRow(_ recording: Recording, channelIdByName: [String: Int], showSeriesMeta: Bool = false) -> some View {
        let fallbackChannelId: Int? = {
            guard let name = recording.channel?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            return channelIdByName[name.lowercased()]
        }()

        return RecordingRowTV(
            recording: recording,
            fallbackChannelId: fallbackChannelId,
            onPlay: {
                if recording.recordingStatus == .recording {
                    inProgressRecording = recording
                } else if recording.hasResumePosition && !recording.isWatched {
                    resumeRecording = recording
                } else {
                    playRecording(recording)
                }
            },
            onShowDetails: { selectedRecording = recording },
            onDelete: { deleteRecording(recording) },
            showSeriesMeta: showSeriesMeta,
            durationMismatch: viewModel.durationMismatches[recording.id],
            durationVerified: viewModel.durationVerified.contains(recording.id),
            durationUnverifiable: viewModel.durationUnverifiable.contains(recording.id)
        )
        .padding(.leading, Theme.spacingMD)
        .contextMenu {
            recordingContextMenu(for: recording)
            Button(role: .destructive) {
                deleteRecording(recording)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .resumeDialog(recording: recording, resumeRecording: $resumeRecording, playRecording: playRecording, playFromBeginning: playRecordingFromBeginning)
    }

    private func tvOSSeriesRecordingRow(_ recording: Recording, channelIdByName: [String: Int]) -> some View {
        tvOSRecordingRow(recording, channelIdByName: channelIdByName, showSeriesMeta: true)
    }

    private func sectionHeaderTV(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.top, Theme.spacingMD)
            .padding(.leading, Theme.spacingMD)
    }

    private func emptySeriesView(seriesName: String) -> some View {
        VStack(spacing: Theme.spacingMD) {
            Image(systemName: "arrow.2.squarepath")
                .font(.system(size: 44))
                .foregroundStyle(Theme.textTertiary)
            Text("No recordings for \(seriesName).")
                .font(.headline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.spacingXL)
    }
    #else
    private func iOSRecordingRow(_ recording: Recording) -> some View {
        RecordingRow(
            recording: recording,
            durationMismatch: viewModel.durationMismatches[recording.id],
            durationVerified: viewModel.durationVerified.contains(recording.id),
            durationUnverifiable: viewModel.durationUnverifiable.contains(recording.id)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if recording.recordingStatus == .recording {
                inProgressRecording = recording
            } else if recording.recordingStatus.isPlayable {
                if recording.hasResumePosition && !recording.isWatched {
                    resumeRecording = recording
                } else {
                    playRecording(recording)
                }
            } else {
                selectedRecording = recording
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteRecording(recording)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            recordingContextMenu(for: recording)
            Divider()
            Button(role: .destructive) {
                deleteRecording(recording)
            } label: {
                Label(recording.recordingStatus.isScheduled ? "Cancel Recording" : "Delete", systemImage: "trash")
            }
        }
        .resumeDialog(recording: recording, resumeRecording: $resumeRecording, playRecording: playRecording, playFromBeginning: playRecordingFromBeginning)
        .listRowBackground(Color.clear)
    }

    private func seriesRecordingRow(_ recording: Recording) -> some View {
        HStack(alignment: .center, spacing: Theme.spacingMD) {
            RecordingStatusIcon(recording: recording, size: 44)

            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                HStack {
                    if let series = recording.seriesInfo {
                        Text(series.shortDisplayString)
                            .font(.headline)
                            .foregroundStyle(Theme.accent)
                    }

                    if let subtitle = recording.subtitle, !subtitle.isEmpty {
                        let cleaned = SeriesInfo.stripPattern(from: subtitle)
                        if !cleaned.isEmpty {
                            Text(cleaned)
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if let date = recording.startDate {
                        Text(date, style: .date)
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                if let desc = episodeDescription(for: recording) {
                    Text(desc)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.vertical, Theme.spacingXS)
        .padding(.horizontal, Theme.spacingSM)
        .background(Theme.surface.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
        .contentShape(Rectangle())
        .onTapGesture {
            if recording.recordingStatus == .recording {
                inProgressRecording = recording
            } else if recording.recordingStatus.isPlayable {
                if recording.hasResumePosition && !recording.isWatched {
                    resumeRecording = recording
                } else {
                    playRecording(recording)
                }
            } else {
                selectedRecording = recording
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteRecording(recording)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            recordingContextMenu(for: recording)
            Divider()
            Button(role: .destructive) {
                deleteRecording(recording)
            } label: {
                Label(recording.recordingStatus.isScheduled ? "Cancel Recording" : "Delete", systemImage: "trash")
            }
        }
        .resumeDialog(recording: recording, resumeRecording: $resumeRecording, playRecording: playRecording, playFromBeginning: playRecordingFromBeginning)
        .listRowBackground(Theme.surface)
    }

    private func sectionHeaderIOS(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(Theme.textPrimary)
            .textCase(nil)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private func emptySeriesView(seriesName: String) -> some View {
        VStack(spacing: Theme.spacingMD) {
            Image(systemName: "arrow.2.squarepath")
                .font(.system(size: 44))
                .foregroundStyle(Theme.textTertiary)
            Text("No recordings for \(seriesName).")
                .font(.headline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.spacingXL)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
    #endif

    private func playRecording(_ recording: Recording) {
        if recording.isWatched {
            playRecordingFromBeginning(recording)
            return
        }
        Task {
            do {
                // Use viewModel.playRecording for URL (handles stream URL logic)
                let url = try await viewModel.playRecording(recording)
                appState.playStream(
                    url: url,
                    title: recording.name,
                    recordingId: recording.id,
                    resumePosition: recording.playbackPosition,
                    isRecordingInProgress: recording.recordingStatus == .recording
                )
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private func playRecordingFromBeginning(_ recording: Recording) {
        viewModel.resetPlaybackPosition(for: recording.id)
        Task {
            do {
                try await RecordingPlaybackHelper.playFromBeginning(
                    recording: recording, using: client, appState: appState
                )
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private func playRecordingLive(_ recording: Recording) {
        Task {
            do {
                try await RecordingPlaybackHelper.playLive(
                    recording: recording, using: client, appState: appState
                )
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private func deleteRecording(_ recording: Recording) {
        Task {
            do {
                try await viewModel.deleteRecording(recording)
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }
}

private struct ResumeDialogModifier: ViewModifier {
    let recording: Recording
    @Binding var resumeRecording: Recording?
    let playRecording: (Recording) -> Void
    let playFromBeginning: (Recording) -> Void

    private var isPresented: Binding<Bool> {
        Binding(
            get: { resumeRecording?.id == recording.id },
            set: { if !$0 { resumeRecording = nil } }
        )
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Resume Playback", isPresented: isPresented) {
                Button("Resume") {
                    playRecording(recording)
                    resumeRecording = nil
                }
                Button("Watch from Beginning") {
                    playFromBeginning(recording)
                    resumeRecording = nil
                }
                Button("Cancel", role: .cancel) {
                    resumeRecording = nil
                }
            } message: {
                if let position = recording.playbackPosition {
                    let minutes = position / 60
                    let seconds = position % 60
                    Text("\(recording.name)\nStopped at \(minutes):\(String(format: "%02d", seconds))")
                }
            }
    }
}

private extension View {
    func resumeDialog(recording: Recording, resumeRecording: Binding<Recording?>, playRecording: @escaping (Recording) -> Void, playFromBeginning: @escaping (Recording) -> Void) -> some View {
        modifier(ResumeDialogModifier(recording: recording, resumeRecording: resumeRecording, playRecording: playRecording, playFromBeginning: playFromBeginning))
    }
}

#Preview {
    RecordingsListView()
        .environmentObject(PVRClient())
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
