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

    @State private var config: ServerConfig
    @State private var isConnecting = false
    @State private var connectionError: String?
    #if DISPATCHERPVR
    @State private var useApiKey: Bool
    #endif
    #if os(tvOS)
    @State private var portString: String
    #endif

    init(prefillConfig: ServerConfig? = nil) {
        let c = prefillConfig ?? ServerConfig.load()
        _config = State(initialValue: c)
        #if DISPATCHERPVR
        _useApiKey = State(initialValue: !c.apiKey.isEmpty)
        #endif
        #if os(tvOS)
        _portString = State(initialValue: c.port > 0 ? String(c.port) : "")
        #endif
    }

    var body: some View {
        #if os(tvOS)
        formContent
            .navigationTitle("Server Setup")
            .alert("Connection Error", isPresented: .constant(connectionError != nil)) {
                Button("OK") {
                    connectionError = nil
                }
            } message: {
                if let error = connectionError {
                    Text(error)
                }
            }
        #elseif os(macOS)
        formContent
            .alert("Connection Error", isPresented: .constant(connectionError != nil)) {
                Button("OK") {
                    connectionError = nil
                }
            } message: {
                if let error = connectionError {
                    Text(error)
                }
            }
        #else
        NavigationStack {
            formContent
                .navigationTitle("Server Setup")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if isConnecting {
                            ProgressView()
                                .tint(Theme.accent)
                        } else {
                            Button("Save") {
                                saveAndConnect()
                            }
                            .disabled(!config.isConfigured)
                        }
                    }
                }
                .alert("Connection Error", isPresented: .constant(connectionError != nil)) {
                    Button("OK") {
                        connectionError = nil
                    }
                } message: {
                    if let error = connectionError {
                        Text(error)
                    }
                }
        }
        #endif
    }

    @ViewBuilder
    private var formContent: some View {
        #if os(tvOS)
        tvOSFormContent
        #elseif os(macOS)
        macOSFormContent
        #else
        Form {
            serverSection
            connectionSection
        }
        #endif
    }

    #if os(tvOS)
    private var tvOSFormContent: some View {
        VStack(spacing: Theme.spacingLG) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingLG) {
                    // Server Address Section
                    VStack(alignment: .leading, spacing: Theme.spacingMD) {
                        Text("Server Address")
                            .font(.headline)
                            .foregroundStyle(Theme.textSecondary)

                        VStack(spacing: Theme.spacingMD) {
                            TextField("Host (e.g. 192.168.1.100)", text: $config.host)
                                .textContentType(.URL)
                                .autocorrectionDisabled()

                            TextField("Port (default: \(String(Brand.defaultPort)))", text: $portString)
                                .keyboardType(.numberPad)
                                .onChange(of: portString) { _, newValue in
                                    config.port = Int(newValue) ?? Brand.defaultPort
                                }

                            HStack {
                                Text("Use HTTPS")
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Button {
                                    config.useHTTPS.toggle()
                                } label: {
                                    Text(config.useHTTPS ? "On" : "Off")
                                        .fontWeight(.medium)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, Theme.spacingLG)
                                        .padding(.vertical, Theme.spacingSM)
                                        .background(config.useHTTPS ? Theme.accent : Theme.textTertiary)
                                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                                }
                                .buttonStyle(.card)
                            }
                        }
                    }
                    .padding()
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))
                    .focusSection()

                    // Authentication Section
                    VStack(alignment: .leading, spacing: Theme.spacingMD) {
                        Text("Authentication")
                            .font(.headline)
                            .foregroundStyle(Theme.textSecondary)

                        #if DISPATCHERPVR
                        if useApiKey {
                            SecureField("API Key", text: $config.apiKey)
                        } else {
                            TextField("Username", text: $config.username)
                                .autocorrectionDisabled()

                            SecureField("Password", text: $config.password)
                        }

                        Button {
                            useApiKey.toggle()
                        } label: {
                            Text(useApiKey ? "Use Username & Password" : "Use API Key")
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.card)
                        #else
                        TextField("PIN", text: $config.pin)
                        #endif
                    }
                    .padding()
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))
                    .focusSection()
                }
                .padding()
            }

            // Action Buttons - outside ScrollView so always reachable
            VStack(spacing: Theme.spacingMD) {
                if isConnecting {
                    HStack {
                        ProgressView()
                            .tint(Theme.accent)
                        Text("Connecting...")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

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
                            .background(config.isConfigured && !isConnecting ? Theme.accent : Theme.textTertiary)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
                    }
                    .buttonStyle(.card)
                    .disabled(!config.isConfigured || isConnecting)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
            .focusSection()
        }
    }
    #endif

    #if os(macOS)
    private var macOSFormContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Theme.spacingLG) {
                    // Header
                    VStack(spacing: Theme.spacingSM) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 40))
                            .foregroundStyle(Theme.accent)

                        Text("Connect to \(Brand.serverName)")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)

                        Text(Brand.serverFooter)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, Theme.spacingLG)
                    .padding(.bottom, Theme.spacingSM)

                    // Server Address Card
                    VStack(alignment: .leading, spacing: Theme.spacingMD) {
                        Label("Server Address", systemImage: "network")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)

                        VStack(spacing: Theme.spacingSM) {
                            HStack {
                                Text("Host")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 60, alignment: .trailing)
                                TextField("192.168.1.100", text: $config.host)
                                    .textContentType(.URL)
                                    .textFieldStyle(.roundedBorder)
                            }

                            HStack {
                                Text("Port")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 60, alignment: .trailing)
                                TextField("\(String(Brand.defaultPort))", value: $config.port, format: .number.grouping(.never))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                                Spacer()
                            }

                            HStack {
                                Text("")
                                    .frame(width: 60)
                                Toggle("Use HTTPS", isOn: $config.useHTTPS)
                                    .toggleStyle(.switch)
                                    .tint(Theme.accent)
                                Spacer()
                            }
                        }
                    }
                    .padding(Theme.spacingMD)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))

                    // Authentication Card
                    VStack(alignment: .leading, spacing: Theme.spacingMD) {
                        Label("Authentication", systemImage: "lock")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)

                        VStack(spacing: Theme.spacingSM) {
                            #if DISPATCHERPVR
                            if useApiKey {
                                HStack {
                                    Text("Key")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.textSecondary)
                                        .frame(width: 60, alignment: .trailing)
                                    SecureField("API Key", text: $config.apiKey)
                                        .textFieldStyle(.roundedBorder)
                                }
                            } else {
                                HStack {
                                    Text("User")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.textSecondary)
                                        .frame(width: 60, alignment: .trailing)
                                    TextField("Username", text: $config.username)
                                        .textFieldStyle(.roundedBorder)
                                }
                                HStack {
                                    Text("Pass")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.textSecondary)
                                        .frame(width: 60, alignment: .trailing)
                                    SecureField("Password", text: $config.password)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }

                            HStack {
                                Text("")
                                    .frame(width: 60)
                                Button {
                                    useApiKey.toggle()
                                } label: {
                                    Text(useApiKey ? "Use Username & Password" : "Use API Key")
                                        .font(.system(size: 12))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.accent)
                                Spacer()
                            }
                            #else
                            HStack {
                                Text("PIN")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 60, alignment: .trailing)
                                TextField("Enter PIN", text: $config.pin)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 120)
                                Spacer()
                            }
                            #endif
                        }

                        Text(Brand.authFooter)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(Theme.spacingMD)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))
                }
                .padding(.horizontal, Theme.spacingLG)
                .padding(.bottom, Theme.spacingMD)
            }

            Divider()

            // Footer buttons
            HStack {
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, Theme.spacingMD)
                    Text("Connecting...")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    saveAndConnect()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!config.isConfigured || isConnecting)
            }
            .padding(Theme.spacingMD)
        }
        .background(Theme.background)
    }
    #endif

    #if os(iOS)
    private var serverSection: some View {
        Section {
            LabeledContent("Host") {
                TextField("192.168.1.100", text: $config.host)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
            }

            LabeledContent("Port") {
                TextField("\(String(Brand.defaultPort))", value: $config.port, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
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
            if useApiKey {
                LabeledContent("API Key") {
                    SecureField("API Key", text: $config.apiKey)
                        .autocapitalization(.none)
                }
            } else {
                LabeledContent("Username") {
                    TextField("Username", text: $config.username)
                        .autocapitalization(.none)
                }
                LabeledContent("Password") {
                    SecureField("Password", text: $config.password)
                }
            }

            Button(useApiKey ? "Use Username & Password" : "Use API Key") {
                useApiKey.toggle()
            }
            .foregroundStyle(Theme.accent)
            #else
            LabeledContent("PIN") {
                TextField("Enter PIN", text: $config.pin)
                    .keyboardType(.numberPad)
            }
            #endif
        } header: {
            Text("Authentication")
        } footer: {
            Text(Brand.authFooter)
        }
    }
    #endif

    private func saveAndConnect() {
        guard config.isConfigured else { return }

        isConnecting = true
        connectionError = nil

        #if DISPATCHERPVR
        // Clear unused credentials based on auth mode
        if useApiKey {
            config.username = ""
            config.password = ""
        } else {
            config.apiKey = ""
        }
        #endif

        config.save()
        client.updateConfig(config)

        Task {
            do {
                try await client.authenticate()
                isConnecting = false
                dismiss()
            } catch {
                isConnecting = false
                connectionError = error.localizedDescription
            }
        }
    }
}

#Preview {
    ServerConfigView()
        .environmentObject(PVRClient())
        .preferredColorScheme(.dark)
}
