//
//  ContentProvider.swift
//  DispatcherPVR TopShelf
//
//  Provides recent recordings for the tvOS Top Shelf.
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
}

class ContentProvider: TVTopShelfContentProvider {

    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        let config = ServerConfig.loadFromAppGroup()
        guard config.isConfigured else { return nil }

        let recordings = await RecordingFetcher.fetchRecentRecordings(config: config, limit: 5)
        guard !recordings.isEmpty else { return nil }

        let urlScheme = "dispatcharr"
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("topshelf_images", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        var items: [TVTopShelfSectionedItem] = []

        for recording in recordings {
            let item = TVTopShelfSectionedItem(identifier: "\(recording.id)")
            item.title = recording.name

            if let playURL = URL(string: "\(urlScheme)://recording/\(recording.id)") {
                item.playAction = TVTopShelfAction(url: playURL)
                item.displayAction = TVTopShelfAction(url: playURL)
            }

            let imageURL = cacheDir.appendingPathComponent("rec_\(recording.id).png")
            renderTileImage(for: recording, to: imageURL)
            item.setImageURL(imageURL, for: .screenScale1x)
            item.setImageURL(imageURL, for: .screenScale2x)

            items.append(item)
        }

        let section = TVTopShelfItemCollection(items: items)
        section.title = "Recent Recordings"

        return TVTopShelfSectionedContent(sections: [section])
    }

    private func renderTileImage(for recording: Recording, to url: URL) {
        let size = CGSize(width: 548, height: 308)
        let renderer = UIGraphicsImageRenderer(size: size)

        let data = renderer.pngData { context in
            let rect = CGRect(origin: .zero, size: size)
            let ctx = context.cgContext

            // Rounded rect clip
            let cornerRadius: CGFloat = 16
            let path = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)
            path.addClip()

            // Background gradient
            let colors = [TileColors.surfaceElevated.cgColor, TileColors.background.cgColor]
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0.0, 1.0]) {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: size.width / 2, y: 0), end: CGPoint(x: size.width / 2, y: size.height), options: [])
            }

            // Sport icon
            let sport = SportDetector.detect(from: recording)
            let symbolName = sport?.sfSymbol ?? "play.rectangle.fill"
            let iconSize: CGFloat = 80

            if let symbolImage = UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: iconSize, weight: .regular)) {
                let tinted = symbolImage.withTintColor(TileColors.accent.withAlphaComponent(0.7), renderingMode: .alwaysOriginal)
                let iconRect = CGRect(
                    x: (size.width - tinted.size.width) / 2,
                    y: size.height * 0.15,
                    width: tinted.size.width,
                    height: tinted.size.height
                )
                tinted.draw(in: iconRect)
            }

            // Title label (up to 2 lines, word wrap with tail truncation)
            let titleLabel = UILabel()
            titleLabel.text = recording.name
            titleLabel.font = UIFont.systemFont(ofSize: 22, weight: .semibold)
            titleLabel.textColor = TileColors.textPrimary
            titleLabel.textAlignment = .center
            titleLabel.numberOfLines = 2
            titleLabel.lineBreakMode = .byTruncatingTail
            let titleWidth = size.width - 40
            let titleSize = titleLabel.sizeThatFits(CGSize(width: titleWidth, height: 60))
            let titleFrame = CGRect(x: 20, y: size.height * 0.55, width: titleWidth, height: min(titleSize.height, 60))
            titleLabel.frame = titleFrame
            titleLabel.drawText(in: titleFrame)

            // Date + time
            if let startDate = recording.startDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short

                let dateLabel = UILabel()
                dateLabel.text = formatter.string(from: startDate)
                dateLabel.font = UIFont.systemFont(ofSize: 16, weight: .regular)
                dateLabel.textColor = TileColors.textSecondary
                dateLabel.textAlignment = .center
                dateLabel.numberOfLines = 1
                let dateFrame = CGRect(x: 20, y: titleFrame.maxY + 2, width: titleWidth, height: 22)
                dateLabel.frame = dateFrame
                dateLabel.drawText(in: dateFrame)
            }
        }

        try? data.write(to: url)
    }
}
