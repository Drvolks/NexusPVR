//
//  NexusPVRBrand.swift
//  NexusPVR
//
//  Brand configuration for NexusPVR
//

import SwiftUI

nonisolated enum NexusPVRBrand: BrandConfig {
    // App identity
    static let appName = "NextPVR Client"
    static let serverName = "NextPVR"
    static let deviceName = "NextPVR-Apple"

    // Network defaults
    static let defaultPort = 8866
    static let defaultPIN = "0000"
    static let authType: AuthType = .pin

    // User-facing strings
    static let setupPrompt = "Connect to your NextPVR server to get started."
    static let serverFooter = "Enter your NextPVR server address. Default port is 8866."
    static let authFooter = "Enter your NextPVR PIN for authentication."
    static let connectionSuccessMessage = "Successfully connected to NextPVR server."
    static let configureServerMessage = "Configure your NextPVR server in Settings"

    // Discovery
    static let discoveryProbePath = "/services/service?method=session.initiate&ver=1.0&device=probe&format=json"

    // Colors
    static let accent = Color(hex: "#00a8e8")
    static let accentSecondary = Color(hex: "#48cae4")
    static let background = Color(hex: "#0f0f0f")
    static let surface = Color(hex: "#141414")
    static let surfaceElevated = Color(hex: "#1a1a1a")
    static let surfaceHighlight = Color(hex: "#222222")
    static let textPrimary = Color.white
    static let textSecondary = Color(hex: "#b3b3b3")
    static let textTertiary = Color(hex: "#666666")
    static let success = Color(hex: "#4caf50")
    static let warning = Color(hex: "#ff9800")
    static let error = Color(hex: "#f44336")
    static let recording = Color(hex: "#e91e63")
    static let guideNowPlaying = Color(hex: "#1e3a5f")
}
