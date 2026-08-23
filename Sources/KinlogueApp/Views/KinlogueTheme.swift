import SwiftUI

enum KinlogueTheme {
    static let primary = Color(hex: 0x1E6254)
    static let primaryHover = Color(hex: 0x15453B)
    static let primaryPressed = Color(hex: 0x0F322B)

    static let surface = Color(hex: 0xFFF8F5)
    static let container = Color(hex: 0xF5ECE7)
    static let accent = Color(hex: 0xDF8A4A)
    static let onSurface = Color(hex: 0x1E1B18)
    static let onVariant = Color(hex: 0x3F4946)
    static let outline = Color(hex: 0xBFC9C4)
    static let chip = Color(hex: 0xE9E1DC)
    static let selection = container
    static let selectionForeground = primary
    static let selectionHover = primary.opacity(0.08)
    static let card = Color.white
    static let cardHover = Color(hex: 0xFBF2ED)
}

enum KinlogueChipTone {
    case neutral
    case selected
    case accent
}

struct KinloguePrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(background(for: configuration), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(.white.opacity(0.85), lineWidth: 1)
                }
            }
            .shadow(
                color: .black.opacity(isHovering && isEnabled ? 0.18 : 0.08),
                radius: isHovering && isEnabled ? 5 : 2,
                y: isHovering && isEnabled ? 3 : 1
            )
            .scaleEffect(
                configuration.isPressed && !reduceMotion ? 0.95 : 1
            )
            .opacity(isEnabled ? 1 : 0.48)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: isHovering
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.08),
                value: configuration.isPressed
            )
            .onHover { isHovering = $0 }
    }

    private func background(for configuration: Configuration) -> Color {
        if configuration.isPressed { return KinlogueTheme.primaryPressed }
        if isHovering && isEnabled { return KinlogueTheme.primaryHover }
        return KinlogueTheme.primary
    }
}

struct KinlogueSecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.medium)
            .foregroundStyle(KinlogueTheme.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(background(for: configuration), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(
                        contrast == .increased || isHovering
                            ? KinlogueTheme.primary
                            : KinlogueTheme.outline,
                        lineWidth: contrast == .increased ? 2 : 1
                    )
            }
            .offset(y: configuration.isPressed && !reduceMotion ? 1 : 0)
            .opacity(isEnabled ? 1 : 0.48)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: isHovering
            )
            .onHover { isHovering = $0 }
    }

    private func background(for configuration: Configuration) -> Color {
        if configuration.isPressed { return KinlogueTheme.primary.opacity(0.20) }
        if isHovering && isEnabled { return KinlogueTheme.primary.opacity(0.10) }
        return .clear
    }
}

struct KinlogueCardButtonStyle: ButtonStyle {
    let isHighlighted: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(KinlogueTheme.onSurface)
            .padding(16)
            .background(
                isHovering ? KinlogueTheme.cardHover : KinlogueTheme.card,
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        isHighlighted ? KinlogueTheme.primary : KinlogueTheme.outline,
                        lineWidth: isHighlighted || contrast == .increased ? 2 : 1
                    )
            }
            .shadow(
                color: .black.opacity(isHovering ? 0.13 : 0.06),
                radius: isHovering ? 8 : 3,
                y: isHovering ? 4 : 1
            )
            .scaleEffect(
                configuration.isPressed && !reduceMotion ? 0.95 : 1
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: isHovering
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.08),
                value: configuration.isPressed
            )
            .onHover { isHovering = $0 }
    }
}

private struct KinlogueChipModifier: ViewModifier {
    let tone: KinlogueChipTone

    func body(content: Content) -> some View {
        content
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch tone {
        case .neutral: KinlogueTheme.onVariant
        case .selected: .white
        case .accent: KinlogueTheme.onSurface
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: KinlogueTheme.chip
        case .selected: KinlogueTheme.primary
        case .accent: KinlogueTheme.accent
        }
    }
}

extension ButtonStyle where Self == KinloguePrimaryButtonStyle {
    static var kinloguePrimary: KinloguePrimaryButtonStyle { .init() }
}

extension ButtonStyle where Self == KinlogueSecondaryButtonStyle {
    static var kinlogueSecondary: KinlogueSecondaryButtonStyle { .init() }
}

extension ButtonStyle where Self == KinlogueCardButtonStyle {
    static func kinlogueCard(isHighlighted: Bool) -> KinlogueCardButtonStyle {
        .init(isHighlighted: isHighlighted)
    }
}

extension View {
    func kinlogueChip(_ tone: KinlogueChipTone = .neutral) -> some View {
        modifier(KinlogueChipModifier(tone: tone))
    }
}

private extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
