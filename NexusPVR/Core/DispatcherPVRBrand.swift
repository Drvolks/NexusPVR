//
//  DispatcherPVRBrand.swift
//  DispatcherPVR
//
//  Brand configuration for DispatcherPVR
//

import SwiftUI

nonisolated enum DispatcherPVRBrand: BrandConfig {
    // App identity
    static let appName = "Dispatcharr Client"
    static let serverName = "Dispatcharr"
    static let deviceName = "Dispatcharr-Apple"

    // Network defaults
    static let defaultPort = 9191
    static let defaultPIN = ""
    static let authType: AuthType = .usernamePassword

    // User-facing strings
    static let setupPrompt = "Connect to your Dispatcharr server to get started."
    static let serverFooter = "Enter your Dispatcharr server address. Default port is 9191."
    static let authFooter = "Enter your Dispatcharr credentials or API key."
    static let connectionSuccessMessage = "Successfully connected to Dispatcharr server."
    static let configureServerMessage = "Configure your Dispatcharr server in Settings"

    // Discovery
    static let discoveryProbePath = "/proxy/ts/status"

    // Colors — teal palette derived from app icon (#438f7f)
    static let accent = Color(light: Color(hex: "#357265"), dark: Color(hex: "#438f7f"))
    static let accentSecondary = Color(light: Color(hex: "#2a5c52"), dark: Color(hex: "#357265"))
    static let background = Color(light: Color(hex: "#f2f2f7"), dark: Color(hex: "#121214"))
    static let surface = Color(light: Color(hex: "#ffffff"), dark: Color(hex: "#1a1a1e"))
    static let surfaceElevated = Color(light: Color(hex: "#f2f2f7"), dark: Color(hex: "#242428"))
    static let surfaceHighlight = Color(light: Color(hex: "#e5e5ea"), dark: Color(hex: "#2e2e34"))
    static let textPrimary = Color(light: Color(hex: "#1c1c1e"), dark: Color(hex: "#f0f0f2"))
    static let textSecondary = Color(light: Color(hex: "#636366"), dark: Color(hex: "#b0b0b8"))
    static let textTertiary = Color(light: Color(hex: "#aeaeb2"), dark: Color(hex: "#6e6e78"))
    static let success = Color(light: Color(hex: "#2d8a68"), dark: Color(hex: "#3da882"))
    static let warning = Color(light: Color(hex: "#c4872e"), dark: Color(hex: "#e5a03a"))
    static let error = Color(light: Color(hex: "#c43535"), dark: Color(hex: "#d94848"))
    static let recording = Color(light: Color(hex: "#c43535"), dark: Color(hex: "#d94848"))
    static let guideNowPlaying = Color(light: Color(hex: "#d4ece7"), dark: Color(hex: "#1a3630"))
}
