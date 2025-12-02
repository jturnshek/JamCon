import SwiftUI

// MARK: - JamCon Design System
// See DESIGN.md for full documentation

// MARK: - Colors

/// Rainbow spectrum colors - saturated "laser" colors
enum JamConColors {
    // MARK: Rainbow Spectrum

    /// Red - Destructive, disconnect, error
    static let red = Color(light: Color(hex: 0xFF3B30), dark: Color(hex: 0xFF453A))

    /// Orange - Warning, caution
    static let orange = Color(light: Color(hex: 0xFF9500), dark: Color(hex: 0xFF9F0A))

    /// Yellow - Highlight, attention
    static let yellow = Color(light: Color(hex: 0xFFCC00), dark: Color(hex: 0xFFD60A))

    /// Green - Success, connected, enabled
    static let green = Color(light: Color(hex: 0x34C759), dark: Color(hex: 0x30D158))

    /// Cyan - Info, accent
    static let cyan = Color(light: Color(hex: 0x00C7BE), dark: Color(hex: 0x66D4CF))

    /// Blue - Primary accent, links
    static let blue = Color(light: Color(hex: 0x007AFF), dark: Color(hex: 0x0A84FF))

    /// Purple - Secondary accent
    static let purple = Color(light: Color(hex: 0xAF52DE), dark: Color(hex: 0xBF5AF2))

    /// Magenta - Emphasis, special
    static let magenta = Color(light: Color(hex: 0xFF2D55), dark: Color(hex: 0xFF375F))

    /// All rainbow colors in spectrum order
    static let rainbow: [Color] = [red, orange, yellow, green, cyan, blue, purple, magenta]

    /// Get rainbow color by index (wraps around)
    static func rainbow(at index: Int, count: Int) -> Color {
        let normalizedIndex = count > 0 ? index % count : 0
        let colorIndex = Int(Double(normalizedIndex) / Double(max(count, 1)) * Double(rainbow.count))
        return rainbow[min(colorIndex, rainbow.count - 1)]
    }

    // MARK: Semantic Colors

    /// Stroke color for light mode
    static let strokeLight = Color.primary.opacity(0.2)

    /// Stroke color for dark mode
    static let strokeDark = Color.primary.opacity(0.4)

    /// Divider color
    static let divider = Color.primary.opacity(0.1)

    /// Disabled state opacity
    static let disabledOpacity: Double = 0.3
}

// MARK: - Typography

enum JamConFonts {
    /// Title - 15pt medium, for section headers
    static let title = Font.system(size: 15, weight: .medium)

    /// Headline - 13pt medium, for subsection headers
    static let headline = Font.system(size: 13, weight: .medium)

    /// Body - 12pt regular, for general text
    static let body = Font.system(size: 12, weight: .regular)

    /// Caption - 11pt regular, for labels and helper text
    static let caption = Font.system(size: 11, weight: .regular)

    /// Small - 10pt regular, for fine print
    static let small = Font.system(size: 10, weight: .regular)

    /// Mono - 11pt SF Mono, for numbers and values
    static let mono = Font.system(size: 11, weight: .regular, design: .monospaced)

    /// Tracking for geometric feel on headings
    static let headingTracking: CGFloat = 0.3
}

// MARK: - Metrics

enum JamConMetrics {
    // MARK: Stroke Widths

    /// Hairline stroke - 0.5pt, subtle dividers
    static let strokeHairline: CGFloat = 0.5

    /// Thin stroke - 1pt, default borders
    static let strokeThin: CGFloat = 1

    /// Regular stroke - 1.5pt, emphasis
    static let strokeRegular: CGFloat = 1.5

    /// Bold stroke - 2pt, strong emphasis
    static let strokeBold: CGFloat = 2

    // MARK: Corner Radius

    /// No radius - sharp geometric edges
    static let radiusNone: CGFloat = 0

    /// Minimal radius - 2pt, badges and tags
    static let radiusMinimal: CGFloat = 2

    /// Small radius - 4pt, buttons and cards
    static let radiusSmall: CGFloat = 4

    // MARK: Spacing

    /// Extra extra small - 2pt
    static let spacingXXS: CGFloat = 2

    /// Extra small - 4pt
    static let spacingXS: CGFloat = 4

    /// Small - 8pt
    static let spacingSM: CGFloat = 8

    /// Medium - 12pt
    static let spacingMD: CGFloat = 12

    /// Large - 16pt
    static let spacingLG: CGFloat = 16

    /// Extra large - 24pt
    static let spacingXL: CGFloat = 24

    // MARK: Icon Sizes

    /// Small inline icon
    static let iconSmall: CGFloat = 12

    /// Regular inline icon
    static let iconRegular: CGFloat = 14

    /// Large standalone icon
    static let iconLarge: CGFloat = 20
}

// MARK: - View Extensions

extension View {
    /// Apply thin stroke border with a color
    func strokeBorder(_ color: Color, width: CGFloat = JamConMetrics.strokeThin) -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: JamConMetrics.radiusMinimal)
                .strokeBorder(color, lineWidth: width)
        )
    }

    /// Apply hairline divider below
    func hairlineDivider() -> some View {
        self.overlay(alignment: .bottom) {
            Rectangle()
                .fill(JamConColors.divider)
                .frame(height: JamConMetrics.strokeHairline)
        }
    }

    /// Apply heading tracking for geometric feel
    func headingStyle() -> some View {
        self.tracking(JamConFonts.headingTracking)
    }
}

// MARK: - Color Helpers

extension Color {
    /// Create color from hex value
    init(hex: UInt32, opacity: Double = 1.0) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }

    /// Create adaptive color for light/dark modes
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(dark)
            } else {
                return NSColor(light)
            }
        })
    }
}

// MARK: - Stroke Color Environment

private struct StrokeColorKey: EnvironmentKey {
    static let defaultValue: Color = JamConColors.strokeLight
}

extension EnvironmentValues {
    var strokeColor: Color {
        get { self[StrokeColorKey.self] }
        set { self[StrokeColorKey.self] = newValue }
    }
}

// MARK: - Badge Style

/// Outline badge with rainbow color
struct OutlineBadge: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color = JamConColors.blue) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(JamConFonts.small)
            .foregroundColor(color)
            .padding(.horizontal, JamConMetrics.spacingXS)
            .padding(.vertical, JamConMetrics.spacingXXS)
            .overlay(
                RoundedRectangle(cornerRadius: JamConMetrics.radiusMinimal)
                    .strokeBorder(color, lineWidth: JamConMetrics.strokeThin)
            )
    }
}

// MARK: - Section Header Style

/// Section header with thin underline
struct SectionHeader: View {
    let title: String
    let color: Color

    init(_ title: String, color: Color = .primary) {
        self.title = title
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: JamConMetrics.spacingXXS) {
            Text(title)
                .font(JamConFonts.headline)
                .foregroundColor(color)
                .headingStyle()

            Rectangle()
                .fill(color.opacity(0.3))
                .frame(height: JamConMetrics.strokeHairline)
        }
    }
}

// MARK: - Outline Button Style

struct OutlineButtonStyle: ButtonStyle {
    let color: Color

    init(color: Color = JamConColors.blue) {
        self.color = color
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(JamConFonts.caption)
            .foregroundColor(color)
            .padding(.horizontal, JamConMetrics.spacingSM)
            .padding(.vertical, JamConMetrics.spacingXS)
            .background(
                RoundedRectangle(cornerRadius: JamConMetrics.radiusSmall)
                    .fill(configuration.isPressed ? color.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: JamConMetrics.radiusSmall)
                    .strokeBorder(color, lineWidth: JamConMetrics.strokeThin)
            )
    }
}

extension ButtonStyle where Self == OutlineButtonStyle {
    static var outline: OutlineButtonStyle { OutlineButtonStyle() }
    static func outline(color: Color) -> OutlineButtonStyle { OutlineButtonStyle(color: color) }
}

// MARK: - Liquid Glass (macOS 26+)

extension View {
    /// Apply Liquid Glass effect with capsule shape (macOS 26+) or material fallback
    @ViewBuilder
    func liquidGlass() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// Apply Liquid Glass effect with rounded rect shape
    @ViewBuilder
    func liquidGlassRect(cornerRadius: CGFloat = 8) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// Apply Liquid Glass effect with circle shape
    @ViewBuilder
    func liquidGlassCircle() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .circle)
        } else {
            self.background(.ultraThinMaterial, in: Circle())
        }
    }

    /// Apply tinted Liquid Glass effect with capsule shape
    @ViewBuilder
    func liquidGlass(tint color: Color) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(color), in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().fill(color.opacity(0.1)))
        }
    }

    /// Apply interactive Liquid Glass with capsule shape
    @ViewBuilder
    func liquidGlassInteractive() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// MARK: - Glass Badge (Liquid Glass)

/// Badge with Liquid Glass effect
struct GlassBadge: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color = JamConColors.blue) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(JamConFonts.small)
            .foregroundColor(color)
            .padding(.horizontal, JamConMetrics.spacingSM)
            .padding(.vertical, JamConMetrics.spacingXS)
            .liquidGlass(tint: color)
    }
}

// MARK: - Glass Button Style

/// Button with Liquid Glass effect
struct GlassButtonStyle: ButtonStyle {
    let color: Color

    init(color: Color = JamConColors.blue) {
        self.color = color
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(JamConFonts.caption)
            .foregroundColor(color)
            .padding(.horizontal, JamConMetrics.spacingSM)
            .padding(.vertical, JamConMetrics.spacingXS)
            .liquidGlassInteractive()
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var glass: GlassButtonStyle { GlassButtonStyle() }
    static func glass(color: Color) -> GlassButtonStyle { GlassButtonStyle(color: color) }
}
