//
//  GPUAPI.swift
//  nextpvr-apple-client
//
//  GPU rendering API options
//

import Foundation

enum GPUAPI: String, Codable, CaseIterable {
    case metal
    case opengl
    case pixelbuffer
}
