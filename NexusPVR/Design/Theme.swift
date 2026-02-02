//
//  Theme.swift
//  nextpvr-apple-client
//
//  UHF-inspired design system
//

import SwiftUI

// MARK: - Colors

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

enum Theme {
    // MARK: - Primary Colors (NextPVR branding)

    static let accent = Color(hex: "#00a8e8")        // Bright cyan-blue
    static let accentSecondary = Color(hex: "#48cae4") // Lighter cyan

    // MARK: - Background Colors

    static let background = Color(hex: "#0f0f0f")    // Deep dark
    static let surface = Color(hex: "#141414")       // Card/surface
    static let surfaceElevated = Color(hex: "#1a1a1a") // Elevated surface
    static let surfaceHighlight = Color(hex: "#222222") // Highlighted surface

    // MARK: - Text Colors

    static let textPrimary = Color.white
    static let textSecondary = Color(hex: "#b3b3b3")
    static let textTertiary = Color(hex: "#666666")

    // MARK: - Status Colors

    static let success = Color(hex: "#4caf50")
    static let warning = Color(hex: "#ff9800")
    static let error = Color(hex: "#f44336")
    static let recording = Color(hex: "#e91e63")     // Recording indicator

    // MARK: - Guide Colors

    static let guideNowPlaying = Color(hex: "#1e3a5f") // Current program highlight
    static let guidePast = Color(hex: "#1a1a1a").opacity(0.5) // Past programs
    static let guideScheduled = accent.opacity(0.3)  // Scheduled recording

    // MARK: - Spacing

    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 16
    static let spacingLG: CGFloat = 24
    static let spacingXL: CGFloat = 32

    // MARK: - Corner Radius

    static let cornerRadiusSM: CGFloat = 8
    static let cornerRadiusMD: CGFloat = 12
    static let cornerRadiusLG: CGFloat = 20

    // MARK: - Animation

    static let animationDuration: Double = 0.25
    static let springAnimation = Animation.spring(response: 0.3, dampingFraction: 0.8)

    // MARK: - Platform-specific sizing

    #if os(tvOS)
    static let cellHeight: CGFloat = 100
    static let channelColumnWidth: CGFloat = 200
    static let hourColumnWidth: CGFloat = 600
    static let iconSize: CGFloat = 80
    #else
    static let cellHeight: CGFloat = 60
    static let channelColumnWidth: CGFloat = 72
    static let hourColumnWidth: CGFloat = 300
    static let iconSize: CGFloat = 48
    #endif
}

// MARK: - View Modifiers

struct CardStyle: ViewModifier {
    var isSelected: Bool = false

    func body(content: Content) -> some View {
        content
            .background(isSelected ? Theme.surfaceHighlight : Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))
    }
}

struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Theme.spacingLG)
            .padding(.vertical, Theme.spacingMD)
            .background(isEnabled ? Theme.accent : Theme.textTertiary)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Theme.spacingLG)
            .padding(.vertical, Theme.spacingMD)
            .background(Theme.surfaceElevated)
            .foregroundStyle(Theme.textPrimary)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

#if os(tvOS)
struct TVNavigationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVNavigationFocusWrapper {
            configuration.label
        }
    }
}

private struct TVNavigationFocusWrapper<Content: View>: View {
    @Environment(\.isFocused) private var isFocused
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .foregroundStyle(isFocused ? Color(white: 0.1) : Theme.textSecondary)
            .background(isFocused ? Color.white : Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
            .scaleEffect(isFocused ? 1.1 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// Button style for guide grid cells with prominent focus indication
struct TVGuideButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVGuideFocusWrapper {
            configuration.label
        }
    }
}

/// Wrapper view to properly detect focus state on tvOS
private struct TVGuideFocusWrapper<Content: View>: View {
    @Environment(\.isFocused) private var isFocused
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: Theme.cornerRadiusSM)
                        .strokeBorder(Color.white, lineWidth: 4)
                }
            }
            .shadow(color: isFocused ? Color.white.opacity(0.5) : .clear, radius: 15)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

/// Button style for channel icons in the guide with prominent focus indication
struct TVChannelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVChannelFocusWrapper {
            configuration.label
        }
    }
}

/// Wrapper view to properly detect focus state on tvOS for channel buttons
private struct TVChannelFocusWrapper<Content: View>: View {
    @Environment(\.isFocused) private var isFocused
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .scaleEffect(isFocused ? 1.1 : 1.0)
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: Theme.cornerRadiusSM)
                        .strokeBorder(Color.white, lineWidth: 4)
                }
            }
            .shadow(color: isFocused ? Color.white.opacity(0.5) : .clear, radius: 15)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }
}

struct TVTextField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: (() -> Void)? = nil
    @State private var isEditing = false
    @State private var editingText = ""

    var body: some View {
        Button {
            editingText = text
            isEditing = true
        } label: {
            HStack {
                Text(text.isEmpty ? placeholder : text)
                    .foregroundStyle(text.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                Spacer()
                Image(systemName: "pencil")
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding()
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
        }
        .buttonStyle(.card)
        .alert(placeholder, isPresented: $isEditing) {
            TextField(placeholder, text: $editingText)
            Button("OK") {
                text = editingText
                onSubmit?()
            }
            Button("Cancel", role: .cancel, action: {})
        }
    }
}

struct TVNumberField: View {
    let placeholder: String
    @Binding var value: Int
    @State private var isEditing = false
    @State private var textValue: String = ""

    var body: some View {
        Button {
            textValue = value == 0 ? "" : String(value)
            isEditing = true
        } label: {
            HStack {
                Text(value == 0 ? placeholder : String(value))
                    .foregroundStyle(value == 0 ? Theme.textTertiary : Theme.textPrimary)
                Spacer()
                Image(systemName: "pencil")
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding()
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusSM))
        }
        .buttonStyle(.card)
        .alert(placeholder, isPresented: $isEditing) {
            TextField(placeholder, text: $textValue)
                .keyboardType(.numberPad)
            Button("OK") {
                if let intValue = Int(textValue) {
                    value = intValue
                }
            }
            Button("Cancel", role: .cancel, action: {})
        }
    }
}

struct TVSettingsSection<Content: View, StatusView: View>: View {
    let title: String
    let icon: String
    var footer: String? = nil
    var statusView: StatusView?
    @ViewBuilder let content: Content

    init(
        title: String,
        icon: String,
        footer: String? = nil,
        @ViewBuilder statusView: () -> StatusView,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.footer = footer
        self.statusView = statusView()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingMD) {
            // Header
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let statusView {
                    statusView
                }
            }
            .padding(.horizontal, Theme.spacingMD)
            .padding(.top, Theme.spacingMD)

            // Content
            content
                .padding(.horizontal, Theme.spacingMD)
                .padding(.bottom, Theme.spacingMD)

            // Footer
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.spacingMD)
                    .padding(.bottom, Theme.spacingSM)
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusMD))
    }
}

extension TVSettingsSection where StatusView == EmptyView {
    init(
        title: String,
        icon: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.footer = footer
        self.statusView = nil
        self.content = content()
    }
}
#endif

extension View {
    func cardStyle(isSelected: Bool = false) -> some View {
        modifier(CardStyle(isSelected: isSelected))
    }
}

// MARK: - Typography

extension Font {
    static let displayLarge = Font.system(size: 34, weight: .bold)
    static let displayMedium = Font.system(size: 28, weight: .bold)
    static let headline = Font.system(size: 20, weight: .semibold)
    static let subheadline = Font.system(size: 16, weight: .medium)
    static let body = Font.system(size: 16, weight: .regular)
    static let caption = Font.system(size: 14, weight: .regular)
    static let footnote = Font.system(size: 12, weight: .regular)

    #if os(tvOS)
    static let tvTitle = Font.system(size: 48, weight: .bold)
    static let tvHeadline = Font.system(size: 32, weight: .semibold)
    static let tvBody = Font.system(size: 28, weight: .regular)
    static let tvCaption = Font.system(size: 24, weight: .regular)
    #endif
}

// MARK: - Preview Helpers

#Preview("Theme Colors") {
    ScrollView {
        VStack(alignment: .leading, spacing: Theme.spacingMD) {
            Group {
                Text("Theme Colors")
                    .font(.displayMedium)
                    .foregroundStyle(Theme.textPrimary)

                HStack(spacing: Theme.spacingSM) {
                    colorSwatch(Theme.accent, "Accent")
                    colorSwatch(Theme.accentSecondary, "Secondary")
                    colorSwatch(Theme.recording, "Recording")
                }

                HStack(spacing: Theme.spacingSM) {
                    colorSwatch(Theme.background, "Background")
                    colorSwatch(Theme.surface, "Surface")
                    colorSwatch(Theme.surfaceElevated, "Elevated")
                }

                HStack(spacing: Theme.spacingSM) {
                    colorSwatch(Theme.success, "Success")
                    colorSwatch(Theme.warning, "Warning")
                    colorSwatch(Theme.error, "Error")
                }
            }

            Divider()

            Group {
                Text("Buttons")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)

                HStack(spacing: Theme.spacingMD) {
                    Button("Primary") {}
                        .buttonStyle(AccentButtonStyle())

                    Button("Secondary") {}
                        .buttonStyle(SecondaryButtonStyle())
                }
            }

            Divider()

            Group {
                Text("Cards")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)

                HStack(spacing: Theme.spacingMD) {
                    Text("Normal Card")
                        .padding()
                        .cardStyle()

                    Text("Selected Card")
                        .padding()
                        .cardStyle(isSelected: true)
                }
                .foregroundStyle(Theme.textPrimary)
            }
        }
        .padding()
    }
    .background(Theme.background)
}

@ViewBuilder
private func colorSwatch(_ color: Color, _ name: String) -> some View {
    VStack {
        RoundedRectangle(cornerRadius: Theme.cornerRadiusSM)
            .fill(color)
            .frame(width: 60, height: 60)
        Text(name)
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
    }
}
