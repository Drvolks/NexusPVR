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
    static let accent = Color(light: Color(hex: "#0077b6"), dark: Color(hex: "#00a8e8"))
    static let accentSecondary = Color(light: Color(hex: "#0096c7"), dark: Color(hex: "#48cae4"))
    static let background = Color(light: Color(hex: "#f2f2f7"), dark: Color(hex: "#0f0f0f"))
    static let surface = Color(light: Color(hex: "#ffffff"), dark: Color(hex: "#141414"))
    static let surfaceElevated = Color(light: Color(hex: "#f2f2f7"), dark: Color(hex: "#1a1a1a"))
    static let surfaceHighlight = Color(light: Color(hex: "#e5e5ea"), dark: Color(hex: "#222222"))
    static let textPrimary = Color(light: Color(hex: "#1c1c1e"), dark: .white)
    static let textSecondary = Color(light: Color(hex: "#636366"), dark: Color(hex: "#b3b3b3"))
    static let textTertiary = Color(light: Color(hex: "#aeaeb2"), dark: Color(hex: "#666666"))
    static let success = Color(light: Color(hex: "#34a853"), dark: Color(hex: "#4caf50"))
    static let warning = Color(light: Color(hex: "#e67e00"), dark: Color(hex: "#ff9800"))
    static let error = Color(light: Color(hex: "#d32f2f"), dark: Color(hex: "#f44336"))
    static let recording = Color(light: Color(hex: "#c2185b"), dark: Color(hex: "#e91e63"))
    static let guideNowPlaying = Color(light: Color(hex: "#d0e8ff"), dark: Color(hex: "#1e3a5f"))
}
