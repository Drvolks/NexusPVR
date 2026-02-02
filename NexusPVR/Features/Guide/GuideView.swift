//
//  GuideView.swift
//  nextpvr-apple-client
//
//  EPG grid view
//

import SwiftUI

// PreferenceKey for tracking horizontal scroll offset (to sync timeline header)
private struct HorizontalScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// Helper struct to hold both program and channel for sheet presentation
private struct ProgramDetail: Identifiable {
    let id = UUID()
    let program: Program
    let channel: Channel
}

struct GuideView: View {
    @EnvironmentObject private var client: NextPVRClient
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = GuideViewModel()

    @State private var selectedProgramDetail: (program: Program, channel: Channel)?
    @State private var streamError: String?

    // Cache keywords to avoid disk I/O during rendering
    @State private var cachedKeywords: [String] = []

    private let hourWidth: CGFloat = Theme.hourColumnWidth
    private let channelWidth: CGFloat = Theme.channelColumnWidth
    private let rowHeight: CGFloat = Theme.cellHeight

    var body: some View {
        contentView
            .background(Theme.background)
            #if os(macOS)
            .toolbar(.hidden)
            #endif
            .sheet(item: programDetailBinding, onDismiss: onDismissDetail) { detail in
                programDetailSheet(detail)
            }
            .alert("Error", isPresented: .constant(streamError != nil)) {
                Button("OK") { streamError = nil }
            } message: {
                streamErrorMessage
            }
            .task {
                cachedKeywords = UserPreferences.load().keywords
                await viewModel.loadData(using: client)
            }
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var contentView: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            iOSNavigationBar
                // Extra padding for Dynamic Island on iPhone (compact width)
                .padding(.top, horizontalSizeClass == .compact ? 16 : 0)
            #elseif os(macOS)
            iOSNavigationBar
            #endif

            Group {
                if (viewModel.isLoading || !viewModel.hasLoaded) && viewModel.channels.isEmpty {
                    loadingView
                } else if let error = viewModel.error, viewModel.channels.isEmpty {
                    errorView(error)
                } else if viewModel.hasLoaded && viewModel.channels.isEmpty {
                    emptyView
                } else {
                    guideContent
                }
            }
        }
        #if os(iOS)
        .safeAreaPadding(.top)
        #endif
    }

    private var programDetailBinding: Binding<ProgramDetail?> {
        Binding(
            get: { selectedProgramDetail.map { ProgramDetail(program: $0.program, channel: $0.channel) } },
            set: { selectedProgramDetail = $0.map { ($0.program, $0.channel) } }
        )
    }

    private func programDetailSheet(_ detail: ProgramDetail) -> some View {
        ProgramDetailView(program: detail.program, channel: detail.channel)
            .environmentObject(client)
            .environmentObject(appState)
    }

    private func onDismissDetail() {
        Task {
            await refreshRecordings()
        }
    }

    @ViewBuilder
    private var streamErrorMessage: some View {
        if let error = streamError {
            Text(error)
        }
    }

    private func playLiveChannel(_ channel: Channel) {
        // Use the direct stream URL from channelDetails
        guard let urlString = channel.streamURL,
              let url = URL(string: urlString) else {
            streamError = "No stream URL available for this channel"
            return
        }

        #if DEBUG
        print("Playing channel stream: \(url.absoluteString)")
        #endif

        appState.playStream(url: url, title: channel.name)
    }

    #if !os(tvOS)
    private var iOSNavigationBar: some View {
        HStack(spacing: Theme.spacingMD) {
            Button {
                viewModel.previousDay()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Theme.surfaceElevated)
                    .clipShape(Circle())
            }

            Text(viewModel.selectedDate, format: .dateTime.month(.abbreviated).day())
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 80)

            Button {
                viewModel.nextDay()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Theme.surfaceElevated)
                    .clipShape(Circle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.spacingSM)
        .background(Theme.surface)
    }
    #endif

    private var loadingView: some View {
        VStack(spacing: Theme.spacingMD) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(Theme.accent)
            Text("Loading guide...")
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: Theme.spacingMD) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(Theme.warning)
            Text("Unable to load guide")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(error)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task { await viewModel.loadData(using: client) }
            }
            .buttonStyle(AccentButtonStyle())
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: Theme.spacingMD) {
            Image(systemName: "tv")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textTertiary)
            Text("No channels available")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Configure your NextPVR server in Settings")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @State private var horizontalScrollOffset: CGFloat = 0
    @State private var scrollProxy: ScrollViewProxy?
    @State private var currentTimelineHour: Date?
    @Environment(\.scenePhase) private var scenePhase
    #if os(tvOS)
    @Namespace private var guideNamespace
    #endif

    private var guideContent: some View {
        VStack(spacing: 0) {
            #if os(tvOS)
            // tvOS navigation controls
            tvOSNavigationBar
            #endif

            // Timeline header row (fixed at top)
            HStack(alignment: .top, spacing: 0) {
                // Corner spacer
                Rectangle()
                    .fill(Theme.surfaceElevated)
                    .frame(width: channelWidth, height: 30)

                // Timeline header (scrolls horizontally)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        timelineHeaderContent
                    }
                    .onAppear {
                        scrollProxy = proxy
                        #if os(tvOS)
                        scrollToCurrentTime(proxy: proxy, isInitialLoad: true)
                        #else
                        scrollToCurrentTime(proxy: proxy)
                        #endif
                    }
                    .onChange(of: viewModel.selectedDate) {
                        scrollToCurrentTime(proxy: proxy)
                    }
                }
            }

            // Main grid - single vertical scroll for both channels and programs
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 1) {
                    ForEach(viewModel.channels) { channel in
                        HStack(alignment: .top, spacing: 0) {
                            // Channel icon (fixed horizontally)
                            channelCell(channel)
                                .frame(width: channelWidth, height: rowHeight)

                            // Program row (scrolls horizontally)
                            ScrollView(.horizontal, showsIndicators: false) {
                                programsRow(channel)
                                    .frame(height: rowHeight)
                            }
                        }
                        .background(Theme.surface)
                    }
                }
            }
            #if os(tvOS)
            .focusSection()
            .ignoresSafeArea(.all, edges: .leading)
            #endif
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                // When app becomes active, scroll to current time
                viewModel.scrollToNow()
                if let proxy = scrollProxy {
                    scrollToCurrentTime(proxy: proxy)
                }
            }
        }
        #if os(tvOS)
        .focusScope(guideNamespace)
        #endif
    }

    #if os(tvOS)
    private var tvOSNavigationBar: some View {
        HStack(spacing: 24) {
            Button {
                viewModel.previousDay()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title2)
                    .frame(width: 60, height: 60)
            }
            .buttonStyle(TVNavigationButtonStyle())
            .prefersDefaultFocus(in: guideNamespace)

            Text(viewModel.selectedDate, format: .dateTime.month(.wide).day().year())
                .font(.title3)
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 200)

            Button {
                viewModel.nextDay()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.title2)
                    .frame(width: 60, height: 60)
            }
            .buttonStyle(TVNavigationButtonStyle())

            Spacer()
        }
        .padding(.leading, Theme.spacingMD)
        .padding(.trailing, 40)
        .padding(.vertical, 20)
        .background(Theme.surface)
    }
    #endif

    private var timelineHeaderContent: some View {
        HStack(spacing: 0) {
            // Hour markers with :00 and :30 scroll anchors
            ForEach(viewModel.hoursToShow, id: \.self) { hour in
                HStack(spacing: 0) {
                    // :00 half with hour label
                    Text(hour, format: .dateTime.hour())
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: hourWidth / 2, alignment: .leading)
                        .padding(.leading, Theme.spacingSM)
                        .id("scroll-\(hour.timeIntervalSince1970)")
                    // :30 half (empty)
                    Color.clear
                        .frame(width: hourWidth / 2)
                        .id("scroll-\(hour.timeIntervalSince1970 + 1800)")
                }
            }
        }
        .frame(height: 30)
        .background(Theme.surfaceElevated)
    }

    @ViewBuilder
    private func channelCell(_ channel: Channel) -> some View {
        #if os(tvOS)
        // tvOS: non-interactive channel icon - logo fills the cell
        CachedAsyncImage(url: client.channelIconURL(channelId: channel.id)) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
        } placeholder: {
            ProgressView()
                .scaleEffect(0.5)
        }
        .padding(Theme.spacingSM)
        .frame(width: channelWidth, height: rowHeight)
        .background(Theme.surfaceElevated)
        #else
        // iOS/macOS: tappable to play live
        Button {
            playLiveChannel(channel)
        } label: {
            ZStack {
                CachedAsyncImage(url: client.channelIconURL(channelId: channel.id)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    ProgressView()
                        .scaleEffect(0.5)
                }
                .frame(width: Theme.iconSize, height: Theme.iconSize)

                // Play indicator on hover/focus
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(Theme.accent)
                    .font(.caption)
                    .offset(x: Theme.iconSize * 0.35, y: Theme.iconSize * 0.35)
            }
            .frame(width: channelWidth, height: rowHeight)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
        }
        .buttonStyle(.plain)
        #endif
    }

    private func programsRow(_ channel: Channel) -> some View {
        let timelineStart = viewModel.timelineStart
        let programs = viewModel.visiblePrograms(for: channel)
        // Calculate scroll target: :00 or :30 based on current minute
        let scrollTarget = GuideScrollHelper.calculateScrollTarget(currentTime: Date())

        return ZStack(alignment: .leading) {
            // Background for the full timeline
            Color.clear
                .frame(width: hourWidth * 24)

            // Program cells
            ForEach(programs) { program in
                let isScheduled = viewModel.isScheduledRecording(program)
                let status = viewModel.recordingStatus(program)
                let isRecording = isScheduled && program.isCurrentlyAiring && status == .recording
                let matchesKeywords = matchesKeywords(program)
                // Calculate leading padding for live programs - push text to visible left edge (scroll target)
                let leadingPad = GuideScrollHelper.calculateLeadingPadding(
                    programStart: program.startDate,
                    scrollTarget: scrollTarget,
                    hourWidth: hourWidth,
                    isCurrentlyAiring: program.isCurrentlyAiring
                )

                Button {
                    #if os(tvOS)
                    // tvOS: live programs play directly, past/future show details
                    if program.isCurrentlyAiring {
                        playLiveChannel(channel)
                    } else {
                        selectedProgramDetail = (program: program, channel: channel)
                    }
                    #else
                    selectedProgramDetail = (program: program, channel: channel)
                    #endif
                } label: {
                    ProgramCell(
                        program: program,
                        width: viewModel.programWidth(for: program, hourWidth: hourWidth, startTime: timelineStart),
                        isScheduledRecording: isScheduled,
                        isCurrentlyRecording: isRecording,
                        matchesKeyword: matchesKeywords,
                        leadingPadding: leadingPad
                    )
                }
                #if os(tvOS)
                .buttonStyle(TVGuideButtonStyle())
                .focusEffectDisabled()
                .contextMenu {
                    if program.isCurrentlyAiring {
                        Button {
                            selectedProgramDetail = (program: program, channel: channel)
                        } label: {
                            Label("Details", systemImage: "info.circle")
                        }

                        if !isScheduled {
                            Button {
                                selectedProgramDetail = (program: program, channel: channel)
                            } label: {
                                Label("Record", systemImage: "record.circle")
                            }
                        }
                    }
                }
                #else
                .buttonStyle(.plain)
                #endif
                .offset(x: viewModel.programOffset(for: program, hourWidth: hourWidth, startTime: timelineStart))
            }

            // Now indicator
            nowIndicator(timelineStart: timelineStart)
        }
        .frame(width: hourWidth * 24, height: rowHeight)
    }

    @ViewBuilder
    private func nowIndicator(timelineStart: Date) -> some View {
        let now = Date()
        if now >= timelineStart && now < timelineStart.addingTimeInterval(24 * 3600) {
            let offset = CGFloat(now.timeIntervalSince(timelineStart) / 3600) * hourWidth
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 2)
                .offset(x: offset)
        }
    }

    private func scrollToCurrentTime(proxy: ScrollViewProxy, isInitialLoad: Bool = false) {
        let calendar = Calendar.current
        let now = Date()

        // Only scroll to current time if viewing today
        guard calendar.isDate(viewModel.selectedDate, inSameDayAs: now) else { return }

        // Calculate the target scroll position using helper
        let scrollTargetDate = GuideScrollHelper.calculateScrollTarget(currentTime: now)

        // Store scroll target for text padding calculation
        currentTimelineHour = scrollTargetDate

        // Find the hour marker in hoursToShow and scroll to the appropriate :00 or :30 anchor
        let currentHour = calendar.component(.hour, from: now)
        if let targetHour = viewModel.hoursToShow.first(where: { calendar.component(.hour, from: $0) == currentHour }) {
            let scrollId = GuideScrollHelper.calculateScrollId(currentTime: now, targetHour: targetHour)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(isInitialLoad ? nil : .default) {
                    proxy.scrollTo(scrollId, anchor: UnitPoint(x: 0, y: 0))
                }
            }
        }
    }

    private func refreshRecordings() async {
        do {
            let (completed, scheduled) = try await client.getAllRecordings()
            viewModel.recordings = completed + scheduled
        } catch {
            // Silently fail - the grid just won't update the indicators
        }
    }

    private func matchesKeywords(_ program: Program) -> Bool {
        guard !cachedKeywords.isEmpty else { return false }

        let searchText = [
            program.name,
            program.subtitle ?? "",
            program.desc ?? ""
        ].joined(separator: " ").lowercased()

        return cachedKeywords.contains { keyword in
            searchText.contains(keyword.lowercased())
        }
    }
}

#Preview {
    GuideView()
        .environmentObject(NextPVRClient())
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
