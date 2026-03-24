//
//  CalendarView.swift
//  NexusPVR
//
//  Calendar view for topic programs schedule
//

import SwiftUI

#if !os(tvOS)

// MARK: - Constants

private let hourHeight: CGFloat = 60
private let timeColumnWidth: CGFloat = 50
private let startHour = 0
private let endHour = 24

// Light pastel colors for topic keywords — deterministic by keyword hash
private let topicColors: [Color] = [
    Color(red: 0.40, green: 0.73, blue: 0.88),  // sky blue
    Color(red: 0.56, green: 0.83, blue: 0.56),  // light green
    Color(red: 0.91, green: 0.58, blue: 0.48),  // salmon
    Color(red: 0.73, green: 0.58, blue: 0.88),  // lavender
    Color(red: 0.95, green: 0.75, blue: 0.40),  // golden
    Color(red: 0.48, green: 0.82, blue: 0.75),  // teal
    Color(red: 0.88, green: 0.52, blue: 0.72),  // pink
    Color(red: 0.65, green: 0.78, blue: 0.45),  // lime
    Color(red: 0.55, green: 0.68, blue: 0.90),  // periwinkle
    Color(red: 0.90, green: 0.68, blue: 0.50),  // peach
]

private func colorForKeyword(_ keyword: String) -> Color {
    var hash: UInt64 = 5381
    for char in keyword.utf8 {
        hash = ((hash &<< 5) &+ hash) &+ UInt64(char)
    }
    return topicColors[Int(hash % UInt64(topicColors.count))]
}

// MARK: - CalendarView

struct CalendarView: View {
    let programs: [MatchingProgram]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var client: PVRClient
    @EnvironmentObject private var appState: AppState
    @State private var viewMode: ViewMode = .day
    @State private var selectedDate: Date = Date()
    @State private var selectedProgramDetail: ProgramTopicDetail?
    @State private var selectedKeyword: String = ""
    @State private var contentWidth: CGFloat = 0
    @State private var scheduledProgramIds: Set<Int> = []

    enum ViewMode: String, CaseIterable {
        case day = "Day"
        case week = "Week"
    }

    private var keywords: [String] {
        Array(Set(programs.map(\.matchedKeyword))).sorted()
    }

    private var filteredPrograms: [MatchingProgram] {
        if selectedKeyword == MatchingProgram.scheduledKeyword {
            // Show all scheduled recordings
            return programs.filter { $0.matchedKeyword == MatchingProgram.scheduledKeyword }
        } else if !selectedKeyword.isEmpty {
            // Show only the selected topic keyword
            return programs.filter { $0.matchedKeyword == selectedKeyword }
        }
        // "All": deduplicate — if a program has both a topic and "Scheduled" entry, keep the topic one
        let scheduledIds = Set(
            programs.filter { $0.matchedKeyword == MatchingProgram.scheduledKeyword }.map { $0.program.id }
        )
        let topicIds = Set(
            programs.filter { $0.matchedKeyword != MatchingProgram.scheduledKeyword }.map { $0.program.id }
        )
        let duplicateIds = scheduledIds.intersection(topicIds)
        return programs.filter {
            !($0.matchedKeyword == MatchingProgram.scheduledKeyword && duplicateIds.contains($0.program.id))
        }
    }

    private var blockTextColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var programsByDate: [Date: [MatchingProgram]] {
        Dictionary(grouping: filteredPrograms) { item in
            Calendar.current.startOfDay(for: item.program.startDate)
        }
    }

    private var visibleDates: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: selectedDate)

        switch viewMode {
        case .day:
            return [today]
        case .week:
            let weekday = cal.component(.weekday, from: today)
            let diff = weekday - cal.firstWeekday
            let startOfWeek = cal.date(byAdding: .day, value: -(diff < 0 ? diff + 7 : diff), to: today) ?? today
            return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: startOfWeek) }
        }
    }

    private var dateRangeLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE dd"
        switch viewMode {
        case .day:
            return formatter.string(from: selectedDate)
        case .week:
            let dates = visibleDates
            guard let first = dates.first, let last = dates.last else { return "" }
            let monthDay = DateFormatter()
            monthDay.dateFormat = "MMM dd"
            let dd = DateFormatter()
            dd.dateFormat = "dd"
            return "\(monthDay.string(from: first))-\(dd.string(from: last))"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                navigationBar
                Divider()

                switch viewMode {
                case .day:
                    dayView
                case .week:
                    weekView
                }
            }
            .accessibilityIdentifier("calendar-view")
            .frame(maxHeight: .infinity)
            .background(Theme.background)
            .onGeometryChange(for: CGFloat.self) { geo in
                geo.size.width
            } action: { newWidth in
                contentWidth = newWidth
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
            .sheet(item: $selectedProgramDetail) { detail in
                ProgramDetailView(
                    program: detail.program,
                    channel: detail.channel,
                    initialRecordingId: detail.recordingId,
                    initialCompletedRecording: detail.completedRecording
                )
                .environmentObject(client)
                .environmentObject(appState)
            }
            #if os(iOS)
            .presentationDetents([.large])
            .presentationSizing(.page)
            #endif
        }
        .task {
            await loadScheduledRecordings()
        }
    }

    private func loadScheduledRecordings() async {
        do {
            let (_, recording, scheduled) = try await client.getAllRecordings()
            let ids = Set((recording + scheduled).compactMap(\.epgEventId))
            scheduledProgramIds = ids
        } catch {
            // Silently fail
        }
    }

    // MARK: - Navigation Bar

    private var navigationBar: some View {
        HStack(spacing: Theme.spacingMD) {
            Button { navigateBack() } label: {
                Image(systemName: "chevron.left")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.plain)
            .disabled(!canNavigateBack)

            Text(dateRangeLabel)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Button { navigateForward() } label: {
                Image(systemName: "chevron.right")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.plain)

            Spacer()

            Menu {
                Button { selectedKeyword = "" } label: {
                    if selectedKeyword.isEmpty {
                        Label("All", systemImage: "checkmark")
                    } else {
                        Text("All")
                    }
                }
                ForEach(keywords, id: \.self) { keyword in
                    Button {
                        selectedKeyword = keyword
                    } label: {
                        Label(keyword, systemImage: keyword == selectedKeyword ? "checkmark.circle.fill" : "circle.fill")
                    }
                    .tint(colorForKeyword(keyword))
                }
            } label: {
                HStack(spacing: 4) {
                    if !selectedKeyword.isEmpty {
                        Circle()
                            .fill(colorForKeyword(selectedKeyword))
                            .frame(width: 8, height: 8)
                    }
                    Text(selectedKeyword.isEmpty ? "All" : selectedKeyword)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
                .font(.subheadline)
            }

            Picker("", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.vertical, Theme.spacingSM)
        .background(Theme.surface)
    }

    // MARK: - Day View

    private var dayView: some View {
        let cal = Calendar.current
        let date = cal.startOfDay(for: selectedDate)
        let dayPrograms = programsByDate[date] ?? []
        let availableWidth = contentWidth - timeColumnWidth - Theme.spacingSM
        let columns = layoutColumns(for: dayPrograms)

        let scrollTarget: Int = {
            if cal.isDateInToday(selectedDate) {
                return max(0, cal.component(.hour, from: Date()) - 1)
            }
            if let first = dayPrograms.min(by: { $0.program.startDate < $1.program.startDate }) {
                return max(0, cal.component(.hour, from: first.program.startDate) - 1)
            }
            return 0
        }()

        return ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    // VStack grid for real layout positions (scroll targets)
                    timelineVStack

                    // Program blocks overlaid
                    if availableWidth > 0 {
                        ForEach(dayPrograms) { item in
                            let layout = columns[item.id] ?? (column: 0, totalColumns: 1)
                            programBlock(item, columnOffset: timeColumnWidth, columnWidth: availableWidth, colIndex: layout.column, totalCols: layout.totalColumns)
                        }
                    }
                }
                .padding(.trailing, Theme.spacingSM)
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    proxy.scrollTo(scrollTarget, anchor: .top)
                }
            }
        }
    }

    // MARK: - Week View

    private var weekView: some View {
        let dates = visibleDates
        let cal = Calendar.current
        let dayFormatter = DateFormatter()
        let totalHeight = CGFloat(endHour - startHour) * hourHeight
        let columnWidth = contentWidth > 0 ? (contentWidth - timeColumnWidth) / CGFloat(dates.count) : 0
        let currentHour = max(0, cal.component(.hour, from: Date()) - 1)

        return VStack(spacing: 0) {
            // Day headers
            HStack(spacing: 0) {
                Color.clear.frame(width: timeColumnWidth, height: 1)
                ForEach(dates, id: \.self) { date in
                    let isToday = cal.isDateInToday(date)
                    VStack(spacing: 2) {
                        Text({
                            dayFormatter.dateFormat = "EEE"
                            return dayFormatter.string(from: date)
                        }())
                            .font(.caption2)
                            .foregroundStyle(isToday ? Theme.accent : Theme.textTertiary)
                        Text("\(cal.component(.day, from: date))")
                            .font(.subheadline)
                            .fontWeight(isToday ? .bold : .regular)
                            .foregroundStyle(isToday ? Theme.accent : Theme.textPrimary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.spacingXS)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.surface)

            Divider()

            // Timeline
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        // VStack grid for real layout positions (scroll targets)
                        timelineVStack

                        if columnWidth > 0 {
                            // Vertical column dividers
                            ForEach(0..<dates.count, id: \.self) { index in
                                Rectangle()
                                    .fill(Theme.surfaceHighlight.opacity(0.5))
                                    .frame(width: 0.5)
                                    .offset(x: timeColumnWidth + columnWidth * CGFloat(index))
                            }

                            // Program blocks per day
                            ForEach(Array(dates.enumerated()), id: \.offset) { index, date in
                                let dayPrograms = programsByDate[Calendar.current.startOfDay(for: date)] ?? []
                                let xOffset = timeColumnWidth + columnWidth * CGFloat(index)
                                let columns = layoutColumns(for: dayPrograms)

                                ForEach(dayPrograms) { item in
                                    let layout = columns[item.id] ?? (column: 0, totalColumns: 1)
                                    programBlock(item, columnOffset: xOffset + 1, columnWidth: columnWidth - 2, colIndex: layout.column, totalCols: layout.totalColumns)
                                }
                            }
                        }
                    }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        proxy.scrollTo(currentHour, anchor: .top)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Timeline Grid

    /// VStack-based timeline — each hour row has real layout height so ScrollViewReader can find it
    private var timelineVStack: some View {
        VStack(spacing: 0) {
            ForEach(startHour..<endHour, id: \.self) { hour in
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text(hourLabel(hour))
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: timeColumnWidth, alignment: .trailing)
                            .padding(.trailing, 4)

                        Rectangle()
                            .fill(Theme.textTertiary.opacity(0.3))
                            .frame(height: 0.5)
                    }
                    Spacer()
                }
                .frame(height: hourHeight)
                .id(hour)
            }
        }
    }

    // MARK: - Overlap Layout

    /// Assigns each program a column index and total column count for side-by-side layout
    private func layoutColumns(for programs: [MatchingProgram]) -> [String: (column: Int, totalColumns: Int)] {
        let sorted = programs.sorted { $0.program.startDate < $1.program.startDate }
        // Each item gets a column assignment
        var assignments: [(id: String, column: Int, start: Date, end: Date)] = []

        for item in sorted {
            let start = item.program.startDate
            let end = item.program.endDate
            // Find the first column where this program doesn't overlap with any existing assignment
            var col = 0
            while assignments.contains(where: { $0.column == col && $0.end > start && $0.start < end }) {
                col += 1
            }
            assignments.append((id: item.id, column: col, start: start, end: end))
        }

        // For each group of overlapping programs, determine the total column count
        var result: [String: (column: Int, totalColumns: Int)] = [:]
        for assignment in assignments {
            // Find all assignments that overlap with this one
            let overlapping = assignments.filter { $0.end > assignment.start && $0.start < assignment.end }
            let totalColumns = (overlapping.map(\.column).max() ?? 0) + 1
            result[assignment.id] = (column: assignment.column, totalColumns: totalColumns)
        }

        // Normalize: ensure all mutually overlapping items share the same totalColumns
        for assignment in assignments {
            let overlapping = assignments.filter { $0.end > assignment.start && $0.start < assignment.end }
            let maxTotal = overlapping.compactMap { result[$0.id]?.totalColumns }.max() ?? 1
            for ovl in overlapping {
                if let existing = result[ovl.id], existing.totalColumns < maxTotal {
                    result[ovl.id] = (column: existing.column, totalColumns: maxTotal)
                }
            }
        }

        return result
    }

    // MARK: - Program Block

    private func programBlock(_ item: MatchingProgram, columnOffset: CGFloat, columnWidth: CGFloat?) -> some View {
        programBlock(item, columnOffset: columnOffset, columnWidth: columnWidth, colIndex: 0, totalCols: 1)
    }

    private func programBlock(_ item: MatchingProgram, columnOffset: CGFloat, columnWidth: CGFloat?, colIndex: Int, totalCols: Int) -> some View {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: item.program.startDate)
        let startMinutes = cal.dateComponents([.hour, .minute], from: dayStart, to: item.program.startDate)
        let totalStartMinutes = CGFloat((startMinutes.hour ?? 0) * 60 + (startMinutes.minute ?? 0))
        let durationMinutes = CGFloat(item.program.durationMinutes)
        let yOffset = (totalStartMinutes / 60.0) * hourHeight
        let blockHeight = max((durationMinutes / 60.0) * hourHeight, 20)

        return Button {
            selectedProgramDetail = ProgramTopicDetail(
                program: item.program,
                channel: item.channel
            )
        } label: {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.program.name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(blockTextColor)
                        .lineLimit(blockHeight > 40 ? 2 : 1)

                    if blockHeight > 35 {
                        Text(item.channel.name)
                            .font(.system(size: 9))
                            .foregroundStyle(blockTextColor.opacity(0.8))
                            .lineLimit(1)
                    }

                    if blockHeight > 50 {
                        Text("\(item.program.startDate.formatted(date: .omitted, time: .shortened)) - \(item.program.endDate.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 9))
                            .foregroundStyle(blockTextColor.opacity(0.7))
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: blockHeight, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(colorForKeyword(item.matchedKeyword).opacity(item.program.isCurrentlyAiring ? 0.6 : 0.4))
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .topTrailing) {
                if scheduledProgramIds.contains(item.program.id) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .padding(3)
                }
            }
        }
        .buttonStyle(.plain)
        .offset(x: {
            if let w = columnWidth {
                let colWidth = w / CGFloat(totalCols)
                return columnOffset + colWidth * CGFloat(colIndex)
            }
            return columnOffset
        }(), y: yOffset)
        .frame(width: {
            if let w = columnWidth {
                return w / CGFloat(totalCols)
            }
            return nil
        }())
    }

    // MARK: - Helpers

    private func hourLabel(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        let cal = Calendar.current
        let date = cal.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return formatter.string(from: date)
    }

    private var canNavigateBack: Bool {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        switch viewMode {
        case .day:
            return cal.startOfDay(for: selectedDate) > today
        case .week:
            return visibleDates.last.map { cal.startOfDay(for: $0) > today } ?? false
        }
    }

    private func navigateBack() {
        let cal = Calendar.current
        switch viewMode {
        case .day:
            let newDate = cal.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
            let today = cal.startOfDay(for: Date())
            selectedDate = max(newDate, today)
        case .week:
            selectedDate = cal.date(byAdding: .weekOfYear, value: -1, to: selectedDate) ?? selectedDate
        }
    }

    private func navigateForward() {
        let cal = Calendar.current
        switch viewMode {
        case .day:
            selectedDate = cal.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
        case .week:
            selectedDate = cal.date(byAdding: .weekOfYear, value: 1, to: selectedDate) ?? selectedDate
        }
    }
}

/// Standalone calendar tab for macOS sidebar — loads its own topic data
struct CalendarTabView: View {
    @EnvironmentObject private var client: PVRClient
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var epgCache: EPGCache
    @StateObject private var viewModel = TopicsViewModel()

    var body: some View {
        CalendarView(programs: viewModel.matchingPrograms)
            .environmentObject(client)
            .environmentObject(appState)
            .task {
                viewModel.epgCache = epgCache
                viewModel.client = client
                await viewModel.loadData()
            }
    }
}
#endif
