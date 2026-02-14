//
//  ImageCache.swift
//  nextpvr-apple-client
//
//  In-memory image cache for channel icons and thumbnails
//

import SwiftUI

/// Thread-safe in-memory image cache using NSCache
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, PlatformImage>()
    private let lock = NSLock()

    private init() {
        // Limit cache to ~50MB or 100 images
        cache.totalCostLimit = 50 * 1024 * 1024
        cache.countLimit = 100
    }

    func image(for url: URL) -> PlatformImage? {
        lock.lock()
        defer { lock.unlock() }
        return cache.object(forKey: url.absoluteString as NSString)
    }

    func setImage(_ image: PlatformImage, for url: URL) {
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

    /// Preload multiple images in the background
    func preload(urls: [URL]) {
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for url in urls {
                    // Skip if already cached
                    if self.image(for: url) != nil { continue }

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
    var size: CGSize {
        let rep = representations.first
        return CGSize(width: rep?.pixelsWide ?? 0, height: rep?.pixelsHigh ?? 0)
    }
}
#else
import UIKit
typealias PlatformImage = UIImage
#endif

// MARK: - Cached Async Image View

struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var loadedImage: PlatformImage?
    @State private var isLoading = false
    @State private var loadFailed = false

    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image = loadedImage {
                #if os(macOS)
                content(Image(nsImage: image))
                #else
                content(Image(uiImage: image))
                #endif
            } else if url != nil && !loadFailed {
                placeholder()
                    .onAppear {
                        loadImage()
                    }
            } else {
                // No URL provided — show static fallback instead of an infinite spinner
                Image(systemName: "tv")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadImage() {
        guard let url = url, !isLoading else { return }

        // Check cache first
        if let cached = ImageCache.shared.image(for: url) {
            loadedImage = cached
            return
        }

        isLoading = true

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = PlatformImage(data: data) {
                    ImageCache.shared.setImage(image, for: url)
                    await MainActor.run {
                        loadedImage = image
                        isLoading = false
                    }
                } else {
                    await MainActor.run {
                        isLoading = false
                        loadFailed = true
                    }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    loadFailed = true
                }
            }
        }
    }
}

// Convenience initializer for common use case
extension CachedAsyncImage where Placeholder == ProgressView<EmptyView, EmptyView> {
    init(url: URL?, @ViewBuilder content: @escaping (Image) -> Content) {
        self.init(url: url, content: content, placeholder: { ProgressView() })
    }
}
