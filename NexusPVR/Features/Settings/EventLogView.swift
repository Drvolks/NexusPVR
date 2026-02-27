//
//  EventLogView.swift
//  PVR Client
//
//  Network event log sub-page in Settings
//

import SwiftUI

struct EventLogView: View {
    @ObservedObject private var eventLog = NetworkEventLog.shared
    @State private var showingCopied = false

    var body: some View {
        #if os(tvOS)
        tvOSContent
        #else
        listContent
            .navigationTitle("Event Log")
        #endif
    }

    #if !os(tvOS)
    private var listContent: some View {
        List {
            if eventLog.events.isEmpty {
                Text("No network events yet")
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(eventLog.events.reversed()) { event in
                    eventRow(event)
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        #elseif os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if !eventLog.events.isEmpty {
                    Button {
                        copyLog()
                    } label: {
                        Label(showingCopied ? "Copied" : "Copy All", systemImage: showingCopied ? "checkmark" : "doc.on.doc")
                    }

                    Button(role: .destructive) {
                        eventLog.clear()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                }
            }
        }
    }
    #endif

    #if os(tvOS)
    private var tvOSContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacingXL) {
                TVSettingsSection(
                    title: "Event Log",
                    icon: "list.bullet.rectangle"
                ) {
                    VStack(spacing: Theme.spacingSM) {
                        if eventLog.events.isEmpty {
                            Text("No network events yet")
                                .foregroundStyle(Theme.textTertiary)
                        } else {
                            HStack {
                                Spacer()
                                Button {
                                    eventLog.clear()
                                } label: {
                                    Text("Clear")
                                        .font(.caption)
                                        .padding(.horizontal, Theme.spacingMD)
                                        .padding(.vertical, Theme.spacingSM)
                                        .background(Theme.surfaceElevated)
                                        .foregroundStyle(Theme.textSecondary)
                                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                                }
                                .buttonStyle(.card)
                            }

                            ForEach(eventLog.events.reversed()) { event in
                                eventRow(event)
                            }
                        }
                    }
                }
                .focusSection()
            }
            .padding(.vertical)
            .padding(.horizontal, 40)
        }
    }
    #endif

    private func eventRow(_ event: NetworkEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(event.timestamp, format: .dateTime.hour().minute().second())
                    .foregroundStyle(Theme.textTertiary)
                    .font(.caption)
                Text(event.method)
                    .foregroundStyle(Theme.textSecondary)
                    .font(.caption)
                    .fontWeight(.medium)
                Text(event.path)
                    .foregroundStyle(event.isSuccess ? Theme.textPrimary : Theme.error)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                if let code = event.statusCode {
                    Text("\(code)")
                        .foregroundStyle(event.isSuccess ? Theme.success : Theme.error)
                        .font(.caption)
                        .fontWeight(.medium)
                } else {
                    Text("ERR")
                        .foregroundStyle(Theme.error)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                Text("\(event.durationMs)ms")
                    .foregroundStyle(Theme.textTertiary)
                    .font(.caption)
            }
            if let detail = event.errorDetail {
                Text(detail)
                    .foregroundStyle(Theme.error)
                    .font(.caption2)
                    .lineLimit(3)
            }
        }
    }

    #if !os(tvOS)
    private func copyLog() {
        let text = eventLog.formattedLog
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        showingCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showingCopied = false
        }
    }
    #endif
}
