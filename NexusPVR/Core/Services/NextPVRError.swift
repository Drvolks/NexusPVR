//
//  NextPVRError.swift
//  nextpvr-apple-client
//
//  NextPVR API error types
//

import Foundation

enum NextPVRError: Error, LocalizedError {
    case notConfigured
    case authenticationFailed
    case sessionExpired
    case networkError(Error)
    case invalidResponse
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Server not configured"
        case .authenticationFailed:
            return "Authentication failed. Check your PIN."
        case .sessionExpired:
            return "Session expired. Please reconnect."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server"
        case .apiError(let message):
            return message
        }
    }
}
