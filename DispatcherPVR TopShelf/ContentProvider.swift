//
//  ContentProvider.swift
//  DispatcherPVR TopShelf
//
//  Provides recent recordings and live programs for the tvOS Top Shelf.
//

import TVServices
import UIKit

private extension UIColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

// Brand colors as UIColor (avoids SwiftUI import)
private enum TileColors {
    static let accent = UIColor(hex: "438f7f")
    static let background = UIColor(hex: "121214")
    static let surfaceElevated = UIColor(hex: "242428")
    static let textPrimary = UIColor(hex: "f0f0f2")
    static let textSecondary = UIColor(hex: "b0b0b8")
    static let liveRed = UIColor(hex: "d94848")
}

class ContentProvider: TVTopShelfContentProvider {

    private let urlScheme = "dispatcharr"
    private lazy var cacheDir: URL = {
        // Images must be in the extension's own container — the system process
        // that renders Top Shelf tiles cannot read from the app group container.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("topshelf_images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        let config = ServerConfig.loadFromAppGroup()
        guard config.isConfigured else { return nil }

        var items: [TVTopShelfSectionedItem] = []
        var usedChannelIds: Set<Int> = []

        // Tier 1: Recent recordings (up to 4)
        let recordings = await RecordingFetcher.fetchRecentRecordings(config: config, limit: 4)
        for recording in recordings {
            items.append(makeRecordingItem(recording))
            if let chId = recording.channelId { usedChannelIds.insert(chId) }
        }

        // Tier 2: Topic-matched live programs
        if items.count < 4 {
            let prefs = UserPreferences.loadFromAppGroup()
            if !prefs.keywords.isEmpty {
                let needed = 4 - items.count
                let topicMatches = await LiveProgramFetcher.fetchCurrentByKeywords(
                    config: config, keywords: prefs.keywords,
                    excludeChannelIds: usedChannelIds, limit: needed
                )
                for program in topicMatches {
                    items.append(makeLiveItem(program))
                    usedChannelIds.insert(program.channelId)
                }
            }
        }

        // Tier 3: Recently watched channels
        if items.count < 4 {
            let history = WatchHistory.loadFromAppGroup()
            if !history.recentChannels.isEmpty {
                let needed = 4 - items.count
                let channelIds = history.recentChannels.map { $0.channelId }
                let channelMatches = await LiveProgramFetcher.fetchCurrentForChannels(
                    config: config, channelIds: channelIds,
                    excludeChannelIds: usedChannelIds, limit: needed
                )
                for program in channelMatches {
                    items.append(makeLiveItem(program))
                    usedChannelIds.insert(program.channelId)
                }
            }
        }

        guard !items.isEmpty else { return nil }

        let section = TVTopShelfItemCollection(items: items)
        section.title = items.count == recordings.count ? "Recent Recordings" : "Recommended"
        return TVTopShelfSectionedContent(sections: [section])
    }

    // MARK: - Item Builders

    private func makeRecordingItem(_ recording: Recording) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: "rec-\(recording.id)")
        item.title = " "
        item.imageShape = .hdtv

        if let playURL = URL(string: "\(urlScheme)://recording/\(recording.id)") {
            item.playAction = TVTopShelfAction(url: playURL)
            item.displayAction = TVTopShelfAction(url: playURL)
        }

        let imageURL = cacheDir.appendingPathComponent("rec_\(recording.id).png")
        renderRecordingTile(recording, to: imageURL)
        item.setImageURL(imageURL, for: .screenScale1x)
        item.setImageURL(imageURL, for: .screenScale2x)
        return item
    }

    private func makeLiveItem(_ program: TopShelfProgram) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: "live-\(program.channelId)")
        item.title = " "
        item.imageShape = .hdtv

        if let playURL = URL(string: "\(urlScheme)://channel/\(program.channelId)") {
            item.playAction = TVTopShelfAction(url: playURL)
            item.displayAction = TVTopShelfAction(url: playURL)
        }

        let imageURL = cacheDir.appendingPathComponent("live_\(program.channelId).png")
        renderLiveTile(program, to: imageURL)
        item.setImageURL(imageURL, for: .screenScale1x)
        item.setImageURL(imageURL, for: .screenScale2x)
        return item
    }

    // MARK: - Tile Rendering

    private func renderRecordingTile(_ recording: Recording, to url: URL) {
        let size = CGSize(width: 548, height: 308)
        let data = UIGraphicsImageRenderer(size: size).pngData { context in
            let ctx = context.cgContext
            drawTileBackground(in: ctx, size: size)

            let sport = SportDetector.detect(from: recording)
            drawIcon(sport?.sfSymbol ?? "play.rectangle.fill", in: ctx, size: size)
            drawTitle(recording.name, in: ctx, size: size)

            if let startDate = recording.startDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                drawSubtitle(formatter.string(from: startDate), in: ctx, size: size)
            }
        }
        try? data.write(to: url)
    }

    private func renderLiveTile(_ program: TopShelfProgram, to url: URL) {
        let size = CGSize(width: 548, height: 308)
        let data = UIGraphicsImageRenderer(size: size).pngData { context in
            let ctx = context.cgContext
            drawTileBackground(in: ctx, size: size)

            let sport = SportDetector.detect(name: program.programName, desc: program.desc, genres: program.genres)
            drawIcon(sport?.sfSymbol ?? "tv", in: ctx, size: size)
            drawTitle(program.programName, in: ctx, size: size)
            drawSubtitle("LIVE · \(program.channelName)", in: ctx, size: size)

            // Live indicator dot
            let dotSize: CGFloat = 10
            let dotRect = CGRect(x: 16, y: 16, width: dotSize, height: dotSize)
            ctx.setFillColor(TileColors.liveRed.cgColor)
            ctx.fillEllipse(in: dotRect)
        }
        try? data.write(to: url)
    }

    // MARK: - Shared Drawing

    private func drawTileBackground(in ctx: CGContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 16)
        path.addClip()

        let colors = [TileColors.surfaceElevated.cgColor, TileColors.background.cgColor]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: size.width / 2, y: 0), end: CGPoint(x: size.width / 2, y: size.height), options: [])
        }
    }

    private func drawIcon(_ symbolName: String, in ctx: CGContext, size: CGSize) {
        if let image = UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 80, weight: .regular)) {
            let tinted = image.withTintColor(TileColors.accent.withAlphaComponent(0.7), renderingMode: .alwaysOriginal)
            tinted.draw(in: CGRect(
                x: (size.width - tinted.size.width) / 2,
                y: size.height * 0.15,
                width: tinted.size.width,
                height: tinted.size.height
            ))
        }
    }

    private let textInset: CGFloat = 48

    private func drawTitle(_ text: String, in ctx: CGContext, size: CGSize) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byWordWrapping

        let font = UIFont.systemFont(ofSize: 22, weight: .semibold)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: TileColors.textPrimary,
            .paragraphStyle: paragraphStyle
        ]

        let width = size.width - textInset * 2
        // Allow up to 2 lines of text
        let maxHeight = ceil(font.lineHeight) * 2 + ceil(font.leading)
        let frame = CGRect(x: textInset, y: size.height * 0.55, width: width, height: maxHeight)
        let attrString = NSAttributedString(string: text, attributes: attrs)
        attrString.draw(with: frame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    private func drawSubtitle(_ text: String, in ctx: CGContext, size: CGSize) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byTruncatingTail

        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16, weight: .regular),
            .foregroundColor: TileColors.textSecondary,
            .paragraphStyle: paragraphStyle
        ]

        let frame = CGRect(x: textInset, y: size.height * 0.82, width: size.width - textInset * 2, height: 22)
        (text as NSString).draw(in: frame, withAttributes: attrs)
    }
}
