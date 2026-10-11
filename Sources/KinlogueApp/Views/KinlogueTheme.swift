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
    static let onVariantSubtle = onVariant.opacity(0.6)
    static let outline = Color(hex: 0xBFC9C4)
    static let chip = Color(hex: 0xE9E1DC)
    static let card = Color.white
    static let cardHover = Color(hex: 0xFBF2ED)

    // Row layers stay translucent so one value reads on Surface, Card and
    // Container, and so selected is always heavier than hover.
    static let selection = primary.opacity(0.13)
    static let selectionForeground = primary
    static let selectionHover = primary.opacity(0.05)
    static let selectionPressed = primary.opacity(0.18)

    static let success = primary
    static let warning = Color(hex: 0x8A4712)
    static let warningContainer = Color(hex: 0xFFF4E9)
    static let danger = Color(hex: 0x8A302D)
    static let dangerContainer = Color(hex: 0xF4E2DF)
    static let dangerContainerHover = Color(hex: 0xEDD3CF)
    static let dangerContainerPressed = Color(hex: 0xE6C4BF)

    enum Radius {
        static let control: CGFloat = 8
        static let card: CGFloat = 12
        static let interactiveCard: CGFloat = 16
    }

    static func rowFill(isSelected: Bool, isHovering: Bool, isPressed: Bool) -> Color {
        if isPressed { return selectionPressed }
        if isSelected { return selection }
        if isHovering { return selectionHover }
        return .clear
    }
}

enum KinlogueChipTone {
    case neutral
    case selected
    case accent
}

enum KinloguePanelTone {
    case container
    case card
    case warning
}

enum KinlogueGhostTone {
    case primary
    case neutral
    case danger
}

enum KinlogueStatusTone {
    case success
    case warning
    case danger

    var color: Color {
        switch self {
        case .success: KinlogueTheme.success
        case .warning: KinlogueTheme.warning
        case .danger: KinlogueTheme.danger
        }
    }

    var systemImage: String {
        switch self {
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .danger: "exclamationmark.octagon"
        }
    }
}

/// Hover and press tracking for list rows whose fill spans more than the
/// button itself, such as a navigation label with a trailing menu.
struct KinlogueRowInteraction<ID: Hashable> {
    private(set) var hoveredID: ID?
    private(set) var pressedID: ID?

    mutating func setHovering(_ isHovering: Bool, for id: ID) {
        if isHovering {
            hoveredID = id
        } else if hoveredID == id {
            hoveredID = nil
        }
    }

    mutating func setPressed(_ isPressed: Bool, for id: ID) {
        if isPressed {
            pressedID = id
        } else if pressedID == id {
            pressedID = nil
        }
    }

    func fill(for id: ID, isSelected: Bool) -> Color {
        KinlogueTheme.rowFill(
            isSelected: isSelected,
            isHovering: hoveredID == id,
            isPressed: pressedID == id
        )
    }
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
            .background(
                background(for: configuration),
                in: RoundedRectangle(cornerRadius: KinlogueTheme.Radius.control)
            )
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: KinlogueTheme.Radius.control)
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
            .background(
                background(for: configuration),
                in: RoundedRectangle(cornerRadius: KinlogueTheme.Radius.control)
            )
            .overlay {
                RoundedRectangle(cornerRadius: KinlogueTheme.Radius.control)
                    .stroke(
                        contrast == .increased || (isHovering && isEnabled)
                            ? KinlogueTheme.primary
                            : KinlogueTheme.outline,
                        lineWidth: contrast == .increased ? 2 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: KinlogueTheme.Radius.control))
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

struct KinlogueDestructiveButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.medium)
            .foregroundStyle(KinlogueTheme.danger)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                background(for: configuration),
                in: RoundedRectangle(cornerRadius: KinlogueTheme.Radius.control)
            )
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: KinlogueTheme.Radius.control)
                        .stroke(KinlogueTheme.danger, lineWidth: 2)
                }
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
        if configuration.isPressed { return KinlogueTheme.dangerContainerPressed }
        if isHovering && isEnabled { return KinlogueTheme.dangerContainerHover }
        return KinlogueTheme.dangerContainer
    }
}

/// Borderless control for icon-only and compact inline actions.
struct KinlogueGhostButtonStyle: ButtonStyle {
    let tone: KinlogueGhostTone

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .frame(minWidth: 28, minHeight: 28)
            .background(
                background(for: configuration),
                in: RoundedRectangle(cornerRadius: KinlogueTheme.Radius.control)
            )
            .overlay {
                if contrast == .increased && isHovering && isEnabled {
                    RoundedRectangle(cornerRadius: KinlogueTheme.Radius.control)
                        .stroke(foreground, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: KinlogueTheme.Radius.control))
            .opacity(isEnabled ? 1 : 0.4)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: isHovering
            )
            .onHover { isHovering = $0 }
    }

    private var foreground: Color {
        switch tone {
        case .primary: KinlogueTheme.primary
        case .neutral: KinlogueTheme.onVariant
        case .danger: KinlogueTheme.danger
        }
    }

    private func background(for configuration: Configuration) -> Color {
        switch tone {
        case .primary, .neutral:
            if configuration.isPressed { return KinlogueTheme.primary.opacity(0.20) }
            if isHovering && isEnabled { return KinlogueTheme.primary.opacity(0.10) }
        case .danger:
            if configuration.isPressed { return KinlogueTheme.dangerContainerHover }
            if isHovering && isEnabled { return KinlogueTheme.dangerContainer }
        }
        return .clear
    }
}

/// Plain-looking row button. The row that owns it draws one shared fill, so
/// the style only reports the pressed state instead of painting its own.
struct KinlogueRowButtonStyle: ButtonStyle {
    let onPressedChange: (Bool) -> Void

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.48)
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressedChange(isPressed)
            }
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
                in: RoundedRectangle(cornerRadius: KinlogueTheme.Radius.interactiveCard)
            )
            .overlay {
                RoundedRectangle(cornerRadius: KinlogueTheme.Radius.interactiveCard)
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

/// Icon plus text status line. The symbol differs per tone so the meaning
/// never depends on color alone.
struct KinlogueStatusLabel: View {
    let text: String
    let tone: KinlogueStatusTone

    init(_ text: String, tone: KinlogueStatusTone) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Label(text, systemImage: tone.systemImage)
            .foregroundStyle(tone.color)
    }
}

/// Full-sentence warning. Body text stays On Surface because the warning
/// tone is reserved for the symbol and short labels.
struct KinlogueWarningNotice: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(KinlogueTheme.onSurface)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: KinlogueStatusTone.warning.systemImage)
                .foregroundStyle(KinlogueTheme.warning)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kinloguePanel(.warning, cornerRadius: KinlogueTheme.Radius.control)
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

private struct KinloguePanelModifier: ViewModifier {
    let tone: KinloguePanelTone
    let cornerRadius: CGFloat

    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(stroke, lineWidth: contrast == .increased ? 2 : 1)
            }
    }

    private var fill: Color {
        switch tone {
        case .container: KinlogueTheme.container
        case .card: KinlogueTheme.card
        case .warning: KinlogueTheme.warningContainer
        }
    }

    private var stroke: Color {
        switch tone {
        case .container, .card: KinlogueTheme.outline
        case .warning: KinlogueTheme.accent
        }
    }
}

extension ButtonStyle where Self == KinloguePrimaryButtonStyle {
    static var kinloguePrimary: KinloguePrimaryButtonStyle { .init() }
}

extension ButtonStyle where Self == KinlogueSecondaryButtonStyle {
    static var kinlogueSecondary: KinlogueSecondaryButtonStyle { .init() }
}

extension ButtonStyle where Self == KinlogueDestructiveButtonStyle {
    static var kinlogueDestructive: KinlogueDestructiveButtonStyle { .init() }
}

extension ButtonStyle where Self == KinlogueGhostButtonStyle {
    static var kinlogueGhost: KinlogueGhostButtonStyle { .init(tone: .primary) }

    static func kinlogueGhost(_ tone: KinlogueGhostTone) -> KinlogueGhostButtonStyle {
        .init(tone: tone)
    }
}

extension ButtonStyle where Self == KinlogueRowButtonStyle {
    static func kinlogueRow(
        onPressedChange: @escaping (Bool) -> Void
    ) -> KinlogueRowButtonStyle {
        .init(onPressedChange: onPressedChange)
    }
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

    /// Static container. Container holds read-only information, Card holds
    /// controls or the one block a sheet is about, Warning mirrors the phone
    /// upload page notice.
    func kinloguePanel(
        _ tone: KinloguePanelTone = .container,
        cornerRadius: CGFloat = KinlogueTheme.Radius.card
    ) -> some View {
        modifier(KinloguePanelModifier(tone: tone, cornerRadius: cornerRadius))
    }

    /// Multi-line text input frame shared by SwiftUI and AppKit editors.
    func kinlogueInputFrame() -> some View {
        kinloguePanel(.card, cornerRadius: KinlogueTheme.Radius.control)
    }

    /// Warm Sanctuary is a light-only palette. Every window root and every
    /// presented sheet or popover opts in, because tint and color scheme set
    /// inside one presentation are not guaranteed to reach another.
    func kinlogueAppearance() -> some View {
        tint(KinlogueTheme.primary)
            .preferredColorScheme(.light)
    }

    /// Sheets share the main window's paper canvas.
    func kinlogueSheetCanvas() -> some View {
        background(KinlogueTheme.surface)
            .kinlogueAppearance()
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
