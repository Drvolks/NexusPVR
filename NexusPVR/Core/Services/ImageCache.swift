//
//  ImageCache.swift
//  nextpvr-apple-client
//
//  In-memory image cache for channel icons and thumbnails
//

import SwiftUI

/// Thread-safe in-memory image cache using NSCache
nonisolated final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, PlatformImage>()
    private let lock = NSLock()

    private init() {
        // Limit cache to ~50MB or 100 images
        cache.totalCostLimit = 50 * 1024 * 1024
        cache.countLimit = 100
    }

    nonisolated func image(for url: URL) -> PlatformImage? {
        lock.lock()
        defer { lock.unlock() }
        return cache.object(forKey: url.absoluteString as NSString)
    }

    nonisolated func setImage(_ image: PlatformImage, for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        // Estimate cost based on image size
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: url.absoluteString as NSString, cost: cost)
    }

    func removeImage(for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeObject(forKey: url.absoluteString as NSString)
    }

    func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAllObjects()
    }

    /// Preload multiple images in the background with concurrency limit
    func preload(urls: [URL], maxConcurrent: Int = 10) {
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var running = 0
                for url in urls {
                    // Skip if already cached
                    if self.image(for: url) != nil { continue }

                    if running >= maxConcurrent {
                        await group.next()
                        running -= 1
                    }

                    running += 1
                    group.addTask {
                        do {
                            let (data, _) = try await URLSession.shared.data(from: url)
                            if let image = PlatformImage(data: data) {
                                self.setImage(image, for: url)
                            }
                        } catch {
                            // Ignore preload failures
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Platform Image Type

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage

extension NSImage {
    nonisolated var size: CGSize {
        let rep = representations.first
        return CGSize(width: rep?.pixelsWide ?? 0, height: rep?.pixelsHigh ?? 0)
    }
}
#else
import UIKit
typealias PlatformImage = UIImage
#endif

// CachedAsyncImage extracted to CachedAsyncImage.swift
