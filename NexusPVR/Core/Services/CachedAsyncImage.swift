//
//  CachedAsyncImage.swift
//  nextpvr-apple-client
//
//  Cached async image view using ImageCache
//

import SwiftUI

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
                    .foregroundColor(.secondary)
            }
        }
        .onChange(of: url) { newURL in
            // Row views are reused (especially on tvOS). Reset state when URL changes
            // so logos don't stick from the previous channel.
            loadedImage = nil
            loadFailed = false
            isLoading = false

            guard let newURL else { return }
            if let cached = ImageCache.shared.image(for: newURL) {
                loadedImage = cached
            } else {
                loadImage()
            }
        }
    }

    private func loadImage() {
        guard let url = url, !isLoading else { return }
        let requestedURL = url

        // Check cache first
        if let cached = ImageCache.shared.image(for: requestedURL) {
            loadedImage = cached
            return
        }

        isLoading = true

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: requestedURL)
                if let image = PlatformImage(data: data) {
                    ImageCache.shared.setImage(image, for: requestedURL)
                    await MainActor.run {
                        guard self.url == requestedURL else { return }
                        loadedImage = image
                        isLoading = false
                    }
                } else {
                    await MainActor.run {
                        guard self.url == requestedURL else { return }
                        isLoading = false
                        loadFailed = true
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.url == requestedURL else { return }
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
