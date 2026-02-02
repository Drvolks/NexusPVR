//
//  MD5Hasher.swift
//  nextpvr-apple-client
//
//  MD5 hashing utility for NextPVR authentication
//

import Foundation
import CryptoKit

enum MD5Hasher {
    static func hash(_ string: String) -> String {
        let data = Data(string.utf8)
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
