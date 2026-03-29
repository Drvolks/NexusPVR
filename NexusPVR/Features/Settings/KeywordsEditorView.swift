//
//  KeywordsEditorView.swift
//  nextpvr-apple-client
//
//  Editor for managing topic keywords
//

import SwiftUI

struct KeywordsEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @State private var preferences = UserPreferences.load()
    @State private var newKeyword = ""

    var body: some View {
        NavigationStack {
            #if os(tvOS)
            tvOSContent
                .navigationTitle("Topic Keywords")
            #else
            List {
                Section {
                    HStack {
                        TextField("Add keyword...", text: $newKeyword)
                            .textFieldStyle(.plain)
                            .submitLabel(.done)
                            .onSubmit {
                                addKeyword()
                            }
                            .accessibilityIdentifier("keyword-text-field")

                        Button {
                            addKeyword()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("add-keyword-confirm")
                    }
                } header: {
                    Text("Add Keyword")
                } footer: {
                    Text("Keywords are matched against program titles, subtitles, and descriptions")
                }

                if !preferences.keywords.isEmpty {
                    Section {
                        ForEach(preferences.keywords, id: \.self) { keyword in
                            HStack {
                                Text(keyword)
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                #if !os(iOS)
                                HStack(spacing: Theme.spacingMD) {
                                    Button {
                                        moveKeyword(keyword, offset: -1)
                                    } label: {
                                        Image(systemName: "arrow.up")
                                            .foregroundStyle(canMoveKeyword(keyword, offset: -1) ? Theme.accent : Theme.textTertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!canMoveKeyword(keyword, offset: -1))
                                    .accessibilityLabel("Move \(keyword) up")

                                    Button {
                                        moveKeyword(keyword, offset: 1)
                                    } label: {
                                        Image(systemName: "arrow.down")
                                            .foregroundStyle(canMoveKeyword(keyword, offset: 1) ? Theme.accent : Theme.textTertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!canMoveKeyword(keyword, offset: 1))
                                    .accessibilityLabel("Move \(keyword) down")

                                    Button {
                                        removeKeyword(keyword)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(Theme.error)
                                    }
                                    .buttonStyle(.plain)
                                }
                                #endif
                                #if os(iOS)
                                Button {
                                    removeKeyword(keyword)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(Theme.error)
                                }
                                .buttonStyle(.plain)
                                #endif
                            }
                        }
                        #if os(iOS)
                        .onMove(perform: moveKeywords)
                        #endif
                    } header: {
                        Text("Your Keywords (\(preferences.keywords.count))")
                    } footer: {
                        Text("Reorder topics here. The first topic becomes the default selection.")
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle("Topic Keywords")
            #if !os(iOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityIdentifier("keywords-done-button")
                }
            }
            #endif
            #endif
        }
        .background(Theme.background)
        .onChange(of: preferences.keywords) { _ in
            appState.topicKeywords = preferences.keywords
        }
    }

    #if os(tvOS)
    private var tvOSContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacingLG) {
                // Add Keyword Section
                VStack(alignment: .leading, spacing: Theme.spacingMD) {
                    Text("Add Keyword")
                        .font(.headline)
                        .foregroundStyle(Theme.textSecondary)

                    TVTextField(placeholder: "Enter keyword...", text: $newKeyword)
                        .onSubmit {
                            addKeyword()
                        }

                    Button {
                        addKeyword()
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Keyword")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Theme.accent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                    }
                    .buttonStyle(.card)
                    .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)

                    Text("Keywords are matched against program titles, subtitles, and descriptions")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding()
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))

                // Keywords List Section
                if !preferences.keywords.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.spacingMD) {
                        Text("Your Keywords (\(preferences.keywords.count))")
                            .font(.headline)
                            .foregroundStyle(Theme.textSecondary)

                        ForEach(preferences.keywords, id: \.self) { keyword in
                            HStack(spacing: Theme.spacingSM) {
                                Text(keyword)
                                    .foregroundStyle(Theme.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Button {
                                    moveKeyword(keyword, offset: -1)
                                } label: {
                                    Image(systemName: "arrow.up")
                                }
                                .buttonStyle(.card)
                                .disabled(!canMoveKeyword(keyword, offset: -1))

                                Button {
                                    moveKeyword(keyword, offset: 1)
                                } label: {
                                    Image(systemName: "arrow.down")
                                }
                                .buttonStyle(.card)
                                .disabled(!canMoveKeyword(keyword, offset: 1))

                                Button {
                                    removeKeyword(keyword)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "trash")
                                        Text("Delete")
                                    }
                                    .foregroundStyle(Theme.error)
                                }
                                .buttonStyle(.card)
                            }
                            .padding()
                            .background(Theme.surfaceElevated)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                        }
                    }
                    .padding()
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))
                }

                // Done Button
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Theme.accent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                }
                .buttonStyle(.card)
            }
            .padding()
        }
    }
    #endif

    private func addKeyword() {
        let trimmed = newKeyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard !preferences.keywords.contains(trimmed) else {
            newKeyword = ""
            return
        }

        preferences.keywords.append(trimmed)
        preferences.save()
        newKeyword = ""
    }

    private func removeKeyword(_ keyword: String) {
        preferences.keywords.removeAll { $0 == keyword }
        preferences.save()
    }

    private func canMoveKeyword(_ keyword: String, offset: Int) -> Bool {
        guard let index = preferences.keywords.firstIndex(of: keyword) else { return false }
        let destination = index + offset
        return preferences.keywords.indices.contains(destination)
    }

    private func moveKeyword(_ keyword: String, offset: Int) {
        guard let index = preferences.keywords.firstIndex(of: keyword) else { return }
        let destination = index + offset
        guard preferences.keywords.indices.contains(destination) else { return }

        preferences.keywords.swapAt(index, destination)
        preferences.save()
    }

    private func moveKeywords(from source: IndexSet, to destination: Int) {
        preferences.keywords.move(fromOffsets: source, toOffset: destination)
        preferences.save()
    }
}

#Preview {
    KeywordsEditorView()
        .preferredColorScheme(.dark)
}
