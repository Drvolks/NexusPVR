//
//  DispatcherPVRBrand.swift
//  DispatcherPVR
//
//  Brand configuration for DispatcherPVR
//

import SwiftUI

enum DispatcherPVRBrand: BrandConfig {
    // App identity
    static let appName = "Dispatcharr"
    static let serverName = "Dispatcharr"
    static let subtitle = "Apple Client"
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

    // Colors
    static let accent = Color(hex: "#2563eb")
    static let accentSecondary = Color(hex: "#1e40af")
    static let background = Color(hex: "#0f0f0f")
    static let surface = Color(hex: "#1a1a1a")
    static let surfaceElevated = Color(hex: "#2a2a2a")
    static let surfaceHighlight = Color(hex: "#333333")
    static let textPrimary = Color(hex: "#f9fafb")
    static let textSecondary = Color(hex: "#d1d5db")
    static let textTertiary = Color(hex: "#9ca3af")
    static let success = Color(hex: "#10b981")
    static let warning = Color(hex: "#f59e0b")
    static let error = Color(hex: "#ef4444")
    static let recording = Color(hex: "#ef4444")
    static let guideNowPlaying = Color(hex: "#1e3a5f")
}
