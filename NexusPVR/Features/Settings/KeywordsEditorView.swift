//
//  KeywordsEditorView.swift
//  nextpvr-apple-client
//
//  Editor for managing topic keywords
//

import SwiftUI

struct KeywordsEditorView: View {
    @Environment(\.dismiss) private var dismiss
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
                                Button {
                                    removeKeyword(keyword)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(Theme.error)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        Text("Your Keywords (\(preferences.keywords.count))")
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .navigationTitle("Topic Keywords")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityIdentifier("keywords-done-button")
                }
            }
            #endif
        }
        .background(Theme.background)
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
                            Button {
                                removeKeyword(keyword)
                            } label: {
                                HStack {
                                    Text(keyword)
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    HStack(spacing: 8) {
                                        Image(systemName: "trash")
                                        Text("Delete")
                                    }
                                    .foregroundStyle(Theme.error)
                                }
                                .padding()
                                .background(Theme.surfaceElevated)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                            }
                            .buttonStyle(.card)
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
}

#Preview {
    KeywordsEditorView()
        .preferredColorScheme(.dark)
}
