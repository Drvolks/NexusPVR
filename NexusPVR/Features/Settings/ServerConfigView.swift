//
//  ServerConfigView.swift
//  nextpvr-apple-client
//
//  Server configuration and connection view
//

import SwiftUI

struct ServerConfigView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var client: PVRClient

    @State private var config = ServerConfig.load()
    @State private var isConnecting = false
    @State private var connectionError: String?
    @State private var showSuccess = false

    var body: some View {
        NavigationStack {
            formContent
                .navigationTitle("Server Configuration")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                #if !os(tvOS)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            saveAndConnect()
                        }
                        .disabled(!config.isConfigured || isConnecting)
                    }
                }
                #endif
                .alert("Connection Error", isPresented: .constant(connectionError != nil)) {
                    Button("OK") {
                        connectionError = nil
                    }
                } message: {
                    if let error = connectionError {
                        Text(error)
                    }
                }
                .alert("Connected", isPresented: $showSuccess) {
                    Button("OK") {
                        dismiss()
                    }
                } message: {
                    Text(Brand.connectionSuccessMessage)
                }
        }
    }

    @ViewBuilder
    private var formContent: some View {
        #if os(tvOS)
        tvOSFormContent
        #elseif os(macOS)
        Form {
            serverSection
            connectionSection
            statusSection
        }
        .formStyle(.grouped)
        #else
        Form {
            serverSection
            connectionSection
            statusSection
        }
        #endif
    }

    #if os(tvOS)
    private var tvOSFormContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacingLG) {
                // Server Address Section
                VStack(alignment: .leading, spacing: Theme.spacingMD) {
                    Text("Server Address")
                        .font(.headline)
                        .foregroundStyle(Theme.textSecondary)

                    VStack(spacing: Theme.spacingMD) {
                        TVTextField(placeholder: "Host (e.g. 192.168.1.100)", text: $config.host)
                        TVNumberField(placeholder: "Port (default: \(Brand.defaultPort))", value: $config.port)

                        HStack {
                            Text("Use HTTPS")
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Toggle("", isOn: $config.useHTTPS)
                                .labelsHidden()
                        }
                        .padding()
                        .background(Theme.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                    }
                }
                .padding()
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))

                // Authentication Section
                VStack(alignment: .leading, spacing: Theme.spacingMD) {
                    Text("Authentication")
                        .font(.headline)
                        .foregroundStyle(Theme.textSecondary)

                    #if DISPATCHERPVR
                    TVTextField(placeholder: "Username", text: $config.username)
                    TVTextField(placeholder: "Password", text: $config.password)
                    #else
                    TVTextField(placeholder: "PIN", text: $config.pin)
                    #endif
                }
                .padding()
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))

                // Connection Status Section
                VStack(alignment: .leading, spacing: Theme.spacingMD) {
                    Text("Connection Status")
                        .font(.headline)
                        .foregroundStyle(Theme.textSecondary)

                    if isConnecting {
                        HStack {
                            ProgressView()
                                .tint(Theme.accent)
                            Text("Connecting...")
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding()
                        .background(Theme.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                    } else if client.isAuthenticated {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.success)
                            Text("Connected")
                                .foregroundStyle(Theme.success)
                        }
                        .padding()
                        .background(Theme.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                    }

                    Button {
                        testConnection()
                    } label: {
                        Text("Test Connection")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Theme.accent)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                    }
                    .buttonStyle(.card)
                    .disabled(!config.isConfigured || isConnecting)

                    if client.isAuthenticated {
                        Button {
                            client.disconnect()
                        } label: {
                            Text("Disconnect")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Theme.error)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding()
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))

                // Action Buttons
                HStack(spacing: Theme.spacingMD) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Theme.surfaceElevated)
                            .foregroundStyle(Theme.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                    }
                    .buttonStyle(.card)

                    Button {
                        saveAndConnect()
                    } label: {
                        Text("Save")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Theme.accent)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                    }
                    .buttonStyle(.card)
                    .disabled(!config.isConfigured || isConnecting)
                }
            }
            .padding()
        }
    }
    #endif

    #if !os(tvOS)
    private var serverSection: some View {
        Section {
            LabeledContent("Host") {
                TextField("192.168.1.100", text: $config.host)
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    #endif
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
            }

            LabeledContent("Port") {
                TextField("\(Brand.defaultPort)", value: $config.port, format: .number)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    #endif
            }

            Toggle("Use HTTPS", isOn: $config.useHTTPS)
        } header: {
            Text("Server Address")
        } footer: {
            Text(Brand.serverFooter)
        }
    }

    private var connectionSection: some View {
        Section {
            #if DISPATCHERPVR
            LabeledContent("Username") {
                TextField("Username", text: $config.username)
                    #if os(iOS)
                    .autocapitalization(.none)
                    #endif
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    #endif
            }
            LabeledContent("Password") {
                SecureField("Password", text: $config.password)
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    #endif
            }
            #else
            LabeledContent("PIN") {
                SecureField("Enter PIN", text: $config.pin)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    #endif
            }
            #endif
        } header: {
            Text("Authentication")
        } footer: {
            Text(Brand.authFooter)
        }
    }

    private var statusSection: some View {
        Section {
            if isConnecting {
                HStack {
                    ProgressView()
                        .tint(Theme.accent)
                    Text("Connecting...")
                        .foregroundStyle(Theme.textSecondary)
                }
            } else if client.isAuthenticated {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                    Text("Connected")
                        .foregroundStyle(Theme.success)
                }
            }

            Button {
                testConnection()
            } label: {
                HStack {
                    Spacer()
                    Text("Test Connection")
                    Spacer()
                }
            }
            .disabled(!config.isConfigured || isConnecting)

            if client.isAuthenticated {
                Button(role: .destructive) {
                    client.disconnect()
                } label: {
                    HStack {
                        Spacer()
                        Text("Disconnect")
                        Spacer()
                    }
                }
            }
        } header: {
            Text("Connection Status")
        }
    }
    #endif

    private func testConnection() {
        guard config.isConfigured else { return }

        isConnecting = true
        connectionError = nil

        config.save()
        client.updateConfig(config)

        Task {
            do {
                try await client.authenticate()
                isConnecting = false
            } catch {
                isConnecting = false
                connectionError = error.localizedDescription
            }
        }
    }

    private func saveAndConnect() {
        config.save()
        client.updateConfig(config)

        if !client.isAuthenticated {
            testConnection()
        }

        if client.isAuthenticated {
            showSuccess = true
        } else {
            Task {
                do {
                    try await client.authenticate()
                    showSuccess = true
                } catch {
                    connectionError = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    ServerConfigView()
        .environmentObject(PVRClient())
        .preferredColorScheme(.dark)
}
