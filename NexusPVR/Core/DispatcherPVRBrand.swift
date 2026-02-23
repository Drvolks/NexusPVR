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
    static let authFooter = "Enter your Dispatcharr username and password."
    static let connectionSuccessMessage = "Successfully connected to Dispatcharr server."
    static let configureServerMessage = "Configure your Dispatcharr server in Settings"

    // Discovery
    static let discoveryProbePath = "/proxy/ts/status"

    // Colors — teal palette derived from app icon (#438f7f)
    static let accent = Color(hex: "#438f7f")
    static let accentSecondary = Color(hex: "#357265")
    static let background = Color(hex: "#121214")
    static let surface = Color(hex: "#1a1a1e")
    static let surfaceElevated = Color(hex: "#242428")
    static let surfaceHighlight = Color(hex: "#2e2e34")
    static let textPrimary = Color(hex: "#f0f0f2")
    static let textSecondary = Color(hex: "#b0b0b8")
    static let textTertiary = Color(hex: "#6e6e78")
    static let success = Color(hex: "#3da882")
    static let warning = Color(hex: "#e5a03a")
    static let error = Color(hex: "#d94848")
    static let recording = Color(hex: "#d94848")
    static let guideNowPlaying = Color(hex: "#1a3630")
}
